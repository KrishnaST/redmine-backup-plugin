# frozen_string_literal: true

require_relative 'test_helper'

class StoreTest < BackupTest
  def setup
    super
    @encryptor = ActiveSupport::MessageEncryptor.new('a' * 32, cipher: 'aes-256-gcm', serializer: JSON)
    @store = RedmineBackup::Store.new(File.join(@temporary, 'private'), encryptor: @encryptor)
  end

  def test_control_state_is_encrypted_and_round_trips
    @store.write('secrets', 'password' => 'do-not-publish-this')
    contents = File.binread(File.join(@store.root, 'control', 'secrets.json.enc'))
    refute_includes contents, 'do-not-publish-this'
    assert_equal 'do-not-publish-this', @store.read('secrets')['password']
  end

  def test_wrong_key_fails_closed
    @store.write('secrets', 'token' => 'value')
    other = RedmineBackup::Store.new(@store.root, encryptor: ActiveSupport::MessageEncryptor.new('b' * 32, cipher: 'aes-256-gcm', serializer: JSON))
    assert_raises(ActiveSupport::MessageEncryptor::InvalidMessage) { other.read('secrets') }
  end

  def test_path_traversal_is_rejected
    assert_raises(RedmineBackup::Error) { @store.write('../outside', {}) }
    assert_raises(RedmineBackup::Error) { @store.run_path('../other') }
    assert_raises(RedmineBackup::Error) { @store.atomic(File.join(@temporary, 'outside'), 'data') }
  end

  def test_durable_state_survives_new_store_instance
    @store.write('queue', [{ 'kind' => 'backup' }])
    assert_equal 'backup', RedmineBackup::Store.new(@store.root, encryptor: @encryptor).read('queue').first['kind']
  end

  def test_lock_prevents_second_worker
    blocked = false
    @store.lock('worker') do
      thread = Thread.new { blocked = !@store.lock('worker', nonblock: true) { flunk 'Concurrent worker acquired lock' } }
      thread.join
    end
    assert blocked
    assert @store.lock('worker', nonblock: true) { true }
  end

  def test_audit_has_no_configuration_payload
    @store.audit('settings_changed', actor: '42')
    assert_equal %w[actor at event run], @store.read('audit').first.keys.sort
  end
end
