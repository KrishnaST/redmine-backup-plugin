# frozen_string_literal: true

require_relative 'lib/redmine_backup'

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

Rails.application.config.filter_parameters += %i[client_secret access_token refresh_token password private_key secret_access_key session_token code state]
