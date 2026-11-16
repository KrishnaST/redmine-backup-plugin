# frozen_string_literal: true

require_relative 'test_helper'

class WorkerTest < BackupTest
  class Runtime
    attr_reader :store, :config

    def initialize(store, config)
      @store, @config = store, config
    end

    def recovery?
      false
    end
  end

  class FakeProvider < RedmineBackup::Providers::Base
    attr_accessor :fail_upload, :locked
    attr_reader :objects, :deleted

    def initialize
      super({})
      @objects, @deleted = {}, []
    end

    def upload(path, key, _session)
      raise RedmineBackup::Error, 'TEST_UPLOAD_FAILED' if fail_upload
      @objects[key] = File.binread(path)
      { 'key' => key }
    end

    def stream(reference)
      yield @objects.fetch(reference.fetch('key'))
    end

    def list_markers(prefix)
      @objects.keys.filter_map { |key| { 'key' => key } if key.start_with?(prefix) && key.end_with?('-complete.json', '/complete.json') }
    end

    def assert_reference!(reference, namespace)
      raise RedmineBackup::Error, 'FOREIGN_REFERENCE' unless RedmineBackup::BackupLayout.owned_key?(reference.fetch('key'), namespace)
    end

    def delete(reference)
      @deleted << reference['key']
      @objects.delete(reference['key'])
    end

    def locked?(_reference)
      locked
    end
  end

  class Notices
    attr_reader :events

    def initialize
      @events = []
    end

    def queue(_run, code)
      events << code
    end

    def deliver_pending; end
  end

  def setup
    super
    @store = RedmineBackup::Store.new(File.join(@temporary, 'state'))
    @primary, @secondary = FakeProvider.new, FakeProvider.new
    @notices = Notices.new
  end

  def setup_run(mode = nil, **overrides)
    settings = { 'primary' => { 'provider' => 's3', 'bucket' => 'primary' } }
    settings['secondary'] = { 'enabled' => true, 'provider' => 's3', 'bucket' => 'secondary', 'mode' => mode } if mode
    @config = config(settings.merge(overrides.stringify_keys))
    @run = run_record('20261115T143000Z-abcdef123456', installation_id: 'test-installation', config: JSON.parse(JSON.generate(@config.values)),
                      destinations: {}, secondary_mode: mode, status: 'captured')
    FileUtils.mkdir_p(@store.run_path(@run['id']))
    File.binwrite(File.join(@store.run_path(@run['id']), 'database.dump'), 'dump')
    @run['artifacts'] = [{ 'name' => 'database.dump', 'bytes' => 4, 'sha256' => Digest::SHA256.hexdigest('dump') }]
    factory = ->(target, _checkpoint) { target['bucket'] == 'primary' ? @primary : @secondary }
    @worker = RedmineBackup::Worker.new(Runtime.new(@store, @config), provider_factory: factory)
    @worker.define_singleton_method(:sleep) { |_seconds| nil }
  end

  def upload
    RedmineBackup::NotificationService.stub(:new, @notices) { @worker.upload(@run) }
  end

  def test_primary_only_never_uses_secondary
    setup_run
    upload
    assert_equal 'complete', @run['status']
    assert_empty @secondary.objects
    folder = RedmineBackup::BackupLayout.folder_name(@run)
    assert_equal ["#{folder}/complete.json", "#{folder}/database.dump"], @primary.objects.keys.sort
    assert_equal folder, @run.dig('destinations', 'primary', 'folder', 'name')
  end

  def test_zip_upload_is_one_named_archive_in_destination_root
    setup_run(nil, packaging: 'zip')
    File.write(File.join(@store.run_path(@run['id']), 'backup.zip'), 'archive')
    @run['artifacts'] = [{ 'name' => 'backup.zip', 'bytes' => 7, 'sha256' => Digest::SHA256.hexdigest('archive') }]
    upload
    folder = RedmineBackup::BackupLayout.folder_name(@run)
    assert_equal 'complete', @run['status']
    assert_equal ["#{folder}-complete.json", "#{folder}.zip"], @primary.objects.keys.sort
    refute @run['destinations']['primary'].key?('folder')
    assert_equal 'complete', @run.dig('destinations', 'primary', 'cleanup')
  end

  def test_folder_retention_deletes_payloads_marker_and_the_empty_container
    setup_run(nil, remote_keep_dates: 1)
    old_id = '20261101T143000Z-abcdef123456'
    folder = "test-installation-#{old_id}"
    marker = "#{folder}/complete.json"
    payload = "#{folder}/database.dump"
    @primary.objects[payload] = 'older dump'
    @primary.objects[marker] = JSON.generate('installation_id' => 'test-installation', 'id' => old_id, 'date' => '2026-11-01',
                                             'completed_at' => '2026-11-01T14:30:00Z', 'verified' => true, 'folder' => { 'name' => folder },
                                             'artifacts' => [{ 'reference' => { 'key' => payload } }])
    removed = []
    @primary.define_singleton_method(:delete_folder) { |reference| removed << reference['name'] }
    upload
    assert_equal 'complete', @run.dig('destinations', 'primary', 'cleanup')
    assert_equal [folder], removed
    refute @primary.objects.key?(marker)
    refute @primary.objects.key?(payload)
    assert @run.dig('destinations', 'primary', 'verified')
  end

  def test_tar_upload_is_one_named_archive_and_retention_understands_older_zip_archives
    setup_run(nil, packaging: 'tar_gz', remote_keep_dates: 1)
    File.write(File.join(@store.run_path(@run['id']), 'backup.tar.gz'), 'archive')
    @run['artifacts'] = [{ 'name' => 'backup.tar.gz', 'bytes' => 7, 'sha256' => Digest::SHA256.hexdigest('archive') }]
    old_folder = 'test-installation-20261101T143000Z-abcdef123456'
    @primary.objects["#{old_folder}.zip"] = 'old ZIP'
    @primary.objects["#{old_folder}-complete.json"] = JSON.generate(
      'installation_id' => 'test-installation', 'id' => '20261101T143000Z-abcdef123456',
      'date' => '2026-11-01', 'completed_at' => '2026-11-01T14:30:00Z', 'verified' => true,
      'artifacts' => [{ 'reference' => { 'key' => "#{old_folder}.zip" } }]
    )
    upload
    folder = RedmineBackup::BackupLayout.folder_name(@run)
    assert_equal 'complete', @run['status']
    assert_equal ["#{folder}-complete.json", "#{folder}.tar.gz"], @primary.objects.keys.sort
    refute @run['destinations']['primary'].key?('folder')
    assert_equal 'complete', @run.dig('destinations', 'primary', 'cleanup')
    assert_includes @primary.deleted, "#{old_folder}.zip"
  end

  def test_redundant_uploads_both
    setup_run('redundant')
    upload
    assert_equal 'complete', @run['status']
    assert @run.dig('destinations', 'primary', 'verified')
    assert @run.dig('destinations', 'secondary', 'verified')
  end

  def test_redundant_attempts_secondary_even_after_primary_failure
    setup_run('redundant')
    @primary.fail_upload = true
    upload
    assert_equal 'partially_protected', @run['status']
    assert @run.dig('destinations', 'secondary', 'verified')
    assert_includes @notices.events, 'PRIMARY_UPLOAD_FAILED'
  end

  def test_failover_uses_secondary_after_primary_failure
    setup_run('failover')
    @primary.fail_upload = true
    upload
    assert_equal 'failover_used', @run['status']
    assert_includes @notices.events, 'PRIMARY_UPLOAD_FAILED'
  end

  def test_failover_does_not_upload_secondary_when_primary_succeeds
    setup_run('failover')
    upload
    assert_empty @secondary.objects
  end

  def test_retry_skips_already_verified_target
    setup_run('redundant')
    @secondary.fail_upload = true
    upload
    primary_count = @primary.objects.length
    @primary.fail_upload = true
    @secondary.fail_upload = false
    upload
    assert_equal 'complete', @run['status']
    assert_equal primary_count, @primary.objects.length
  end

  def test_tampered_payload_is_not_uploaded
    setup_run
    File.binwrite(File.join(@store.run_path(@run['id']), 'database.dump'), 'bad!')
    assert_raises(RedmineBackup::Error) { upload }
    assert_empty @primary.objects
  end

  def test_locked_remote_cleanup_does_not_change_verified_upload_success
    setup_run(nil, remote_keep_dates: 1)
    @primary.locked = true
    older = @run.merge('id' => '20261101T143000Z-abcdef123456', 'date' => '2026-11-01', 'completed_at' => '2026-11-01T14:30:00Z', 'verified' => true,
                      'artifacts' => [{ 'reference' => { 'key' => 'test-installation-20261101T143000Z-abcdef123456-data' } }])
    @primary.objects['test-installation-20261101T143000Z-abcdef123456-complete.json'] = JSON.generate(older)
    upload
    assert_equal 'complete', @run['status']
    assert_equal 'deferred_locked', @run.dig('destinations', 'primary', 'cleanup')
    assert_empty @primary.deleted
  end

  def test_historical_upload_cannot_cleanup_a_reconfigured_destination
    setup_run
    @config.values['primary'] = @config['primary'].merge('bucket' => 'new-location')
    # The durable run contains its own historical settings, not a shared reference.
    @run['config']['primary'] = { 'provider' => 's3', 'bucket' => 'primary' }
    upload
    assert_equal 'skipped_destination_changed', @run.dig('destinations', 'primary', 'cleanup')
  end

  def test_queued_upload_recovery_captures_fresh_data_with_current_storage
    setup_run
    @store.write('metadata', 'installation_id' => 'test-installation')
    @run['status'] = 'upload_failed'
    @run['completed_at'] = (Time.now.utc - 60).iso8601
    @run['destinations']['primary'] = { 'verified' => false, 'sessions' => { 'database.dump' => { 'url' => 'stale-session' } } }
    original = JSON.parse(JSON.generate(@run))
    @store.write('runs', [@run])
    @store.write('queue', [{ 'id' => 'old-retry', 'kind' => 'retry_upload', 'run_id' => @run['id'] }])
    @config.values['primary'] = @config['primary'].merge('bucket' => 'secondary')
    store = @store
    capture = Object.new
    capture.define_singleton_method(:sources) { [] }
    capture.define_singleton_method(:call) do |run, &block|
      FileUtils.mkdir_p(store.run_path(run['id']))
      File.write(File.join(store.run_path(run['id']), 'database.dump'), 'fresh-data')
      block.call
      [{ 'name' => 'database.dump', 'bytes' => 10, 'sha256' => Digest::SHA256.hexdigest('fresh-data') }]
    end
    @worker.instance_variable_set(:@capture_factory, ->(_config) { capture })
    job = @worker.send(:claim)
    assert_equal 'backup', job['kind']
    refute job.key?('run_id')
    RedmineBackup::NotificationService.stub(:new, @notices) { @worker.send(:execute, job) }
    runs = @store.read('runs')
    assert_equal 2, runs.length
    assert_equal original, runs.first
    fresh = runs.last
    refute_equal @run['id'], fresh['id']
    assert_equal 'complete', fresh['status']
    assert_equal 'secondary', fresh['config']['primary']['bucket']
    assert_equal 'fresh-data', File.read(File.join(@store.run_path(fresh['id']), 'database.dump'))
    assert_empty @primary.objects
    assert_equal 2, @secondary.objects.length
  end

  def test_interrupted_upload_starts_new_capture_instead_of_resuming_old_snapshot
    setup_run
    @run.merge!('status' => 'uploading', 'job_id' => 'interrupted-job')
    @store.write('runs', [@run])
    @store.write('active_job', 'id' => 'interrupted-job', 'kind' => 'backup')
    @worker.send(:recover_interrupted)
    job = @store.read('queue').first
    assert_equal 'backup', job['kind']
    refute job.key?('run_id')
    assert_equal 'interrupted', @store.read('runs').first['status']
    assert_equal 'dump', File.read(File.join(@store.run_path(@run['id']), 'database.dump'))
  end

  def test_queued_packaging_recovery_also_requires_fresh_capture
    setup_run
    @store.write('queue', [{ 'id' => 'old-packaging', 'kind' => 'retry_packaging', 'run_id' => @run['id'] }])
    job = @worker.send(:claim)
    assert_equal 'backup', job['kind']
    refute job.key?('run_id')
  end

  def test_restart_recovery_shares_an_existing_fresh_scheduled_backup
    setup_run
    @run.merge!('status' => 'uploading', 'job_id' => 'interrupted-job')
    @store.write('runs', [@run])
    @store.write('active_job', 'id' => 'interrupted-job', 'kind' => 'backup')
    @store.write('queue', [{ 'id' => 'current-schedule', 'kind' => 'backup' }])
    @worker.send(:recover_interrupted)
    assert_equal ['current-schedule'], @store.read('queue').map { |job| job['id'] }
  end

  def test_interrupted_deletion_keeps_its_exact_ids_and_is_not_converted_to_a_backup
    setup_run
    job = { 'id' => 'delete-job', 'kind' => 'delete_backups', 'run_ids' => [@run['id']], 'actor' => '7' }
    @store.write('active_job', job)
    service = Object.new
    service.define_singleton_method(:perform!) { |_item| raise RedmineBackup::WorkerStoppedException }
    RedmineBackup::BackupDeletionService.stub(:new, service) do
      assert_raises(RedmineBackup::WorkerStoppedException) { @worker.send(:execute, job) }
    end
    assert_equal job, @store.read('active_job')
    @worker.send(:recover_interrupted)
    recovered = @store.read('queue').first
    assert_equal 'delete_backups', recovered['kind']
    assert_equal job['run_ids'], recovered['run_ids']
    assert_equal '7', recovered['actor']
  end

end
