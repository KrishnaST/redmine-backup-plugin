# frozen_string_literal: true

require_relative 'test_helper'

class RunStatusTest < BackupTest
  def test_success_requires_verified_uploads
    run = { 'status' => 'complete', 'destinations' => { 'primary' => { 'verified' => true } } }
    assert_equal 'Upload successful', RedmineBackup::RunStatusService.upload_label(run)
    run['destinations']['primary']['verified'] = false
    assert_equal 'Upload not verified', RedmineBackup::RunStatusService.upload_label(run)
  end

  def test_secondary_success_and_partial_failure_are_distinct
    run = { 'status' => 'failover_used', 'secondary_mode' => 'failover', 'destinations' => { 'secondary' => { 'verified' => true } } }
    assert_equal 'Upload successful (secondary destination)', RedmineBackup::RunStatusService.upload_label(run)
    run['status'] = 'partially_protected'
    assert_equal 'Upload incomplete: a required destination failed', RedmineBackup::RunStatusService.upload_label(run)
  end

  def test_retry_is_available_only_for_failed_uploads
    %w[upload_failed partially_protected].each { |status| assert RedmineBackup::RunStatusService.retryable?('status' => status) }
    %w[complete failover_used capturing packaging captured uploading capture_failed packaging_failed interrupted].each do |status|
      refute RedmineBackup::RunStatusService.retryable?('status' => status)
    end
  end

  def test_capture_failure_is_not_presented_as_an_upload_failure
    assert_equal 'Backup failed; upload not started', RedmineBackup::RunStatusService.upload_label('status' => 'capture_failed')
    assert_equal 'Upload failed', RedmineBackup::RunStatusService.upload_label('status' => 'upload_failed')
    assert_equal 'Upload in progress', RedmineBackup::RunStatusService.upload_label('status' => 'uploading')
  end
end
