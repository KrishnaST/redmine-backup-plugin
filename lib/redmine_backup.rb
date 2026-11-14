# frozen_string_literal: true

require 'date'
require 'digest'
require 'fileutils'
require 'json'
require 'securerandom'
require 'time'

module RedmineBackup
  VERSION = '0.1.0'
  class Error < StandardError; end

  def self.load_runtime!
    require_relative 'redmine_backup/configuration'
    require_relative 'redmine_backup/store'
    require_relative 'redmine_backup/retention'
    require_relative 'redmine_backup/process_runner'
    require_relative 'redmine_backup/coverage'
    require_relative 'redmine_backup/resources'
    require_relative 'redmine_backup/capture'
    require_relative 'redmine_backup/providers'
    require_relative 'redmine_backup/notification_service'
    require_relative 'redmine_backup/worker'
  end
end
