# frozen_string_literal: true

require_relative 'test_helper'

class HomepageSummaryTest < BackupTest
  Runtime = Struct.new(:store, :config) do
    def recovery?
      false
    end
  end

  def test_initial_summary_is_clear_and_contains_no_storage_paths_or_credentials
    store = RedmineBackup::Store.new(File.join(@temporary, 'private'))
    summary = RedmineBackup::HomepageSummaryService.call(Runtime.new(store, config))
    assert_equal 'No backup recorded', summary['status']
    assert_equal 'Paused', summary['schedule']
    assert_equal 'Missing or stale', summary['worker']
    refute JSON.generate(summary).include?(store.root)
  end

  def test_latest_failure_does_not_hide_previous_successful_remote_backup
    store = RedmineBackup::Store.new(File.join(@temporary, 'private'))
    store.write('runs', [run_record('good', status: 'complete', completed: '2026-11-14T20:00:00Z'), run_record('failed', status: 'capture_failed', destinations: {}, completed: '2026-11-15T20:00:00Z')])
    store.write('heartbeat', 'at' => '2026-11-15T20:01:00Z')
    summary = RedmineBackup::HomepageSummaryService.call(Runtime.new(store, config), now: Time.iso8601('2026-11-15T20:01:30Z'))
    assert_equal 'Capture failed', summary['status']
    assert_equal '2026-11-14T20:00:00Z', summary['last_remote_at']
    assert_equal 'Healthy', summary['worker']
  end

  def test_running_backup_without_completion_keeps_previous_local_success
    store = RedmineBackup::Store.new(File.join(@temporary, 'private'))
    completed = run_record('good', status: 'complete', completed: '2026-11-14T20:00:00Z').merge('captured' => true)
    store.write('runs', [completed, { 'id' => 'running', 'status' => 'capturing', 'started_at' => '2026-11-15T20:00:00Z' }])
    summary = RedmineBackup::HomepageSummaryService.call(Runtime.new(store, config))
    assert_equal 'Capturing', summary['status']
    assert_equal completed['completed_at'], summary['last_backup_at']
  end
end
