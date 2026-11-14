# frozen_string_literal: true

gem 'minitest', '~> 5.25'
ENV['MT_NO_PLUGINS'] = '1'
require 'minitest/autorun'
require 'minitest/mock'
require 'active_support/all'
require 'tmpdir'

require_relative '../lib/redmine_backup'
RedmineBackup.load_runtime!

class BackupTest < Minitest::Test
  def setup
    @temporary_parent = File.expand_path('../tmp/test', __dir__)
    FileUtils.mkdir_p(@temporary_parent)
    @temporary = Dir.mktmpdir('backup-', @temporary_parent)
  end

  def teardown
    FileUtils.remove_entry(@temporary) if @temporary && File.directory?(@temporary)
  end

  def config(values = {})
    RedmineBackup::Configuration.new(values).validate!
  end

  def run_record(identifier, date: '2026-11-15', completed: '2026-11-15T20:00:00+05:30', **attributes)
    { 'id' => identifier, 'date' => date, 'completed_at' => completed, 'verified' => true,
      'captured' => true, 'destinations' => { 'primary' => { 'verified' => true } } }.merge(attributes.stringify_keys)
  end
end
