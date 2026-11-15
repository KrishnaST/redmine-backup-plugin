# frozen_string_literal: true

require_relative 'test_helper'

class ProviderSettingsTest < BackupTest
  def test_unrelated_provider_inputs_and_credentials_are_not_saved
    original = { 'provider' => 'sftp', 'host' => 'old.example.test', 'password' => 'old-secret' }
    result = RedmineBackup::ProviderSettingsService.merge(original, 'provider' => 'google_drive', 'client_id' => 'client', 'host' => 'ignored', 'password' => 'ignored')
    assert_equal 'oauth2', result['auth_method']
    refute result.key?('password')
    refute result.key?('host')
    assert_equal 'client', result['client_id']
  end

  def test_blank_secret_preserves_the_existing_secret_without_trimming
    result = RedmineBackup::ProviderSettingsService.merge({ 'provider' => 'sftp', 'password' => ' spaced secret ', 'auth_method' => 'password' }, 'password' => '')
    assert_equal ' spaced secret ', result['password']
  end

  def test_provider_change_resets_oauth_grant
    original = { 'provider' => 'google_drive', 'client_id' => 'one', 'refresh_token' => 'old', 'access_token' => 'old' }
    result = RedmineBackup::ProviderSettingsService.merge(original, 'provider' => 'onedrive', 'client_id' => 'two')
    refute result.key?('refresh_token')
    refute result.key?('access_token')
  end

  def test_legacy_authentication_is_inferred
    assert_equal 'access_key', RedmineBackup::ProviderSettingsService.authentication('provider' => 's3', 'access_key_id' => 'id')
    assert_equal 'session_token', RedmineBackup::ProviderSettingsService.authentication('provider' => 's3', 'session_token' => 'token')
    assert_equal 'password', RedmineBackup::ProviderSettingsService.authentication('provider' => 'sftp', 'password' => 'secret')
  end

  def test_invalid_authentication_method_is_rejected
    assert_raises(RedmineBackup::Error) { config('primary' => { 'provider' => 's3', 'auth_method' => 'oauth2' }) }
  end

  def test_changing_authentication_mode_discards_previous_user_grant
    original = { 'provider' => 'onedrive', 'auth_method' => 'oauth2', 'client_id' => 'app',
                 'access_token' => 'user-access', 'refresh_token' => 'user-refresh' }
    result = RedmineBackup::ProviderSettingsService.merge(original, 'auth_method' => 'certificate')
    refute result.key?('access_token')
    refute result.key?('refresh_token')
  end

  def test_imported_tokens_are_write_only_preserved_and_explicitly_replaceable
    original = { 'provider' => 'google_drive', 'auth_method' => 'oauth2', 'client_id' => 'app', 'access_token' => 'old' }
    result = RedmineBackup::ProviderSettingsService.merge(original, 'auth_method' => 'imported_token', 'access_token' => 'new', 'expires_at' => '9999999999')
    assert_equal 'new', result['access_token']
    assert_equal '9999999999', result['expires_at']
    result = RedmineBackup::ProviderSettingsService.merge(result, 'access_token' => '', 'expires_at' => '')
    assert_equal 'new', result['access_token']
    assert_equal '9999999999', result['expires_at']
  end

  def test_personal_onedrive_does_not_accept_application_credentials
    result = RedmineBackup::ProviderSettingsService.merge({}, 'provider' => 'onedrive_personal', 'private_key' => 'unexpected', 'tenant_id' => 'other')
    refute result.key?('private_key')
    refute result.key?('tenant_id')
  end

  def test_new_credential_fields_are_private_in_runtime_and_recovery_bootstrap
    require_relative '../lib/redmine_backup/runtime'
    %w[service_account_json certificate_pem private_key password access_token refresh_token].each do |field|
      assert_includes RedmineBackup::Runtime::SECRET_FIELDS, field
    end
  end

  def test_account_type_hint_and_explicit_default_method_preserve_existing_google_grant
    original = { 'provider' => 'google_drive', 'client_id' => 'app', 'refresh_token' => 'private-refresh' }
    result = RedmineBackup::ProviderSettingsService.merge(original, 'auth_method' => 'oauth2', 'account_type' => 'personal')
    assert_equal 'private-refresh', result['refresh_token']
  end

  def test_switching_to_device_code_removes_unneeded_web_secret
    original = { 'provider' => 'onedrive', 'auth_method' => 'oauth2', 'client_id' => 'app', 'client_secret' => 'old-web-secret' }
    result = RedmineBackup::ProviderSettingsService.merge(original, 'auth_method' => 'device_code')
    refute result.key?('client_secret')
  end

  def test_certificate_mode_ignores_password_and_secret_fields
    result = RedmineBackup::ProviderSettingsService.merge({}, 'provider' => 'sharepoint', 'auth_method' => 'certificate',
                                                           'private_key' => 'key', 'certificate_pem' => 'certificate',
                                                           'client_secret' => 'irrelevant', 'password' => 'irrelevant')
    assert_equal 'key', result['private_key']
    refute result.key?('client_secret')
    refute result.key?('password')
  end
end
