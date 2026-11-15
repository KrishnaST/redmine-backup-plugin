# frozen_string_literal: true

require_relative 'test_helper'

class PlatformTest < BackupTest
  def test_native_disk_query_handles_directory_names_with_spaces
    path = File.join(@temporary, 'space and unicode 研究')
    FileUtils.mkdir_p(path)
    bytes = RedmineBackup::PlatformService.available_bytes(path)
    assert_kind_of Integer, bytes
    assert_operator bytes, :>, 0
  end

  def test_private_directory_and_inherited_file_permissions_are_real
    path = File.join(@temporary, 'private')
    store = RedmineBackup::Store.new(path)
    store.write('secret', 'fixture' => 'private')
    assert RedmineBackup::PlatformService.private_path?(path)
    assert RedmineBackup::PlatformService.private_path?(File.join(path, 'control/secret.json.enc'))
  end

  def test_windows_case_insensitive_containment_and_sibling_rejection
    RedmineBackup::PlatformService.stub(:windows?, true) do
      root = File.join(@temporary, 'Private')
      assert RedmineBackup::PlatformService.within?(File.join(root.downcase, 'child'), root.upcase)
      refute RedmineBackup::PlatformService.within?(root + '-sibling/child', root)
      refute RedmineBackup::PlatformService.within?(File.join(root, '..', 'outside'), root)
    end
  end

  def test_platform_specific_postgresql_executable_suffix
    RedmineBackup::PlatformService.stub(:windows?, true) do
      assert_equal 'pg_dump.exe', RedmineBackup::PlatformService.executable('pg_dump')
      assert_equal File.join(@temporary, 'pg_restore.exe'), RedmineBackup::PlatformService.executable('pg_restore', directory: @temporary)
    end
    RedmineBackup::PlatformService.stub(:windows?, false) do
      assert_equal 'pg_dump', RedmineBackup::PlatformService.executable('pg_dump')
    end
  end

  def test_posix_disk_response_is_parsed_without_shell_expansion
    arguments = nil
    success = Struct.new(:success?).new(true)
    operation = lambda do |*values, **_options|
      arguments = values
      ["Filesystem 1024-blocks Used Available Capacity Mounted on\nvolume 1000 200 800 20% /mount with spaces\n", success]
    end
    RedmineBackup::PlatformService.stub(:windows?, false) do
      Open3.stub(:capture2, operation) do
        assert_equal 819_200, RedmineBackup::PlatformService.available_bytes(@temporary)
      end
    end
    assert_equal 'df', arguments[1]
    assert_equal File.expand_path(@temporary), arguments.last
  end

  def test_disk_reserve_and_timeout_checks_fail_closed
    RedmineBackup::PlatformService.stub(:available_bytes, 100 * 1024 * 1024) do
      resources = RedmineBackup::Resources.new(root: @temporary, reserve_mb: 64, timeout_seconds: 10)
      assert resources.check!
      error = assert_raises(RedmineBackup::Error) { resources.check!(40 * 1024 * 1024) }
      assert_equal 'DISK_RESERVE_REACHED', error.message
    end
    resources = RedmineBackup::Resources.new(root: @temporary, reserve_mb: 64, timeout_seconds: -1)
    assert_equal 'CAPTURE_TIMEOUT', assert_raises(RedmineBackup::Error) { resources.check! }.message
  end

  def test_disk_queries_are_throttled_during_fast_file_streaming
    queries = 0
    operation = ->(_path) { queries += 1; 1024 * 1024 * 1024 }
    Process.stub(:clock_gettime, 1000) do
      RedmineBackup::PlatformService.stub(:available_bytes, operation) do
        resources = RedmineBackup::Resources.new(root: @temporary, reserve_mb: 64, timeout_seconds: 10)
        5.times { resources.check! }
        assert_equal 1, queries
      end
    end
  end

  def test_non_linux_discovery_does_not_require_service_manager_files
    RedmineBackup::PlatformService.stub(:linux?, false) do
      Dir.stub(:glob, ->(_pattern) { flunk 'OS service discovery must not run here' }) do
        paths = RedmineBackup::Coverage.discover(application_root: @temporary, attachment_root: @temporary,
                                                environment: { 'REDMINE_CONFIGURATION_FILE' => File.join(@temporary, 'external.env') })
        assert_includes paths, File.realpath(@temporary)
        assert_includes paths, File.join(@temporary, 'external.env')
      end
    end
  end

  if Gem.win_platform?
    def test_windows_acl_rejects_everyone_even_if_mode_bits_look_private
      windows = RedmineBackup::WindowsPlatformService.new
      windows.stub(:security_descriptor, 'D:P(A;;FA;;;WD)') do
        refute windows.private_path?(@temporary)
      end
    end
  end
end
