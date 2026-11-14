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
end
