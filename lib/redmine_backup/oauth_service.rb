# frozen_string_literal: true

require 'base64'
require 'uri'

module RedmineBackup
  class OauthService
    def initialize(http: Providers::Http.new)
      @http = http
    end

    def authorization(target, redirect_uri:)
      raise Error, 'OAUTH_PROVIDER_REQUIRED' unless CloudIdentity::PROVIDERS.include?(target['provider'])
      raise Error, 'BROWSER_AUTHENTICATION_REQUIRED' unless CloudIdentity.method(target) == 'oauth2'
      raise Error, 'CLIENT_ID_REQUIRED' if target['client_id'].to_s.empty?
      CloudIdentity.validate!(target)
      validate_redirect!(redirect_uri)
      state, verifier = SecureRandom.urlsafe_base64(32), SecureRandom.urlsafe_base64(48)
      google = CloudIdentity.google?(target)
      form = { client_id: target['client_id'], redirect_uri: redirect_uri, response_type: 'code',
               scope: CloudIdentity.scope(target), state: state,
               code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false),
               code_challenge_method: 'S256', prompt: google ? 'consent select_account' : 'select_account' }
      form[:access_type] = 'offline' if google
      endpoint = google ? 'https://accounts.google.com/o/oauth2/v2/auth' : "https://login.microsoftonline.com/#{CloudIdentity.tenant(target)}/oauth2/v2.0/authorize"
      { 'url' => "#{endpoint}?#{URI.encode_www_form(form)}", 'state' => state, 'verifier' => verifier,
        'created_at' => Time.now.to_i, 'fingerprint' => Configuration.fingerprint(target) }
    end

    def exchange(target, code:, verifier:, redirect_uri:)
      raise Error, 'OAUTH_PROVIDER_REQUIRED' unless CloudIdentity::PROVIDERS.include?(target['provider'])
      raise Error, 'BROWSER_AUTHENTICATION_REQUIRED' unless CloudIdentity.method(target) == 'oauth2'
      validate_redirect!(redirect_uri)
      raise Error, 'INVALID_AUTHORIZATION_RESPONSE' if code.to_s.empty? || verifier.to_s.empty?
      grant = CloudTokenService.new(http: @http).post(target, grant_type: 'authorization_code', code: code,
                                                           redirect_uri: redirect_uri, code_verifier: verifier)
      raise Error, 'OFFLINE_ACCESS_REQUIRED' if grant['refresh_token'].to_s.empty?
      CloudLocationService.new(http: @http).prepare(target.merge(grant).merge('auth_method' => 'oauth2'))
    end

    def connect(target)
      grant = CloudTokenService.new(http: @http).acquire(target, force: CloudIdentity.method(target) != 'imported_token')
      CloudLocationService.new(http: @http).prepare(target.merge(grant))
    end

    private

    def validate_redirect!(value)
      uri = URI(value)
      raise Error, 'HTTPS_CALLBACK_REQUIRED' unless uri.is_a?(URI::HTTPS) && uri.host && !uri.userinfo && !uri.fragment && !uri.query
    end
  end
end
