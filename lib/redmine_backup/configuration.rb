# frozen_string_literal: true

module RedmineBackup
  class Configuration
    DEFAULTS = {
      'enabled' => false, 'time' => '20:00', 'timezone' => 'Asia/Kolkata',
      'local_directory' => '', 'local_keep_dates' => 3, 'remote_keep_dates' => 10,
      'packaging' => 'separate', 'disk_reserve_mb' => 1024, 'timeout_seconds' => 21_600,
      'pg_bin' => '', 'additional_paths' => [], 'user_ids' => [], 'group_ids' => [],
      'recovery_notifications' => false, 'daily_success_summary' => false,
      'recovery_mode' => false, 'primary' => { 'provider' => 'google_drive' },
      'secondary' => { 'enabled' => false, 'mode' => '', 'provider' => '' }
    }.freeze
    PROVIDERS = %w[google_drive onedrive sftp s3].freeze

    attr_reader :values

    def initialize(values = {})
      @values = JSON.parse(JSON.generate(DEFAULTS)).merge(values.transform_keys(&:to_s))
      %w[primary secondary].each do |slot|
        @values[slot] = DEFAULTS[slot].merge(values.fetch(slot, {}).transform_keys(&:to_s))
      end
    end

    def [](key)
      values.fetch(key.to_s)
    end

    def validate!
      integer!('local_keep_dates', 1, 3650)
      integer!('remote_keep_dates', 1, 3650)
      integer!('disk_reserve_mb', 64, 1_048_576)
      integer!('timeout_seconds', 60, 172_800)
      raise Error, 'INVALID_TIME' unless self['time'].match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)
      raise Error, 'INVALID_PACKAGING' unless %w[separate zip].include?(self['packaging'])
      raise Error, 'INVALID_TIMEZONE' if defined?(ActiveSupport::TimeZone) && !ActiveSupport::TimeZone[self['timezone']]
      destinations.each do |slot, target|
        raise Error, 'INVALID_PROVIDER' unless PROVIDERS.include?(target['provider'])
        if slot == 'secondary' && !%w[redundant failover].include?(target['mode'])
          raise Error, 'SECONDARY_MODE_REQUIRED'
        end
        if target['remote_keep_dates'] && !target['remote_keep_dates'].to_s.empty?
          strict_integer!(target['remote_keep_dates'], 1, 3650)
        end
        if target['retention_lock']
          strict_integer!(target.fetch('lock_days', 0), 1, 3650)
        end
      end
      self
    end

    def destinations
      result = { 'primary' => self['primary'] }
      result['secondary'] = self['secondary'] if self['secondary']['enabled'] == true
      result
    end

    def remote_keep(slot)
      override = self[slot]['remote_keep_dates']
      override.to_s.empty? ? self['remote_keep_dates'].to_i : override.to_i
    end

    def self.fingerprint(target)
      public_target = target.slice(*%w[provider endpoint region bucket prefix host port username directory client_id tenant_id folder_id])
      Digest::SHA256.hexdigest(JSON.generate(public_target.sort.to_h))
    end

    private

    def integer!(key, minimum, maximum)
      values[key] = strict_integer!(values[key], minimum, maximum)
    end

    def strict_integer!(value, minimum, maximum)
      raise Error, 'INVALID_INTEGER' unless value.to_s.match?(/\A\d+\z/)
      number = Integer(value)
      raise Error, 'INTEGER_OUT_OF_RANGE' unless number.between?(minimum, maximum)
      number
    end
  end
end
