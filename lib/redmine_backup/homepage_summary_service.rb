# frozen_string_literal: true

module RedmineBackup
  class HomepageSummaryService
    def self.call(runtime, now: Time.now.utc)
      records = runtime.store.read('runs', [])
      latest = records.max_by { |record| Time.iso8601(record['started_at'] || record.fetch('completed_at')) }
      local = records.select { |record| record['captured'] && !record['local_deleted'] && record['completed_at'] }
                     .max_by { |record| Time.iso8601(record.fetch('completed_at')) }
      remote = records.select { |record| Retention.offsite_satisfied?(record) }
                      .max_by { |record| Time.iso8601(record.fetch('completed_at')) }
      heartbeat = runtime.store.read('heartbeat')['at']
      {
        'status' => latest ? (latest['deletion'] ? RunStatusService.upload_label(latest) : latest.fetch('status').tr('_', ' ').capitalize) : 'No backup recorded',
        'last_backup_at' => local && local['completed_at'],
        'last_remote_at' => remote && remote['completed_at'],
        'schedule' => runtime.config['enabled'] ? "#{runtime.config['time']} #{runtime.config['timezone']}" : 'Paused',
        'worker' => heartbeat && Time.iso8601(heartbeat) > now - 120 ? 'Healthy' : 'Missing or stale',
        'recovery' => runtime.recovery?
      }
    end
  end
end
