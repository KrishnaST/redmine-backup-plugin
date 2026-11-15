# frozen_string_literal: true

require 'socket'

module RedmineBackup
  class Runtime
    SECRET_FIELDS = %w[password private_key key_passphrase client_secret secret_access_key session_token access_token refresh_token expires_at service_account_json certificate_pem].freeze
    TARGET_FIELDS = %w[provider auth_method enabled mode remote_keep_dates versioning retention_lock lock_days region endpoint bucket prefix access_key_id host port username private_key_path known_hosts directory account_type client_id tenant_id folder_id shared_drive_id drive_id site_id impersonated_user federated_token_path user_assertion_path].freeze
    attr_reader :store, :config

    def self.host_identity
      machine = File.read('/etc/machine-id').strip if File.file?('/etc/machine-id')
      Digest::SHA256.hexdigest([Socket.gethostname, machine, Rails.root.to_s].join('|'))
    end

    def initialize
      RedmineBackup.load_runtime!
      # Redmine caches this hash: never merge private credentials into that shared object.
      raw = JSON.parse(JSON.generate(Setting.plugin_redmine_backup_plugin.to_h))
      defaults = File.join(Attachment.storage_path, 'redmine-backups')
      root = raw['local_directory'].to_s.empty? ? defaults : raw['local_directory']
      parent = File.realpath(File.dirname(File.expand_path(root)))
      root = File.join(parent, File.basename(root))
      public_root = File.join(File.realpath(Rails.root), 'public')
      raise Error, 'PUBLIC_BACKUP_DIRECTORY' if root == public_root || root.start_with?(public_root + '/')
      raise Error, 'WRITABLE_PARENT_REQUIRED' unless File.writable?(parent)
      key = ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base).generate_key('redmine-backup-v1', 32)
      @encryptor = ActiveSupport::MessageEncryptor.new(key, cipher: 'aes-256-gcm', serializer: JSON)
      @store = Store.new(root, encryptor: @encryptor)
      secrets = store.read('secrets')
      %w[primary secondary].each { |slot| raw[slot] = raw.fetch(slot, {}).merge(secrets.fetch(slot, {})) }
      @config = Configuration.new(raw).validate!
      store.lock('metadata') do
        metadata = store.read('metadata')
        if metadata.empty?
          store.write('metadata', 'installation_id' => SecureRandom.uuid, 'host_identity' => self.class.host_identity,
                                  'created_at' => Time.now.utc.iso8601)
        end
      end
    end

    def recovery?
      config['recovery_mode'] || File.exist?(File.join(store.root, 'control', 'RECOVERY')) ||
        ENV['REDMINE_BACKUP_RECOVERY'] == '1' || store.read('metadata')['host_identity'] != self.class.host_identity
    end

    def save!(input, actor:)
      updated = Configuration.new(input).validate!
      original_store = store
      original_store.lock('worker', nonblock: true) do
        desired = File.expand_path(input['local_directory'].to_s.empty? ? store.root : input['local_directory'])
        if desired != store.root
          raise Error, 'EXISTING_BACKUPS_REQUIRE_DOCUMENTED_STORAGE_MIGRATION' unless store.read('runs', []).empty? && store.read('queue', []).empty?
          parent = File.realpath(File.dirname(desired))
          desired = File.join(parent, File.basename(desired))
          public_root = File.join(File.realpath(Rails.root), 'public')
          raise Error, 'PUBLIC_BACKUP_DIRECTORY' if desired == public_root || desired.start_with?(public_root + '/')
          raise Error, 'WRITABLE_PARENT_REQUIRED' unless File.writable?(parent)
          raise Error, 'DESTINATION_MUST_BE_EMPTY' if File.exist?(desired) && !Dir.empty?(desired)
          metadata = store.read('metadata')
          @store = Store.new(desired, encryptor: @encryptor)
          store.write('metadata', metadata)
          updated.values['local_directory'] = desired
        end
        metadata = store.read('metadata')
        metadata['schedule_resumed_at'] = Time.now.utc.iso8601 if updated['enabled'] && !config['enabled']
        store.write('metadata', metadata)
        secrets = {}
        public_values = updated.values.dup
        %w[primary secondary].each do |slot|
          public_values[slot] = updated[slot].reject { |key, _| SECRET_FIELDS.include?(key) }
          secrets[slot] = updated[slot].slice(*SECRET_FIELDS)
        end
        store.write('secrets', secrets)
        Setting.plugin_redmine_backup_plugin = public_values
        store.write('bootstrap', 'settings' => public_values, 'secrets' => secrets,
                                 'installation_id' => store.read('metadata')['installation_id'])
        store.audit('settings_changed', actor: actor)
      end || raise(Error, 'WORKER_BUSY_RETRY_SETTINGS')
    end

    def enqueue!(kind, run_id: nil, actor: 'administrator')
      raise Error, 'RECOVERY_MODE_REQUIRES_ACTIVATION' if recovery?
      raise Error, 'INVALID_JOB_KIND' unless %w[backup retry_upload retry_packaging test_notification health_check].include?(kind)
      store.run_path(run_id) if run_id
      store.lock('queue') do
        queue = store.read('queue', [])
        active = store.read('active_job')
        already_active = active['kind'] == kind && active['run_id'] == run_id
        unless already_active || queue.any? { |job| job['kind'] == kind && job['run_id'] == run_id }
          queue << { 'id' => SecureRandom.hex(16), 'kind' => kind, 'run_id' => run_id, 'requested_at' => Time.now.utc.iso8601 }
          store.write('queue', queue)
        end
      end
      store.audit(kind, actor: actor, run: run_id)
    end

    def activate!(actor:)
      store.lock('worker', nonblock: true) do
        metadata = store.read('metadata')
        metadata['host_identity'] = self.class.host_identity
        store.write('metadata', metadata)
        recovery_flag = File.join(store.root, 'control', 'RECOVERY')
        File.delete(recovery_flag) if File.file?(recovery_flag)
        input = config.values.merge('recovery_mode' => false, 'enabled' => false)
        public_values = input.transform_values(&:itself)
        %w[primary secondary].each { |slot| public_values[slot] = input[slot].reject { |key, _| SECRET_FIELDS.include?(key) } }
        Setting.plugin_redmine_backup_plugin = public_values
        store.audit('recovery_instance_activated_schedule_remains_paused', actor: actor)
      end || raise(Error, 'WORKER_BUSY')
    end

    def health
      checks = []
      checks << { 'name' => 'Private local storage', 'ok' => (File.stat(store.root).mode & 0o077).zero? }
      heartbeat = store.read('heartbeat')['at']
      checks << { 'name' => 'Background worker heartbeat', 'ok' => heartbeat && Time.iso8601(heartbeat) > Time.now - 120 }
      checks << { 'name' => 'Recovery activation', 'ok' => !recovery? }
      configuration = ActiveRecord::Base.connection_db_config.configuration_hash
      checks << { 'name' => 'PostgreSQL adapter', 'ok' => configuration[:adapter] == 'postgresql' }
      credential_paths = config.destinations.values.flat_map { |target| target.values_at('federated_token_path', 'user_assertion_path') }.compact.reject(&:empty?)
      paths = [Rails.root.to_s, Attachment.storage_path, *config['additional_paths'], *credential_paths]
      checks << { 'name' => 'Coverage paths readable', 'ok' => paths.all? { |path| File.readable?(path) } }
      checks << { 'name' => 'Alert recipients', 'ok' => NotificationService.new(config, store).recipient_ids.any? }
      checks.concat(store.read('setup_health', []))
      checks
    end
  end
end
