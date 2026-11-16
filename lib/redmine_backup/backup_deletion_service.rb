# frozen_string_literal: true

require 'find'

module RedmineBackup
  class BackupDeletionService
    def initialize(runtime, provider_factory: nil)
      @runtime, @store, @config = runtime, runtime.store, runtime.config
      @provider_factory = provider_factory || ->(target, checkpoint) { Providers.build(target, checkpoint: checkpoint) }
    end

    def enqueue!(run_id: nil, actor:)
      raise Error, 'RECOVERY_MODE_REQUIRES_ACTIVATION' if @runtime.recovery?
      raise Error, 'INVALID_RUN_ID' unless run_id.nil? || run_id.is_a?(String)
      @store.run_path(run_id) if run_id
      @store.lock('queue') do
        eligible = BackupDeletionPolicy.new(@store).eligible_ids
        identifiers = run_id ? eligible & [run_id] : eligible
        raise Error, 'BACKUP_PROTECTED_BUSY_OR_NOT_FOUND' if identifiers.empty?
        queue = @store.read('queue', [])
        queue << { 'id' => SecureRandom.hex(16), 'kind' => 'delete_backups', 'run_ids' => identifiers,
                   'actor' => actor, 'requested_at' => Time.now.utc.iso8601 }
        @store.write('queue', queue)
        visibility = @store.read('history_visibility')
        identifiers.each { |identifier| visibility.delete(identifier) }
        @store.write('history_visibility', visibility)
        identifiers.each { |identifier| @store.audit('backup_deletion_requested', actor: actor, run: identifier) }
      end
    end

    # Called under the worker's existing one-run lock. No cloud I/O runs in a controller.
    def perform!(job)
      raise Error, 'RECOVERY_MODE_REQUIRES_ACTIVATION' if @runtime.recovery?
      job.fetch('run_ids').each do |identifier|
        @store.run_path(identifier)
        run = @store.read('runs', []).find { |item| item['id'] == identifier }
        next unless run
        next if run.dig('deletion', 'status') == 'complete'
        begin
          BackupDeletionPolicy.new(@store).assert_deletable!(run)
          validate_local_copy!(run)
          run['deletion'] ||= {}
          run['deletion'].merge!('status' => 'deleting', 'error' => nil)
          save(run)
          delete_remote_copies(run)
          delete_local_copy(run)
          run['deletion'].merge!('status' => 'complete', 'completed_at' => Time.now.utc.iso8601)
          save(run)
          @store.audit('backup_deleted_from_storage', actor: job.fetch('actor', 'worker'), run: identifier)
        rescue StandardError => error
          run['deletion'] ||= {}
          run['deletion'].merge!('status' => 'failed', 'error' => safe_code(error))
          save(run)
          @store.audit('backup_deletion_failed', actor: job.fetch('actor', 'worker'), run: identifier)
        end
      end
    end

    private

    def delete_remote_copies(run)
      run.fetch('destinations', {}).each do |slot, state|
        next if state['deleted_at']
        target = @config.destinations[slot]
        historical = run.fetch('config').fetch(slot)
        raise Error, 'DESTINATION_CHANGED_REVIEW_OLD_STORAGE' unless target && Configuration.fingerprint(target) == Configuration.fingerprint(historical)
        provider = nil
        begin
          checkpoint = lambda do |key, value|
            next unless key == 'oauth_tokens'
            target.merge!(value)
            secrets = @store.read('secrets')
            secrets[slot] = secrets.fetch(slot, {}).merge(value)
            @store.write('secrets', secrets)
          end
          provider = @provider_factory.call(target.dup, checkpoint)
          provider.health!
          verify_protected_copy!(provider, slot, target)
          remove_remote_set(provider, run, state)
          state['deleted_at'] = Time.now.utc.iso8601
          state['verified'] = false
          save(run)
        ensure
          provider&.close
        end
      end
    end

    def verify_protected_copy!(provider, slot, target)
      records = @store.read('runs', []).select do |record|
        state = record.fetch('destinations', {})[slot]
        state && state['verified'] && !state['deleted_at'] &&
          Configuration.fingerprint(record.fetch('config', {}).fetch(slot, {})) == Configuration.fingerprint(target)
      end
      newest = records.max_by { |record| [Time.iso8601(record.fetch('completed_at')), record.fetch('id')] }
      return unless newest
      state = newest.fetch('destinations').fetch(slot)
      references = state.fetch('artifacts', []).map { |item| item.fetch('reference') }
      raise Error, 'PROTECTED_UPLOAD_NOT_FOUND' unless state['marker'] && !references.empty?
      references << state['marker']
      raise Error, 'PROTECTED_UPLOAD_NOT_FOUND' unless references.all? { |reference| provider.reference_exists?(reference) }
      namespace = BackupLayout.folder_name(newest) + '-'
      references.each { |reference| provider.assert_reference!(reference, namespace) }
    end

    def remove_remote_set(provider, run, state)
      namespace = BackupLayout.folder_name(run) + '-'
      references = state.fetch('artifacts', []).map do |item|
        raise Error, 'UNEXPECTED_BACKUP_COMPONENT' unless BackupLayout::COMPONENTS.include?(item.fetch('name'))
        item.fetch('reference')
      end
      references.unshift(state['marker']) if state['marker']
      journal = state['manual_delete'] ||= { 'validated' => [], 'removed' => [] }
      pending = references.reject { |reference| journal['removed'].include?(reference) }
      pending.each do |reference|
        unless provider.reference_exists?(reference)
          journal['removed'] << reference
          next
        end
        provider.assert_reference!(reference, namespace)
        raise Error, 'RETENTION_LOCKED' if provider.locked?(reference)
        journal['validated'] << reference unless journal['validated'].include?(reference)
      end
      folder = state['folder']
      folder_exists = folder && provider.reference_exists?(folder)
      provider.assert_folder!(folder, namespace.delete_suffix('-')) if folder_exists
      save(run)
      # Marker is always first; an interrupted deletion must not advertise a complete set.
      pending.each do |reference|
        next if journal['removed'].include?(reference)
        raise Error, 'UNVALIDATED_DELETE_REFERENCE' unless journal['validated'].include?(reference)
        state['verified'] = false
        save(run)
        provider.delete(reference)
        journal['removed'] << reference
        save(run)
      end
      provider.delete_folder(folder) if folder_exists
    end

    def delete_local_copy(run)
      directory = validate_local_copy!(run)
      FileUtils.remove_entry_secure(directory) if File.exist?(directory)
      run['local_deleted'] = true
    end

    def validate_local_copy!(run)
      directory = @store.run_path(run.fetch('id'))
      parent = File.dirname(directory)
      raise Error, 'UNSAFE_BACKUP_DIRECTORY' if PlatformService.link?(parent) || PlatformService.link?(directory)
      if File.exist?(directory)
        raise Error, 'UNSAFE_BACKUP_DIRECTORY' unless File.directory?(directory) && @store.inside?(File.realpath(directory))
        Find.find(directory) { |path| raise Error, 'UNSAFE_BACKUP_DIRECTORY' if PlatformService.link?(path) }
      end
      directory
    end

    def save(run)
      records = @store.read('runs', [])
      index = records.index { |record| record['id'] == run['id'] }
      raise Error, 'BACKUP_RECORD_NOT_FOUND' unless index
      records[index] = run
      @store.write('runs', records)
    end

    def safe_code(error)
      error.is_a?(Error) && error.message.match?(/\A[A-Z0-9_]+\z/) ? error.message : 'BACKUP_DELETION_FAILED'
    end
  end
end
