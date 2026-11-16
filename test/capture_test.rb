# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'
require 'pg'
require 'rbconfig'
require 'zip'

require_relative '../lib/redmine_backup/backup_verification_service'

class CaptureTest < BackupTest
  class Rows < Array
    def ntuples
      length
    end

    def getvalue(row, column)
      self[row].values[column]
    end
  end

  class Snapshot
    attr_reader :queries

    def initialize(row)
      @row, @queries, @fetched = row, [], false
    end

    def exec(query)
      @queries << query
      return Rows.new([{ 'snapshot' => 'snapshot-1' }]) if query.include?('pg_export_snapshot')
      return Rows.new([{ 'version' => '18.6' }]) if query == 'SHOW server_version'
      if query.start_with?('FETCH') && !@fetched
        @fetched = true
        return Rows.new([@row])
      end
      Rows.new
    end

    def exec_params(query, _params)
      @queries << query
      Rows.new(%w[id disk_directory disk_filename filesize digest].map { |column| { 'column_name' => column, 'data_type' => column == 'filesize' ? 'bigint' : 'character varying' } })
    end

    def finished?
      false
    end

    def close; end
  end

  class Tools
    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(arguments, **options)
      @calls << [arguments, options]
      File.binwrite(options[:output], 'PGDMP-test-fixture') if options[:output]
    end
  end

  def setup
    super
    @app = File.join(@temporary, 'redmine')
    @attachments = File.join(@app, 'files')
    FileUtils.mkdir_p(File.join(@attachments, '2026'))
    FileUtils.mkdir_p(File.join(@app, 'log'))
    File.write(File.join(@app, 'Gemfile.lock'), 'locked dependencies')
    File.write(File.join(@app, 'custom.rb'), 'custom code')
    File.write(File.join(@app, 'log', 'discard.log'), 'disposable')
    File.binwrite(File.join(@attachments, '2026', 'file.bin'), 'payload')
    @store = RedmineBackup::Store.new(File.join(@attachments, 'redmine-backups'))
    @store.write('metadata', 'installation_id' => 'test-installation', 'host_identity' => 'original-host')
    @tools = Tools.new
    @row = { 'id' => '1', 'disk_directory' => '2026', 'disk_filename' => 'file.bin', 'filesize' => '7', 'digest' => Digest::SHA256.hexdigest('payload') }
    @snapshot = Snapshot.new(@row)
    @run = { 'id' => '20261115T143000Z-abcdef123456', 'date' => '2026-11-15', 'installation_id' => 'test-installation' }
  end

  def capture(settings = config)
    result = RedmineBackup::Capture.new(config: settings, store: @store, application_root: @app, attachment_root: @attachments,
                                       database: { 'adapter' => 'postgresql', 'database' => 'scratch', 'username' => 'test', 'password' => 'test-only' },
                                       secret_key: 'test-application-key', runner: @tools)
    resources = Object.new
    resources.define_singleton_method(:check!) { |_required = 0| true }
    result.instance_variable_set(:@resources, resources)
    result
  end

  def perform(settings = config)
    PG.stub(:connect, @snapshot) { capture(settings).call(@run) }
  end

  def test_snapshot_is_read_only_and_shared_with_dump
    payloads = perform
    assert_equal 'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY', @snapshot.queries.first
    assert_equal 'ROLLBACK', @snapshot.queries.last
    arguments, options = @tools.calls.first
    assert_includes arguments, '--snapshot=snapshot-1'
    refute arguments.any? { |value| value.include?('test-only') }
    assert_equal 'test-only', options[:env]['PGPASSWORD']
    assert_equal 5, payloads.length
  end

  def test_archive_has_customizations_and_only_referenced_attachments
    File.write(File.join(@attachments, 'orphan'), 'not referenced')
    perform
    names = []
    Zlib::GzipReader.open(File.join(@store.run_path(@run['id']), 'application.tar.gz')) do |gzip|
      Gem::Package::TarReader.new(gzip) { |tar| tar.each { |entry| names << entry.full_name } }
    end
    assert_includes names, 'application/custom.rb'
    assert_includes names, 'attachments/2026/file.bin'
    refute names.any? { |name| name.include?('redmine-backups') || name.include?('orphan') || name.include?('discard.log') }
  end

  def test_corrupt_attachment_fails_capture
    @row['digest'] = 'a' * 64
    assert_raises(RedmineBackup::Error) { perform }
    refute File.exist?(File.join(@store.run_path(@run['id']), 'manifest.json'))
  end

  def test_missing_attachment_fails_and_rolls_back
    File.delete(File.join(@attachments, '2026', 'file.bin'))
    assert_raises(RedmineBackup::Error) { perform }
    assert_equal 'ROLLBACK', @snapshot.queries.last
  end

  def test_parent_traversal_from_attachment_metadata_is_rejected
    @row['disk_directory'] = '..'
    @row['disk_filename'] = 'custom.rb'
    assert_raises(RedmineBackup::Error) { perform }
  end

  def test_zip_contains_every_component_and_does_not_redump_on_repackaging
    settings = config('packaging' => 'zip')
    result = perform(settings)
    assert_equal ['backup.zip'], result.map { |item| item['name'] }
    Zip::File.open(File.join(@store.run_path(@run['id']), 'backup.zip')) do |zip|
      folder = RedmineBackup::BackupLayout.folder_name(@run)
      assert_equal %w[RECOVERY.md application.tar.gz bootstrap.json database.dump manifest.json].map { |name| "#{folder}/#{name}" }, zip.map(&:name).sort
    end
    calls = @tools.calls.length
    capture(settings).package(@run)
    assert_equal calls, @tools.calls.length
  end

  def tar_contents
    contents = {}
    Zlib::GzipReader.open(File.join(@store.run_path(@run['id']), 'backup.tar.gz')) do |gzip|
      Gem::Package::TarReader.new(gzip) do |tar|
        tar.each { |entry| contents[entry.full_name] = entry.read if entry.file? }
      end
    end
    contents
  end

  def rewrite_tar(contents)
    path = File.join(@store.run_path(@run['id']), 'backup.tar.gz')
    Zlib::GzipWriter.open(path) do |gzip|
      Gem::Package::TarWriter.new(gzip) do |tar|
        contents.each do |name, bytes|
          tar.add_file_simple(name, 0o600, bytes.bytesize) { |output| output.write(bytes) }
        end
      end
    end
    path
  end

  def test_single_tar_contains_application_and_recovery_files_without_nested_archives
    File.write(File.join(@attachments, 'orphan'), 'unreferenced')
    settings = config('packaging' => 'tar_gz')
    payloads = perform(settings)
    assert_equal ['backup.tar.gz'], payloads.map { |item| item['name'] }
    folder = RedmineBackup::BackupLayout.folder_name(@run)
    contents = tar_contents
    %w[database.dump bootstrap.json manifest.json RECOVERY.md application/custom.rb application/Gemfile.lock attachments/2026/file.bin].each do |name|
      assert contents.key?("#{folder}/#{name}"), name
    end
    refute contents.keys.any? { |name| name.end_with?('application.tar.gz', 'backup.zip') || name.include?('orphan') || name.include?('redmine-backups') }
    manifest = JSON.parse(contents.fetch("#{folder}/manifest.json"))
    assert_equal 2, manifest['format']
    assert_equal %w[RECOVERY.md bootstrap.json database.dump], manifest['artifacts'].map { |item| item['name'] }.sort
    assert_equal 'payload', contents.fetch("#{folder}/attachments/2026/file.bin")
    calls = @tools.calls.length
    assert_equal payloads, capture(settings).package(@run)
    assert_equal calls, @tools.calls.length
  end

  def test_single_tar_can_be_verified_after_extraction_and_detects_modified_application
    perform(config('packaging' => 'tar_gz'))
    stage = File.join(@temporary, 'staging')
    tar_contents.each do |name, bytes|
      path = File.join(stage, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, bytes)
    end
    root = File.join(stage, RedmineBackup::BackupLayout.folder_name(@run))
    assert RedmineBackup::BackupVerificationService.verify_manifest(File.join(root, 'manifest.json'))
    File.write(File.join(root, 'application', 'custom.rb'), 'modified')
    assert_raises(RedmineBackup::Error) { RedmineBackup::BackupVerificationService.verify_manifest(File.join(root, 'manifest.json')) }
  end

  def test_single_tar_verification_rejects_tampered_files_and_folder_identity
    perform(config('packaging' => 'tar_gz'))
    contents = tar_contents
    folder = RedmineBackup::BackupLayout.folder_name(@run)
    contents["#{folder}/application/custom.rb"] = 'tampered'
    path = rewrite_tar(contents)
    assert_raises(RedmineBackup::Error) { RedmineBackup::BackupVerificationService.verify_archive(path) }
    assert_raises(RedmineBackup::Error) { RedmineBackup::BackupVerificationService.verify_archive(path, expected_folder: 'wrong-folder') }
  end

  def test_single_tar_verification_rejects_missing_extra_duplicate_and_unsafe_entries
    perform(config('packaging' => 'tar_gz'))
    original = tar_contents
    folder = RedmineBackup::BackupLayout.folder_name(@run)
    missing = original.reject { |name, _| name.end_with?('/database.dump') }
    extra = original.merge("#{folder}/unknown" => 'unexpected')
    traversal = original.merge("#{folder}/../escape" => 'unsafe')
    duplicate = original.to_a + [original.first]
    [missing, extra, traversal, duplicate].each do |contents|
      path = rewrite_tar(contents)
      assert_raises(RedmineBackup::Error) { RedmineBackup::BackupVerificationService.verify_archive(path) }
    end
  end

  def test_single_tar_checks_gzip_trailer_integrity
    perform(config('packaging' => 'tar_gz'))
    path = File.join(@store.run_path(@run['id']), 'backup.tar.gz')
    bytes = File.binread(path)
    bytes.setbyte(-5, bytes.getbyte(-5) ^ 1)
    File.binwrite(path, bytes)
    assert_raises(RedmineBackup::Error) { RedmineBackup::BackupVerificationService.verify_archive(path) }
  end

  def test_single_tar_preserves_unicode_names_and_external_configuration
    File.write(File.join(@app, 'café.rb'), 'unicode path')
    external = File.join(@temporary, 'service.env')
    File.write(external, 'FIXTURE=value')
    perform(config('packaging' => 'tar_gz', 'additional_paths' => [external]))
    manifest = JSON.parse(File.read(File.join(@store.run_path(@run['id']), 'manifest.json')))
    assert manifest['files'].any? { |item| item['path'] == 'application/café.rb' }
    assert manifest['files'].any? { |item| item['path'].end_with?('/service.env') }
    assert_includes manifest['external_roots'], File.realpath(external)
  end

  def test_single_tar_rejects_links_outside_backup_and_concatenated_gzip_streams
    perform(config('packaging' => 'tar_gz'))
    contents = tar_contents
    folder = RedmineBackup::BackupLayout.folder_name(@run)
    path = rewrite_tar(contents)
    safe_bytes = File.binread(path)
    File.binwrite(path, safe_bytes + safe_bytes)
    assert_raises(RedmineBackup::Error) { RedmineBackup::BackupVerificationService.verify_archive(path) }
    rewrite_tar(contents)
    Zlib::GzipWriter.open(path) do |gzip|
      Gem::Package::TarWriter.new(gzip) { |tar| tar.add_symlink("#{folder}/application/escape", '../../outside', 0o777) }
    end
    assert_raises(RedmineBackup::Error) { RedmineBackup::BackupVerificationService.verify_archive(path) }
  end

  def test_standalone_verifier_accepts_both_tar_and_legacy_manifest
    perform(config('packaging' => 'tar_gz'))
    verifier = File.expand_path('../bin/redmine-backup-verify', __dir__)
    directory = @store.run_path(@run['id'])
    output, errors, status = Open3.capture3(RbConfig.ruby, verifier, File.join(directory, 'backup.tar.gz'))
    assert status.success?, errors
    assert_includes output, 'Backup contents verified'
    @snapshot = Snapshot.new(@row)
    perform
    _output, errors, status = Open3.capture3(RbConfig.ruby, verifier, File.join(directory, 'manifest.json'))
    assert status.success?, errors
  end

  unless Gem.win_platform?
    def test_single_tar_preserves_safe_relative_links
      File.symlink(File.join(@app, 'custom.rb'), File.join(@app, 'custom-link.rb'))
      perform(config('packaging' => 'tar_gz'))
      manifest = JSON.parse(File.read(File.join(@store.run_path(@run['id']), 'manifest.json')))
      assert_equal [{ 'path' => 'application/custom-link.rb', 'target' => 'custom.rb' }], manifest['links']
      assert RedmineBackup::BackupVerificationService.verify_archive(File.join(@store.run_path(@run['id']), 'backup.tar.gz'))
    end
  end

  def test_packaging_rejects_modified_captured_components
    perform
    File.write(File.join(@store.run_path(@run['id']), 'database.dump'), 'tampered')
    assert_raises(RedmineBackup::Error) { capture(config('packaging' => 'zip')).package(@run) }
  end

  def test_bootstrap_preserves_private_state_for_offline_recovery
    perform
    bootstrap = JSON.parse(File.read(File.join(@store.run_path(@run['id']), 'bootstrap.json')))
    assert_equal 'test-application-key', bootstrap['secret_key_base']
    assert_equal 'test-installation', bootstrap.dig('private_state', 'metadata', 'installation_id')
  end

  def test_provider_private_keys_are_discovered_for_recovery
    key = File.join(@temporary, 'test-ssh-key')
    known = File.join(@temporary, 'known_hosts')
    File.write(key, 'fixture key')
    File.write(known, 'fixture host key')
    settings = config('primary' => { 'provider' => 'sftp', 'private_key_path' => key, 'known_hosts' => known })
    paths = capture(settings).sources
    assert_includes paths, File.realpath(key)
    assert_includes paths, File.realpath(known)
  end
end
