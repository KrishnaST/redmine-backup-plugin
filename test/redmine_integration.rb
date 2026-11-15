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
    @attachment&.destroy
    Attachment.storage_path = @previous_storage
    FileUtils.remove_entry(@storage)
    User.current = nil
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
    refute_includes Setting.plugin_redmine_backup_plugin.to_json, 'private-refresh'
    get '/admin/backups/oauth/callback', params: { state: state, code: 'authorized-code' }
    follow_redirect!
    assert_includes response.body, 'INVALID OR EXPIRED OAUTH STATE'
    refute_includes response.body, 'private-refresh'
    assert_includes response.body, 'data-providers="onedrive"'
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
  end
end
