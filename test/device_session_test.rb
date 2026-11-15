# frozen_string_literal: true

require_relative 'test_helper'

class DeviceSessionTest < BackupTest
  class Runtime
    attr_accessor :config, :busy, :recovery
    attr_reader :store, :saved

    def initialize(store, configuration)
      @store, @config = store, configuration
    end

    def recovery?
      @recovery == true
    end

    def save!(values, actor:)
      raise RedmineBackup::Error, 'WORKER_BUSY_RETRY_SETTINGS' if @busy
      @saved = { 'values' => values, 'actor' => actor }
      @config = RedmineBackup::Configuration.new(values).validate!
    end
  end

  class Device
    attr_reader :polls

    def initialize
      @polls = 0
    end

    def start(target)
      { 'device_code' => 'private-device', 'user_code' => 'USER-CODE', 'verification_uri' => 'https://microsoft.com/devicelogin',
        'expires_at' => Time.now.to_i + 900, 'interval' => 5, 'fingerprint' => RedmineBackup::Configuration.fingerprint(target) }
    end

    def poll(_target, pending)
      @polls += 1
      pending.merge('grant' => { 'access_token' => 'private-access', 'refresh_token' => 'private-refresh', 'expires_at' => Time.now.to_i + 3600 })
    end
  end

  class Locations
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def prepare(target)
      @calls += 1
      target.merge('folder_id' => 'created-once')
    end
  end

  def setup
    super
    encryptor = ActiveSupport::MessageEncryptor.new(SecureRandom.random_bytes(32), cipher: 'aes-256-gcm', serializer: JSON)
    store = RedmineBackup::Store.new(File.join(@temporary, 'state'), encryptor: encryptor)
    @runtime = Runtime.new(store, config('primary' => { 'provider' => 'onedrive_personal', 'auth_method' => 'device_code', 'client_id' => 'app' }))
    @device, @locations = Device.new, Locations.new
    @service = RedmineBackup::DeviceAuthorizationSessionService.new(@runtime, user_id: 1, device: @device, locations: @locations)
  end

  def test_start_exposes_only_public_display_information_and_encrypts_private_code
    result = @service.start('primary')
    assert_equal 'USER-CODE', result['display']['user_code']
    refute_includes JSON.generate(result), 'private-device'
    encrypted = File.binread(File.join(@runtime.store.root, 'control/device_oauth.json.enc'))
    refute_includes encrypted, 'private-device'
  end

  def test_other_administrator_cannot_read_or_poll_the_pending_grant
    identifier = @service.start('primary')['identifier']
    other = RedmineBackup::DeviceAuthorizationSessionService.new(@runtime, user_id: 2, device: @device, locations: @locations)
    assert_raises(RedmineBackup::Error) { other.status(identifier) }
    assert_raises(RedmineBackup::Error) { other.poll(identifier) }
    assert_equal 0, @device.polls
  end

  def test_completed_grant_and_created_folder_survive_busy_worker_retry_without_reauthorization
    identifier = @service.start('primary')['identifier']
    @runtime.busy = true
    assert_raises(RedmineBackup::Error) { @service.poll(identifier) }
    encrypted = File.binread(File.join(@runtime.store.root, 'control/device_oauth.json.enc'))
    refute_includes encrypted, 'private-refresh'
    assert_equal 'USER-CODE', @service.status(identifier)['user_code']
    @runtime.busy = false
    assert @service.poll(identifier)['connected']
    assert_equal 1, @device.polls
    assert_equal 1, @locations.calls
    assert_equal 'private-refresh', @runtime.saved['values']['primary']['refresh_token']
    assert_equal '1', @runtime.saved['actor']
    assert_raises(RedmineBackup::Error) { @service.poll(identifier) }
  end

  def test_recovery_mode_and_settings_changes_prevent_continuing_device_sign_in
    identifier = @service.start('primary')['identifier']
    @runtime.recovery = true
    assert_raises(RedmineBackup::Error) { @service.poll(identifier) }
    @runtime.recovery = false
    @runtime.config.values['primary']['client_id'] = 'changed'
    assert_raises(RedmineBackup::Error) { @service.poll(identifier) }
    assert_equal 0, @device.polls
  end

  def test_expired_code_cannot_be_resumed
    identifier = @service.start('primary')['identifier']
    flows = @runtime.store.read('device_oauth')
    flows[identifier]['expires_at'] = Time.now.to_i - 1
    @runtime.store.write('device_oauth', flows)
    assert_raises(RedmineBackup::Error) { @service.status(identifier) }
  end
end
