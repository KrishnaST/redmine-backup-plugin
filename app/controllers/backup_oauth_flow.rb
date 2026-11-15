# frozen_string_literal: true

module BackupOauthFlow
  private

  def begin_storage_authorization(runtime, slot)
    raise RedmineBackup::Error, 'RECOVERY_MODE_REQUIRES_ACTIVATION' if runtime.recovery?
    raise RedmineBackup::Error, 'INVALID_DESTINATION' unless runtime.config.destinations.key?(slot)
    target = runtime.config[slot]
    method = RedmineBackup::CloudIdentity.method(target)
    return begin_device_authorization(runtime, slot) if method == 'device_code'
    unless method == 'oauth2'
      RedmineBackup::CloudConnectionService.new(runtime, actor: User.current.id.to_s).connect(slot)
      flash[:notice] = 'Storage credentials verified and saved privately. A setup check is queued; validate a backup before relying on protection.'
      return redirect_to redmine_backups_path
    end
    flow = RedmineBackup::OauthService.new.authorization(target, redirect_uri: backup_callback_url)
    session[:backup_oauth] = flow.except('url').merge('slot' => slot, 'user_id' => User.current.id)
    redirect_to flow.fetch('url'), allow_other_host: true
  end

  def begin_device_authorization(runtime, slot)
    result = RedmineBackup::DeviceAuthorizationSessionService.new(runtime, user_id: User.current.id).start(slot)
    session[:backup_device] = result.fetch('identifier')
    render_device_authorization(result.fetch('display'))
  end

  def render_device_authorization(pending)
    @device = pending.slice('user_code', 'verification_uri', 'expires_at', 'interval', 'slot')
    render template: 'backup_oauth/device'
  end

  def backup_callback_url
    raise RedmineBackup::Error, 'HTTPS_REDMINE_URL_REQUIRED' unless Setting.protocol == 'https'
    uri = URI("https://#{Setting.host_name}")
    raise RedmineBackup::Error, 'INVALID_REDMINE_HOST' unless uri.host && !uri.userinfo && !uri.query && !uri.fragment
    prefix = uri.path.to_s.sub(%r{/+$}, '')
    prefix = Redmine::Utils.relative_url_root if prefix.empty?
    uri.path = "#{prefix}/admin/backups/oauth/callback"
    uri.to_s
  end
end
