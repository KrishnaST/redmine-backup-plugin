# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../app/controllers/backup_oauth_flow'

class AuthorizationFlowTest < BackupTest
  def test_recovery_mode_blocks_connect_before_configuration_or_network_access
    runtime = Object.new
    runtime.define_singleton_method(:recovery?) { true }
    runtime.define_singleton_method(:config) { raise 'Must not attempt provider access during recovery' }
    controller = Object.new.extend(BackupOauthFlow)
    error = assert_raises(RedmineBackup::Error) { controller.send(:begin_storage_authorization, runtime, 'primary') }
    assert_equal 'RECOVERY_MODE_REQUIRES_ACTIVATION', error.message
  end
end
