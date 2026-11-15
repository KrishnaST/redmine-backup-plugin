# frozen_string_literal: true

require_relative 'test_helper'
require 'rbconfig'

class ProcessRunnerTest < BackupTest
  def test_process_streams_output_without_shell_interpolation
    output = File.join(@temporary, 'dump')
    RedmineBackup::ProcessRunner.new(timeout: 5).call([RbConfig.ruby, '-e', "STDOUT.binmode; STDOUT.write('safe-output')"], output: output)
    assert_equal 'safe-output', File.binread(output)
  end

  def test_subprocess_error_body_is_not_exposed
    error = assert_raises(RedmineBackup::Error) do
      RedmineBackup::ProcessRunner.new(timeout: 5).call([RbConfig.ruby, '-e', "STDERR.write('private test content'); exit 7"])
    end
    assert_equal 'TOOL_FAILED', error.message
    refute_includes error.message, 'private'
  end

  def test_timeout_terminates_the_child_process
    error = assert_raises(RedmineBackup::Error) do
      RedmineBackup::ProcessRunner.new(timeout: 0.05).call([RbConfig.ruby, '-e', 'sleep 30'])
    end
    assert_equal 'TOOL_TIMEOUT', error.message
  end

  def test_managed_shutdown_terminates_an_active_dump_subprocess
    pid_file = File.join(@temporary, 'child-pid')
    thread = Thread.new do
      RedmineBackup::ProcessRunner.new(timeout: 30).call([RbConfig.ruby, '-e', 'File.write(ARGV[0], Process.pid); sleep 30', pid_file])
    end
    thread.report_on_exception = false
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
    until File.file?(pid_file)
      raise 'Child startup timed out' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep(0.02)
    end
    identifier = File.read(pid_file).to_i
    thread.raise(RedmineBackup::WorkerStoppedException)
    assert_raises(RedmineBackup::WorkerStoppedException) { thread.value }
    refute RedmineBackup::PlatformService.process_alive?(identifier)
  ensure
    thread&.kill if thread&.alive?
    RedmineBackup::PlatformService.terminate_process(identifier, signal: 'KILL') if identifier && RedmineBackup::PlatformService.process_alive?(identifier)
  end
end
