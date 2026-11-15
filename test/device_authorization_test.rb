# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/cloud_http'

class DeviceAuthorizationTest < BackupTest
  def target
    { 'provider' => 'onedrive_personal', 'auth_method' => 'device_code', 'client_id' => 'app' }
  end

  def start_response
    { status: 200, data: { 'device_code' => 'private-device-code', 'user_code' => 'PUBLIC-CODE',
                          'verification_uri' => 'https://microsoft.com/devicelogin', 'expires_in' => 900, 'interval' => 5 } }
  end

  def test_start_uses_consumer_endpoint_and_offline_scope
    http = CloudHttp.new(start_response)
    pending = RedmineBackup::DeviceAuthorizationService.new(http: http).start(target, now: 1000)
    assert_includes http.requests.first[1], '/consumers/'
    assert_includes http.requests.first[2][:body], 'offline_access'
    assert_equal 1900, pending['expires_at']
    assert_equal 'PUBLIC-CODE', pending['user_code']
  end

  def test_poll_respects_interval_and_provider_slow_down
    http = CloudHttp.new(start_response, status: 400, data: { error: 'slow_down' })
    service = RedmineBackup::DeviceAuthorizationService.new(http: http)
    pending = service.start(target, now: 1000)
    service.poll(target, pending, now: 1001)
    assert_equal 1, http.requests.length
    service.poll(target, pending, now: 1005)
    assert_equal 10, pending['interval']
    assert_equal 1015, pending['next_poll_at']
  end

  def test_successful_poll_requires_refresh_grant_and_removes_device_code
    http = CloudHttp.new(start_response, status: 200, data: { access_token: 'private-access', refresh_token: 'private-refresh', expires_in: 3600 })
    service = RedmineBackup::DeviceAuthorizationService.new(http: http)
    pending = service.start(target, now: 1000)
    service.poll(target, pending, now: 1005)
    assert_equal 'private-refresh', pending['grant']['refresh_token']
    refute pending.key?('device_code')
    service.poll(target, pending, now: 1015)
    assert_equal 2, http.requests.length
  end

  def test_expiry_and_changed_configuration_cannot_exchange_tokens
    http = CloudHttp.new(start_response)
    service = RedmineBackup::DeviceAuthorizationService.new(http: http)
    pending = service.start(target, now: 1000)
    assert_raises(RedmineBackup::Error) { service.poll(target, pending, now: 1900) }
    assert_raises(RedmineBackup::Error) { service.poll(target.merge('client_id' => 'other'), pending, now: 1005) }
    assert_equal 1, http.requests.length
  end

  def test_google_device_and_untrusted_verification_link_are_rejected
    assert_raises(RedmineBackup::Error) { RedmineBackup::DeviceAuthorizationService.new.start({ 'provider' => 'google_drive', 'auth_method' => 'device_code' }) }
    response = start_response
    response[:data]['verification_uri'] = 'https://untrusted.invalid/steal-code'
    assert_raises(RedmineBackup::Error) { RedmineBackup::DeviceAuthorizationService.new(http: CloudHttp.new(response)).start(target) }
  end
end
