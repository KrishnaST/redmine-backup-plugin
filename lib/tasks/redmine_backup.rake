# frozen_string_literal: true

namespace :redmine_backup do
  desc 'Run the durable backup scheduler/worker (one process per installation)'
  task worker: :environment do
    require_relative '../redmine_backup/runtime'
    stopping = false
    Signal.trap('TERM') { stopping = true }
    Signal.trap('INT') { stopping = true }
    until stopping
      begin
        runtime = RedmineBackup::Runtime.new
        RedmineBackup::Worker.new(runtime).tick
      rescue StandardError
        Rails.logger.error('Redmine backup worker: operation failed; inspect backup health and private storage')
      end
      15.times { break if stopping; sleep(1) }
    end
  end
end
