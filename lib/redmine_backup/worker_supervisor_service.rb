# frozen_string_literal: true

require 'rbconfig'

module RedmineBackup
  class WorkerSupervisorService
    attr_reader :owner_pid

    def self.web_process?
      name = File.basename($PROGRAM_NAME).sub(/\.(?:rb|exe)\z/i, '')
      %w[puma rackup unicorn thin falcon].include?(name) || (name == 'rails' && !!defined?(Rails::Server))
    end

    def self.start_for_application(root)
      return if ENV['REDMINE_BACKUP_WORKER_CHILD'] == '1' || Rails.env.test?
      if @instance && @instance.owner_pid != Process.pid
        return if PlatformService.process_alive?(@instance.owner_pid)
        @instance, @guard = nil, Mutex.new
      end
      @guard ||= Mutex.new
      @guard.synchronize do
        @instance ||= new(root: root)
        @instance.start
        unless @exit_hook_pid == Process.pid
          at_exit { stop_for_application }
          @exit_hook_pid = Process.pid
        end
      end
    end

    def self.stop_for_application
      @instance.stop if @instance && @instance.owner_pid == Process.pid
    end

    def initialize(root:, command: nil, restart_delay: 2, busy_delay: 30, stop_timeout: 10)
      @root, @owner_pid = File.expand_path(root), Process.pid
      @command = command || [RbConfig.ruby, File.expand_path('../../bin/redmine-backup-worker', __dir__), '--managed', "--parent-pid=#{owner_pid}"]
      @restart_delay, @busy_delay, @stop_timeout = restart_delay, busy_delay, stop_timeout
      @mutex, @condition = Mutex.new, ConditionVariable.new
    end

    def start
      @mutex.synchronize do
        return if @thread&.alive?
        @stopping = false
        @thread = Thread.new { supervise }
        @thread.name = 'redmine-backup-supervisor'
      end
    end

    def stop
      thread = @mutex.synchronize do
        @stopping = true
        @input&.close unless @input&.closed?
        @condition.broadcast
        @thread
      end
      return unless thread
      return if thread.join(@stop_timeout)
      identifier = pid
      PlatformService.terminate_process(identifier, signal: 'KILL') if identifier
      thread.join(5)
    rescue Errno::ESRCH
      thread&.join(5)
    end

    def pid
      @mutex.synchronize { @pid }
    end

    private

    def supervise
      loop do
        break if stopping?
        waiter = spawn_worker
        break unless waiter
        waiter.join(1) until stopping? || !waiter.alive?
        if stopping?
          waiter.join(@stop_timeout) || terminate_child
          waiter.join
        end
        status = waiter.value
        @mutex.synchronize do
          @input&.close unless @input&.closed?
          @input, @pid = nil, nil
          break if @stopping
          @condition.wait(@mutex, status.exitstatus == 75 ? @busy_delay : @restart_delay)
        end
      end
    rescue StandardError
      @mutex.synchronize do
        @input&.close unless @input&.closed?
        @input, @pid = nil, nil
        @condition.wait(@mutex, @restart_delay) unless @stopping
      end
      retry unless stopping?
    ensure
      @mutex.synchronize do
        @input&.close unless @input&.closed?
        @input, @pid = nil, nil
      end
    end

    def spawn_worker
      @mutex.synchronize do
        return if @stopping
        reader, writer = IO.pipe
        begin
          options = { chdir: @root, in: reader, out: File::NULL, err: File::NULL, close_others: true }
          options.merge!(PlatformService.windows? ? { new_pgroup: true } : { pgroup: true })
          @pid = Process.spawn({ 'REDMINE_BACKUP_WORKER_CHILD' => '1', 'BUNDLE_GEMFILE' => File.join(@root, 'Gemfile') }, *@command, **options)
          @input = writer
          Process.detach(@pid)
        rescue StandardError
          writer.close
          raise
        ensure
          reader.close
        end
      end
    end

    def terminate_child
      identifier = pid
      PlatformService.terminate_process(identifier, signal: 'KILL') if identifier
    rescue Errno::ESRCH
      nil
    end

    def stopping?
      @mutex.synchronize { @stopping }
    end
  end
end
