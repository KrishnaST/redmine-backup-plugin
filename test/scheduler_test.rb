# frozen_string_literal: true

require_relative 'test_helper'

class SchedulerTest < BackupTest
  def test_due_after_scheduled_time
    settings = config('enabled' => true)
    slot = RedmineBackup::Scheduler.due_slot(settings, now: Time.iso8601('2026-11-15T15:00:00Z'))
    assert_equal '2026-11-15T14:30:00Z', slot
  end

  def test_outage_produces_only_latest_due_slot
    slot = RedmineBackup::Scheduler.due_slot(config('enabled' => true), now: Time.iso8601('2026-11-15T15:00:00Z'), last_slot: '2026-11-01T14:30:00Z')
    assert_equal '2026-11-15T14:30:00Z', slot
  end

  def test_already_scheduled_slot_is_not_enqueued_again
    assert_nil RedmineBackup::Scheduler.due_slot(config('enabled' => true), now: Time.iso8601('2026-11-15T15:00:00Z'), last_slot: '2026-11-15T14:30:00Z')
  end

  def test_pause_and_recovery_mode_suppress_scheduling
    assert_nil RedmineBackup::Scheduler.due_slot(config, now: Time.now)
    assert_nil RedmineBackup::Scheduler.due_slot(config('enabled' => true, 'recovery_mode' => true), now: Time.now)
  end

  def test_new_installation_does_not_backfill_before_activation
    assert_nil RedmineBackup::Scheduler.due_slot(config('enabled' => true), now: Time.iso8601('2026-11-15T15:00:00Z'), activated_at: '2026-11-15T14:45:00Z')
  end

  def test_dst_timezone_produces_one_actual_slot
    settings = config('enabled' => true, 'timezone' => 'America/New_York', 'time' => '01:30')
    slot = RedmineBackup::Scheduler.due_slot(settings, now: Time.iso8601('2026-11-01T08:00:00Z'))
    assert_nil RedmineBackup::Scheduler.due_slot(settings, now: Time.iso8601('2026-11-01T09:00:00Z'), last_slot: slot)
  end
end
