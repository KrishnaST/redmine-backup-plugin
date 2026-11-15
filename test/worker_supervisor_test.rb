# frozen_string_literal: true

require_relative 'test_helper'
require 'rbconfig'

class WorkerSupervisorTest < BackupTest
  def setup
    super
    File.write(File.join(@temporary, 'Gemfile'), "source 'https://rubygems.org'\n")
  end

  def teardown
    @supervisor&.stop
    super
  end

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
    until yield
      raise 'Worker acceptance condition timed out' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep(0.02)
    end
  end

  def test_supervisor_starts_only_once_and_stops_its_child_via_pipe
    @supervisor = RedmineBackup::WorkerSupervisorService.new(root: @temporary, command: [RbConfig.ruby, '-e', 'STDIN.read'], stop_timeout: 3)
    @supervisor.start
    wait_until { @supervisor.pid }
    identifier = @supervisor.pid
    @supervisor.start
    assert_equal identifier, @supervisor.pid
    assert RedmineBackup::PlatformService.process_alive?(identifier)
    @supervisor.stop
    refute RedmineBackup::PlatformService.process_alive?(identifier)
    assert_nil @supervisor.pid
  end

  def test_dead_child_is_restarted_without_an_external_service_manager
    path = File.join(@temporary, 'starts')
    @supervisor = RedmineBackup::WorkerSupervisorService.new(root: @temporary,
      command: [RbConfig.ruby, '-e', 'File.open(ARGV[0], "a") { |file| file.puts("started") }; exit 1', path], restart_delay: 0.01, stop_timeout: 3)
    @supervisor.start
    wait_until { File.file?(path) && File.readlines(path).length >= 2 }
    @supervisor.stop
    assert_operator File.readlines(path).length, :>=, 2
    assert_nil @supervisor.pid
  end

  def test_manager_lease_elects_one_active_worker
    root = @temporary
    entered = false
    assert RedmineBackup::WorkerLoopService.with_manager_lock(root) {
      refute RedmineBackup::WorkerLoopService.with_manager_lock(root) { entered = true }
    }
    refute entered
    assert RedmineBackup::WorkerLoopService.with_manager_lock(root) { entered = true }
    assert entered
  end

  def test_shutdown_does_not_acknowledge_an_interrupted_durable_job
    store = RedmineBackup::Store.new(File.join(@temporary, 'state'))
    runtime = Struct.new(:store, :config).new(store, config)
    worker = RedmineBackup::Worker.new(runtime)
    worker.define_singleton_method(:capture_and_upload) { |_job| raise RedmineBackup::WorkerStoppedException }
    job = { 'id' => 'interrupted', 'kind' => 'backup' }
    store.write('active_job', job)
    assert_raises(RedmineBackup::WorkerStoppedException) { worker.send(:execute, job) }
    assert_equal job, store.read('active_job')
  end

  def test_parent_liveness_monitor_stops_an_orphan_even_with_open_input
    reader, writer = IO.pipe
    script = <<~RUBY
      require ARGV.shift
      require ARGV.shift
      require ARGV.shift
      begin
        monitors = RedmineBackup::WorkerLoopService.monitor_parent(999_999_999)
        sleep 30
      rescue RedmineBackup::WorkerStoppedException
        exit 0
      ensure
        Array(monitors).each { |thread| thread.kill; thread.join }
      end
    RUBY
    root = File.expand_path('../lib', __dir__)
    identifier = Process.spawn(RbConfig.ruby, '-e', script, File.join(root, 'redmine_backup.rb'),
                               File.join(root, 'redmine_backup/platform_service.rb'), File.join(root, 'redmine_backup/worker_loop_service.rb'),
                               in: reader, out: File::NULL, err: File::NULL)
    reader.close
    waiter = Process.detach(identifier)
    assert waiter.join(10), 'Orphan monitor did not stop the child'
    assert waiter.value.success?
  ensure
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
    RedmineBackup::PlatformService.terminate_process(identifier, signal: 'KILL') if identifier && RedmineBackup::PlatformService.process_alive?(identifier)
  end
end
