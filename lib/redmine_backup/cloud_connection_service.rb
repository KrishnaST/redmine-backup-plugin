# frozen_string_literal: true

module RedmineBackup
  class CloudConnectionService
    def initialize(runtime, actor:, oauth: OauthService.new, providers: ->(target) { Providers::CloudDrive.new(target) })
      @runtime, @actor, @oauth, @providers = runtime, actor, oauth, providers
    end

    def connect(slot)
      target = target!(slot)
      raise Error, 'USE_INTERACTIVE_STORAGE_SIGN_IN' if %w[oauth2 device_code].include?(CloudIdentity.method(target))
      connected = @oauth.connect(target)
      provider = @providers.call(connected)
      provider.health!
      save(slot, connected)
    ensure
      provider&.close
    end

    def complete_browser(slot, **options)
      connected = @oauth.exchange(target!(slot), **options)
      save(slot, connected)
    end

    private

    def target!(slot)
      raise Error, 'RECOVERY_MODE_REQUIRES_ACTIVATION' if @runtime.recovery?
      raise Error, 'DESTINATION_DISABLED' unless @runtime.config.destinations.key?(slot)
      target = @runtime.config[slot]
      raise Error, 'CLOUD_PROVIDER_REQUIRED' unless CloudIdentity::PROVIDERS.include?(target['provider'])
      target
    end

    def save(slot, connected)
      @runtime.save!(@runtime.config.values.merge(slot => connected), actor: @actor)
      connected
    end
  end
end
