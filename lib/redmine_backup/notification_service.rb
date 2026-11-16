# frozen_string_literal: true

module RedmineBackup
  class NotificationService
    def initialize(config, store)
      @config, @store = config, store
    end

    def recipient_ids
      # Redmine owns these models; membership is re-evaluated on each delivery.
      group_ids = @config['group_ids'].map(&:to_i)
      member_ids = Group.where(id: group_ids, type: 'Group').includes(:users).flat_map { |group| group.users.map(&:id) }
      selected = (@config['user_ids'].map(&:to_i) + member_ids).uniq
      User.active.where(id: selected).select { |user| user.mail.present? }.map(&:id)
    end

    def queue(run, code)
      pending = @store.read('notifications', [])
      key = "#{run['id']}:#{code}"
      return if pending.any? { |item| item['key'] == key }
      history = @store.read('runs', [])
      local = history.select { |entry| entry['captured'] && !entry['local_deleted'] }.max_by { |entry| entry['completed_at'] }
      remote = history.select { |entry| Retention.offsite_satisfied?(entry) }.max_by { |entry| entry['completed_at'] }
      pending << { 'key' => key, 'run_id' => run['id'], 'code' => code, 'at' => Time.now.utc.iso8601,
                   'last_local' => local&.fetch('completed_at'), 'last_remote' => remote&.fetch('completed_at'),
                   'timezone' => @config['timezone'], 'sent_ids' => [], 'attempts' => 0 }
      @store.write('notifications', pending)
    end

    def deliver_pending
      pending = @store.read('notifications', [])
      pending.each do |item|
        next if item['sent_at'] || item['attempts'] >= 5
        next if item['next_attempt_at'] && Time.iso8601(item['next_attempt_at']) > Time.now.utc
        begin
          audience = recipient_ids
          raise Error, 'NO_ALERT_RECIPIENTS' if audience.empty?
          audience.each do |identifier|
            next if item['sent_ids'].include?(identifier)
            RedmineBackupMailer.alert(User.find(identifier), item).deliver_now
            item['sent_ids'] << identifier
            @store.write('notifications', pending)
          end
          item['sent_at'] = Time.now.utc.iso8601
        rescue StandardError
          item['attempts'] += 1
          item['next_attempt_at'] = (Time.now.utc + 60 * (2**item['attempts'])).iso8601
          item['delivery_status'] = 'EMAIL_DELIVERY_FAILED'
        end
        @store.write('notifications', pending.last(1000))
      end
    end
  end
end
