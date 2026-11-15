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
end
