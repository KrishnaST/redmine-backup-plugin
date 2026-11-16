# frozen_string_literal: true

module RedmineBackup
  class BackupDeletionPolicy
    TERMINAL_STATUSES = %w[complete failover_used capture_failed packaging_failed upload_failed partially_protected interrupted historical_import].freeze

    def initialize(store)
      @store = store
    end

    def protected_ids(runs)
      protected = []
      successful = runs.select { |run| Retention.offsite_satisfied?(run) }
      protected << newest(successful)&.fetch('id')
      copies = runs.flat_map do |run|
        run.fetch('destinations', {}).filter_map do |slot, state|
          next unless state['verified'] && !state['deleted_at']
          [[slot, Configuration.fingerprint(run.fetch('config', {}).fetch(slot, {}))], run]
        end
      end
      copies.group_by(&:first).each_value { |items| protected << newest(items.map(&:last))&.fetch('id') }
      if protected.compact.empty?
        protected << newest(runs.select { |run| run['captured'] && !run['local_deleted'] })&.fetch('id')
      end
      protected.compact.uniq
    end

    def eligible_ids(runs = @store.read('runs', []))
      protected = protected_ids(runs)
      installation = @store.read('metadata')['installation_id']
      runs.filter_map do |run|
        next unless run['installation_id'] == installation && TERMINAL_STATUSES.include?(run['status'])
        next if protected.include?(run['id']) || run.dig('deletion', 'status') == 'complete'
        next if queued_ids.include?(run['id'])
        @store.run_path(run.fetch('id'))
        run['id']
      end
    end

    def assert_deletable!(run)
      raise Error, 'FOREIGN_BACKUP_INSTALLATION' unless run['installation_id'] == @store.read('metadata')['installation_id']
      raise Error, 'BACKUP_IN_PROGRESS' unless TERMINAL_STATUSES.include?(run['status'])
      raise Error, 'LATEST_SUCCESSFUL_UPLOAD_PROTECTED' if protected_ids(@store.read('runs', [])).include?(run['id'])
      @store.run_path(run.fetch('id'))
    end

    private

    def newest(runs)
      runs.max_by { |run| [Time.iso8601(run.fetch('completed_at')), run.fetch('id')] }
    end

    def queued_ids
      @queued_ids ||= (@store.read('queue', []) + [@store.read('active_job')]).select { |job| job['kind'] == 'delete_backups' }
                        .flat_map { |job| Array(job['run_ids']) }
    end
  end
end
