# frozen_string_literal: true

require 'base64'
require 'uri'

module RedmineBackup
  class OauthService
    def initialize(http: Providers::Http.new)
      @http = http
    end

    def authorization(target, redirect_uri:)
      raise Error, 'OAUTH_PROVIDER_REQUIRED' unless %w[google_drive onedrive].include?(target['provider'])
      raise Error, 'CLIENT_ID_REQUIRED' if target['client_id'].to_s.empty?
      validate_redirect!(redirect_uri)
      state, verifier = SecureRandom.urlsafe_base64(32), SecureRandom.urlsafe_base64(48)
      google = target['provider'] == 'google_drive'
      form = { client_id: target['client_id'], redirect_uri: redirect_uri, response_type: 'code',
               scope: google ? 'https://www.googleapis.com/auth/drive.file' : 'offline_access Files.ReadWrite',
               state: state, code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false),
               code_challenge_method: 'S256', prompt: google ? 'consent select_account' : 'select_account' }
      form[:access_type] = 'offline' if google
      endpoint = google ? 'https://accounts.google.com/o/oauth2/v2/auth' : "https://login.microsoftonline.com/#{tenant(target)}/oauth2/v2.0/authorize"
      { 'url' => "#{endpoint}?#{URI.encode_www_form(form)}", 'state' => state, 'verifier' => verifier,
        'created_at' => Time.now.to_i, 'fingerprint' => Configuration.fingerprint(target) }
    end

    def exchange(target, code:, verifier:, redirect_uri:)
      raise Error, 'OAUTH_PROVIDER_REQUIRED' unless %w[google_drive onedrive].include?(target['provider'])
      validate_redirect!(redirect_uri)
      raise Error, 'INVALID_AUTHORIZATION_RESPONSE' if code.to_s.empty? || verifier.to_s.empty?
      google = target['provider'] == 'google_drive'
      endpoint = google ? 'https://oauth2.googleapis.com/token' : "https://login.microsoftonline.com/#{tenant(target)}/oauth2/v2.0/token"
      form = { client_id: target.fetch('client_id'), grant_type: 'authorization_code', code: code,
               redirect_uri: redirect_uri, code_verifier: verifier }
      form[:client_secret] = target['client_secret'] unless target['client_secret'].to_s.empty?
      response = @http.request('post', endpoint, headers: { 'Content-Type' => 'application/x-www-form-urlencoded' }, body: URI.encode_www_form(form))
      unless [200, 201].include?(response.code.to_i)
        error = JSON.parse(response.body).fetch('error', '') rescue ''
        raise Error, { 'invalid_client' => 'OAUTH_CLIENT_CREDENTIALS_REJECTED', 'invalid_grant' => 'OAUTH_CODE_EXPIRED_RECONNECT' }.fetch(error, 'OAUTH_TOKEN_EXCHANGE_FAILED')
      end
      grant = @http.json!(response)
      refresh = grant.fetch('refresh_token', target['refresh_token'])
      raise Error, 'OFFLINE_ACCESS_REQUIRED' if refresh.to_s.empty?
      connected = target.merge('access_token' => grant.fetch('access_token'), 'refresh_token' => refresh,
                               'expires_at' => Time.now.to_i + Integer(grant.fetch('expires_in')), 'auth_method' => 'oauth2')
      connected['folder_id'] = create_folder(connected) if connected['folder_id'].to_s.empty?
      connected
    end

    private

    def validate_redirect!(value)
      uri = URI(value)
      raise Error, 'HTTPS_CALLBACK_REQUIRED' unless uri.is_a?(URI::HTTPS) && uri.host && !uri.userinfo && !uri.fragment
    end

    def tenant(target)
      value = target['tenant_id'].to_s.empty? ? 'organizations' : target['tenant_id']
      raise Error, 'INVALID_TENANT' unless value.match?(/\A(?:organizations|common|consumers|[a-fA-F0-9-]{36})\z/)
      value
    end

    def create_folder(target)
      google = target['provider'] == 'google_drive'
      url = google ? 'https://www.googleapis.com/drive/v3/files?fields=id' : 'https://graph.microsoft.com/v1.0/me/drive/root/children'
      data = if google
               { name: 'Redmine Backups', mimeType: 'application/vnd.google-apps.folder' }
             else
               { name: 'Redmine Backups', folder: {}, '@microsoft.graph.conflictBehavior' => 'rename' }
             end
      response = @http.request('post', url, headers: { 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{target.fetch('access_token')}" }, body: JSON.generate(data))
      @http.json!(response).fetch('id')
    end
  end
end
