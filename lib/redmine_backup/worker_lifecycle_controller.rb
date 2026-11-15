# frozen_string_literal: true

module RedmineBackup
  module WorkerLifecycleController
    def self.included(controller)
      controller.before_action :start_redmine_backup_worker
    end

    private

    def start_redmine_backup_worker
      WorkerSupervisorService.start_for_application(Rails.root)
    rescue StandardError
      Rails.logger.error('Redmine backup supervisor unavailable; inspect backup health')
    end
  end
end
