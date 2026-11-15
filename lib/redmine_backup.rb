# frozen_string_literal: true

require 'date'
require 'digest'
require 'fileutils'
require 'json'
require 'securerandom'
require 'time'

module RedmineBackup
  VERSION = '0.3.3'
  class Error < StandardError; end

  def self.load_runtime!
    require_relative 'redmine_backup/configuration'
    require_relative 'redmine_backup/backup_layout'
    require_relative 'redmine_backup/provider_settings_service'
    require_relative 'redmine_backup/store'
    require_relative 'redmine_backup/retention'
    require_relative 'redmine_backup/run_status_service'
    require_relative 'redmine_backup/process_runner'
    require_relative 'redmine_backup/coverage'
    require_relative 'redmine_backup/resources'
    require_relative 'redmine_backup/capture'
    require_relative 'redmine_backup/providers'
    require_relative 'redmine_backup/cloud_identity'
    require_relative 'redmine_backup/private_credential_file_service'
    require_relative 'redmine_backup/jwt_assertion_service'
    require_relative 'redmine_backup/managed_identity_service'
    require_relative 'redmine_backup/cloud_token_service'
    require_relative 'redmine_backup/cloud_location_service'
    require_relative 'redmine_backup/cloud_folder_service'
    require_relative 'redmine_backup/oauth_service'
    require_relative 'redmine_backup/device_authorization_service'
    require_relative 'redmine_backup/device_authorization_session_service'
    require_relative 'redmine_backup/cloud_connection_service'
    require_relative 'redmine_backup/homepage_summary_service'
    require_relative 'redmine_backup/history_service'
    require_relative 'redmine_backup/notification_service'
    require_relative 'redmine_backup/worker'
  end
end
