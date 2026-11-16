# frozen_string_literal: true

module RedmineBackup
  class Retention
    # Dates, not elapsed age: preserve the newest verified run on each kept date.
    def self.candidates(records, keep_dates)
      raise Error, 'INVALID_RETENTION' unless keep_dates.is_a?(Integer) && keep_dates.positive?
      dates = []
      records.select { |record| record['verified'] == true }
             .sort_by { |record| [Date.iso8601(record.fetch('date')), Time.iso8601(record.fetch('completed_at')), record.fetch('id')] }
             .reverse.reject do |record|
        day = record.fetch('date')
        keep = !dates.include?(day) && dates.length < keep_dates
        dates << day if keep
        keep
      end
    end

    def self.offsite_satisfied?(run)
      statuses = run.fetch('destinations', {})
      primary = statuses.dig('primary', 'verified') == true && !statuses.dig('primary', 'deleted_at')
      secondary = statuses.dig('secondary', 'verified') == true && !statuses.dig('secondary', 'deleted_at')
      case run['secondary_mode']
      when 'redundant' then primary && secondary
      when 'failover' then primary || secondary
      else primary
      end
    end

    def self.local_candidates(runs, keep_dates)
      captured = runs.select { |run| run['captured'] == true && !run['local_deleted'] }
      newest = captured.max_by { |run| Time.iso8601(run.fetch('completed_at')) }
      candidates(captured.map { |run| run.merge('verified' => true) }, keep_dates)
        .select { |run| run != newest && run['id'] != newest&.fetch('id') && offsite_satisfied?(run) }
    end
  end
end
