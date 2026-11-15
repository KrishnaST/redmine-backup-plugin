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

  def test_onedrive_resumes_from_acknowledged_offset_without_forwarding_bearer
    target = { 'provider' => 'onedrive' }
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
