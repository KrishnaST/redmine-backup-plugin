# frozen_string_literal: true

module RedmineBackup
  class WorkerStoppedException < Exception; end

  class WorkerLoopService
    def self.coordination_directory(root)
      path = File.join(File.expand_path(root), 'tmp', 'redmine-backup-manager')
      raise Error, 'UNSAFE_WORKER_COORDINATION_DIRECTORY' if PlatformService.link?(path)
      FileUtils.mkdir_p(path, mode: 0o700)
      PlatformService.secure_directory!(path)
      path
    end

    def self.with_manager_lock(root)
      File.open(File.join(coordination_directory(root), 'manager.lock'), File::RDWR | File::CREAT, 0o600) do |handle|
        return false unless handle.flock(File::LOCK_EX | File::LOCK_NB)
        begin
          yield
        ensure
          handle.flock(File::LOCK_UN)
        end
      end
      true
    end

    def self.run(once: false, lock_held: false)
      require_relative 'runtime'
      return with_manager_lock(Rails.root) { run(once: once, lock_held: true) } unless lock_held
      loop do
        begin
          Rails.application.executor.wrap do
            runtime = Runtime.new
            Worker.new(runtime).tick
          end
        rescue StandardError
          Rails.logger.error('Redmine backup worker: operation failed; inspect backup health and private storage')
        end
        break if once
        15.times { sleep(1) }
      end
    rescue WorkerStoppedException
      true
    end

    def self.monitor_parent(identifier)
      main = Thread.current
      input = Thread.new { $stdin.read(1); main.raise(WorkerStoppedException) }
      parent = Thread.new do
        loop do
          sleep(2)
          break unless PlatformService.process_alive?(identifier)
        end
        main.raise(WorkerStoppedException)
      end
      [input, parent]
    end
  end
end
