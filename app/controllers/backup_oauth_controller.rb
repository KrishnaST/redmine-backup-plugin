# frozen_string_literal: true

require_relative '../../lib/redmine_backup/runtime'

class BackupOauthController < ApplicationController
  include BackupOauthFlow
  before_action :require_admin

  def connect
    begin_storage_authorization(RedmineBackup::Runtime.new, params[:slot])
  rescue RedmineBackup::Error => error
    flash[:error] = safe_oauth_error(error)
    redirect_to redmine_backups_path
  end

  def callback
    data = session.delete(:backup_oauth)&.stringify_keys || {}
    supplied = params[:state].to_s
    valid = supplied.present? && data['state'].present? && ActiveSupport::SecurityUtils.secure_compare(supplied, data['state'])
    valid &&= data['user_id'].to_i == User.current.id && Time.now.to_i - data.fetch('created_at').to_i < 600
    raise RedmineBackup::Error, 'INVALID_OR_EXPIRED_OAUTH_STATE' unless valid
    raise RedmineBackup::Error, 'AUTHORIZATION_NOT_GRANTED' if params[:error].present? || params[:code].blank?
    runtime = RedmineBackup::Runtime.new
    raise RedmineBackup::Error, 'RECOVERY_MODE_REQUIRES_ACTIVATION' if runtime.recovery?
    raise RedmineBackup::Error, 'DESTINATION_DISABLED' unless runtime.config.destinations.key?(data.fetch('slot'))
    target = runtime.config[data.fetch('slot')]
    raise RedmineBackup::Error, 'SETTINGS_CHANGED_RECONNECT' unless RedmineBackup::Configuration.fingerprint(target) == data.fetch('fingerprint')
    RedmineBackup::CloudConnectionService.new(runtime, actor: User.current.id.to_s).complete_browser(
      data.fetch('slot'), code: params[:code], verifier: data.fetch('verifier'), redirect_uri: backup_callback_url
    )
    flash[:notice] = 'Storage account connected. A setup check is queued; refresh shortly to see its result.'
    redirect_to redmine_backups_path
  rescue StandardError => error
    flash[:error] = safe_oauth_error(error)
    redirect_to redmine_backups_path
  end

  def device
    runtime = RedmineBackup::Runtime.new
    service = RedmineBackup::DeviceAuthorizationSessionService.new(runtime, user_id: User.current.id)
    render_device_authorization(service.status(session[:backup_device]))
  rescue StandardError => error
    flash[:error] = safe_oauth_error(error)
    redirect_to redmine_backups_path
  end

  def poll_device
    runtime = RedmineBackup::Runtime.new
    service = RedmineBackup::DeviceAuthorizationSessionService.new(runtime, user_id: User.current.id)
    result = service.poll(session[:backup_device])
    return render_device_authorization(result.fetch('display')) unless result['connected']
    session.delete(:backup_device)
    flash[:notice] = 'Microsoft storage account connected. A setup check is queued; refresh shortly to see its result.'
    redirect_to redmine_backups_path
  rescue StandardError => error
    flash[:error] = safe_oauth_error(error)
    redirect_to redmine_backups_path
  end

  private

  def safe_oauth_error(error)
    if error.is_a?(RedmineBackup::Error) && error.message.match?(/\A[A-Z0-9_]+\z/)
      error.message.tr('_', ' ')
    else
      'Storage authorization failed. Check the registered HTTPS callback and provider application settings, then reconnect.'
    end
  end
end
