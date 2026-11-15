# frozen_string_literal: true

require_relative 'test_helper'

class OauthServiceTest < BackupTest
  CALLBACK = 'https://redmine.example.test/admin/backups/oauth/callback'

  class Http
    attr_reader :requests

    def initialize(responses)
      @responses, @requests = responses, []
    end

    def request(method, url, **options)
      @requests << [method, url, options]
      Struct.new(:code, :body).new('200', JSON.generate(@responses.shift))
    end

    def json!(response)
      JSON.parse(response.body)
    end
  end

  def test_browser_authorization_uses_pkce_offline_scope_and_state
    target = { 'provider' => 'google_drive', 'client_id' => 'client' }
    flow = RedmineBackup::OauthService.new.authorization(target, redirect_uri: CALLBACK)
    query = URI.decode_www_form(URI(flow['url']).query).to_h
    assert_equal 'S256', query['code_challenge_method']
    assert_equal Base64.urlsafe_encode64(Digest::SHA256.digest(flow['verifier']), padding: false), query['code_challenge']
    assert_equal 'offline', query['access_type']
    assert_equal flow['state'], query['state']
    assert_equal CALLBACK, query['redirect_uri']
    refute flow['url'].include?(flow['verifier'])
  end

  def test_microsoft_authorization_has_tenant_and_delegated_files_scope
    flow = RedmineBackup::OauthService.new.authorization({ 'provider' => 'onedrive', 'client_id' => 'client' }, redirect_uri: CALLBACK)
    assert_includes flow['url'], '/organizations/'
    assert_equal 'offline_access Files.ReadWrite', URI.decode_www_form(URI(flow['url']).query).to_h['scope']
  end

  def test_exchange_passes_verifier_and_confidential_client_secret
    http = Http.new([{ 'access_token' => 'access', 'refresh_token' => 'refresh', 'expires_in' => 3600 }])
    target = { 'provider' => 'google_drive', 'client_id' => 'client', 'client_secret' => 'private', 'folder_id' => 'existing' }
    result = RedmineBackup::OauthService.new(http: http).exchange(target, code: 'code', verifier: 'verifier', redirect_uri: CALLBACK)
    fields = URI.decode_www_form(http.requests.first[2][:body]).to_h
    assert_equal 'verifier', fields['code_verifier']
    assert_equal 'private', fields['client_secret']
    assert_equal 'refresh', result['refresh_token']
    assert_equal 'existing', result['folder_id']
  end

  def test_blank_folder_creates_a_folder_only_after_successful_authorization
    http = Http.new([{ 'access_token' => 'access', 'refresh_token' => 'refresh', 'expires_in' => 3600 }, { 'id' => 'created-folder' }])
    result = RedmineBackup::OauthService.new(http: http).exchange({ 'provider' => 'google_drive', 'client_id' => 'client' }, code: 'code', verifier: 'proof', redirect_uri: CALLBACK)
    assert_equal 'created-folder', result['folder_id']
    assert_equal 'application/vnd.google-apps.folder', JSON.parse(http.requests.last[2][:body])['mimeType']
  end

  def test_no_refresh_grant_does_not_claim_connection_or_create_a_folder
    http = Http.new([{ 'access_token' => 'access', 'expires_in' => 3600 }])
    assert_raises(RedmineBackup::Error) { RedmineBackup::OauthService.new(http: http).exchange({ 'provider' => 'google_drive', 'client_id' => 'client' }, code: 'code', verifier: 'proof', redirect_uri: CALLBACK) }
    assert_equal 1, http.requests.length
  end

  def test_http_callback_and_unconfigured_app_are_rejected
    assert_raises(RedmineBackup::Error) { RedmineBackup::OauthService.new.authorization({ 'provider' => 'google_drive', 'client_id' => 'client' }, redirect_uri: CALLBACK.sub('https:', 'http:')) }
    assert_raises(RedmineBackup::Error) { RedmineBackup::OauthService.new.authorization({ 'provider' => 'google_drive' }, redirect_uri: CALLBACK) }
  end

  def test_token_exchange_rejects_non_oauth_provider
    http = Http.new([])
    assert_raises(RedmineBackup::Error) { RedmineBackup::OauthService.new(http: http).exchange({ 'provider' => 'sftp' }, code: 'code', verifier: 'proof', redirect_uri: CALLBACK) }
    assert_empty http.requests
  end
end
