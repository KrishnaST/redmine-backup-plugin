# frozen_string_literal: true

module RedmineBackup
  class Resources
    def initialize(root:, reserve_mb:, timeout_seconds:)
      @root, @reserve = root, Integer(reserve_mb) * 1024 * 1024
      @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
    end

    def check!(required_bytes = 0)
      raise Error, 'CAPTURE_TIMEOUT' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > @deadline
      # A short cache avoids starting an OS utility for every archived file.
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if !@checked_at || now - @checked_at >= 1 || required_bytes.positive?
        @available = PlatformService.available_bytes(@root)
        @checked_at = now
      end
      raise Error, 'DISK_RESERVE_REACHED' if @available < @reserve + required_bytes
      true
    end
  end
end
