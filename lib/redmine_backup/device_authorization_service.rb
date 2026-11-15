# frozen_string_literal: true

module RedmineBackup
  class DeviceAuthorizationService
    def initialize(http: Providers::Http.new)
      @http = http
    end

    def start(target, now: Time.now.to_i)
      raise Error, 'MICROSOFT_DEVICE_AUTHENTICATION_REQUIRED' unless CloudIdentity::MICROSOFT.include?(target['provider']) && CloudIdentity.method(target) == 'device_code'
      raise Error, 'CLIENT_ID_REQUIRED' if target['client_id'].to_s.empty?
      endpoint = "https://login.microsoftonline.com/#{CloudIdentity.tenant(target)}/oauth2/v2.0/devicecode"
      data = @http.json!(@http.request('post', endpoint, headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
                                     body: URI.encode_www_form(client_id: target['client_id'], scope: CloudIdentity.scope(target))))
      uri = URI(data.fetch('verification_uri'))
      unless uri.is_a?(URI::HTTPS) && uri.port == 443 && !uri.userinfo && %w[microsoft.com www.microsoft.com login.microsoftonline.com].include?(uri.host)
        raise Error, 'UNTRUSTED_DEVICE_VERIFICATION_URL'
      end
      interval = [Integer(data.fetch('interval', 5)), 5].max
      { 'device_code' => data.fetch('device_code'), 'user_code' => data.fetch('user_code'), 'verification_uri' => uri.to_s,
        'expires_at' => now + Integer(data.fetch('expires_in')), 'interval' => interval,
        'next_poll_at' => now + interval, 'fingerprint' => Configuration.fingerprint(target) }
    end

    def poll(target, pending, now: Time.now.to_i)
      raise Error, 'DEVICE_AUTHORIZATION_EXPIRED' if now >= pending.fetch('expires_at')
      raise Error, 'SETTINGS_CHANGED_RECONNECT' unless pending['fingerprint'] == Configuration.fingerprint(target)
      return pending if pending['grant'] || now < pending['next_poll_at']
      form = { client_id: target.fetch('client_id'), grant_type: 'urn:ietf:params:oauth:grant-type:device_code', device_code: pending.fetch('device_code') }
      response = @http.request('post', CloudIdentity.token_url(target), headers: { 'Content-Type' => 'application/x-www-form-urlencoded' }, body: URI.encode_www_form(form))
      data = JSON.parse(response.body)
      if response.code.to_i == 200
        grant = CloudTokenService.new(http: @http).normalize(data)
        raise Error, 'OFFLINE_ACCESS_REQUIRED' if grant['refresh_token'].to_s.empty?
        pending['grant'] = grant
        pending.delete('device_code')
      elsif %w[authorization_pending slow_down].include?(data['error'])
        pending['interval'] += 5 if data['error'] == 'slow_down'
      else
        raise Error, 'DEVICE_AUTHORIZATION_DENIED_OR_EXPIRED'
      end
      pending['next_poll_at'] = now + pending['interval']
      pending
    rescue JSON::ParserError
      raise Error, 'INVALID_DEVICE_AUTHORIZATION_RESPONSE'
    end
  end
end
