# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../lib/redmine_backup/runtime'

class RuntimeTest < BackupTest
  def setup
    super
    @store = RedmineBackup::Store.new(File.join(@temporary, 'state'))
    @runtime = RedmineBackup::Runtime.allocate
    @runtime.instance_variable_set(:@store, @store)
    @runtime.define_singleton_method(:recovery?) { false }
  end

  def test_repeated_manual_clicks_share_pending_request
    3.times { @runtime.enqueue!('backup') }
    assert_equal 1, @store.read('queue').length
  end

  def test_repeated_click_during_active_job_does_not_queue_duplicate
    @store.write('active_job', 'kind' => 'backup', 'id' => 'active')
    @runtime.enqueue!('backup')
    assert_empty @store.read('queue', [])
  end

  def test_recovery_mode_blocks_all_outbound_requests_including_test_mail
    @runtime.define_singleton_method(:recovery?) { true }
    assert_raises(RedmineBackup::Error) { @runtime.enqueue!('test_notification') }
    assert_empty @store.read('queue', [])
  end
end
