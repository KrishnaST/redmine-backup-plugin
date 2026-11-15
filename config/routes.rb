# frozen_string_literal: true

get 'admin/backups', to: 'backup_admin#index', as: :redmine_backups
post 'admin/backups/settings', to: 'backup_admin#update', as: :redmine_backup_settings
post 'admin/backups/actions', to: 'backup_admin#create', as: :redmine_backup_actions
post 'admin/backups/activate', to: 'backup_admin#activate', as: :redmine_backup_activate
post 'admin/backups/connect/:slot', to: 'backup_oauth#connect', as: :redmine_backup_connect
get 'admin/backups/oauth/callback', to: 'backup_oauth#callback', as: :redmine_backup_oauth_callback
post 'admin/backups/oauth/device/poll', to: 'backup_oauth#poll_device', as: :redmine_backup_device_poll
get 'admin/backups/oauth/device', to: 'backup_oauth#device', as: :redmine_backup_device
