# frozen_string_literal: true

require 'open3'

module RedmineBackup
  class ProcessRunner
    def initialize(timeout: 21_600)
      @timeout = timeout
    end

    def call(arguments, env: {}, output: File::NULL, check: nil)
      process_options = Gem.win_platform? ? { new_pgroup: true } : { pgroup: true }
      Open3.popen3(env, *arguments, **process_options) do |input, stdout, stderr, waiter|
        input.close
        writer_error = nil
        writer = Thread.new do
          begin
            File.open(output, 'wb', 0o600) do |file|
              while (chunk = stdout.read(4 * 1024 * 1024))
                check&.call
                file.write(chunk)
              end
            end
          rescue StandardError => error
            writer_error = error
            terminate(waiter.pid)
          end
        end
        writer.report_on_exception = false
        reader = Thread.new do
          stderr.read(65_536)
          IO.copy_stream(stderr, File::NULL)
        rescue IOError
          nil
        end
        reader.report_on_exception = false
        unless waiter.join(@timeout)
          terminate(waiter.pid)
          waiter.join(5) || terminate(waiter.pid, 'KILL')
          raise Error, 'TOOL_TIMEOUT'
        end
        writer.value
        reader.value
        raise writer_error if writer_error
        raise Error, 'TOOL_FAILED' unless waiter.value.success?
      rescue Exception
        # Managed shutdown must also stop pg_dump before releasing its snapshot/lock.
        if waiter.alive?
          terminate(waiter.pid)
          waiter.join(2) || terminate(waiter.pid, 'KILL')
        end
        writer&.join(2)
        reader&.join(2)
        raise
      end
    end

    private

    def terminate(pid, signal = 'TERM')
      PlatformService.terminate_process(pid, signal: signal, group: true)
    end
  end
end
