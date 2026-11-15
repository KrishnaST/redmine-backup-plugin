# frozen_string_literal: true

# Run only through a disposable Redmine test environment, never production.
raise 'Disposable test database required' unless Rails.env.test? && ActiveRecord::Base.connection_db_config.database.end_with?('_test')

gem 'minitest', '~> 5.25'
ENV['MT_NO_PLUGINS'] = '1'
require 'minitest/autorun'
require 'minitest/mock'
require 'action_dispatch/testing/integration'
require 'tmpdir'

class RedmineBackupIntegrationTest < ActionDispatch::IntegrationTest
  def setup
    @previous_storage = Attachment.storage_path
    @storage = Dir.mktmpdir('redmine-backup-integration-', Rails.root.join('tmp'))
    Attachment.storage_path = @storage
    Setting.plugin_redmine_backup_plugin = {}
    Setting.protocol = 'https'
    Setting.host_name = 'redmine.example.test'
    Setting.mail_from = 'redmine@example.test'
    ActionMailer::Base.delivery_method = :test
    ActionMailer::Base.perform_deliveries = true
    ActionMailer::Base.deliveries.clear
    @admin = User.new(login: "backup-admin-#{SecureRandom.hex(4)}", firstname: 'Backup', lastname: 'Administrator',
                      mail: "backup-#{SecureRandom.hex(4)}@example.test", admin: true, status: User::STATUS_ACTIVE)
    @admin.password = 'IsolatedTestPassword123!'
    @admin.password_confirmation = @admin.password
    @admin.save!
    ActionMailer::Base.deliveries.clear
  end

  def teardown
    RedmineBackup::WorkerSupervisorService.stop_for_application
    @attachment&.destroy
    Attachment.storage_path = @previous_storage
    FileUtils.remove_entry(@storage)
    User.current = nil
  end

  def test_redmine_supervises_its_worker_without_systemd
    runtime = RedmineBackup::Runtime.new
    runtime.save!(runtime.config.values.merge('local_directory' => runtime.store.root), actor: @admin.id.to_s)
    Rails.env.stub(:test?, false) { RedmineBackup::WorkerSupervisorService.start_for_application(Rails.root) }
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 45
    until runtime.store.read('heartbeat')['at']
      raise 'Managed Redmine worker did not start' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep(0.1)
    end
    assert runtime.store.read('heartbeat')['pid'].positive?
    assert_empty runtime.store.read('runs', [])
    RedmineBackup::WorkerSupervisorService.stop_for_application
    assert_empty runtime.store.read('queue', []).reject { |job| job['kind'] == 'health_check' }
  end

  def test_first_controller_request_activates_supervision_after_redmine_loads_plugins
    assert_includes ApplicationController.included_modules, RedmineBackup::WorkerLifecycleController
    requests = []
    RedmineBackup::WorkerSupervisorService.stub(:start_for_application, ->(root) { requests << root.to_s }) do
      host! 'redmine.example.test'
      get '/login'
      assert_response :success
    end
    assert_equal [Rails.root.to_s], requests
  end

  def sign_in
    host! 'redmine.example.test'
    https!
    post '/login', params: { username: @admin.login, password: 'IsolatedTestPassword123!' }
    assert_response :redirect
  end

  def test_admin_menu_and_plugin_registration
    assert_equal RedmineBackup::VERSION, Redmine::Plugin.find(:redmine_backup_plugin).version
    assert_equal '/admin/backups', Rails.application.routes.url_helpers.redmine_backups_path
  end

  def test_production_style_eager_loading_resolves_plugin_namespaces
    Rails.application.eager_load!
    assert_equal 'RedmineBackup::Providers::CloudDrive', RedmineBackup::Providers::CloudDrive.name
    assert_equal 'RedmineBackup::Runtime', RedmineBackup::Runtime.name
  end

  def test_anonymous_user_cannot_read_or_change_backups
    host! 'redmine.example.test'
    get '/admin/backups'
    assert_response :redirect
    post '/admin/backups/actions', params: { kind: 'backup' }
    assert_response :redirect
  end

  def test_admin_can_render_dashboard_and_save_configurable_retention
    sign_in
    get '/admin/backups'
    assert_response :success
    assert_includes response.body, 'Local successful dates to keep'
    post '/admin/backups/settings', params: { backup: { local_keep_dates: '7', remote_keep_dates: '28', time: '21:00', timezone: 'Asia/Kolkata',
                                                      primary: { provider: 'google_drive' }, secondary: { enabled: '0' } } }
    assert_response :redirect
    assert_equal 7, Setting.plugin_redmine_backup_plugin['local_keep_dates']
    assert_equal 28, Setting.plugin_redmine_backup_plugin['remote_keep_dates']
  end

  def test_homepage_summary_is_only_visible_to_administrators
    host! 'redmine.example.test'
    get '/'
    refute_includes response.body, 'redmine-backup-home-status'
    sign_in
    get '/'
    assert_response :success
    assert_includes response.body, 'redmine-backup-home-status'
    assert_includes response.body, 'No backup recorded'
  end

  def test_save_and_connect_starts_google_oauth_without_exposing_secrets
    sign_in
    post '/admin/backups/settings', params: { connect_slot: 'primary', backup: { primary: { provider: 'google_drive', client_id: 'client', client_secret: 'private-secret' } } }
    assert_response :redirect
    assert_includes response.location, 'https://accounts.google.com/'
    assert_includes response.location, 'code_challenge_method=S256'
    refute_includes response.location, 'private-secret'
    refute Setting.plugin_redmine_backup_plugin['primary'].key?('client_secret')
  end

  def test_invalid_oauth_state_cannot_save_a_grant
    sign_in
    get '/admin/backups/oauth/callback', params: { state: 'untrusted', code: 'untrusted' }
    assert_response :redirect
    runtime = RedmineBackup::Runtime.new
    refute runtime.config['primary'].key?('refresh_token')
  end

  def test_runtime_never_merges_credentials_into_redmine_cached_settings
    sign_in
    post '/admin/backups/settings', params: { backup: { primary: { provider: 'google_drive', client_id: 'client', client_secret: 'private-secret' } } }
    runtime = RedmineBackup::Runtime.new
    assert_equal 'private-secret', runtime.config['primary']['client_secret']
    refute_includes Setting.plugin_redmine_backup_plugin.to_json, 'private-secret'
    Setting.clear_cache
    refute_includes Setting.plugin_redmine_backup_plugin.to_json, 'private-secret'
  end

  def test_runtime_refreshes_settings_changed_by_another_process
    Setting.plugin_redmine_backup_plugin = { 'primary' => { 'provider' => 'google_drive', 'client_id' => 'old-app', 'folder_id' => 'old-folder' } }
    RedmineBackup::Runtime.new
    record = Setting.find_by!(name: 'plugin_redmine_backup_plugin')
    record.value = { 'primary' => { 'provider' => 'google_drive', 'client_id' => 'new-app', 'folder_id' => 'new-folder' } }
    record.update_columns(value: record.read_attribute(:value), updated_on: Time.now + 1)
    assert_equal 'old-app', Setting.plugin_redmine_backup_plugin['primary']['client_id']
    fresh = RedmineBackup::Runtime.new
    assert_equal 'new-app', fresh.config['primary']['client_id']
    assert_equal 'new-folder', fresh.config['primary']['folder_id']
  end

  def test_settings_save_discards_health_results_for_previous_configuration
    runtime = RedmineBackup::Runtime.new
    runtime.store.write('setup_health', [{ 'name' => 'Primary destination connection/protection', 'ok' => false }])
    runtime.save!(runtime.config.values, actor: @admin.id.to_s)
    assert_empty runtime.store.read('setup_health', [])
    assert runtime.store.read('queue', []).any? { |job| job['kind'] == 'health_check' }
  end

  def test_storage_reconfiguration_updates_public_private_and_bootstrap_references
    runtime = RedmineBackup::Runtime.new
    runtime.save!(runtime.config.values.merge('primary' => { 'provider' => 'google_drive', 'auth_method' => 'oauth2',
                                                           'client_id' => 'old-client', 'client_secret' => 'private-secret',
                                                           'folder_id' => 'old-folder', 'folder_origin' => 'application',
                                                           'access_token' => 'old-access', 'refresh_token' => 'old-refresh' }), actor: @admin.id.to_s)
    sign_in
    post '/admin/backups/settings', params: { backup: { primary: { provider: 'google_drive', auth_method: 'oauth2',
                                                                  client_id: 'new-client', folder_id: 'old-folder' } } }
    assert_response :redirect
    fresh = RedmineBackup::Runtime.new
    assert_equal 'new-client', fresh.config['primary']['client_id']
    %w[folder_id folder_origin access_token refresh_token].each { |field| refute fresh.config['primary'].key?(field) }
    bootstrap = fresh.store.read('bootstrap')
    assert_equal 'new-client', bootstrap.dig('settings', 'primary', 'client_id')
    refute bootstrap['secrets']['primary'].key?('refresh_token')
    refute Setting.plugin_redmine_backup_plugin['primary'].key?('folder_id')
  end

  def test_administrator_can_clear_histories_without_losing_backup_state_or_pending_alerts
    sign_in
    runtime = RedmineBackup::Runtime.new
    run = { 'id' => '20261115T143000Z-abcdef123456', 'status' => 'complete', 'date' => '2026-11-15',
            'captured' => true, 'completed_at' => '2026-11-15T14:30:00Z', 'destinations' => { 'primary' => { 'verified' => true } } }
    runtime.store.write('runs', [run])
    runtime.store.write('notifications', [{ 'code' => 'DELIVERED', 'sent_at' => Time.now.utc.iso8601 },
                                          { 'code' => 'PENDING', 'attempts' => 0 }])
    post '/admin/backups/history/clear', params: { category: 'backups' }
    assert_response :redirect
    follow_redirect!
    assert_response :success
    refute_includes response.body, run['id']
    assert_equal 1, runtime.store.read('runs').length
    assert_includes response.body, 'Clear backup history'
    assert_includes response.body, 'Clear audit history'
    assert_includes response.body, 'Clear notification history'
    post '/admin/backups/history/clear', params: { category: 'notifications' }
    assert_response :redirect
    assert_equal ['PENDING'], runtime.store.read('notifications').map { |event| event['code'] }
    post '/admin/backups/history/clear', params: { category: 'audit' }
    assert_response :redirect
    assert_equal ['audit_history_cleared'], runtime.store.read('audit').map { |event| event['event'] }
  end

  def test_history_clear_rejects_anonymous_and_nonadministrator_users
    host! 'redmine.example.test'
    runtime = RedmineBackup::Runtime.new
    runtime.store.audit('preserved_event')
    post '/admin/backups/history/clear', params: { category: 'audit' }
    assert_response :redirect
    sign_in
    @admin.update!(admin: false)
    post '/admin/backups/history/clear', params: { category: 'audit' }
    assert_response :forbidden
    assert_equal ['preserved_event'], runtime.store.read('audit').map { |event| event['event'] }
  end

  def test_upload_recovery_queues_fresh_backup_even_without_old_local_payload
    sign_in
    post '/admin/backups/actions', params: { kind: 'retry_upload', run_id: '20261115T143000Z-abcdef123456' }
    assert_response :redirect
    queue = RedmineBackup::Runtime.new.store.read('queue', [])
    assert_equal ['backup'], queue.map { |job| job['kind'] }
    assert_nil queue.first['run_id']
  end

  def test_retry_controls_are_rendered_only_for_the_latest_run
    sign_in
    runtime = RedmineBackup::Runtime.new
    runs = %w[20261115T143000Z-abcdef123456 20261115T143001Z-abcdef123456].map do |identifier|
      { 'id' => identifier, 'status' => 'upload_failed', 'date' => '2026-11-15', 'captured' => true,
        'completed_at' => '2026-11-15T14:30:00Z', 'destinations' => {} }
    end
    runtime.store.write('runs', runs)
    get '/admin/backups'
    assert_response :success
    assert_select 'table.backup-history tbody tr', count: 2
    assert_select 'table.backup-history strong', text: 'Upload failed', count: 2
    assert_select 'table.backup-history tbody tr:first-child input[value="Retry backup"]', count: 1
    assert_select 'input[value="Retry packaging"]', count: 0
    assert_select 'table.backup-history tbody tr:last-child form', count: 0
  end

  def test_successful_upload_is_explicit_and_has_no_retry_button
    sign_in
    runtime = RedmineBackup::Runtime.new
    runtime.store.write('runs', [{ 'id' => '20261115T143000Z-abcdef123456', 'status' => 'complete', 'date' => '2026-11-15',
                                  'captured' => true, 'completed_at' => '2026-11-15T14:30:00Z',
                                  'destinations' => { 'primary' => { 'verified' => true } } }])
    get '/admin/backups'
    assert_response :success
    assert_select 'table.backup-history strong', text: 'Upload successful'
    assert_select 'table.backup-history form', count: 0
  end

  def test_valid_callback_persists_private_grant_and_rejects_replay
    sign_in
    post '/admin/backups/settings', params: { connect_slot: 'primary', backup: { primary: { provider: 'onedrive', client_id: 'client', folder_id: 'folder' } } }
    state = URI.decode_www_form(URI(response.location).query).to_h.fetch('state')
    service = Object.new
    service.define_singleton_method(:exchange) do |target, **options|
      raise 'PKCE verifier missing' if options[:verifier].to_s.empty?
      target.merge('access_token' => 'private-access', 'refresh_token' => 'private-refresh', 'expires_at' => Time.now.to_i + 3600)
    end
    RedmineBackup::OauthService.stub(:new, service) do
      get '/admin/backups/oauth/callback', params: { state: state, code: 'authorized-code' }
    end
    assert_response :redirect
    assert_equal 'private-refresh', RedmineBackup::Runtime.new.config['primary']['refresh_token']
    assert RedmineBackup::Runtime.new.store.read('queue', []).any? { |job| job['kind'] == 'health_check' }
    refute_includes Setting.plugin_redmine_backup_plugin.to_json, 'private-refresh'
    get '/admin/backups/oauth/callback', params: { state: state, code: 'authorized-code' }
    follow_redirect!
    assert_includes response.body, 'INVALID OR EXPIRED OAUTH STATE'
    refute_includes response.body, 'private-refresh'
    assert_select 'div.backup-provider-fields[data-providers~="onedrive"]'
  end

  def test_native_mailer_uses_existing_redmine_delivery
    event = { 'code' => 'TEST_NOTIFICATION', 'run_id' => 'isolated-test', 'at' => Time.now.utc.iso8601 }
    RedmineBackupMailer.alert(@admin, event).deliver_now
    assert_equal 1, ActionMailer::Base.deliveries.length
    message = ActionMailer::Base.deliveries.last
    assert_equal [@admin.mail], message.to
    assert_includes message.html_part.body.decoded, '/admin/backups'
    assert_includes message.text_part.body.decoded, 'TEST NOTIFICATION'
  end

  def test_service_account_configuration_and_certificate_fields_are_never_rendered_back
    assert_includes Rails.application.config.filter_parameters, :backup
    sign_in
    post '/admin/backups/settings', params: { backup: { primary: { provider: 'google_drive', account_type: 'workspace',
                                                                 auth_method: 'service_account', service_account_json: 'private-json-fixture' } } }
    assert_response :redirect
    refute_includes Setting.plugin_redmine_backup_plugin.to_json, 'private-json-fixture'
    assert_equal 'private-json-fixture', RedmineBackup::Runtime.new.config['primary']['service_account_json']
    get '/admin/backups'
    assert_response :success
    assert_includes response.body, 'OneDrive Personal'
    assert_includes response.body, 'SharePoint document library'
    assert_includes response.body, 'Workspace domain-wide delegation'
    refute_includes response.body, 'private-json-fixture'
  end

  def test_device_flow_keeps_device_code_private_and_saves_refresh_grant_once
    sign_in
    service = Object.new
    service.define_singleton_method(:start) do |target|
      { 'device_code' => 'private-device-fixture', 'user_code' => 'PUBLIC-CODE', 'verification_uri' => 'https://microsoft.com/devicelogin',
        'expires_at' => Time.now.to_i + 900, 'interval' => 5, 'next_poll_at' => Time.now.to_i,
        'fingerprint' => RedmineBackup::Configuration.fingerprint(target) }
    end
    service.define_singleton_method(:poll) do |_target, pending|
      pending.merge('grant' => { 'access_token' => 'private-access-fixture', 'refresh_token' => 'private-refresh-fixture', 'expires_at' => Time.now.to_i + 3600 })
    end
    RedmineBackup::DeviceAuthorizationService.stub(:new, service) do
      post '/admin/backups/settings', params: { connect_slot: 'primary', backup: { primary: { provider: 'onedrive_personal',
                                                                                           auth_method: 'device_code', client_id: 'device-app', folder_id: 'folder' } } }
      assert_response :success
      assert_includes response.body, 'PUBLIC-CODE'
      refute_includes response.body, 'private-device-fixture'
      runtime = RedmineBackup::Runtime.new
      encrypted = File.binread(File.join(runtime.store.root, 'control/device_oauth.json.enc'))
      refute_includes encrypted, 'private-device-fixture'
      post '/admin/backups/oauth/device/poll'
    end
    assert_response :redirect
    assert_equal 'private-refresh-fixture', RedmineBackup::Runtime.new.config['primary']['refresh_token']
    refute_includes Setting.plugin_redmine_backup_plugin.to_json, 'private-refresh-fixture'
    post '/admin/backups/oauth/device/poll'
    follow_redirect!
    assert_includes response.body, 'START DEVICE SIGN IN FIRST'
  end

  def test_anonymous_user_cannot_poll_private_device_authorization
    host! 'redmine.example.test'
    post '/admin/backups/oauth/device/poll'
    assert_response :redirect
  end

  def test_real_postgresql_snapshot_dump_and_attachment_capture
    skip 'Set BACKUP_TEST_PG_BIN to compatible PostgreSQL clients' unless ENV['BACKUP_TEST_PG_BIN']
    Attachment.storage_path = File.join(@storage, 'files')
    FileUtils.mkdir_p(Attachment.storage_path)
    application = File.join(@storage, 'application')
    FileUtils.mkdir_p(application)
    File.write(File.join(application, 'Gemfile.lock'), 'isolated fixture application')
    uploaded = File.join(@storage, 'uploaded.txt')
    File.write(uploaded, 'real snapshot attachment')
    @attachment = Attachment.create!(file: Rack::Test::UploadedFile.new(uploaded, 'text/plain'), author: @admin)
    runtime = RedmineBackup::Runtime.new
    configuration = RedmineBackup::Configuration.new('pg_bin' => ENV['BACKUP_TEST_PG_BIN'], 'disk_reserve_mb' => 64).validate!
    run = { 'id' => '20261115T143000Z-abcdef123456', 'date' => '2026-11-15', 'installation_id' => 'isolated-test' }
    capture = RedmineBackup::Capture.new(config: configuration, store: runtime.store, application_root: application,
                                        attachment_root: Attachment.storage_path,
                                        database: ActiveRecord::Base.connection_db_config.configuration_hash,
                                        secret_key: Rails.application.secret_key_base)
    artifacts = capture.call(run)
    assert_equal 5, artifacts.length
    dump = File.join(runtime.store.run_path(run['id']), 'database.dump')
    assert_equal 'PGDMP', File.binread(dump, 5)
    manifest = JSON.parse(File.read(File.join(runtime.store.run_path(run['id']), 'manifest.json')))
    assert manifest['files'].any? { |item| item['attachment_id'].to_i == @attachment.id }
    zip_configuration = RedmineBackup::Configuration.new(configuration.values.merge('packaging' => 'zip')).validate!
    zip_capture = RedmineBackup::Capture.new(config: zip_configuration, store: runtime.store, application_root: application,
                                            attachment_root: Attachment.storage_path,
                                            database: ActiveRecord::Base.connection_db_config.configuration_hash,
                                            secret_key: Rails.application.secret_key_base)
    assert_equal ['backup.zip'], zip_capture.package(run).map { |item| item['name'] }
    folder = RedmineBackup::BackupLayout.folder_name(run)
    Zip::File.open(File.join(runtime.store.run_path(run['id']), 'backup.zip')) do |zip|
      assert_equal 5, zip.entries.length
      assert zip.entries.all? { |entry| entry.name.start_with?(folder + '/') }
      assert_equal run['id'], JSON.parse(zip.read("#{folder}/manifest.json"))['id']
    end
  end
end
