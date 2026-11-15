# frozen_string_literal: true

module RedmineBackup
  class PrivateCredentialFileService
    def self.read(path)
      raise Error, 'PRIVATE_CREDENTIAL_FILE_REQUIRED' if path.to_s.empty? || !File.file?(path) || !File.readable?(path)
      raise Error, 'CREDENTIAL_FILE_TOO_LARGE' if File.size(path) > 131_072
      if File::ALT_SEPARATOR.nil? && (File.stat(path).mode & 0o077).positive?
        raise Error, 'CREDENTIAL_FILE_MUST_BE_PRIVATE'
      end
      content = File.binread(path).strip
      raise Error, 'EMPTY_CREDENTIAL_FILE' if content.empty?
      content
    end
  end
end
