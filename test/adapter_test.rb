# frozen_string_literal: true

require_relative 'test_helper'
require 'aws-sdk-s3'

class AdapterTest < BackupTest
  class FakeHttp
    attr_reader :requests

    def initialize(responses)
      @responses, @requests = responses, []
    end

    def request(method, url, **options)
      @requests << [method, url, options]
      @responses.shift || raise('Unexpected HTTP request')
    end

    def json!(response, **_options)
      raise RedmineBackup::Error, 'HTTP_FAILED' unless [200, 201, 202].include?(response.code.to_i)
      JSON.parse(response.body)
    end
  end

  def response(code, body = {}, headers = {})
    item = Struct.new(:code, :body, :headers) do
      def [](key)
        headers[key]
      end

      def fetch(key)
        headers.fetch(key)
      end
    end
    item.new(code.to_s, JSON.generate(body), headers)
  end

  def test_google_drive_upload_checkpoints_session_and_returns_reference
    target = { 'provider' => 'google_drive', 'access_token' => 'test-token', 'expires_at' => Time.now.to_i + 3600, 'folder_id' => 'folder' }
    checkpoints = []
    provider = RedmineBackup::Providers::CloudDrive.new(target, checkpoint: ->(key, state) { checkpoints << [key, state] })
    http = FakeHttp.new([response(200, {}, 'location' => 'https://www.googleapis.com/upload/session'), response(200, 'id' => 'file-id')])
    provider.instance_variable_set(:@http, http)
    path = File.join(@temporary, 'data')
    File.binwrite(path, 'payload')
    assert_equal({ 'id' => 'file-id' }, provider.upload(path, 'owned-name'))
    assert_equal 'bytes 0-6/7', http.requests.last[2][:headers]['Content-Range']
    assert_equal({}, checkpoints.last[1])
  end

  def test_cloud_reference_existence_distinguishes_missing_objects_from_permission_errors
    %w[google_drive onedrive onedrive_personal sharepoint].each do |kind|
      provider = RedmineBackup::Providers::CloudDrive.new({ 'provider' => kind, 'drive_id' => 'drive',
        'access_token' => 'fixture', 'expires_at' => Time.now.to_i + 3600 })
      http = FakeHttp.new([response(200, 'id' => 'fixture'), response(404), response(403)])
      http.define_singleton_method(:json!) { |item, **options| RedmineBackup::Providers::Http.new.json!(item, **options) }
      provider.instance_variable_set(:@http, http)
      assert provider.reference_exists?('id' => 'fixture')
      refute provider.reference_exists?('id' => 'fixture')
      error = assert_raises(RedmineBackup::Error) { provider.reference_exists?('id' => 'fixture') }
      assert_equal 'PROVIDER_HTTP_403', error.message
    end
  end

  def test_s3_reference_existence_is_version_specific_and_does_not_hide_access_denied
    client = Aws::S3::Client.new(stub_responses: true, region: 'us-east-1')
    provider = nil
    Aws::S3::Client.stub(:new, client) { provider = RedmineBackup::Providers::S3.new({ 'bucket' => 'fixture' }) }
    reference = { 'key' => 'backup.tar.gz', 'version_id' => 'exact-version' }
    assert provider.reference_exists?(reference)
    assert_equal 'exact-version', client.api_requests.last[:params][:version_id]
    client.stub_responses(:head_object, 'NotFound')
    refute provider.reference_exists?(reference)
    client.stub_responses(:head_object, 'AccessDenied')
    assert_raises(Aws::S3::Errors::AccessDenied) { provider.reference_exists?(reference) }
  end

  def test_sftp_existence_checks_reject_links_and_distinguish_missing_from_permissions
    require 'net/sftp'
    link = false
    code = nil
    attributes = Object.new
    attributes.define_singleton_method(:symlink?) { link }
    session = Object.new
    session.define_singleton_method(:lstat!) do |_path|
      raise Net::SFTP::StatusException.new(Struct.new(:code, :message).new(code, 'fixture')) if code
      attributes
    end
    provider = nil
    Net::SFTP.stub(:start, session) do
      provider = RedmineBackup::Providers::Sftp.new({ 'host' => 'fixture', 'username' => 'fixture',
        'known_hosts' => '/fixture/known_hosts', 'directory' => '/backups', 'auth_method' => 'password', 'password' => 'fixture' })
    end
    assert provider.reference_exists?('path' => '/backups/fixture.tar.gz')
    link = true
    assert_raises(RedmineBackup::Error) { provider.reference_exists?('path' => '/backups/fixture.tar.gz') }
    link, code = false, 2
    refute provider.reference_exists?('path' => '/backups/fixture.tar.gz')
    code = 3
    assert_raises(Net::SFTP::StatusException) { provider.reference_exists?('path' => '/backups/fixture.tar.gz') }
    assert_raises(RedmineBackup::Error) { provider.reference_exists?('path' => '/outside/fixture.tar.gz') }
  end

  def test_google_upload_places_plain_component_name_inside_prepared_backup_folder
    name = 'test-20261115T143000Z-abcdef123456'
    target = { 'provider' => 'google_drive', 'access_token' => 'fixture', 'expires_at' => Time.now.to_i + 3600, 'folder_id' => 'destination' }
    folder = { 'id' => 'backup-folder', 'name' => name, 'mimeType' => 'application/vnd.google-apps.folder', 'parents' => ['destination'] }
    http = FakeHttp.new([response(200, 'files' => []), response(200, folder),
                         response(200, {}, 'location' => 'https://www.googleapis.com/upload/session'), response(200, 'id' => 'payload')])
    provider = RedmineBackup::Providers::CloudDrive.new(target)
    provider.instance_variable_set(:@http, http)
    provider.prepare_run(name)
    path = File.join(@temporary, 'database.dump')
    File.write(path, 'payload')
    reference = provider.upload(path, "#{name}/database.dump")
    metadata = JSON.parse(http.requests[2][2][:body])
    assert_equal 'database.dump', metadata['name']
    assert_equal ['backup-folder'], metadata['parents']
    assert_equal 'backup-folder', reference['folder_id']
    assert_equal name, reference['folder_name']
  end

  def test_cloud_retention_finds_both_nested_completion_markers_and_older_flat_markers
    name = 'test-20261115T143000Z-abcdef123456'
    folder = { 'id' => 'folder', 'name' => name, 'mimeType' => 'application/vnd.google-apps.folder' }
    http = FakeHttp.new([response(200, 'files' => [folder, { 'id' => 'legacy', 'name' => "#{name}-complete.json" },
                                                  { 'id' => 'foreign', 'name' => 'unrelated-folder', 'mimeType' => 'application/vnd.google-apps.folder' }]),
                         response(200, 'files' => [{ 'id' => 'marker', 'name' => 'complete.json' }, { 'id' => 'other', 'name' => 'keep.txt' }])])
    provider = RedmineBackup::Providers::CloudDrive.new({ 'provider' => 'google_drive', 'folder_id' => 'destination', 'access_token' => 'fixture', 'expires_at' => Time.now.to_i + 3600 })
    provider.instance_variable_set(:@http, http)
    references = provider.list_markers('test-')
    assert_equal %w[marker legacy], references.map { |reference| reference['id'] }
    assert_equal 'folder', references.first['folder_id']
    assert_equal 2, http.requests.length
  end

  def test_s3_folder_and_zip_references_remain_inside_exact_configured_prefix
    client = Aws::S3::Client.new(stub_responses: true, region: 'us-east-1')
    provider = nil
    Aws::S3::Client.stub(:new, client) { provider = RedmineBackup::Providers::S3.new({ 'bucket' => 'test', 'prefix' => 'backups' }) }
    namespace = 'test-20261115T143000Z-abcdef123456-'
    folder = namespace.delete_suffix('-')
    provider.assert_reference!({ 'key' => "backups/#{folder}/database.dump" }, namespace)
    provider.assert_reference!({ 'key' => "backups/#{folder}.zip" }, namespace)
    provider.assert_reference!({ 'key' => "backups/#{folder}.tar.gz" }, namespace)
    assert_raises(RedmineBackup::Error) { provider.assert_reference!({ 'key' => "backups/#{folder}-other.tar.gz" }, namespace + 'foreign-') }
    assert_raises(RedmineBackup::Error) { provider.assert_reference!({ 'key' => "#{folder}/database.dump" }, namespace) }
    assert_raises(RedmineBackup::Error) { provider.assert_reference!({ 'key' => "backups/#{folder}/keep.txt" }, namespace) }
    assert_raises(RedmineBackup::Error) { provider.assert_reference!({ 'key' => "backups/#{folder}/../database.dump" }, namespace) }
  end

  def test_sftp_run_folder_creation_and_empty_directory_cleanup_are_scoped
    require 'net/sftp'
    attributes = Object.new
    attributes.define_singleton_method(:directory?) { true }
    attributes.define_singleton_method(:symlink?) { false }
    missing = true
    calls = []
    transport = Object.new
    transport.define_singleton_method(:lstat!) do |_path|
      if missing
        error = Net::SFTP::StatusException.allocate
        error.define_singleton_method(:code) { 2 }
        raise error
      end
      attributes
    end
    transport.define_singleton_method(:mkdir!) { |path, **options| calls << [path, options]; missing = false }
    transport.define_singleton_method(:rmdir!) { |path| calls << [:rmdir, path] }
    provider = RedmineBackup::Providers::Sftp.allocate
    provider.instance_variable_set(:@directory, '/backups')
    provider.instance_variable_set(:@sftp, transport)
    name = 'test-20261115T143000Z-abcdef123456'
    folder = provider.prepare_run(name)
    assert_equal "/backups/#{name}", folder['path']
    assert_equal 0o700, calls.first[1][:permissions]
    provider.delete_folder(folder)
    assert_equal [:rmdir, "/backups/#{name}"], calls.last
    assert_raises(RedmineBackup::Error) { provider.prepare_run('../outside') }
    assert_raises(RedmineBackup::Error) { provider.assert_folder!({ 'name' => name, 'path' => '/other' }, name) }
  end

  def test_onedrive_resumes_from_acknowledged_offset_without_forwarding_bearer
    target = { 'provider' => 'onedrive', 'folder_id' => 'destination' }
    provider = RedmineBackup::Providers::CloudDrive.new(target)
    http = FakeHttp.new([response(200, 'nextExpectedRanges' => ['3-']), response(201, 'id' => 'file-id')])
    provider.instance_variable_set(:@http, http)
    path = File.join(@temporary, 'data')
    File.binwrite(path, 'payload')
    provider.upload(path, 'name', 'url' => 'https://example.up.1drv.com/session')
    assert_equal 'load', http.requests.last[2][:body]
    refute http.requests.last[2][:headers].key?('Authorization')
  end

  def test_oauth_refresh_uses_default_organizations_tenant_and_checkpoints_rotation
    target = { 'provider' => 'onedrive', 'tenant_id' => '', 'client_id' => 'client', 'refresh_token' => 'old', 'folder_id' => 'folder' }
    checkpoints = []
    provider = RedmineBackup::Providers::CloudDrive.new(target, checkpoint: ->(key, state) { checkpoints << [key, state] })
    http = FakeHttp.new([response(200, 'access_token' => 'new', 'refresh_token' => 'rotated', 'expires_in' => 3600),
                         response(200, 'id' => 'drive'), response(200, 'id' => 'folder', 'folder' => {})])
    provider.instance_variable_set(:@http, http)
    provider.health!
    assert_includes http.requests.first[1], '/organizations/'
    assert_equal 'oauth_tokens', checkpoints.first[0]
    assert_equal 'rotated', checkpoints.first[1]['refresh_token']
  end

  def test_s3_multipart_state_and_owned_version_reference
    client = Aws::S3::Client.new(stub_responses: true, region: 'us-east-1')
    client.stub_responses(:create_multipart_upload, upload_id: 'upload-id')
    client.stub_responses(:upload_part, etag: 'part-etag')
    client.stub_responses(:complete_multipart_upload, version_id: 'version-id')
    checkpoints = []
    provider = nil
    Aws::S3::Client.stub(:new, client) do
      provider = RedmineBackup::Providers::S3.new({ 'provider' => 's3', 'bucket' => 'test', 'prefix' => 'backups' }, checkpoint: ->(key, state) { checkpoints << [key, JSON.parse(JSON.generate(state))] })
    end
    path = File.join(@temporary, 'data')
    File.binwrite(path, 'payload')
    reference = provider.upload(path, 'owned-key')
    assert_equal({ 'key' => 'backups/owned-key', 'version_id' => 'version-id' }, reference)
    assert checkpoints.any? { |_key, state| state['upload_id'] == 'upload-id' }
    assert_equal({}, checkpoints.last[1])
  end

  def test_s3_namespace_validation_prevents_foreign_deletion
    client = Aws::S3::Client.new(stub_responses: true, region: 'us-east-1')
    provider = nil
    Aws::S3::Client.stub(:new, client) { provider = RedmineBackup::Providers::S3.new({ 'bucket' => 'test', 'prefix' => 'backups' }) }
    assert_raises(RedmineBackup::Error) { provider.assert_reference!({ 'key' => 'unrelated/object' }, 'installation-') }
  end

  def test_s3_does_not_enable_versioning_or_lock_without_existing_capability
    client = Aws::S3::Client.new(stub_responses: true, region: 'us-east-1')
    provider = nil
    Aws::S3::Client.stub(:new, client) { provider = RedmineBackup::Providers::S3.new({ 'bucket' => 'test', 'versioning' => true }) }
    assert_raises(RedmineBackup::Error) { provider.health! }
    refute client.api_requests.any? { |request| request[:operation_name].to_s.start_with?('put_bucket') }
  end

  def test_s3_authentication_uses_only_selected_credential_method
    %w[sdk_chain access_key session_token].each do |method|
      captured = nil
      factory = ->(**options) { captured = options; Object.new }
      Aws::S3::Client.stub(:new, factory) do
        RedmineBackup::Providers::S3.new({ 'provider' => 's3', 'auth_method' => method, 'bucket' => 'test',
                                         'access_key_id' => 'key', 'secret_access_key' => 'secret', 'session_token' => 'session' })
      end
      if method == 'sdk_chain'
        refute captured.key?(:credentials)
      else
        assert_equal 'key', captured[:credentials].access_key_id
        if method == 'session_token'
          assert_equal 'session', captured[:credentials].session_token
        else
          assert_nil captured[:credentials].session_token
        end
      end
    end
  end

  def test_s3_temporary_method_requires_all_three_credentials
    assert_raises(RedmineBackup::Error) do
      RedmineBackup::Providers::S3.new({ 'provider' => 's3', 'auth_method' => 'session_token', 'bucket' => 'test',
                                       'access_key_id' => 'key', 'secret_access_key' => 'secret' })
    end
  end

  def test_sftp_selects_password_or_private_key_without_falling_back_to_agent
    require 'net/sftp'
    %w[ssh_key password].each do |method|
      captured = nil
      factory = ->(_host, _username, **options) { captured = options; Object.new }
      Net::SFTP.stub(:start, factory) do
        RedmineBackup::Providers::Sftp.new({ 'provider' => 'sftp', 'auth_method' => method, 'host' => 'test.invalid',
                                           'username' => 'backup', 'directory' => '/backups', 'known_hosts' => '/private/known_hosts',
                                           'private_key_path' => '/private/key', 'key_passphrase' => 'phrase', 'password' => 'password' })
      end
      assert_equal :always, captured[:verify_host_key]
      if method == 'ssh_key'
        assert_equal ['publickey'], captured[:auth_methods]
        assert_equal 'phrase', captured[:passphrase]
        assert_equal false, captured[:use_agent]
        refute captured.key?(:password)
      else
        assert_equal ['password'], captured[:auth_methods]
        assert_equal 'password', captured[:password]
        refute captured.key?(:keys)
        refute captured.key?(:passphrase)
      end
    end
  end
end
