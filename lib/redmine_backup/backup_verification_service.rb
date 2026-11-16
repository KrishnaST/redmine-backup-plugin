# frozen_string_literal: true

require 'digest'
require 'json'
require 'rubygems/package'
require 'zlib'

module RedmineBackup
  class BackupVerificationService
    MAX_MANIFEST_BYTES = 64 * 1024 * 1024
    CHUNK_BYTES = 1024 * 1024

    def self.verify_archive(path, expected_folder: nil, check: nil)
      files, links, seen, manifest, folder = {}, {}, {}, nil, nil
      Zlib::GzipReader.open(path) do |gzip|
        Gem::Package::TarReader.new(gzip) do |tar|
          tar.each do |entry|
            name = entry.full_name.dup.force_encoding(Encoding::UTF_8).delete_suffix('/')
            safe_name!(name)
            raise Error, 'DUPLICATE_ARCHIVE_ENTRY' if seen[name]
            seen[name] = true
            folder ||= name.split('/').first
            raise Error, 'ARCHIVE_FOLDER_MISMATCH' unless name == folder || name.start_with?(folder + '/')
            raise Error, 'ARCHIVE_FOLDER_MISMATCH' if expected_folder && folder != expected_folder
            relative = name.delete_prefix(folder + '/')
            if entry.directory?
              next
            elsif entry.file?
              raise Error, 'ARCHIVE_ROOT_MUST_BE_DIRECTORY' if name == folder
              digest, bytes, content = Digest::SHA256.new, 0, +''
              is_manifest = relative == 'manifest.json'
              raise Error, 'MANIFEST_TOO_LARGE' if is_manifest && entry.header.size > MAX_MANIFEST_BYTES
              while (chunk = entry.read(CHUNK_BYTES)) && !chunk.empty?
                check&.call
                digest.update(chunk)
                bytes += chunk.bytesize
                content << chunk if is_manifest
              end
              files[relative] = { 'bytes' => bytes, 'sha256' => digest.hexdigest }
              manifest = JSON.parse(content) if is_manifest
            elsif entry.header.typeflag == '2'
              target = entry.header.linkname.dup.force_encoding(Encoding::UTF_8)
              safe_link!(relative, target)
              links[relative] = target
            else
              raise Error, 'UNSUPPORTED_ARCHIVE_ENTRY'
            end
          end
        end
        # Read through gzip EOF to check its CRC/trailer, not only the TAR end marker.
        while (padding = gzip.read(CHUNK_BYTES)) && !padding.empty?
          check&.call
          raise Error, 'UNEXPECTED_ARCHIVE_TRAILER' unless padding.delete("\0").empty?
        end
        raise Error, 'UNEXPECTED_ARCHIVE_TRAILER' if (gzip.unused && !gzip.unused.empty?) || gzip.to_io.pos < File.size(path)
      end
      raise Error, 'UNSUPPORTED_MANIFEST' unless manifest && manifest['format'] == 2 && manifest['backup_folder'] == folder
      expected = expected_files(manifest)
      raise Error, 'ARCHIVE_CONTENT_MISMATCH' unless files.keys.sort == (expected.keys + ['manifest.json']).sort
      expected.each { |name, item| verify_item!(files.fetch(name), item) }
      raise Error, 'ARCHIVE_LINK_MISMATCH' unless links == expected_links(manifest)
      true
    rescue Error
      raise
    rescue StandardError
      raise Error, 'ARCHIVE_VERIFICATION_FAILED'
    end

    def self.verify_manifest(path)
      root = File.dirname(File.realpath(path))
      manifest = JSON.parse(File.read(path))
      raise Error, 'UNSUPPORTED_MANIFEST' unless [1, 2].include?(manifest['format'])
      expected_files(manifest).each do |name, item|
        file = File.realpath(File.join(root, name))
        raise Error, 'ARTIFACT_OUTSIDE_STAGING' unless file.start_with?(root + File::SEPARATOR)
        verify_item!({ 'bytes' => File.size(file), 'sha256' => Digest::SHA256.file(file).hexdigest }, item)
      end
      expected_links(manifest).each do |name, target|
        file = File.join(root, name)
        resolved = File.realpath(file)
        raise Error, 'ARTIFACT_OUTSIDE_STAGING' unless resolved.start_with?(root + File::SEPARATOR)
        raise Error, 'ARCHIVE_LINK_MISMATCH' unless File.symlink?(file) && File.readlink(file) == target
      end
      true
    rescue Error
      raise
    rescue StandardError
      raise Error, 'MANIFEST_VERIFICATION_FAILED'
    end

    def self.expected_files(manifest)
      items = manifest.fetch('artifacts').map { |item| [item.fetch('name'), item] }
      if manifest['format'] == 2
        required = %w[database.dump bootstrap.json RECOVERY.md]
        raise Error, 'MISSING_RECOVERY_COMPONENT' unless items.map(&:first).sort == required.sort
        items.concat(manifest.fetch('files').map { |item| [item.fetch('path'), item] })
      end
      result = {}
      items.each do |name, item|
        safe_name!(name)
        raise Error, 'DUPLICATE_MANIFEST_ENTRY' if result.key?(name) || name == 'manifest.json'
        result[name] = item
      end
      result
    end
    private_class_method :expected_files

    def self.expected_links(manifest)
      result = {}
      manifest.fetch('links', []).each do |item|
        name, target = item.fetch('path'), item.fetch('target')
        safe_name!(name)
        safe_link!(name, target)
        raise Error, 'DUPLICATE_MANIFEST_ENTRY' if result.key?(name)
        result[name] = target
      end
      result
    end
    private_class_method :expected_links

    def self.safe_name!(name)
      raise Error, 'UNSAFE_ARCHIVE_PATH' unless name.is_a?(String) && name.valid_encoding? && !name.empty? && !name.match?(/[\\:\x00-\x1f]/) && name.split('/', -1).none? { |part| ['', '.', '..'].include?(part) }
    end
    private_class_method :safe_name!

    def self.safe_link!(name, target)
      raise Error, 'UNSAFE_ARCHIVE_LINK' unless target.is_a?(String) && target.valid_encoding? && !target.empty? && !target.start_with?('/') && !target.match?(/[\\:\x00-\x1f]/)
      parts = name.split('/')[0...-1]
      target.split('/').each do |part|
        if part == '..'
          raise Error, 'UNSAFE_ARCHIVE_LINK' if parts.empty?
          parts.pop
        elsif part != '.' && !part.empty?
          parts << part
        end
      end
      scope = name.start_with?('external/') ? name.split('/').first(2) : [name.split('/').first]
      raise Error, 'UNSAFE_ARCHIVE_LINK' unless parts.first(scope.length) == scope
    end
    private_class_method :safe_link!

    def self.verify_item!(actual, expected)
      raise Error, 'ARTIFACT_SIZE_MISMATCH' unless actual.fetch('bytes') == expected.fetch('bytes')
      raise Error, 'ARTIFACT_CHECKSUM_MISMATCH' unless actual.fetch('sha256') == expected.fetch('sha256')
    end
    private_class_method :verify_item!
  end
end
