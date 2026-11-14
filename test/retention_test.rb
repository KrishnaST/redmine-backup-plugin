# frozen_string_literal: true

require_relative 'test_helper'

class RetentionTest < BackupTest
  def test_keep_successful_dates_not_calendar_age
    records = [run_record('new', date: '2026-11-15'), run_record('old', date: '2026-01-01')]
    assert_empty RedmineBackup::Retention.candidates(records, 2)
    assert_equal ['old'], RedmineBackup::Retention.candidates(records, 1).map { |item| item['id'] }
  end

  def test_only_newest_success_on_a_date_counts
    records = [run_record('early', completed: '2026-11-15T10:00:00Z'), run_record('late', completed: '2026-11-15T12:00:00Z')]
    assert_equal ['early'], RedmineBackup::Retention.candidates(records, 3).map { |item| item['id'] }
  end

  def test_completion_offsets_are_compared_as_instants
    records = [run_record('later', completed: '2026-11-15T11:00:00Z'), run_record('earlier', completed: '2026-11-15T15:00:00+05:30')]
    assert_equal ['earlier'], RedmineBackup::Retention.candidates(records, 1).map { |item| item['id'] }
  end

  def test_failures_do_not_displace_good_recovery_points
    records = [run_record('good'), run_record('failed', verified: false, date: '2026-11-16')]
    assert_empty RedmineBackup::Retention.candidates(records, 1)
  end

  def test_invalid_retention_never_deletes_everything
    assert_raises(RedmineBackup::Error) { RedmineBackup::Retention.candidates([run_record('only')], 0) }
  end

  def test_pending_local_copy_is_protected_even_above_limit
    pending = run_record('pending', date: '2026-11-01', destinations: { 'primary' => { 'verified' => false } })
    assert_empty RedmineBackup::Retention.local_candidates([pending, run_record('new')], 1)
  end

  def test_redundant_requires_both_copies
    record = run_record('redundant', secondary_mode: 'redundant')
    refute RedmineBackup::Retention.offsite_satisfied?(record)
    record['destinations']['secondary'] = { 'verified' => true }
    assert RedmineBackup::Retention.offsite_satisfied?(record)
  end

  def test_failover_secondary_verification_is_sufficient
    record = run_record('fallback', secondary_mode: 'failover', destinations: { 'primary' => { 'verified' => false }, 'secondary' => { 'verified' => true } })
    assert RedmineBackup::Retention.offsite_satisfied?(record)
  end

  def test_older_verified_set_can_be_removed_after_new_verified_capture
    old = run_record('old', date: '2026-11-01', completed: '2026-11-01T20:00:00Z')
    assert_equal ['old'], RedmineBackup::Retention.local_candidates([old, run_record('new')], 1).map { |item| item['id'] }
  end
end
