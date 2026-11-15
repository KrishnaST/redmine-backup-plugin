# frozen_string_literal: true

module BackupOauthFlow
  private

  def begin_storage_authorization(runtime, slot)
    raise RedmineBackup::Error, 'INVALID_DESTINATION' unless runtime.config.destinations.key?(slot)
    flow = RedmineBackup::OauthService.new.authorization(runtime.config[slot], redirect_uri: backup_callback_url)
    session[:backup_oauth] = flow.except('url').merge('slot' => slot, 'user_id' => User.current.id)
    redirect_to flow.fetch('url'), allow_other_host: true
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
