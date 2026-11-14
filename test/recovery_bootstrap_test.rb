# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../lib/redmine_backup/recovery_bootstrap'

class RecoveryBootstrapTest < BackupTest
  def test_private_state_is_rebuilt_without_queueing_historical_jobs
    bootstrap = { 'secret_key_base' => 'recovery-test-key', 'config' => config.values,
                  'private_state' => { 'metadata' => { 'installation_id' => 'original-installation' },
                                       'secrets' => { 'primary' => { 'refresh_token' => 'private-token' } },
                                       'runs' => [run_record('old')] } }
    path = File.join(@temporary, 'bootstrap.json')
    File.write(path, JSON.generate(bootstrap))
    store = RedmineBackup::RecoveryBootstrap.restore(path, File.join(@temporary, 'restored'))
    assert_equal 'original-installation', store.read('metadata')['installation_id']
    assert_equal 'private-token', store.read('secrets').dig('primary', 'refresh_token')
    assert store.read('runs').first['local_deleted']
    assert_empty store.read('queue')
    assert File.file?(File.join(store.root, 'control', 'RECOVERY'))
    restored = JSON.parse(File.read(File.join(store.root, 'restored-plugin-settings.json')))
    refute restored['enabled']
    assert restored['recovery_mode']
    assert_raises(RedmineBackup::Error) { RedmineBackup::RecoveryBootstrap.restore(path, store.root) }
  end
end
