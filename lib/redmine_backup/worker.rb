# frozen_string_literal: true

require_relative 'scheduler'

module RedmineBackup
  class Worker
    def initialize(runtime, provider_factory: nil, capture_factory: nil)
      @runtime, @store, @config = runtime, runtime.store, runtime.config
      @provider_factory = provider_factory || ->(target, checkpoint) { Providers.build(target, checkpoint: checkpoint) }
      @capture_factory = capture_factory || lambda do |config|
        Capture.new(config: config, store: @store, application_root: Rails.root,
                    attachment_root: Attachment.storage_path,
                    database: ActiveRecord::Base.connection_db_config.configuration_hash,
                    secret_key: Rails.application.secret_key_base)
      end
    end

    def tick
      @store.lock('worker', nonblock: true) do
        beat
        return if @runtime.recovery?
        heartbeat = Thread.new { loop { sleep(20); beat } }
        begin
          schedule
          recover_interrupted
          job = claim
          execute(job) if job
          NotificationService.new(@config, @store).deliver_pending
        ensure
          heartbeat.kill
          heartbeat.join
          beat
        end
      end
    end

    def capture_and_upload(job)
      configuration = Configuration.new(@config.values).validate!
      now = Time.now.utc
      run = { 'id' => "#{now.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(6)}",
              'installation_id' => @store.read('metadata').fetch('installation_id'),
              'date' => now.in_time_zone(@config['timezone']).to_date.iso8601,
              'started_at' => now.iso8601, 'completed_at' => now.iso8601,
              'scheduled_at' => job['scheduled_at'],
              'config' => configuration.values, 'secondary_mode' => configuration['secondary']['enabled'] ? configuration['secondary']['mode'] : nil,
              'status' => 'capturing', 'captured' => false, 'destinations' => {}, 'job_id' => job['id'] }
      save_run(run)
      begin
        coverage = @capture_factory.call(configuration).sources
        previous = @store.read('coverage', [])
        run['coverage_changed'] = !previous.empty? && previous != coverage
        @store.write('coverage', coverage)
        attempts = 0
        begin
          run['artifacts'] = @capture_factory.call(configuration).call(run) do
            run['captured'] = true
            run['status'] = 'packaging'
            run['completed_at'] = Time.now.utc.iso8601
            save_run(run)
          end
        rescue Error => error
          attempts += 1
          retry if attempts == 1 && error.message.start_with?('ATTACHMENT_', 'SOURCE_DISAPPEARED_')
          raise
        end
        run['status'] = 'captured'
        save_run(run)
        upload(run)
      rescue StandardError => error
        run['status'] = run['captured'] ? 'packaging_failed' : 'capture_failed'
        run['error'] = safe_code(error)
        save_run(run)
        NotificationService.new(@config, @store).queue(run, run['captured'] ? 'PACKAGING_FAILED' : 'CAPTURE_FAILED')
      end
    end

    def upload(run)
      config = Configuration.new(run.fetch('config')).validate!
      raise Error, 'LOCAL_BACKUP_REMOVED' if run['local_deleted']
      validate_payloads!(run)
      run['status'] = 'uploading'
      save_run(run)
      config.destinations.each do |slot, target|
        break if slot == 'secondary' && run['secondary_mode'] == 'failover' && run.dig('destinations', 'primary', 'verified')
        next if run.dig('destinations', slot, 'verified')
        upload_target(run, slot, target)
      end
      primary = run.dig('destinations', 'primary', 'verified')
      run['status'] = if Retention.offsite_satisfied?(run)
                        primary ? 'complete' : 'failover_used'
                      elsif run['destinations'].values.any? { |state| state['verified'] }
                        'partially_protected'
                      else
                        'upload_failed'
                      end
      run['completed_at'] = Time.now.utc.iso8601
      save_run(run)
      success_notifications(run) if Retention.offsite_satisfied?(run)
      cleanup_local
    end

    private

    def safe_code(error)
      return error.message if error.is_a?(Error) && error.message.match?(/\A[A-Z0-9_]+\z/)
      "OPERATION_FAILED_#{error.class.name.split('::').last.gsub(/[^a-zA-Z0-9]/, '').upcase}"[0, 100]
    end

    def success_notifications(run)
      notices = NotificationService.new(@config, @store)
      if @config['daily_success_summary'] && run['scheduled_at']
        notices.queue(run, 'BACKUP_COMPLETE')
      end
      previous = @store.read('runs', []).reject { |entry| entry['id'] == run['id'] }.last
      if @config['recovery_notifications'] && previous && %w[capture_failed packaging_failed upload_failed partially_protected].include?(previous['status'])
        notices.queue(run, 'BACKUP_RECOVERED')
      end
    end

    def beat
      @store.write('heartbeat', 'at' => Time.now.utc.iso8601, 'pid' => Process.pid,
                                'management' => ENV['REDMINE_BACKUP_WORKER_CHILD'] == '1' ? 'redmine' : 'manual')
    end

    def schedule
      metadata = @store.read('metadata')
      slot = Scheduler.due_slot(@config, now: Time.now.utc, last_slot: metadata['last_slot'], activated_at: metadata['schedule_resumed_at'] || metadata['created_at'])
      return unless slot
      @store.lock('queue') do
        queue = @store.read('queue', [])
        unless queue.any? { |item| item['id'] == "schedule-#{slot}" }
          queue << { 'id' => "schedule-#{slot}", 'kind' => 'backup', 'scheduled_at' => slot }
          @store.write('queue', queue)
        end
      end
      metadata['last_slot'] = slot
      @store.write('metadata', metadata)
    end

    def claim
      job = nil
      @store.lock('queue') do
        queue = @store.read('queue', [])
        job = queue.shift
        if job
          if %w[retry_upload retry_packaging].include?(job['kind'])
            @store.audit('fresh_backup_replaces_queued_retry', run: job['run_id'])
            job = job.except('run_id').merge('kind' => 'backup')
          end
          @store.write('active_job', job)
          @store.write('queue', queue)
        end
      end
      job
    end

    def execute(job)
      acknowledged = false
      case job['kind']
      when 'backup' then capture_and_upload(job)
      when 'test_notification'
        NotificationService.new(@config, @store).queue({ 'id' => 'notification-test-' + job['id'] }, 'TEST_NOTIFICATION')
      when 'health_check' then setup_health
      when 'delete_backups' then BackupDeletionService.new(@runtime, provider_factory: @provider_factory).perform!(job)
      end
      @store.audit('job_finished', run: job['run_id'])
      acknowledged = true
    rescue StandardError
      @store.audit('job_failed', run: job['run_id'])
      NotificationService.new(@config, @store).queue({ 'id' => job['run_id'] || job['id'] }, 'JOB_FAILED')
      acknowledged = true
    ensure
      @store.write('active_job', {}) if acknowledged
    end

    def recover_interrupted
      active = @store.read('active_job')
      return if active.empty?
      affected = @store.read('runs', []).find { |run| run['job_id'] == active['id'] || run['id'] == active['run_id'] }
      @store.lock('queue') do
        queue = @store.read('queue', [])
        queue.reject! { |item| item['id'] == active['id'] }
        terminal = affected && %w[complete failover_used capture_failed packaging_failed upload_failed partially_protected interrupted].include?(affected['status'])
        if terminal
          # The job had finished before its acknowledgement reached durable storage.
        else
          if affected
            affected['status'] = 'interrupted'
            affected['completed_at'] = Time.now.utc.iso8601
            save_run(affected)
            unless queue.any? { |job| %w[backup retry_upload retry_packaging].include?(job['kind']) }
              queue.unshift('id' => SecureRandom.hex(16), 'kind' => 'backup', 'scheduled_at' => affected['scheduled_at'])
            end
          else
            queue.unshift(active.except('run_id').merge('id' => SecureRandom.hex(16), 'kind' => (%w[retry_upload retry_packaging].include?(active['kind']) ? 'backup' : active['kind'])))
          end
        end
        @store.write('queue', queue)
      end
      @store.write('active_job', {})
      @store.audit('interrupted_job_recovered', run: affected&.fetch('id'))
    end

    def setup_health
      results = []
      %w[pg_dump pg_restore].each do |name|
        path = PlatformService.executable(name, directory: @config['pg_bin'])
        begin
          ProcessRunner.new(timeout: 15).call([path, '--version'])
          results << { 'name' => "#{name} executable", 'ok' => true }
        rescue StandardError
          results << { 'name' => "#{name} executable", 'ok' => false }
        end
      end
      begin
        Resources.new(root: @store.root, reserve_mb: @config['disk_reserve_mb'], timeout_seconds: 15).check!
        @capture_factory.call(@config).sources
        results << { 'name' => 'Disk reserve and discovered source paths', 'ok' => true }
      rescue StandardError
        results << { 'name' => 'Disk reserve and discovered source paths', 'ok' => false }
      end
      @config.destinations.each do |slot, target|
        provider = nil
        begin
          checkpoint = lambda do |key, value|
            next unless key == 'oauth_tokens'
            secrets = @store.read('secrets')
            secrets[slot] = secrets.fetch(slot, {}).merge(value)
            @store.write('secrets', secrets)
          end
          provider = @provider_factory.call(target, checkpoint)
          provider.health!
          results << { 'name' => "#{slot.capitalize} destination connection/protection", 'ok' => true }
        rescue StandardError
          results << { 'name' => "#{slot.capitalize} destination connection/protection", 'ok' => false }
        ensure
          provider&.close
        end
      end
      @store.write('setup_health', results)
      @store.audit('setup_health_completed')
    end

    def validate_payloads!(run)
      run.fetch('artifacts').each do |item|
        raise Error, 'UNSAFE_ARTIFACT_NAME' unless item.fetch('name').match?(/\A[a-zA-Z0-9._-]+\z/)
        path = File.join(@store.run_path(run.fetch('id')), item['name'])
        raise Error, 'LOCAL_INTEGRITY_FAILED' unless File.size(path) == item['bytes'] && Digest::SHA256.file(path).hexdigest == item['sha256']
      end
    end

    def upload_target(run, slot, target)
      state = run['destinations'][slot] ||= { 'verified' => false, 'artifacts' => [], 'sessions' => {} }
      provider = nil
      checkpoint = lambda do |key, value|
        if key == 'oauth_tokens'
          target.merge!(value)
          secrets = @store.read('secrets')
          current = secrets.fetch(slot, {})
          if Configuration.fingerprint(@config[slot]) == Configuration.fingerprint(target)
            secrets[slot] = current.merge(value)
            @store.write('secrets', secrets)
          end
        else
          state['sessions'][state['current_artifact']] = value
        end
        save_run(run)
      end
      3.times do |attempt|
        begin
          provider = @provider_factory.call(target, checkpoint)
          provider.health!
          folder_name = BackupLayout.folder_name(run)
          extension = BackupLayout.archive_extension(run['config']['packaging'])
          unless extension
            state['folder'] = provider.prepare_run(folder_name, state['folder'])
            save_run(run)
          end
          state['protection'] = target['retention_lock'] || target['versioning'] ? 'checking' : 'not_requested'
          run['artifacts'].each do |item|
            next if state['artifacts'].any? { |existing| existing['name'] == item['name'] }
            state['current_artifact'] = item['name']
            key = extension ? "#{folder_name}.#{extension}" : "#{folder_name}/#{item['name']}"
            reference = provider.upload(File.join(@store.run_path(run['id']), item['name']), key, state['sessions'].fetch(item['name'], {}))
            provider.verify!(reference, item)
            state['artifacts'] << item.merge('reference' => reference)
            save_run(run)
          end
          record = { 'installation_id' => run['installation_id'], 'id' => run['id'], 'date' => run['date'],
                     'completed_at' => Time.now.utc.iso8601, 'verified' => true, 'artifacts' => state['artifacts'], 'folder' => state['folder'] }
          marker_path = File.join(@store.run_path(run['id']), "#{slot}-complete.json")
          @store.atomic(marker_path, JSON.generate(record))
          state['current_artifact'] = 'marker'
          marker_key = extension ? "#{folder_name}-complete.json" : "#{folder_name}/complete.json"
          state['marker'] = provider.upload(marker_path, marker_key, state['sessions'].fetch('marker', {}))
          provider.verify!(state['marker'], 'bytes' => File.size(marker_path), 'sha256' => Digest::SHA256.file(marker_path).hexdigest)
          state['verified'], state['completed_at'], state['error'] = true, Time.now.utc.iso8601, nil
          state['protection'] = 'verified' if target['retention_lock'] || target['versioning']
          save_run(run)
          cleanup_remote(provider, run, slot)
          break
        rescue StandardError => error
          state['error'] = safe_code(error)
          state['protection'] = 'failed' if state['error'].match?(/PROTECTION|OBJECT_LOCK|VERSIONING/)
          save_run(run)
          if attempt == 2
            NotificationService.new(@config, @store).queue(run, "#{slot.upcase}_UPLOAD_FAILED")
          else
            sleep(2**attempt)
          end
        ensure
          provider&.close
        end
      end
    end

    def cleanup_remote(provider, run, slot)
      if Configuration.fingerprint(run['config'][slot]) != Configuration.fingerprint(@config[slot])
        run['destinations'][slot]['cleanup'] = 'skipped_destination_changed'
        return
      end
      records = provider.list_markers("#{run['installation_id']}-").map do |reference|
        data = +''
        provider.stream(reference) do |chunk|
          raise Error, 'REMOTE_MARKER_TOO_LARGE' if data.bytesize + chunk.bytesize > 1024 * 1024
          data << chunk
        end
        record = JSON.parse(data)
        raise Error, 'FOREIGN_BACKUP_MARKER' unless record['installation_id'] == run['installation_id'] && record['verified'] == true
        @store.run_path(record.fetch('id'))
        namespace = "#{run['installation_id']}-#{record['id']}-"
        provider.assert_folder!(record['folder'], namespace.delete_suffix('-')) if record['folder']
        provider.assert_reference!(reference, namespace)
        record.fetch('artifacts').each { |item| provider.assert_reference!(item.fetch('reference'), namespace) }
        record.merge('marker' => reference)
      end
      # Duplicate completion markers may reference the same immutable artifacts.
      # Keep that run intact rather than deleting a shared payload through one marker.
      duplicates = records.group_by { |record| record['id'] }.select { |_id, items| items.length > 1 }.keys
      records.reject! { |record| duplicates.include?(record['id']) }
      Retention.candidates(records, @config.remote_keep(slot)).each do |record|
        provider.delete_set!(record)
        @store.audit('remote_retention_deleted', run: record['id'])
      end
      run['destinations'][slot]['cleanup'] = 'complete'
    rescue StandardError => error
      run['destinations'][slot]['cleanup'] = error.is_a?(Error) && error.message == 'RETENTION_LOCKED' ? 'deferred_locked' : 'cleanup_failed'
      @store.audit('remote_cleanup_deferred', run: run['id'])
    ensure
      save_run(run)
    end

    def cleanup_local
      runs = @store.read('runs', [])
      Retention.local_candidates(runs, @config['local_keep_dates']).each do |run|
        path = @store.run_path(run['id'])
        raise Error, 'UNSAFE_BACKUP_DIRECTORY' unless @store.inside?(path) && !PlatformService.link?(path)
        FileUtils.remove_entry_secure(path) if File.directory?(path)
        run['local_deleted'] = true
        @store.audit('local_retention_deleted', run: run['id'])
      end
      @store.write('runs', runs)
    end

    def save_run(run)
      runs = @store.read('runs', [])
      runs.reject! { |existing| existing['id'] == run['id'] }
      @store.write('runs', runs + [run])
    end

  end
end
