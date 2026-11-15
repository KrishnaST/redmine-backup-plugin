# frozen_string_literal: true

namespace :redmine_backup do
  desc 'Run the portable worker manually for diagnostics (Redmine normally manages it)'
  task worker: :environment do
    require_relative '../redmine_backup/runtime'
    require_relative '../redmine_backup/worker_loop_service'
    %w[TERM INT].each do |signal|
      Signal.trap(signal) { Thread.main.raise(RedmineBackup::WorkerStoppedException) } if Signal.list.key?(signal)
    end
    RedmineBackup::WorkerLoopService.run
  end

  desc 'Run one locked worker cycle for diagnostics without an OS scheduler'
  task tick: :environment do
    require_relative '../redmine_backup/runtime'
    require_relative '../redmine_backup/worker_loop_service'
    RedmineBackup::WorkerLoopService.run(once: true)
  end
end
