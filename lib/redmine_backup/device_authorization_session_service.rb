# frozen_string_literal: true

module RedmineBackup
  # Keeps device grants out of browser cookies and preserves a completed grant across busy-worker retries.
  class DeviceAuthorizationSessionService
    def initialize(runtime, user_id:, device: DeviceAuthorizationService.new, locations: CloudLocationService.new)
      @runtime, @user_id, @device, @locations = runtime, user_id, device, locations
    end

    def start(slot)
      check_slot!(slot)
      pending = @device.start(@runtime.config[slot]).merge('user_id' => @user_id, 'slot' => slot)
      identifier = SecureRandom.hex(24)
      @runtime.store.lock('device_oauth') do
        flows = @runtime.store.read('device_oauth').reject { |_key, value| value['expires_at'].to_i <= Time.now.to_i }
        flows[identifier] = pending
        @runtime.store.write('device_oauth', flows.to_a.last(50).to_h)
      end
      { 'identifier' => identifier, 'display' => display(pending) }
    end

    def status(identifier)
      display(find!(@runtime.store.read('device_oauth'), identifier))
    end

    def poll(identifier)
      pending = nil
      @runtime.store.lock('device_oauth') do
        flows = @runtime.store.read('device_oauth')
        pending = find!(flows, identifier)
        pending = @device.poll(@runtime.config[pending.fetch('slot')], pending) unless pending['grant']
        flows[identifier] = pending
        @runtime.store.write('device_oauth', flows)
      end
      return { 'connected' => false, 'display' => display(pending) } unless pending['grant']
      slot = pending.fetch('slot')
      connected = pending['connected_target'] || @locations.prepare(@runtime.config[slot].merge(pending['grant']))
      @runtime.store.lock('device_oauth') do
        flows = @runtime.store.read('device_oauth')
        pending = find!(flows, identifier)
        pending['connected_target'] = connected
        flows[identifier] = pending
        @runtime.store.write('device_oauth', flows)
      end
      @runtime.save!(@runtime.config.values.merge(slot => connected), actor: @user_id.to_s)
      @runtime.store.lock('device_oauth') do
        flows = @runtime.store.read('device_oauth')
        flows.delete(identifier)
        @runtime.store.write('device_oauth', flows)
      end
      { 'connected' => true }
    end

    private

    def check_slot!(slot)
      raise Error, 'RECOVERY_MODE_REQUIRES_ACTIVATION' if @runtime.recovery?
      raise Error, 'DESTINATION_DISABLED' unless @runtime.config.destinations.key?(slot)
      raise Error, 'DEVICE_AUTHENTICATION_REQUIRED' unless CloudIdentity.method(@runtime.config[slot]) == 'device_code'
    end

    def find!(flows, identifier)
      pending = flows[identifier.to_s]
      raise Error, 'START_DEVICE_SIGN_IN_FIRST' unless pending && pending['user_id'] == @user_id
      check_slot!(pending.fetch('slot'))
      raise Error, 'DEVICE_AUTHORIZATION_EXPIRED' if pending['expires_at'].to_i <= Time.now.to_i
      unless pending['fingerprint'] == Configuration.fingerprint(@runtime.config[pending.fetch('slot')])
        raise Error, 'SETTINGS_CHANGED_RECONNECT'
      end
      pending
    end

    def display(pending)
      pending.slice('user_code', 'verification_uri', 'expires_at', 'interval', 'slot')
    end
  end
end
