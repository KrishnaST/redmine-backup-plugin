# frozen_string_literal: true

require 'base64'
require 'net/http'
require 'openssl'
require 'stringio'
require 'uri'

module RedmineBackup
  module Providers
    def self.build(target, checkpoint: nil)
      case target.fetch('provider')
      when 's3' then S3.new(target, checkpoint: checkpoint)
      when 'sftp' then Sftp.new(target, checkpoint: checkpoint)
      when 'google_drive', 'onedrive', 'onedrive_personal', 'sharepoint' then CloudDrive.new(target, checkpoint: checkpoint)
      else raise Error, 'UNSUPPORTED_PROVIDER'
      end
    end

    class Base
      attr_reader :target

      def initialize(target, checkpoint: nil)
        @target, @checkpoint = target, checkpoint || ->(_key, _value) {}
      end

      def verify!(reference, expected)
        digest = Digest::SHA256.new
        bytes = 0
        stream(reference) { |chunk| bytes += chunk.bytesize; digest.update(chunk) }
        raise Error, 'REMOTE_INTEGRITY_FAILED' unless bytes == expected.fetch('bytes') && digest.hexdigest == expected.fetch('sha256')
        true
      end

      def protect!
        raise Error, 'PROTECTION_NOT_SUPPORTED' if target['versioning'] || target['retention_lock']
      end

      def health!
        protect!
        true
      end

      def close; end

      def prepare_run(name, reference = nil)
        BackupLayout.validate_folder!(name)
        assert_folder!(reference, name) if reference
        { 'name' => name }
      end

      def assert_folder!(reference, name)
        BackupLayout.validate_folder!(name)
        raise Error, 'FOREIGN_BACKUP_FOLDER' unless reference['name'] == name
      end

      def delete_folder(_reference); end

      def assert_reference!(_reference, _namespace)
        raise Error, 'PROVIDER_NAMESPACE_CHECK_REQUIRED'
      end

      def delete_set!(record)
        references = record.fetch('artifacts').map { |item| item.fetch('reference') } + [record.fetch('marker')]
        raise Error, 'RETENTION_LOCKED' if references.any? { |reference| locked?(reference) }
        # Remove discovery marker first: partially deleted sets must not look restorable.
        delete(record.fetch('marker'))
        record.fetch('artifacts').each { |item| delete(item.fetch('reference')) }
        delete_folder(record['folder']) if record['folder']
      end

      def locked?(_reference)
        false
      end
    end

    class S3 < Base
      def initialize(target, checkpoint: nil)
        super
        require 'aws-sdk-s3'
        region = target['region'].to_s.empty? ? 'us-east-1' : target['region']
        options = { region: region, retry_limit: 2, http_open_timeout: 15, http_read_timeout: 60 }
        if target['endpoint'].to_s != ''
          raise Error, 'HTTPS_ENDPOINT_REQUIRED' unless URI(target['endpoint']).scheme == 'https'
          options[:endpoint] = target['endpoint']
          options[:force_path_style] = true
        end
        authentication = ProviderSettingsService.authentication(target.merge('provider' => 's3'))
        unless authentication == 'sdk_chain'
          raise Error, 'S3_ACCESS_KEY_AND_SECRET_REQUIRED' if target['access_key_id'].to_s.empty? || target['secret_access_key'].to_s.empty?
          raise Error, 'S3_SESSION_TOKEN_REQUIRED' if authentication == 'session_token' && target['session_token'].to_s.empty?
          token = authentication == 'session_token' ? target['session_token'] : nil
          options[:credentials] = Aws::Credentials.new(target['access_key_id'], target['secret_access_key'], token)
        end
        @client = Aws::S3::Client.new(**options)
        @bucket = target.fetch('bucket')
      end

      def health!
        @client.head_bucket(bucket: @bucket)
        protect!
      end

      def protect!
        if target['versioning'] || target['retention_lock']
          state = @client.get_bucket_versioning(bucket: @bucket)
          raise Error, 'BUCKET_VERSIONING_REQUIRED' unless state.status == 'Enabled'
        end
        if target['retention_lock']
          state = @client.get_object_lock_configuration(bucket: @bucket)
          raise Error, 'BUCKET_OBJECT_LOCK_REQUIRED' unless state.object_lock_configuration.object_lock_enabled == 'Enabled'
        end
        true
      end

      def upload(path, key, session = {})
        protect!
        key = scoped(key)
        size = File.size(path)
        chunk_size = [16 * 1024 * 1024, (size.fdiv(9999)).ceil].max
        options = { bucket: @bucket, key: key }
        if target['retention_lock']
          options[:object_lock_mode] = 'COMPLIANCE'
          options[:object_lock_retain_until_date] = Time.now.utc + Integer(target.fetch('lock_days')) * 86_400
        end
        state = session.dup
        if state['upload_id']
          begin
            @client.list_parts(bucket: @bucket, key: key, upload_id: state['upload_id'])
          rescue Aws::S3::Errors::NoSuchUpload
            state = {}
          end
        end
        state['upload_id'] ||= @client.create_multipart_upload(**options).upload_id
        state['parts'] ||= []
        @checkpoint.call(key, state)
        File.open(path, 'rb') do |input|
          state['parts'].each do |part|
            input.seek([chunk_size, size - input.pos].min, IO::SEEK_CUR)
          end
          until input.eof?
            part_number = state['parts'].length + 1
            payload = input.read(chunk_size)
            part = @client.upload_part(bucket: @bucket, key: key, upload_id: state['upload_id'], part_number: part_number,
                                       body: payload, content_md5: Base64.strict_encode64(Digest::MD5.digest(payload)))
            state['parts'] << { 'etag' => part.etag, 'part_number' => part_number }
            @checkpoint.call(key, state)
          end
        end
        parts = state['parts'].map { |part| { etag: part['etag'], part_number: part['part_number'] } }
        result = @client.complete_multipart_upload(bucket: @bucket, key: key, upload_id: state['upload_id'], multipart_upload: { parts: parts })
        @checkpoint.call(key, {})
        { 'key' => key, 'version_id' => result.version_id }
      end

      def stream(reference, &block)
        @client.get_object(**object_options(reference)) { |chunk| block.call(chunk) }
      end

      def verify!(reference, expected)
        super
        if target['versioning'] || target['retention_lock']
          metadata = @client.head_object(**object_options(reference))
          raise Error, 'VERSIONING_PROTECTION_FAILED' if target['versioning'] && metadata.version_id.to_s.empty?
          minimum = Time.now.utc + Integer(target.fetch('lock_days', 1)) * 86_400 - 300
          if target['retention_lock'] && (!metadata.object_lock_retain_until_date || metadata.object_lock_retain_until_date < minimum)
            raise Error, 'RETENTION_PROTECTION_FAILED'
          end
        end
        true
      end

      def list_markers(prefix)
        @client.list_objects_v2(bucket: @bucket, prefix: scoped(prefix)).flat_map do |page|
          page.contents.filter_map do |object|
            next unless object.key.end_with?('-complete.json', '/complete.json')
            metadata = @client.head_object(bucket: @bucket, key: object.key)
            { 'key' => object.key, 'version_id' => metadata.version_id }
          end
        end
      end

      def delete(reference)
        @client.delete_object(**object_options(reference))
      end

      def assert_reference!(reference, namespace)
        key = reference.fetch('key')
        prefix = target['prefix'].to_s.gsub(%r{\A/+|/+$}, '')
        raise Error, 'FOREIGN_OBJECT_REFERENCE' if !prefix.empty? && !key.start_with?(prefix + '/')
        logical = prefix.empty? ? key : key.delete_prefix(prefix + '/')
        raise Error, 'FOREIGN_OBJECT_REFERENCE' unless BackupLayout.owned_key?(logical, namespace)
      end

      def locked?(reference)
        metadata = @client.head_object(**object_options(reference))
        metadata.object_lock_legal_hold_status == 'ON' ||
          (metadata.object_lock_retain_until_date && metadata.object_lock_retain_until_date > Time.now.utc)
      end

      private

      def scoped(key)
        [target['prefix'].to_s.gsub(%r{\A/+|/+$}, ''), key].reject(&:empty?).join('/')
      end

      def object_options(reference)
        options = { bucket: @bucket, key: reference.fetch('key') }
        options[:version_id] = reference['version_id'] if reference['version_id']
        options
      end
    end

    class Sftp < Base
      def initialize(target, checkpoint: nil)
        super
        require 'net/sftp'
        options = { port: Integer(target['port'].to_s.empty? ? 22 : target['port']), verify_host_key: :always,
                    non_interactive: true, timeout: 15, user_known_hosts_file: [target.fetch('known_hosts')] }
        if ProviderSettingsService.authentication(target) == 'password'
          raise Error, 'SFTP_PASSWORD_REQUIRED' if target['password'].to_s.empty?
          options[:password] = target['password']
          options[:auth_methods] = ['password']
        else
          raise Error, 'SFTP_PRIVATE_KEY_PATH_REQUIRED' if target['private_key_path'].to_s.empty?
          options[:keys] = [target['private_key_path']]
          options[:passphrase] = target['key_passphrase'] unless target['key_passphrase'].to_s.empty?
          options[:auth_methods] = ['publickey']
          options[:use_agent] = false
        end
        @sftp = Net::SFTP.start(target.fetch('host'), target.fetch('username'), **options)
        @directory = target.fetch('directory').sub(%r{/+$}, '')
        raise Error, 'ABSOLUTE_SFTP_DIRECTORY_REQUIRED' unless @directory.start_with?('/')
      end

      def health!
        super
        @sftp.stat!(@directory)
        true
      end

      def prepare_run(name, reference = nil)
        BackupLayout.validate_folder!(name)
        folder = reference || { 'name' => name, 'path' => "#{@directory}/#{name}" }
        begin
          assert_folder!(folder, name)
        rescue Net::SFTP::StatusException => error
          raise unless error.code == 2 && !reference
          @sftp.mkdir!(folder.fetch('path'), permissions: 0o700)
          assert_folder!(folder, name)
        end
        folder
      end

      def assert_folder!(reference, name)
        super
        raise Error, 'FOREIGN_BACKUP_FOLDER' unless reference['path'] == "#{@directory}/#{name}"
        attributes = @sftp.lstat!(reference.fetch('path'))
        raise Error, 'UNSAFE_BACKUP_FOLDER' unless attributes.directory? && !attributes.symlink?
      end

      def delete_folder(reference)
        assert_folder!(reference, reference.fetch('name'))
        # rmdir removes only an empty directory; never recursively delete remote data.
        @sftp.rmdir!(reference.fetch('path'))
      end

      def upload(path, key, _session = {})
        final = "#{@directory}/#{key}"
        partial = "#{final}.partial"
        offset = begin
          @sftp.stat!(partial).size
        rescue Net::SFTP::StatusException => error
          raise unless error.code == 2
          0
        end
        raise Error, 'INVALID_REMOTE_PARTIAL_SIZE' if offset > File.size(path)
        # A matching size is insufficient: verify every existing partial byte.
        File.open(path, 'rb') do |local|
          if offset.positive?
            @sftp.file.open(partial, 'r') do |remote|
              remaining = offset
              while remaining.positive?
                chunk = remote.read([remaining, 1024 * 1024].min)
                raise Error, 'REMOTE_PARTIAL_MISMATCH' if !chunk || chunk.empty? || chunk != local.read(chunk.bytesize)
                remaining -= chunk.bytesize
              end
            end
          end
          @sftp.file.open(partial, offset.zero? ? 'w' : 'a') do |remote|
            while (chunk = local.read(1024 * 1024))
              remote.write(chunk)
            end
          end
        end
        @sftp.rename!(partial, final)
        { 'path' => final }
      end

      def stream(reference)
        @sftp.file.open(reference.fetch('path'), 'r') do |remote|
          while (chunk = remote.read(1024 * 1024)) && !chunk.empty?
            yield chunk
          end
        end
      end

      def list_markers(prefix)
        @sftp.dir.entries(@directory).flat_map do |entry|
          next [] unless entry.name.start_with?(prefix)
          path = "#{@directory}/#{entry.name}"
          if entry.name.end_with?('-complete.json') && !entry.attributes.directory? && !entry.attributes.symlink?
            [{ 'path' => path }]
          elsif entry.name.delete_prefix(prefix).match?(/\A\d{8}T\d{6}Z-[a-f0-9]{12}\z/) && entry.attributes.directory? && !entry.attributes.symlink?
            @sftp.dir.entries(path).filter_map do |child|
              { 'path' => "#{path}/complete.json" } if child.name == 'complete.json' && !child.attributes.directory? && !child.attributes.symlink?
            end
          else
            []
          end
        end
      end

      def delete(reference)
        path = reference.fetch('path')
        raise Error, 'SFTP_DELETE_OUTSIDE_NAMESPACE' unless path.start_with?(@directory + '/') && !path.split('/').include?('..')
        @sftp.remove!(path)
      end

      def close
        @sftp&.session&.close
      end

      def assert_reference!(reference, namespace)
        path = reference.fetch('path')
        raise Error, 'FOREIGN_OBJECT_REFERENCE' unless path.start_with?(@directory + '/') && !path.split('/').include?('..')
        raise Error, 'FOREIGN_OBJECT_REFERENCE' unless BackupLayout.owned_key?(path.delete_prefix(@directory + '/'), namespace)
      end
    end
  end
end

require_relative 'providers/cloud_drive'
