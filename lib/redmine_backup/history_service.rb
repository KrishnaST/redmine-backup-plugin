# frozen_string_literal: true

module RedmineBackup
  class HistoryService
    TERMINAL_STATUSES = %w[complete failover_used capture_failed packaging_failed upload_failed partially_protected interrupted historical_import].freeze
    CATEGORIES = %w[backups audit notifications].freeze

    def initialize(store)
      @store = store
    end

    def visible_runs
      hidden = @store.read('history_visibility')
      @store.read('runs', []).reject do |run|
        TERMINAL_STATUSES.include?(run['status']) && hidden.key?(run['id']) && hidden[run['id']] == run['completed_at']
      end
    end

    def clear!(category, actor:)
      raise Error, 'INVALID_HISTORY_CATEGORY' unless CATEGORIES.include?(category)
      @store.lock('worker', nonblock: true) do
        case category
        when 'backups'
          protected_ids = @store.read('queue', []).map { |job| job['run_id'] }
          protected_ids << @store.read('active_job')['run_id']
          hidden = @store.read('history_visibility')
          @store.read('runs', []).each do |run|
            next unless TERMINAL_STATUSES.include?(run['status']) && !protected_ids.include?(run['id'])
            hidden[run['id']] = run['completed_at']
          end
          @store.write('history_visibility', hidden)
        when 'audit'
          @store.lock('audit') { @store.write('audit', []) }
        when 'notifications'
          pending = @store.read('notifications', []).reject { |event| event['sent_at'] || event['attempts'].to_i >= 5 }
          @store.write('notifications', pending)
        end
        @store.audit("#{category}_history_cleared", actor: actor)
      end || raise(Error, 'WORKER_BUSY_RETRY_HISTORY_CLEAR')
    end
  end
end
