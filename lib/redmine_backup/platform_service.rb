# frozen_string_literal: true

require 'open3'
module RedmineBackup
  class PlatformService
    def self.windows?
      Gem.win_platform?
    end

    def self.linux?
      RUBY_PLATFORM.include?('linux')
    end

    def self.available_bytes(path)
      return windows.available_bytes(path) if windows?
      output, status = Open3.capture2({ 'LC_ALL' => 'C' }, 'df', '-Pk', File.expand_path(path), err: File::NULL)
      available = output.lines.last.to_s.split[3]
      raise Error, 'DISK_SPACE_CHECK_FAILED' unless status.success? && available.to_s.match?(/\A\d+\z/)
      available.to_i * 1024
    rescue SystemCallError
      raise Error, 'DISK_SPACE_CHECK_FAILED'
    end

    def self.secure_directory!(path)
      windows? ? windows.secure_directory!(path) : File.chmod(0o700, path)
    end

    def self.private_path?(path)
      windows? ? windows.private_path?(path) : (File.stat(path).mode & 0o077).zero?
    end

    def self.link?(path)
      File.symlink?(path) || (windows? && windows.reparse_path?(path))
    end

    def self.path_key(path)
      expanded = File.expand_path(path)
      windows? ? expanded.tr('\\', '/').downcase : expanded
    end

    def self.within?(path, root, include_root: false)
      child, parent = path_key(path), path_key(root).sub(%r{/+$}, '')
      (include_root && child == parent) || child.start_with?(parent + '/')
    end

    def self.executable(name, directory: '')
      executable = windows? ? "#{name}.exe" : name
      directory.to_s.empty? ? executable : File.join(directory, executable)
    end

    def self.machine_identity
      if windows?
        require 'win32/registry'
        Win32::Registry::HKEY_LOCAL_MACHINE.open('SOFTWARE\\Microsoft\\Cryptography') { |key| key.read_s('MachineGuid') }
      elsif File.file?('/etc/machine-id')
        File.read('/etc/machine-id').strip
      end
    rescue LoadError, StandardError
      nil
    end

    def self.process_alive?(identifier)
      return false unless identifier.to_i.positive?
      Process.kill(0, identifier.to_i)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    rescue Errno::EINVAL
      raise unless windows?
      false
    end

    def self.terminate_process(identifier, signal: 'TERM', group: false)
      return windows.terminate_process(identifier) if windows?
      Process.kill(signal, group && !windows? ? -identifier : identifier)
    rescue Errno::ESRCH
      nil
    rescue Errno::EINVAL
      raise unless windows? && !process_alive?(identifier)
      nil
    end

    def self.windows
      require_relative 'windows_platform_service'
      @windows ||= WindowsPlatformService.new
    end
    private_class_method :windows
  end
end
