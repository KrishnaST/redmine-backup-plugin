# frozen_string_literal: true

module RedmineBackup
  class RecoveryBootstrap
    def self.restore(bootstrap_path, destination)
      require 'active_support'
      require 'active_support/key_generator'
      require 'active_support/message_encryptor'
      bootstrap = JSON.parse(File.read(bootstrap_path))
      root = File.expand_path(destination)
      raise Error, 'RECOVERY_DESTINATION_MUST_BE_EMPTY' if File.exist?(root) && (!File.directory?(root) || !Dir.empty?(root))
      raise Error, 'RECOVERY_PARENT_REQUIRED' unless File.directory?(File.dirname(root)) && File.writable?(File.dirname(root))
      key = ActiveSupport::KeyGenerator.new(bootstrap.fetch('secret_key_base')).generate_key('redmine-backup-v1', 32)
      encryptor = ActiveSupport::MessageEncryptor.new(key, cipher: 'aes-256-gcm', serializer: JSON)
      store = Store.new(root, encryptor: encryptor)
      bootstrap.fetch('private_state').each do |name, value|
        next unless %w[metadata audit runs coverage secrets].include?(name)
        if name == 'runs'
          value.each do |run|
            run['local_deleted'] = true
            run['status'] = 'historical_import'
          end
        end
        store.write(name, value)
      end
      store.write('queue', [])
      store.write('active_job', {})
      store.atomic(File.join(root, 'control', 'RECOVERY'), 'Activation required')
      settings = bootstrap.fetch('config').merge('enabled' => false, 'recovery_mode' => true, 'local_directory' => root)
      %w[primary secondary].each do |slot|
        settings[slot] = settings.fetch(slot, {}).reject { |key_name, _| %w[password private_key client_secret secret_access_key session_token access_token refresh_token expires_at].include?(key_name) }
      end
      store.atomic(File.join(root, 'restored-plugin-settings.json'), JSON.pretty_generate(settings))
      store.audit('offline_bootstrap_restored')
      store
    end
  end
end
