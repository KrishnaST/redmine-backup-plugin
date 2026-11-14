# frozen_string_literal: true

module RedmineBackup
  class Scheduler
    def self.due_slot(config, now:, last_slot: nil, activated_at: nil)
      return nil unless config['enabled'] && !config['recovery_mode']
      zone = ActiveSupport::TimeZone[config['timezone']]
      local = now.in_time_zone(zone)
      hour, minute = config['time'].split(':').map(&:to_i)
      slot = zone.local(local.year, local.month, local.day, hour, minute)
      slot -= 1.day if slot > now
      return nil if last_slot && Time.iso8601(last_slot) >= slot
      return nil if activated_at && Time.iso8601(activated_at) > slot
      slot.utc.iso8601
    end
  end
end
