# frozen_string_literal: true

require 'find'

module RedmineBackup
  # Local durable control state. No plugin tables or migrations are required.
  class Store
    attr_reader :root

    def initialize(root, encryptor: nil)
      @root = File.expand_path(root)
      @encryptor = encryptor
      raise Error, 'SYMLINK_STATE_DIRECTORY' if PlatformService.link?(@root)
      FileUtils.mkdir_p(@root, mode: 0o700)
      PlatformService.secure_directory!(@root)
      %w[control runs].each { |name| FileUtils.mkdir_p(File.join(@root, name), mode: 0o700) }
    end

    def lock(name, nonblock: false)
      raise Error, 'INVALID_LOCK' unless name.match?(/\A[a-z_]+\z/)
      File.open(File.join(root, 'control', "#{name}.lock"), File::RDWR | File::CREAT, 0o600) do |handle|
        flags = File::LOCK_EX | (nonblock ? File::LOCK_NB : 0)
        return false unless handle.flock(flags)
        begin
          yield
        ensure
          handle.flock(File::LOCK_UN)
        end
      end
      true
    end

    def read(name, fallback = {})
      path = control_path(name)
      return fallback unless File.file?(path)
      payload = File.binread(path)
      payload = @encryptor.decrypt_and_verify(payload) if @encryptor
      JSON.parse(payload)
    rescue JSON::ParserError
      raise Error, 'CONTROL_STATE_CORRUPT'
    end

    def write(name, object)
      payload = JSON.generate(object)
      payload = @encryptor.encrypt_and_sign(payload) if @encryptor
      atomic(control_path(name), payload)
    end

    def atomic(path, payload)
      raise Error, 'WRITE_OUTSIDE_STORE' unless inside?(path)
      temporary = "#{path}.#{SecureRandom.hex(8)}.tmp"
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(payload)
        file.flush
        file.fsync
      end
      File.rename(temporary, path)
    ensure
      File.delete(temporary) if temporary && File.exist?(temporary)
    end

    def run_path(identifier)
      raise Error, 'INVALID_RUN_ID' unless identifier.match?(/\A\d{8}T\d{6}Z-[a-f0-9]{12}\z/)
      File.join(root, 'runs', identifier)
    end

    def inside?(path)
      PlatformService.within?(path, root)
    end

    def audit(event, actor: 'worker', run: nil)
      lock('audit') do
        history = read('audit', [])
        history << { 'at' => Time.now.utc.iso8601, 'event' => event, 'actor' => actor, 'run' => run }
        write('audit', history.last(5000))
      end
    end

    private

    def control_path(name)
      raise Error, 'INVALID_STATE_NAME' unless name.match?(/\A[a-zA-Z0-9_-]+\z/)
      File.join(root, 'control', "#{name}.json.enc")
    end
  end
end
