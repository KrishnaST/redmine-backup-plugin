# frozen_string_literal: true

require 'open3'

module RedmineBackup
  class Resources
    def initialize(root:, reserve_mb:, timeout_seconds:)
      @root, @reserve = root, Integer(reserve_mb) * 1024 * 1024
      @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
    end

    def check!(required_bytes = 0)
      raise Error, 'CAPTURE_TIMEOUT' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > @deadline
      result, status = Open3.capture2('df', '-Pk', @root, err: File::NULL)
      raise Error, 'DISK_SPACE_CHECK_FAILED' unless status.success?
      available = result.lines.last.split[3]
      raise Error, 'DISK_SPACE_CHECK_FAILED' unless available&.match?(/\A\d+\z/)
      raise Error, 'DISK_RESERVE_REACHED' if available.to_i * 1024 < @reserve + required_bytes
      true
    end
  end
end
