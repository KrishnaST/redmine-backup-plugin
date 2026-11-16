# frozen_string_literal: true

require 'find'
require 'pathname'
require 'rubygems/package'
require 'zlib'

require_relative 'backup_verification_service'
require_relative 'prefixed_tar_writer'

module RedmineBackup
  class Capture
    def initialize(config:, store:, application_root:, attachment_root:, database:, secret_key:, runner: nil)
      @config, @store = config, store
      @application_root = File.realpath(application_root)
      @attachment_root = File.realpath(attachment_root)
      @database, @secret_key = database.transform_keys(&:to_s), secret_key
      @runner = runner || ProcessRunner.new(timeout: config['timeout_seconds'])
      @resources = Resources.new(root: store.root, reserve_mb: config['disk_reserve_mb'], timeout_seconds: config['timeout_seconds'])
    end

    def sources
      discovered = Coverage.discover(application_root: @application_root, attachment_root: @attachment_root)
      provider_files = @config.destinations.values.flat_map { |target| target.values_at('private_key_path', 'known_hosts') }.compact.reject(&:empty?)
      database_files = @database.values_at('sslcert', 'sslkey', 'sslrootcert', 'sslcrl').compact.reject { |path| path.empty? || path == 'system' }
      paths = (discovered + provider_files + database_files + @config['additional_paths']).uniq
      Coverage.validate!(paths)
      paths.map { |path| File.realpath(path) }.uniq
    end

    def call(run)
      require 'pg'
      destination = @store.run_path(run.fetch('id'))
      FileUtils.mkdir_p(destination, mode: 0o700)
      @resources.check!
      dump = File.join(destination, 'database.dump')
      single_archive = @config['packaging'] == 'tar_gz'
      archive = File.join(destination, single_archive ? 'backup.tar.gz' : 'application.tar.gz')
      manifest = { 'format' => single_archive ? 2 : 1, 'id' => run['id'], 'date' => run['date'], 'installation_id' => run['installation_id'],
                   'backup_folder' => BackupLayout.folder_name(run), 'packaging' => @config['packaging'],
                   'created_at' => Time.now.utc.iso8601, 'plugin_version' => VERSION,
                   'ruby_version' => RUBY_VERSION, 'platform' => RUBY_PLATFORM, 'rails_version' => defined?(Rails) ? Rails.version : nil,
                   'redmine_version' => defined?(Redmine::VERSION) ? Redmine::VERSION.to_s : nil,
                   'application_root' => @application_root, 'attachment_root' => @attachment_root,
                   'sources' => sources, 'gateway_included' => false, 'files' => [], 'artifacts' => [] }
      capture_snapshot(dump, archive, manifest, prefix: single_archive ? manifest['backup_folder'] : nil) do |tar|
        next unless single_archive
        write_metadata(destination, manifest)
        (manifest['artifacts'].map { |item| item['name'] } + ['manifest.json']).each do |name|
          add_file(tar, File.join(destination, name), name)
        end
      end
      write_metadata(destination, manifest) unless single_archive
      yield if block_given?
      package(run)
    end

    def write_metadata(destination, manifest)
      @store.atomic(File.join(destination, 'bootstrap.json'), JSON.pretty_generate(
        'config' => @config.values, 'installation_id' => manifest['installation_id'],
        'database' => @database, 'secret_key_base' => @secret_key, 'recovery_mode_required' => true,
        'private_state' => %w[metadata audit runs coverage secrets].to_h { |name| [name, @store.read(name, name == 'metadata' || name == 'secrets' ? {} : [])] }
      ))
      guide = File.read(File.expand_path('../../documentation/RECOVERY.md', __dir__))
      @store.atomic(File.join(destination, 'RECOVERY.md'), guide)
      payloads = %w[database.dump bootstrap.json RECOVERY.md]
      payloads << 'application.tar.gz' if manifest['format'] == 1
      payloads.each do |name|
        path = File.join(destination, name)
        manifest['artifacts'] << { 'name' => name, 'bytes' => File.size(path), 'sha256' => Digest::SHA256.file(path).hexdigest }
      end
      @store.atomic(File.join(destination, 'manifest.json'), JSON.pretty_generate(manifest))
    end

    private :write_metadata

    def package(run)
      destination = @store.run_path(run.fetch('id'))
      if @config['packaging'] == 'tar_gz'
        path = File.join(destination, 'backup.tar.gz')
        BackupVerificationService.verify_archive(path, expected_folder: BackupLayout.folder_name(run), check: -> { @resources.check! })
        return [{ 'name' => 'backup.tar.gz', 'bytes' => File.size(path), 'sha256' => Digest::SHA256.file(path).hexdigest }]
      end
      manifest = JSON.parse(File.read(File.join(destination, 'manifest.json')))
      @resources.check!(manifest.fetch('artifacts').sum { |item| item['bytes'] }) if @config['packaging'] == 'zip'
      manifest.fetch('artifacts').each do |item|
        raise Error, 'UNSAFE_ARTIFACT_NAME' unless item['name'].match?(/\A[a-zA-Z0-9._-]+\z/)
        path = File.join(destination, item['name'])
        raise Error, 'LOCAL_INTEGRITY_FAILED' unless File.size(path) == item['bytes'] && Digest::SHA256.file(path).hexdigest == item['sha256']
      end
      payloads = manifest['artifacts'].map { |item| item['name'] } + ['manifest.json']
      if @config['packaging'] == 'zip'
        require 'zip'
        Zip.write_zip64_support = true
        zip_path = File.join(destination, 'backup.zip')
        File.delete(zip_path) if File.exist?(zip_path)
        folder = BackupLayout.folder_name(run)
        Zip::File.open(zip_path, create: true) do |zip|
          payloads.each do |name|
            entry = Zip::Entry.new('', "#{folder}/#{name}")
            entry.compression_method = Zip::Entry::STORED
            zip.add(entry, File.join(destination, name))
          end
        end
        Zip::File.open(zip_path) do |zip|
          zip.each do |entry|
            digest = Digest::SHA256.new
            entry.get_input_stream do |input|
              while (chunk = input.read(1024 * 1024))
                digest.update(chunk)
              end
            end
            expected = Digest::SHA256.file(File.join(destination, entry.name.delete_prefix("#{folder}/"))).hexdigest
            raise Error, 'ZIP_INTEGRITY_FAILED' unless digest.hexdigest == expected
          end
        end
        payloads = ['backup.zip']
      end
      payloads.map do |name|
        path = File.join(destination, name)
        { 'name' => name, 'bytes' => File.size(path), 'sha256' => Digest::SHA256.file(path).hexdigest }
      end
    end

    private

    def capture_snapshot(dump, archive, manifest, prefix: nil)
      raise Error, 'POSTGRESQL_REQUIRED' unless @database['adapter'] == 'postgresql'
      connection = PG.connect(pg_options)
      connection.exec('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY')
      table = defined?(Attachment) ? Attachment.table_name : 'attachments'
      raise Error, 'INVALID_ATTACHMENT_TABLE' unless table.match?(/\A[a-zA-Z_][a-zA-Z0-9_]*\z/)
      columns = connection.exec_params('SELECT column_name, data_type FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1', [table]).map { |row| [row['column_name'], row['data_type']] }.to_h
      required = %w[id disk_filename disk_directory filesize digest]
      raise Error, 'ATTACHMENT_SCHEMA_MISMATCH' unless (required - columns.keys).empty? && %w[integer bigint].include?(columns['filesize'])
      snapshot = connection.exec('SELECT pg_export_snapshot()').getvalue(0, 0)
      manifest['postgresql_version'] = connection.exec('SHOW server_version').getvalue(0, 0)
      @runner.call([tool('pg_dump'), '--format=custom', '--no-password', "--snapshot=#{snapshot}"], env: pg_environment, output: dump, check: -> { @resources.check! })
      @runner.call([tool('pg_restore'), '--list', dump])
      @resources.check!
      Zlib::GzipWriter.open(archive) do |gzip|
        Gem::Package::TarWriter.new(gzip) do |tar|
          if prefix
            tar.mkdir(prefix, 0o700)
            tar = PrefixedTarWriter.new(tar, prefix)
          end
          archive_sources(tar, manifest)
          quoted = PG::Connection.quote_ident(table)
          connection.exec("DECLARE backup_attachments NO SCROLL CURSOR FOR SELECT id, disk_directory, disk_filename, filesize, digest FROM #{quoted}")
          seen = {}
          loop do
            rows = connection.exec('FETCH FORWARD 500 FROM backup_attachments')
            break if rows.ntuples.zero?
            rows.each do |row|
              path = attachment_path(row)
              next if seen[path]
              seen[path] = true
              item = add_file(tar, path, "attachments/#{Pathname.new(path).relative_path_from(Pathname.new(@attachment_root))}", expected_digest: row['digest'])
              raise Error, 'ATTACHMENT_SIZE_MISMATCH' unless item['bytes'] == row['filesize'].to_i
              expected = row['digest'].to_s.downcase
              algorithm = { 32 => Digest::MD5, 40 => Digest::SHA1, 64 => Digest::SHA256 }[expected.length]
              raise Error, 'ATTACHMENT_DIGEST_UNSUPPORTED' if !expected.empty? && (!algorithm || !expected.match?(/\A[0-9a-f]+\z/))
              raise Error, 'ATTACHMENT_DIGEST_MISMATCH' if algorithm && item.delete('stored_digest') != expected
              manifest['files'] << item.merge('attachment_id' => row['id'])
            end
          end
          yield tar if block_given?
        end
      end
    rescue Errno::ENOENT
      raise Error, 'SOURCE_DISAPPEARED_DURING_CAPTURE'
    ensure
      connection.exec('ROLLBACK') if connection && !connection.finished?
      connection&.close
    end

    def archive_sources(tar, manifest)
      roots = sources.reject { |path| path == @attachment_root }
      roots.reject! { |path| PlatformService.within?(path, @application_root) }
      roots.each_with_index do |root, index|
        Find.find(root) do |path|
          if excluded?(path)
            Find.prune if File.directory?(path)
            next
          end
          relative = path == root ? (File.file?(root) ? File.basename(root) : '') : Pathname.new(path).relative_path_from(Pathname.new(root)).to_s.tr('\\', '/')
          name = "#{index.zero? ? 'application' : "external/#{index}"}/#{relative}"
          if PlatformService.link?(path)
            raise Error, 'REPARSE_SOURCE_REQUIRES_EXPLICIT_COVERAGE' unless File.symlink?(path)
            resolved = File.realpath(path)
            raise Error, 'EXTERNAL_SYMLINK_REQUIRES_EXPLICIT_COVERAGE' unless PlatformService.within?(resolved, root) && !excluded?(resolved)
            target = File.readlink(path)
            if manifest['format'] == 2
              target = Pathname.new(resolved).relative_path_from(Pathname.new(File.dirname(path))).to_s.tr('\\', '/')
              (manifest['links'] ||= []) << { 'path' => name, 'target' => target }
            end
            tar.add_symlink(name, target, File.lstat(path).mode & 0o777)
          elsif File.directory?(path)
            tar.mkdir(name, File.stat(path).mode & 0o777)
          elsif File.file?(path)
            manifest['files'] << add_file(tar, path, name)
          else
            raise Error, 'UNSUPPORTED_SOURCE_FILE_TYPE'
          end
        end
      end
      manifest['external_roots'] = roots.drop(1)
    end

    def excluded?(path)
      resolved = File.expand_path(path)
      return true if resolved.split(/[\\\/]/).any? { |part| part.match?(/\A(?:gateway(?:[-_.].*)?|cbs-gateway|letsencrypt)\z/i) }
      return true if PlatformService.within?(resolved, @store.root, include_root: true)
      return true if PlatformService.within?(resolved, @attachment_root, include_root: true)
      %w[.git log tmp].any? { |part| PlatformService.within?(resolved, File.join(@application_root, part), include_root: true) }
    end

    def add_file(tar, path, name, expected_digest: nil)
      raise Error, 'SYMLINK_SOURCE_FILE' if PlatformService.link?(path)
      before = File.stat(path)
      @resources.check!
      digest = Digest::SHA256.new
      legacy_algorithm = { 32 => Digest::MD5, 40 => Digest::SHA1, 64 => Digest::SHA256 }[expected_digest.to_s.length]
      legacy_digest = legacy_algorithm&.new
      since_check = 0
      File.open(path, 'rb') do |input|
        raise Error, 'SOURCE_CHANGED_DURING_CAPTURE' unless input.stat.ino == before.ino
        tar.add_file_simple(name, before.mode & 0o777, before.size) do |output|
          while (chunk = input.read(1024 * 1024))
            output.write(chunk)
            digest.update(chunk)
            legacy_digest&.update(chunk)
            since_check += chunk.bytesize
            if since_check >= 64 * 1024 * 1024
              @resources.check!
              since_check = 0
            end
          end
        end
      end
      after = File.stat(path)
      raise Error, 'SOURCE_CHANGED_DURING_CAPTURE' unless [before.size, before.mtime, before.ino] == [after.size, after.mtime, after.ino]
      result = { 'path' => name, 'bytes' => after.size, 'sha256' => digest.hexdigest }
      result['stored_digest'] = legacy_digest.hexdigest if legacy_digest
      result
    end

    def attachment_path(row)
      relative = File.join(row['disk_directory'].to_s, row.fetch('disk_filename'))
      raise Error, 'UNSAFE_ATTACHMENT_PATH' if relative.split(/[\\\/]/).include?('..') || Pathname.new(relative).absolute?
      path = File.realpath(File.join(@attachment_root, relative))
      raise Error, 'UNSAFE_ATTACHMENT_PATH' unless PlatformService.within?(path, @attachment_root)
      path
    end

    def tool(name)
      PlatformService.executable(name, directory: @config['pg_bin'])
    end

    def pg_options
      keys = %w[host port database username password sslmode sslcert sslkey sslrootcert sslcrl connect_timeout]
      { 'connect_timeout' => 15 }.merge(@database.slice(*keys).transform_keys { |key| { 'database' => 'dbname', 'username' => 'user' }.fetch(key, key) })
    end

    def pg_environment
      pg_options.to_h { |key, value| ["PG#{key.upcase}", value.to_s] }
                .transform_keys { |key| { 'PGDBNAME' => 'PGDATABASE' }.fetch(key, key) }
    end
  end
end
