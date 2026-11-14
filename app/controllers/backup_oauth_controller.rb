# frozen_string_literal: true

require_relative '../../lib/redmine_backup/runtime'

class BackupOauthController < ApplicationController
  before_action :require_admin

  def connect
    runtime = RedmineBackup::Runtime.new
    slot = params[:slot]
    raise RedmineBackup::Error, 'INVALID_DESTINATION' unless runtime.config.destinations.key?(slot)
    target = runtime.config[slot]
    provider = target['provider']
    raise RedmineBackup::Error, 'OAUTH_PROVIDER_REQUIRED' unless %w[google_drive onedrive].include?(provider)
    raise RedmineBackup::Error, 'CLIENT_ID_REQUIRED' if target['client_id'].to_s.empty?
    state, verifier = SecureRandom.urlsafe_base64(32), SecureRandom.urlsafe_base64(48)
    session[:backup_oauth] = { state: state, verifier: verifier, slot: slot, created_at: Time.now.to_i,
                              fingerprint: RedmineBackup::Configuration.fingerprint(target) }
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    callback = callback_url
    scope = provider == 'google_drive' ? 'https://www.googleapis.com/auth/drive.file' : 'offline_access Files.ReadWrite'
    arguments = { client_id: target['client_id'], redirect_uri: callback, response_type: 'code', scope: scope,
                  state: state, code_challenge: challenge, code_challenge_method: 'S256' }
    arguments.merge!(access_type: 'offline', prompt: 'consent') if provider == 'google_drive'
    endpoint = provider == 'google_drive' ? 'https://accounts.google.com/o/oauth2/v2/auth' : "https://login.microsoftonline.com/#{tenant(target)}/oauth2/v2.0/authorize"
    redirect_to "#{endpoint}?#{URI.encode_www_form(arguments)}", allow_other_host: true
  rescue StandardError
    flash[:error] = 'Unable to start provider authorization. Save the provider application settings first.'
    redirect_to redmine_backups_path
  end

  def callback
    data = session.delete(:backup_oauth)&.stringify_keys || {}
    supplied = params[:state].to_s
    valid = supplied.present? && data['state'].present? && ActiveSupport::SecurityUtils.secure_compare(supplied, data['state'])
    raise RedmineBackup::Error, 'INVALID_OAUTH_STATE' unless valid && Time.now.to_i - data.fetch('created_at').to_i < 600
    raise RedmineBackup::Error, 'AUTHORIZATION_NOT_GRANTED' if params[:error].present? || params[:code].blank?
    runtime = RedmineBackup::Runtime.new
    target = runtime.config[data.fetch('slot')]
    raise RedmineBackup::Error, 'SETTINGS_CHANGED_RECONNECT' unless RedmineBackup::Configuration.fingerprint(target) == data.fetch('fingerprint')
    google = target['provider'] == 'google_drive'
    endpoint = google ? 'https://oauth2.googleapis.com/token' : "https://login.microsoftonline.com/#{tenant(target)}/oauth2/v2.0/token"
    form = { client_id: target.fetch('client_id'), grant_type: 'authorization_code', code: params[:code],
             redirect_uri: callback_url, code_verifier: data.fetch('verifier') }
    form[:client_secret] = target['client_secret'] if target['client_secret'].present?
    http = RedmineBackup::Providers::Http.new
    response = http.json!(http.request('post', endpoint, headers: { 'Content-Type' => 'application/x-www-form-urlencoded' }, body: URI.encode_www_form(form)))
    raise RedmineBackup::Error, 'OFFLINE_ACCESS_REQUIRED' if response['refresh_token'].blank?
    values = runtime.config.values
    values[data['slot']].merge!(response.slice('access_token', 'refresh_token'))
    values[data['slot']]['expires_at'] = Time.now.to_i + response.fetch('expires_in').to_i
    runtime.save!(values, actor: User.current.id.to_s)
    flash[:notice] = 'Storage provider connected.'
    redirect_to redmine_backups_path
  rescue StandardError
    flash[:error] = 'Storage authorization did not complete. Check application permissions and the registered callback URL, then reconnect.'
    redirect_to redmine_backups_path
  end

  private

  def callback_url
    raise RedmineBackup::Error, 'HTTPS_REDMINE_URL_REQUIRED' unless Setting.protocol == 'https'
    "https://#{Setting.host_name}#{Redmine::Utils.relative_url_root}/admin/backups/oauth/callback"
  end

  def tenant(target)
    value = target.fetch('tenant_id', 'organizations').presence || 'organizations'
    raise RedmineBackup::Error, 'INVALID_TENANT' unless value.match?(/\A(?:organizations|common|consumers|[a-fA-F0-9-]{36})\z/)
    value
  end
end
