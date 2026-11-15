# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/cloud_http'

class CloudAuthenticationTest < BackupTest
  TENANT = '11111111-2222-3333-4444-555555555555'

  Http = CloudHttp

  def microsoft(method, **values)
    { 'provider' => 'sharepoint', 'auth_method' => method, 'client_id' => 'application', 'tenant_id' => TENANT,
      'site_id' => 'tenant.sharepoint.com,site,web', 'folder_id' => 'folder' }.merge(values.stringify_keys)
  end

  def success
    { status: 200, data: { 'access_token' => 'access', 'expires_in' => 3600 } }
  end

  def form(http)
    URI.decode_www_form(http.requests.last[2].fetch(:body)).to_h
  end

  def jwt_parts(token)
    token.split('.').first(2).map { |part| JSON.parse(Base64.urlsafe_decode64(part)) }
  end

  def rsa
    @rsa ||= OpenSSL::PKey::RSA.new(2048)
  end

  def service_account
    JSON.generate(type: 'service_account', client_email: 'backup@project.iam.gserviceaccount.com',
                  private_key_id: 'key-id', private_key: rsa.to_pem)
  end

  def certificate
    item = OpenSSL::X509::Certificate.new
    item.version = 2
    item.serial = 1
    item.subject = OpenSSL::X509::Name.parse('/CN=isolated-test')
    item.issuer = item.subject
    item.public_key = rsa.public_key
    item.not_before = Time.now - 60
    item.not_after = Time.now + 3600
    item.sign(rsa, OpenSSL::Digest.new('SHA256'))
    item
  end

  def private_file(name, value)
    path = File.join(@temporary, name)
    File.write(path, value)
    File.chmod(0o600, path)
    path
  end

  def test_google_personal_browser_flow_is_standard_google_oauth
    target = { 'provider' => 'google_drive', 'account_type' => 'personal', 'client_id' => 'personal-app' }
    flow = RedmineBackup::OauthService.new.authorization(target, redirect_uri: 'https://redmine.example.test/admin/backups/oauth/callback')
    assert_includes flow['url'], 'https://accounts.google.com/'
    assert_equal 'offline', URI.decode_www_form(URI(flow['url']).query).to_h['access_type']
  end

  def test_personal_onedrive_uses_consumers_endpoint
    target = { 'provider' => 'onedrive_personal', 'client_id' => 'personal-app' }
    flow = RedmineBackup::OauthService.new.authorization(target, redirect_uri: 'https://redmine.example.test/admin/backups/oauth/callback')
    assert_includes flow['url'], '/consumers/'
    assert_includes flow['url'], 'code_challenge_method=S256'
  end

  def test_personal_and_google_device_method_constraints_are_enforced
    assert_raises(RedmineBackup::Error) { config('primary' => { 'provider' => 'onedrive_personal', 'auth_method' => 'client_secret' }) }
    assert_raises(RedmineBackup::Error) { config('primary' => { 'provider' => 'google_drive', 'auth_method' => 'device_code' }) }
    assert_raises(RedmineBackup::Error) { config('primary' => microsoft('client_secret', tenant_id: 'common')) }
  end

  def test_google_service_account_assertion_is_signed_and_has_no_user_subject
    target = { 'provider' => 'google_drive', 'auth_method' => 'service_account', 'service_account_json' => service_account }
    token = RedmineBackup::JwtAssertionService.google(target)
    header, claims = jwt_parts(token)
    assert_equal 'RS256', header['alg']
    assert_equal 'https://oauth2.googleapis.com/token', claims['aud']
    refute claims.key?('sub')
    assert rsa.public_key.verify('SHA256', Base64.urlsafe_decode64(token.split('.').last), token.split('.').first(2).join('.'))
  end

  def test_workspace_delegation_adds_only_explicit_impersonated_user
    target = { 'provider' => 'google_drive', 'auth_method' => 'domain_delegation', 'service_account_json' => service_account,
               'impersonated_user' => 'backup@example.test' }
    assert_equal 'backup@example.test', jwt_parts(RedmineBackup::JwtAssertionService.google(target)).last['sub']
    target.delete('impersonated_user')
    assert_raises(RedmineBackup::Error) { RedmineBackup::JwtAssertionService.google(target) }
  end

  def test_service_account_renewal_exchanges_signed_jwt_without_client_secret
    http = Http.new(success)
    target = { 'provider' => 'google_drive', 'auth_method' => 'service_account', 'service_account_json' => service_account }
    grant = RedmineBackup::CloudTokenService.new(http: http).acquire(target)
    assert_equal 'access', grant['access_token']
    assert_equal 'urn:ietf:params:oauth:grant-type:jwt-bearer', form(http)['grant_type']
    refute form(http).key?('client_secret')
    assert_includes form(http)['assertion'], '.'
  end

  def test_application_client_secret_uses_default_scope_and_tenant
    http = Http.new(success)
    target = microsoft('client_secret', client_secret: 'private-secret')
    RedmineBackup::CloudTokenService.new(http: http).acquire(target)
    assert_equal 'client_credentials', form(http)['grant_type']
    assert_equal 'https://graph.microsoft.com/.default', form(http)['scope']
    assert_equal 'private-secret', form(http)['client_secret']
    assert_includes http.requests.last[1], TENANT
  end

  def test_certificate_assertion_is_ps256_and_matches_registered_key
    target = microsoft('certificate', certificate_pem: certificate.to_pem, private_key: rsa.to_pem)
    endpoint = RedmineBackup::CloudIdentity.token_url(target)
    token = RedmineBackup::JwtAssertionService.microsoft(target, endpoint: endpoint)
    header, claims = jwt_parts(token)
    assert_equal 'PS256', header['alg']
    assert_equal endpoint, claims['aud']
    assert_equal target['client_id'], claims['sub']
    assert header['x5t#S256']
    assert rsa.public_key.verify_pss('SHA256', Base64.urlsafe_decode64(token.split('.').last), token.split('.').first(2).join('.'), salt_length: :digest, mgf1_hash: 'SHA256')
  end

  def test_certificate_method_posts_assertion_without_secret
    http = Http.new(success)
    target = microsoft('certificate', certificate_pem: certificate.to_pem, private_key: rsa.to_pem)
    RedmineBackup::CloudTokenService.new(http: http).acquire(target)
    assert_equal RedmineBackup::CloudTokenService::ASSERTION_TYPE, form(http)['client_assertion_type']
    refute form(http).key?('client_secret')
  end

  def test_mismatched_certificate_and_private_key_are_rejected
    target = microsoft('certificate', certificate_pem: certificate.to_pem, private_key: OpenSSL::PKey::RSA.new(2048).to_pem)
    assert_raises(RedmineBackup::Error) { RedmineBackup::JwtAssertionService.microsoft(target, endpoint: 'https://example.test/token') }
  end

  def test_workload_identity_rereads_rotated_private_file
    path = private_file('oidc', 'first-assertion')
    http = Http.new(success, success)
    service = RedmineBackup::CloudTokenService.new(http: http)
    target = microsoft('workload_identity', federated_token_path: path)
    service.acquire(target)
    assert_equal 'first-assertion', form(http)['client_assertion']
    File.write(path, 'rotated-assertion')
    service.acquire(target)
    assert_equal 'rotated-assertion', form(http)['client_assertion']
    refute form(http).key?('client_secret')
  end

  def test_obo_uses_upstream_assertion_and_delegated_scope
    http = Http.new(success)
    target = microsoft('on_behalf_of', client_secret: 'secret', user_assertion_path: private_file('assertion', 'upstream-user-token'))
    RedmineBackup::CloudTokenService.new(http: http).acquire(target)
    assert_equal 'on_behalf_of', form(http)['requested_token_use']
    assert_equal 'upstream-user-token', form(http)['assertion']
    assert_includes form(http)['scope'], 'Files.ReadWrite.All'
  end

  def test_legacy_ropc_is_explicit_and_posts_password_only_to_microsoft
    http = Http.new(success)
    target = microsoft('password_grant', username: 'fixture@example.test', password: 'private-password')
    RedmineBackup::CloudTokenService.new(http: http).acquire(target)
    assert_equal 'password', form(http)['grant_type']
    assert_equal 'private-password', form(http)['password']
    assert_equal 'login.microsoftonline.com', URI(http.requests.last[1]).host
  end

  def test_imported_short_lived_token_is_used_until_expiry_then_requires_reconnect
    service = RedmineBackup::CloudTokenService.new(http: Http.new)
    target = microsoft('imported_token', access_token: 'imported', expires_at: Time.now.to_i + 3600)
    assert_equal 'imported', service.acquire(target)['access_token']
    target['expires_at'] = Time.now.to_i - 1
    assert_raises(RedmineBackup::Error) { service.acquire(target) }
  end

  def test_imported_refresh_token_can_renew_offline_access
    http = Http.new(success)
    target = microsoft('imported_token', refresh_token: 'offline-grant')
    result = RedmineBackup::CloudTokenService.new(http: http).acquire(target)
    assert_equal 'refresh_token', form(http)['grant_type']
    assert_equal 'offline-grant', result['refresh_token']
  end

  def test_provider_error_body_is_never_in_exception
    http = Http.new(status: 400, data: { error: 'invalid_client', error_description: 'sensitive-provider-details' })
    error = assert_raises(RedmineBackup::Error) { RedmineBackup::CloudTokenService.new(http: http).acquire(microsoft('client_secret', client_secret: 'secret')) }
    refute_includes error.message, 'sensitive-provider-details'
  end

  def test_managed_identity_imds_has_fixed_resource_and_no_proxy_transport
    request = nil
    transport = ->(uri, headers) { request = [uri, headers]; { 'access_token' => 'managed', 'expires_in' => 3600 } }
    identity = RedmineBackup::ManagedIdentityService.new(environment: {}, transport: transport)
    service = RedmineBackup::CloudTokenService.new(managed_identity: identity)
    assert_equal 'managed', service.acquire(microsoft('managed_identity'))['access_token']
    assert_equal '169.254.169.254', request[0].host
    assert_equal 'true', request[1]['Metadata']
    assert_equal 'https://graph.microsoft.com', URI.decode_www_form(request[0].query).to_h['resource']
  end

  def test_app_service_uses_platform_header_and_rejects_external_endpoint
    request = nil
    transport = ->(uri, headers) { request = [uri, headers]; {} }
    identity = RedmineBackup::ManagedIdentityService.new(environment: { 'IDENTITY_ENDPOINT' => 'http://127.0.0.1:8081/msi/token', 'IDENTITY_HEADER' => 'platform-secret' }, transport: transport)
    identity.acquire({})
    assert_equal 'platform-secret', request[1]['X-IDENTITY-HEADER']
    identity = RedmineBackup::ManagedIdentityService.new(environment: { 'IDENTITY_ENDPOINT' => 'http://external.invalid/token' }, transport: transport)
    assert_raises(RedmineBackup::Error) { identity.acquire({}) }
    identity = RedmineBackup::ManagedIdentityService.new(environment: { 'IDENTITY_ENDPOINT' => 'http://169.254.129.2:8081/msi/token', 'IDENTITY_HEADER' => 'platform-secret' }, transport: transport)
    identity.acquire({})
    assert_equal '169.254.129.2', request[0].hostname
  end

  def test_sharepoint_and_business_application_routes_never_use_me
    assert_includes RedmineBackup::CloudLocationService.graph_base(microsoft('client_secret', drive_id: 'library-id')), '/drives/library-id'
    assert_includes RedmineBackup::CloudLocationService.graph_base(microsoft('client_secret')), '/sites/'
    assert_raises(RedmineBackup::Error) { RedmineBackup::CloudLocationService.graph_base(microsoft('client_secret', site_id: '')) }
  end

  def test_service_account_folder_creation_requires_shared_storage
    target = { 'provider' => 'google_drive', 'auth_method' => 'service_account', 'access_token' => 'token' }
    assert_raises(RedmineBackup::Error) { RedmineBackup::CloudLocationService.new.prepare(target) }
    http = Http.new(status: 200, data: { 'id' => 'created-folder' })
    connected = RedmineBackup::CloudLocationService.new(http: http).prepare(target.merge('shared_drive_id' => 'team-drive'))
    assert_equal 'created-folder', connected['folder_id']
    assert_equal 'application', connected['folder_origin']
    assert_equal ['team-drive'], JSON.parse(http.requests.first[2][:body])['parents']
  end

  def test_imported_token_cannot_inject_header_lines
    target = microsoft('imported_token', access_token: "token\r\nInjected: header", expires_at: Time.now.to_i + 3600)
    assert_raises(RedmineBackup::Error) { RedmineBackup::CloudTokenService.new.acquire(target) }
  end

  def test_sharepoint_upload_and_readback_use_configured_document_library
    target = microsoft('imported_token', drive_id: 'library', access_token: 'access', expires_at: Time.now.to_i + 3600)
    http = Http.new({ status: 200, data: { 'uploadUrl' => 'https://example.up.1drv.com/session' } },
                    { status: 201, data: { 'id' => 'uploaded' } })
    provider = RedmineBackup::Providers::CloudDrive.new(target)
    provider.instance_variable_set(:@http, http)
    path = private_file('payload', 'backup')
    assert_equal({ 'id' => 'uploaded' }, provider.upload(path, 'owned-backup'))
    assert_includes http.requests.first[1], '/drives/library/items/folder:'
    refute_includes http.requests.first[1], '/me/'
    refute http.requests.last[2][:headers].key?('Authorization')
  end

  def test_service_account_health_rejects_personal_drive_folder
    target = { 'provider' => 'google_drive', 'auth_method' => 'service_account', 'folder_id' => 'folder',
               'access_token' => 'access', 'expires_at' => Time.now.to_i + 3600 }
    http = Http.new({ status: 200, data: {} }, { status: 200, data: { mimeType: 'application/vnd.google-apps.folder' } })
    provider = RedmineBackup::Providers::CloudDrive.new(target)
    provider.instance_variable_set(:@http, http)
    error = assert_raises(RedmineBackup::Error) { provider.health! }
    assert_equal 'SERVICE_ACCOUNT_REQUIRES_SHARED_DRIVE_FOLDER', error.message
  end

  def test_device_refresh_never_sends_a_leftover_web_client_secret
    http = Http.new(success)
    target = { 'provider' => 'onedrive_personal', 'auth_method' => 'device_code', 'client_id' => 'public-app',
               'client_secret' => 'leftover', 'refresh_token' => 'refresh' }
    RedmineBackup::CloudTokenService.new(http: http).acquire(target)
    refute form(http).key?('client_secret')
  end

  def test_expired_certificate_cannot_sign_a_fresh_application_assertion
    expired = certificate
    expired.not_before = Time.now - 7200
    expired.not_after = Time.now - 3600
    expired.sign(rsa, OpenSSL::Digest.new('SHA256'))
    target = microsoft('certificate', certificate_pem: expired.to_pem, private_key: rsa.to_pem)
    assert_raises(RedmineBackup::Error) { RedmineBackup::JwtAssertionService.microsoft(target, endpoint: 'https://example.test/token') }
  end

  def test_private_assertion_file_limits_are_enforced
    assert_raises(RedmineBackup::Error) { RedmineBackup::PrivateCredentialFileService.read('') }
    path = private_file('oversized', 'x' * 131_073)
    assert_raises(RedmineBackup::Error) { RedmineBackup::PrivateCredentialFileService.read(path) }
    File.write(path, '')
    assert_raises(RedmineBackup::Error) { RedmineBackup::PrivateCredentialFileService.read(path) }
  end

  def test_connection_health_cannot_pass_with_no_destination_folder
    provider = RedmineBackup::Providers::CloudDrive.new({ 'provider' => 'google_drive', 'auth_method' => 'oauth2' })
    http = Http.new
    provider.instance_variable_set(:@http, http)
    error = assert_raises(RedmineBackup::Error) { provider.health! }
    assert_equal 'DESTINATION_FOLDER_REQUIRED', error.message
    assert_empty http.requests
  end

  def test_reconnecting_reuses_accessible_automatic_folder
    http = Http.new(status: 200, data: { 'id' => 'existing' })
    target = { 'provider' => 'google_drive', 'access_token' => 'access', 'folder_id' => 'existing', 'folder_origin' => 'application' }
    connected = RedmineBackup::CloudLocationService.new(http: http).prepare(target)
    assert_equal 'existing', connected['folder_id']
    assert_equal ['get'], http.requests.map(&:first)
  end

  def test_changed_account_or_deleted_automatic_folder_creates_a_new_binding
    http = Http.new({ status: 404, data: {} }, { status: 200, data: { 'id' => 'replacement' } })
    target = { 'provider' => 'onedrive_personal', 'access_token' => 'access', 'folder_id' => 'old', 'folder_origin' => 'application' }
    connected = RedmineBackup::CloudLocationService.new(http: http).prepare(target)
    assert_equal 'replacement', connected['folder_id']
    assert_equal 'application', connected['folder_origin']
    assert_equal %w[get post], http.requests.map(&:first)
  end

  def test_temporary_provider_errors_do_not_silently_recreate_automatic_folders
    http = Http.new(status: 503, data: {})
    target = { 'provider' => 'google_drive', 'access_token' => 'access', 'folder_id' => 'old', 'folder_origin' => 'application' }
    assert_raises(RedmineBackup::Error) { RedmineBackup::CloudLocationService.new(http: http).prepare(target) }
    assert_equal 1, http.requests.length
  end

  def test_explicit_folder_reference_is_not_replaced_on_sign_in
    http = Http.new
    target = { 'provider' => 'google_drive', 'access_token' => 'access', 'folder_id' => 'explicit' }
    assert_equal 'explicit', RedmineBackup::CloudLocationService.new(http: http).prepare(target)['folder_id']
    assert_empty http.requests
  end
end
