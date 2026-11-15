# frozen_string_literal: true

module RedmineBackup
  class WindowsPlatformService
    DACL = 0x00000004
    PROTECTED_DACL = 0x80000000

    def initialize
      require 'fiddle'
    end

    def available_bytes(path)
      bytes = "\0" * 8
      directory = File.expand_path(path).sub(%r{[\\/]+\z}, '') + '/'
      result = function('kernel32', 'GetDiskFreeSpaceExW', [pointer, pointer, pointer, pointer]).call(wide(directory), bytes, 0, 0)
      raise Error, 'DISK_SPACE_CHECK_FAILED' if result.zero?
      bytes.unpack1('Q<')
    end

    def secure_directory!(path)
      return if private_path?(path, protected: true)
      descriptor = "D:P#{allowed_sids.map { |sid| "(A;OICI;FA;;;#{sid})" }.join}"
      address = "\0" * Fiddle::SIZEOF_VOIDP
      result = function('advapi32', 'ConvertStringSecurityDescriptorToSecurityDescriptorW', [pointer, integer, pointer, pointer]).call(wide(descriptor), 1, address, 0)
      raise Error, 'PRIVATE_STORAGE_ACL_FAILED' if result.zero?
      native = Fiddle::Pointer.new(address.unpack1('J'))
      begin
        flags = (DACL | PROTECTED_DACL) - (1 << 32)
        result = function('advapi32', 'SetFileSecurityW', [pointer, long, pointer]).call(wide(path), flags, native)
        raise Error, 'PRIVATE_STORAGE_ACL_FAILED' if result.zero? || !private_path?(path, protected: true)
      ensure
        function('kernel32', 'LocalFree', [pointer], pointer).call(native)
      end
    end

    def private_path?(path, protected: false)
      descriptor = security_descriptor(path)
      return false if protected && !descriptor.split('(', 2).first.include?('P')
      entries = descriptor.scan(/\(([^()]*)\)/).flatten
      return false if entries.empty?
      entries.all? do |entry|
        fields = entry.split(';', -1)
        fields[0] == 'D' || (fields[0] == 'A' && allowed_sids.include?(fields[5]))
      end && entries.any? { |entry| fields = entry.split(';', -1); fields[0] == 'A' && current_sids.include?(fields[5]) }
    rescue Error
      false
    end

    def terminate_process(identifier)
      handle = function('kernel32', 'OpenProcess', [long, integer, long], pointer).call(0x0001, 0, identifier)
      if handle.null?
        raise Error, 'TOOL_TERMINATION_FAILED' if PlatformService.process_alive?(identifier)
        return
      end
      begin
        result = function('kernel32', 'TerminateProcess', [pointer, integer]).call(handle, 1)
        raise Error, 'TOOL_TERMINATION_FAILED' if result.zero? && PlatformService.process_alive?(identifier)
      ensure
        function('kernel32', 'CloseHandle', [pointer]).call(handle)
      end
    end

    def reparse_path?(path)
      attributes = function('kernel32', 'GetFileAttributesW', [pointer], long).call(wide(path))
      attributes != -1 && attributes != 0xFFFFFFFF && (attributes & 0x400).positive?
    end

    private

    def security_descriptor(path)
      length = "\0" * 4
      reader = function('advapi32', 'GetFileSecurityW', [pointer, long, pointer, long, pointer])
      reader.call(wide(path), DACL, 0, 0, length)
      size = length.unpack1('L<')
      raise Error, 'PRIVATE_STORAGE_ACL_UNREADABLE' unless size.positive? && size <= 1_048_576
      buffer = "\0" * size
      raise Error, 'PRIVATE_STORAGE_ACL_UNREADABLE' if reader.call(wide(path), DACL, buffer, size, length).zero?
      output = "\0" * Fiddle::SIZEOF_VOIDP
      characters = "\0" * 4
      converter = function('advapi32', 'ConvertSecurityDescriptorToStringSecurityDescriptorW', [pointer, integer, long, pointer, pointer])
      raise Error, 'PRIVATE_STORAGE_ACL_UNREADABLE' if converter.call(buffer, 1, DACL, output, characters).zero?
      native = Fiddle::Pointer.new(output.unpack1('J'))
      begin
        native.to_s(characters.unpack1('L<') * 2).force_encoding(Encoding::UTF_16LE).encode(Encoding::UTF_8).delete_suffix("\0")
      ensure
        function('kernel32', 'LocalFree', [pointer], pointer).call(native)
      end
    end

    def current_sid
      @current_sid ||= begin
        current = function('kernel32', 'GetCurrentProcess', [], pointer).call
        output = "\0" * Fiddle::SIZEOF_VOIDP
        opener = function('advapi32', 'OpenProcessToken', [pointer, long, pointer])
        raise Error, 'WINDOWS_SERVICE_IDENTITY_UNAVAILABLE' if opener.call(current, 0x0008, output).zero?
        token = Fiddle::Pointer.new(output.unpack1('J'))
        begin
          length = "\0" * 4
          reader = function('advapi32', 'GetTokenInformation', [pointer, integer, pointer, long, pointer])
          reader.call(token, 1, 0, 0, length)
          size = length.unpack1('L<')
          raise Error, 'WINDOWS_SERVICE_IDENTITY_UNAVAILABLE' unless size.positive? && size <= 65_536
          buffer = "\0" * size
          raise Error, 'WINDOWS_SERVICE_IDENTITY_UNAVAILABLE' if reader.call(token, 1, buffer, size, length).zero?
          sid = Fiddle::Pointer.new(buffer.byteslice(0, Fiddle::SIZEOF_VOIDP).unpack1('J'))
          address = "\0" * Fiddle::SIZEOF_VOIDP
          converter = function('advapi32', 'ConvertSidToStringSidW', [pointer, pointer])
          raise Error, 'WINDOWS_SERVICE_IDENTITY_UNAVAILABLE' if converter.call(sid, address).zero?
          text = Fiddle::Pointer.new(address.unpack1('J'))
          begin
            bytes = +''.b
            256.times do |index|
              character = text[index * 2, 2]
              break if character == "\0\0".b
              bytes << character
            end
            identifier = bytes.force_encoding(Encoding::UTF_16LE).encode(Encoding::UTF_8)
            raise Error, 'WINDOWS_SERVICE_IDENTITY_UNAVAILABLE' unless identifier.match?(/\AS-1-\d+(?:-\d+)+\z/)
            identifier
          ensure
            function('kernel32', 'LocalFree', [pointer], pointer).call(text)
          end
        ensure
          function('kernel32', 'CloseHandle', [pointer]).call(token)
        end
      end
    end

    def allowed_sids
      # SDDL uses aliases for SYSTEM and built-in administrators when reading an ACL.
      [*current_sids, 'SY', 'BA', 'S-1-5-18', 'S-1-5-32-544']
    end

    def current_sids
      aliases = { 'S-1-5-18' => 'SY', 'S-1-5-19' => 'LS', 'S-1-5-20' => 'NS' }
      relative = current_sid.end_with?('-500') ? 'LA' : (current_sid.end_with?('-501') ? 'LG' : nil)
      [current_sid, aliases[current_sid], relative].compact
    end

    def wide(value)
      value.to_s.tr('/', '\\').encode(Encoding::UTF_16LE).b + "\0\0".b
    end

    def pointer
      Fiddle::TYPE_VOIDP
    end

    def integer
      Fiddle::TYPE_INT
    end

    def long
      Fiddle::TYPE_LONG
    end

    def function(library, name, arguments, result = Fiddle::TYPE_INT)
      @functions ||= {}
      @libraries ||= {}
      @functions[name] ||= begin
        @libraries[library] ||= Fiddle.dlopen("#{library}.dll")
        abi = Fiddle::Function.const_defined?(:STDCALL) ? Fiddle::Function::STDCALL : Fiddle::Function::DEFAULT
        Fiddle::Function.new(@libraries[library][name], arguments, result, abi)
      end
    end
  end
end
