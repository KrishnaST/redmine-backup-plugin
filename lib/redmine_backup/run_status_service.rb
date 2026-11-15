# frozen_string_literal: true

module RedmineBackup
  class RunStatusService
    def self.upload_label(run)
      case run['status']
      when 'complete', 'failover_used'
        return 'Upload not verified' unless Retention.offsite_satisfied?(run)
        run['status'] == 'failover_used' ? 'Upload successful (secondary destination)' : 'Upload successful'
      when 'upload_failed' then 'Upload failed'
      when 'partially_protected' then 'Upload incomplete: a required destination failed'
      when 'uploading' then 'Upload in progress'
      when 'capturing' then 'Backup in progress; upload not started'
      when 'packaging' then 'Packaging in progress; upload not started'
      when 'captured' then 'Waiting for upload'
      when 'capture_failed' then 'Backup failed; upload not started'
      when 'packaging_failed' then 'Packaging failed; upload not started'
      when 'interrupted' then 'Interrupted; upload not confirmed'
      else 'Upload status unavailable'
      end
    end

    def self.retryable?(run)
      %w[upload_failed partially_protected].include?(run['status'])
    end
  end
end
