# frozen_string_literal: true

require_relative 'test_helper'

class ConfigurationTest < BackupTest
  def test_retention_is_configurable_and_coerces_form_integers
    settings = config('local_keep_dates' => '8', 'remote_keep_dates' => '45')
    assert_equal 8, settings['local_keep_dates']
    assert_equal 45, settings.remote_keep('primary')
  end

  def test_destination_retention_override_and_default
    settings = config('remote_keep_dates' => 30, 'primary' => { 'remote_keep_dates' => '12' },
                      'secondary' => { 'enabled' => true, 'mode' => 'redundant', 'provider' => 's3', 'remote_keep_dates' => '' })
    assert_equal 12, settings.remote_keep('primary')
    assert_equal 30, settings.remote_keep('secondary')
  end

  def test_invalid_retention_is_rejected_without_silent_truncation
    [0, -1, '1.5', 'abc', 3651, nil].each do |value|
      assert_raises(RedmineBackup::Error) { config('local_keep_dates' => value) }
      assert_raises(RedmineBackup::Error) { config('remote_keep_dates' => value) }
    end
  end

  def test_optional_secondary_needs_no_configuration
    assert_equal ['primary'], config.destinations.keys
  end

  def test_enabled_secondary_requires_mode_and_provider
    assert_raises(RedmineBackup::Error) { config('secondary' => { 'enabled' => true }) }
    assert_raises(RedmineBackup::Error) { config('secondary' => { 'enabled' => true, 'provider' => 's3' }) }
    assert_equal 2, config('secondary' => { 'enabled' => true, 'provider' => 's3', 'mode' => 'failover' }).destinations.length
  end

  def test_supported_packaging_excludes_seven_zip
    assert_equal 'zip', config('packaging' => 'zip')['packaging']
    assert_raises(RedmineBackup::Error) { config('packaging' => '7z') }
  end

  def test_invalid_schedule_and_zone_are_rejected
    %w[24:00 12:61 5:30 nope].each { |time| assert_raises(RedmineBackup::Error) { config('time' => time) } }
    assert_raises(RedmineBackup::Error) { config('timezone' => 'Not/AZone') }
  end

  def test_retention_lock_requires_a_positive_duration
    assert_raises(RedmineBackup::Error) { config('primary' => { 'retention_lock' => true }) }
    assert_equal 14, config('primary' => { 'retention_lock' => true, 'lock_days' => 14 })['primary']['lock_days']
  end

  def test_destination_identity_excludes_secrets_and_retention_policy
    first = { 'provider' => 's3', 'bucket' => 'example', 'secret_access_key' => 'one', 'remote_keep_dates' => 3 }
    second = first.merge('secret_access_key' => 'two', 'remote_keep_dates' => 40)
    assert_equal RedmineBackup::Configuration.fingerprint(first), RedmineBackup::Configuration.fingerprint(second)
    refute_equal RedmineBackup::Configuration.fingerprint(first), RedmineBackup::Configuration.fingerprint(first.merge('bucket' => 'other'))
  end
end
