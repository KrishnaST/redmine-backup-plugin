# frozen_string_literal: true

require_relative 'test_helper'

class BackupDeletionTest < BackupTest
  class Runtime
    attr_reader :store, :config
    attr_accessor :recovering

    def initialize(store, config)
      @store, @config = store, config
    end

    def recovery?
      recovering
    end
  end

  class Provider < RedmineBackup::Providers::Base
    attr_reader :objects, :deleted
    attr_accessor :locked_key, :fail_key, :stop_key, :folder_error

    def initialize
      super({})
      @objects, @deleted = {}, []
    end

    def reference_exists?(reference)
      reference['name'] || @objects.key?(reference.fetch('key'))
    end

    def assert_reference!(reference, namespace)
      raise RedmineBackup::Error, 'FOREIGN_OBJECT_REFERENCE' unless RedmineBackup::BackupLayout.owned_key?(reference.fetch('key'), namespace)
    end

    def locked?(reference)
      reference['key'] == locked_key
    end

    def delete(reference)
      raise RedmineBackup::WorkerStoppedException if reference['key'] == stop_key
      raise RedmineBackup::Error, 'FIXTURE_DELETE_FAILED' if reference['key'] == fail_key
      @deleted << reference['key']
      @objects.delete(reference['key'])
    end

    def delete_folder(_reference)
      raise RedmineBackup::Error, 'BACKUP_FOLDER_NOT_EMPTY' if folder_error
    end
  end

  def setup
    super
    @store = RedmineBackup::Store.new(File.join(@temporary, 'state'))
    @store.write('metadata', 'installation_id' => 'test-installation')
    @config = config('primary' => { 'provider' => 's3', 'bucket' => 'fixture' })
    @runtime = Runtime.new(@store, @config)
    @provider = Provider.new
    @service = RedmineBackup::BackupDeletionService.new(@runtime, provider_factory: ->(_target, _checkpoint) { @provider })
    @records = (1..3).map { |day| record(day) }
    @store.write('runs', @records)
  end

  def record(day)
    identifier = "202611#{format('%02d', day)}T143000Z-abcdef123456"
    folder = "test-installation-#{identifier}"
    payload = { 'key' => "#{folder}.tar.gz" }
    marker = { 'key' => "#{folder}-complete.json" }
    @provider.objects[payload['key']] = 'payload'
    @provider.objects[marker['key']] = 'marker'
    FileUtils.mkdir_p(@store.run_path(identifier))
    File.write(File.join(@store.run_path(identifier), 'backup.tar.gz'), 'local payload')
    run_record(identifier, date: "2026-11-#{format('%02d', day)}", completed: "2026-11-#{format('%02d', day)}T14:30:00Z",
      installation_id: 'test-installation', status: 'complete', config: @config.values,
      destinations: { 'primary' => { 'verified' => true, 'marker' => marker,
                                    'artifacts' => [{ 'name' => 'backup.tar.gz', 'reference' => payload }] } })
  end

  def result(index = 0)
    @store.read('runs')[index]
  end

  def delete_job(*identifiers)
    { 'id' => 'delete-fixture', 'kind' => 'delete_backups', 'run_ids' => identifiers, 'actor' => '7' }
  end

  def perform(job)
    @store.lock('worker') { @service.perform!(job) }
  end

  def test_queue_is_non_destructive_and_snapshots_only_eligible_runs
    @service.enqueue!(actor: '7')
    assert_equal @records.first(2).map { |run| run['id'] }, @store.read('queue').first['run_ids']
    assert_empty @provider.deleted
    assert File.directory?(@store.run_path(@records.first['id']))
    assert_raises(RedmineBackup::Error) { @service.enqueue!(run_id: @records.last['id'], actor: '7') }
    assert_raises(RedmineBackup::Error) { @service.enqueue!(run_id: @records.first['id'], actor: '7') }
    assert_raises(RedmineBackup::Error) { @service.enqueue!(run_id: {}, actor: '7') }
  end

  def test_delete_removes_marker_first_remote_payloads_and_local_directory_but_retains_history
    job = delete_job(@records.first['id'])
    perform(job)
    assert_equal 'complete', result.dig('deletion', 'status')
    assert result['local_deleted']
    refute File.exist?(@store.run_path(@records.first['id']))
    assert_equal 3, @store.read('runs').length
    assert @provider.deleted.first.end_with?('-complete.json')
    refute result.dig('destinations', 'primary', 'verified')
    assert_equal 'backup_deleted_from_storage', @store.read('audit').last['event']
    assert File.directory?(@store.run_path(@records.last['id']))
    assert_equal 'Deleted from remote and local storage', RedmineBackup::RunStatusService.upload_label(result)
    before = @provider.deleted.dup
    perform(job)
    assert_equal before, @provider.deleted
  end

  def test_forged_job_cannot_delete_latest_successful_upload
    perform(delete_job(@records.last['id']))
    assert_equal 'LATEST_SUCCESSFUL_UPLOAD_PROTECTED', result(2).dig('deletion', 'error')
    assert File.directory?(@store.run_path(@records.last['id']))
    assert_empty @provider.deleted
  end

  def test_protection_is_rechecked_when_a_newer_copy_is_no_longer_verified
    @service.enqueue!(run_id: @records[1]['id'], actor: '7')
    @records.last['destinations']['primary']['verified'] = false
    @records.last['status'] = 'upload_failed'
    @store.write('runs', @records)
    perform(@store.read('queue').first)
    assert_equal 'LATEST_SUCCESSFUL_UPLOAD_PROTECTED', result(1).dig('deletion', 'error')
    assert_empty @provider.deleted
  end

  def test_newer_failed_capture_does_not_displace_latest_successful_upload
    failed = record(4).merge('status' => 'capture_failed', 'captured' => false, 'destinations' => {})
    @store.write('runs', @records + [failed])
    eligible = RedmineBackup::BackupDeletionPolicy.new(@store).eligible_ids
    assert_includes eligible, failed['id']
    refute_includes eligible, @records.last['id']
  end

  def test_missing_protected_remote_copy_prevents_deleting_older_copies
    @provider.objects.delete(@records.last.dig('destinations', 'primary', 'marker', 'key'))
    perform(delete_job(@records.first['id']))
    assert_equal 'PROTECTED_UPLOAD_NOT_FOUND', result.dig('deletion', 'error')
    assert_empty @provider.deleted
    assert File.directory?(@store.run_path(@records.first['id']))
  end

  def test_hold_and_foreign_references_prevent_any_deletion
    @provider.locked_key = @records.first.dig('destinations', 'primary', 'artifacts', 0, 'reference', 'key')
    perform(delete_job(@records.first['id']))
    assert_equal 'RETENTION_LOCKED', result.dig('deletion', 'error')
    assert_empty @provider.deleted
    @provider.locked_key = nil
    records = @store.read('runs')
    records.first['destinations']['primary']['artifacts'].first['reference'] = @records.last.dig('destinations', 'primary', 'artifacts', 0, 'reference')
    @store.write('runs', records)
    perform(delete_job(@records.first['id']))
    assert_equal 'FOREIGN_OBJECT_REFERENCE', result.dig('deletion', 'error')
    assert_empty @provider.deleted
  end

  def test_failed_delete_keeps_local_copy_and_can_resume_after_marker_was_removed
    @provider.fail_key = @records.first.dig('destinations', 'primary', 'artifacts', 0, 'reference', 'key')
    job = delete_job(@records.first['id'])
    perform(job)
    assert_equal 'failed', result.dig('deletion', 'status')
    assert File.directory?(@store.run_path(@records.first['id']))
    assert_equal 1, @provider.deleted.length
    @provider.fail_key = nil
    perform(job)
    assert_equal 'complete', result.dig('deletion', 'status')
    assert_equal 2, @provider.deleted.length
  end

  def test_managed_shutdown_preserves_a_resumable_deletion
    @provider.stop_key = @records.first.dig('destinations', 'primary', 'artifacts', 0, 'reference', 'key')
    job = delete_job(@records.first['id'])
    assert_raises(RedmineBackup::WorkerStoppedException) { perform(job) }
    assert_equal 'deleting', result.dig('deletion', 'status')
    assert File.directory?(@store.run_path(@records.first['id']))
    @provider.stop_key = nil
    perform(job)
    assert_equal 'complete', result.dig('deletion', 'status')
  end

  def test_already_missing_remote_and_local_payloads_are_idempotent
    state = @records.first['destinations']['primary']
    @provider.objects.delete(state['marker']['key'])
    @provider.objects.delete(state['artifacts'].first['reference']['key'])
    FileUtils.remove_entry(@store.run_path(@records.first['id']))
    perform(delete_job(@records.first['id']))
    assert_equal 'complete', result.dig('deletion', 'status')
    assert_empty @provider.deleted
  end

  def test_reconfigured_destination_and_unsafe_local_paths_preserve_backups
    @config.values['primary']['bucket'] = 'different'
    # Historical configuration is a value snapshot, not the current mutable hash.
    records = @store.read('runs')
    records.each { |run| run['config']['primary']['bucket'] = 'fixture' }
    @store.write('runs', records)
    perform(delete_job(@records.first['id']))
    assert_equal 'DESTINATION_CHANGED_REVIEW_OLD_STORAGE', result.dig('deletion', 'error')
    assert_empty @provider.deleted
    directory = @store.run_path(@records.first['id'])
    RedmineBackup::PlatformService.stub(:link?, ->(path) { path == directory }) do
      perform(delete_job(@records.first['id']))
    end
    assert_equal 'UNSAFE_BACKUP_DIRECTORY', result.dig('deletion', 'error')
    assert File.directory?(directory)
  end

  def test_recovery_mode_and_foreign_installation_are_blocked
    @runtime.recovering = true
    assert_raises(RedmineBackup::Error) { @service.enqueue!(actor: '7') }
    assert_raises(RedmineBackup::Error) { perform(delete_job(@records.first['id'])) }
    @runtime.recovering = false
    records = @store.read('runs')
    records.first['installation_id'] = 'foreign'
    @store.write('runs', records)
    perform(delete_job(@records.first['id']))
    assert_equal 'FOREIGN_BACKUP_INSTALLATION', result.dig('deletion', 'error')
    assert_empty @provider.deleted
  end

  def test_no_upload_success_preserves_latest_captured_local_backup
    @records.each { |run| run['destinations'] = {}; run['status'] = 'upload_failed' }
    @store.write('runs', @records)
    assert_equal [@records.last['id']], RedmineBackup::BackupDeletionPolicy.new(@store).protected_ids(@records)
  end

  def test_bulk_deletion_uses_a_request_time_snapshot_and_exposes_hidden_results
    @store.write('history_visibility', @records.to_h { |run| [run['id'], run['completed_at']] })
    @service.enqueue!(actor: '7')
    job = @store.read('queue').first
    assert_equal @records.first(2).map { |run| run['id'] }, job['run_ids']
    later = record(4)
    @store.write('runs', @store.read('runs') + [later])
    perform(job)
    assert_equal @records.first(2).map { |run| run['id'] }, RedmineBackup::HistoryService.new(@store).visible_runs.map { |run| run['id'] }.first(2)
    assert File.directory?(@store.run_path(later['id']))
    assert File.directory?(@store.run_path(@records.last['id']))
    assert result(0)['local_deleted']
    assert result(1)['local_deleted']
  end

  def test_secondary_latest_copy_is_protected_even_when_primary_has_newer_success
    records = @store.read('runs')
    records[1]['destinations']['secondary'] = { 'verified' => true }
    records[1]['config']['secondary'] = { 'provider' => 's3', 'bucket' => 'secondary' }
    records[1]['secondary_mode'] = 'redundant'
    @store.write('runs', records)
    protected = RedmineBackup::BackupDeletionPolicy.new(@store).protected_ids(records)
    assert_includes protected, records[1]['id']
    assert_includes protected, records[2]['id']
    assert_equal [records[0]['id']], RedmineBackup::BackupDeletionPolicy.new(@store).eligible_ids
  end

  def test_secondary_failure_retains_local_copy_and_resumes_without_redeleting_primary
    @config.values['secondary'] = { 'enabled' => true, 'mode' => 'redundant', 'provider' => 's3', 'bucket' => 'secondary' }
    secondary = Provider.new
    records = @store.read('runs')
    records.each do |run|
      run['secondary_mode'] = 'redundant'
      run['config'] = JSON.parse(JSON.generate(@config.values))
      run['destinations']['secondary'] = JSON.parse(JSON.generate(run['destinations']['primary']))
      state = run['destinations']['secondary']
      secondary.objects[state['marker']['key']] = 'marker'
      secondary.objects[state['artifacts'].first['reference']['key']] = 'payload'
    end
    @store.write('runs', records)
    factory = ->(target, _checkpoint) { target['bucket'] == 'secondary' ? secondary : @provider }
    @service = RedmineBackup::BackupDeletionService.new(@runtime, provider_factory: factory)
    secondary.fail_key = records.first.dig('destinations', 'secondary', 'artifacts', 0, 'reference', 'key')
    job = delete_job(records.first['id'])
    perform(job)
    assert result.dig('destinations', 'primary', 'deleted_at')
    assert File.directory?(@store.run_path(records.first['id']))
    first_deletions = @provider.deleted.dup
    secondary.fail_key = nil
    perform(job)
    assert_equal first_deletions, @provider.deleted
    assert_equal 'complete', result.dig('deletion', 'status')
    refute File.exist?(@store.run_path(records.first['id']))
  end

  def test_unrelated_folder_contents_prevent_local_removal_and_can_be_retried
    records = @store.read('runs')
    records.first['destinations']['primary']['folder'] = { 'name' => RedmineBackup::BackupLayout.folder_name(records.first) }
    @store.write('runs', records)
    @provider.folder_error = true
    job = delete_job(records.first['id'])
    perform(job)
    assert_equal 'BACKUP_FOLDER_NOT_EMPTY', result.dig('deletion', 'error')
    assert File.directory?(@store.run_path(records.first['id']))
    assert_equal 2, @provider.deleted.length
    @provider.folder_error = false
    perform(job)
    assert_equal 'complete', result.dig('deletion', 'status')
    assert_equal 2, @provider.deleted.length
  end

  def test_oauth_refresh_preserves_other_secrets_and_updates_subsequent_connections
    @store.write('secrets', 'primary' => { 'client_secret' => 'fixture-secret' }, 'secondary' => { 'password' => 'fixture-password' })
    factory = lambda do |_target, checkpoint|
      checkpoint.call('oauth_tokens', { 'access_token' => 'fixture-refreshed', 'expires_at' => 123 })
      @provider
    end
    @service = RedmineBackup::BackupDeletionService.new(@runtime, provider_factory: factory)
    perform(delete_job(@records.first['id']))
    assert_equal 'complete', result.dig('deletion', 'status')
    assert_equal 'fixture-secret', @store.read('secrets').dig('primary', 'client_secret')
    assert_equal 'fixture-password', @store.read('secrets').dig('secondary', 'password')
    assert_equal 'fixture-refreshed', @config['primary']['access_token']
  end
end
