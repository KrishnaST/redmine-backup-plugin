# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'
require 'rbconfig'

class SourceCheckerTest < BackupTest
  def test_downloaded_dependency_documentation_is_not_treated_as_project_links
    root = File.expand_path('..', __dir__)
    parent = File.join(root, 'vendor', 'bundle')
    FileUtils.mkdir_p(parent)
    fixture = Dir.mktmpdir('documentation-fixture-', parent)
    File.write(File.join(fixture, 'README.md'), '[dependency reference](does-not-exist.rdoc)')
    output, status = Open3.capture2e(RbConfig.ruby, File.join(root, 'tools', 'check_sources.rb'))
    assert status.success?, output
  ensure
    FileUtils.remove_entry(fixture) if fixture && File.directory?(fixture)
  end
end
