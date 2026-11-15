# frozen_string_literal: true

require_relative 'test_helper'

class HistoryTest < BackupTest
  def setup
    super
    @store = RedmineBackup::Store.new(File.join(@temporary, 'state'))
    @service = RedmineBackup::HistoryService.new(@store)
  end

  def test_cleared_backup_history_preserves_files_retention_and_pending_runs
    complete = run_record('20261115T143000Z-abcdef123456', status: 'complete')
    queued = run_record('20261115T143001Z-abcdef123456', status: 'upload_failed')
    active = run_record('20261115T143002Z-abcdef123456', status: 'uploading')
    @store.write('runs', [complete, queued, active])
    @store.write('queue', [{ 'kind' => 'retry_upload', 'run_id' => queued['id'] }])
    FileUtils.mkdir_p(@store.run_path(complete['id']))
    payload = File.join(@store.run_path(complete['id']), 'database.dump')
    File.write(payload, 'preserved')
    @service.clear!('backups', actor: '7')
    assert_equal [queued['id'], active['id']], @service.visible_runs.map { |run| run['id'] }
    assert_equal 3, @store.read('runs').length
    assert_equal 'preserved', File.read(payload)
    assert_equal 1, @store.read('queue').length
    assert_equal 'backups_history_cleared', @store.read('audit').last['event']
  end

  def test_retried_run_reappears_after_its_result_changes
    run = run_record('20261115T143000Z-abcdef123456', status: 'upload_failed')
    @store.write('runs', [run])
    @service.clear!('backups', actor: '7')
    assert_empty @service.visible_runs
    run['status'] = 'uploading'
    @store.write('runs', [run])
    assert_equal 1, @service.visible_runs.length
    run.merge!('status' => 'complete', 'completed_at' => '2026-11-16T20:00:00+05:30')
    @store.write('runs', [run])
    assert_equal 1, @service.visible_runs.length
  end

  def test_audit_clear_retains_only_the_clearing_event
    @store.audit('previous_event')
    @service.clear!('audit', actor: '7')
    assert_equal ['audit_history_cleared'], @store.read('audit').map { |event| event['event'] }
    assert_equal '7', @store.read('audit').first['actor']
  end

  def test_notification_clear_preserves_partially_delivered_and_pending_alerts
    events = [{ 'key' => 'delivered', 'sent_at' => Time.now.utc.iso8601, 'attempts' => 0 },
              { 'key' => 'exhausted', 'attempts' => 5 }, { 'key' => 'pending', 'attempts' => 0 },
              { 'key' => 'partial', 'attempts' => 2, 'sent_ids' => [7] }]
    @store.write('notifications', events)
    @service.clear!('notifications', actor: '7')
    assert_equal %w[pending partial], @store.read('notifications').map { |event| event['key'] }
    assert_equal [7], @store.read('notifications').last['sent_ids']
  end

  def test_invalid_category_and_busy_worker_cannot_clear_state
    @store.audit('preserved')
    assert_raises(RedmineBackup::Error) { @service.clear!('runs', actor: '7') }
    @store.lock('worker') do
      error = assert_raises(RedmineBackup::Error) { @service.clear!('audit', actor: '7') }
      assert_equal 'WORKER_BUSY_RETRY_HISTORY_CLEAR', error.message
    end
    assert_equal ['preserved'], @store.read('audit').map { |event| event['event'] }
  end
end
