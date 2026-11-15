# frozen_string_literal: true

require_relative 'lib/redmine_backup'
require_relative 'lib/redmine_backup/homepage_hook'
require_relative 'lib/redmine_backup/platform_service'
require_relative 'lib/redmine_backup/worker_supervisor_service'
require_relative 'lib/redmine_backup/worker_lifecycle_middleware'

Redmine::Plugin.register :redmine_backup_plugin do
  directory File.expand_path(__dir__)
  name 'Redmine Backup'
  author 'Redmine Backup contributors'
  description 'Full PostgreSQL and file backups with verified uploads and configurable retention.'
  version RedmineBackup::VERSION
  url 'https://github.com/KrishnaST/redmine-backup-plugin'
  requires_redmine version_or_higher: '7.0.0'
  settings default: {}, partial: 'backup_admin/plugin_link'
  menu :admin_menu, :redmine_backup, { controller: 'backup_admin', action: 'index' },
       caption: 'Backups', html: { class: 'icon icon-save' }
end

Rails.application.config.filter_parameters += %i[backup client_secret access_token refresh_token password private_key key_passphrase secret_access_key session_token service_account_json certificate_pem device_code user_code assertion client_assertion code state]

Rails.application.config.middleware.use RedmineBackup::WorkerLifecycleMiddleware
Rails.application.config.after_initialize do
  if RedmineBackup::WorkerSupervisorService.web_process?
    RedmineBackup::WorkerSupervisorService.start_for_application(Rails.root)
  end
rescue StandardError
  Rails.logger.error('Redmine backup supervisor unavailable; inspect backup health')
end
