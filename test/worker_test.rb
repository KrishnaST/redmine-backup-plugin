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
      @objects.keys.filter_map { |key| { 'key' => key } if key.start_with?(prefix) && key.end_with?('-complete.json') }
    end

    def assert_reference!(reference, namespace)
      raise RedmineBackup::Error, 'FOREIGN_REFERENCE' unless reference.fetch('key').start_with?(namespace)
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

  def test_historical_retry_cannot_cleanup_a_reconfigured_destination
    setup_run
    @config.values['primary'] = @config['primary'].merge('bucket' => 'new-location')
    # The durable run contains its own historical settings, not a shared reference.
    @run['config']['primary'] = { 'provider' => 's3', 'bucket' => 'primary' }
    upload
    assert_equal 'skipped_destination_changed', @run.dig('destinations', 'primary', 'cleanup')
  end
end
