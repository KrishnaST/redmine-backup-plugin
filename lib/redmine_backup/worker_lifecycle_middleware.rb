# frozen_string_literal: true

module RedmineBackup
  class WorkerLifecycleMiddleware
    def initialize(application)
      @application = application
    end

    def call(environment)
      begin
        WorkerSupervisorService.start_for_application(Rails.root)
      rescue StandardError
        Rails.logger.error('Redmine backup supervisor unavailable; inspect backup health')
      end
      @application.call(environment)
    end
  end
end
