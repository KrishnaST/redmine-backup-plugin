# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'
require 'rbconfig'

class DocumentationTest < BackupTest
  def test_offline_guide_contains_all_sections_and_unique_navigation_targets
    output = File.join(@temporary, 'guide.html')
    generator = File.expand_path('../tools/build_documentation.rb', __dir__)
    messages, status = Open3.capture2e(RbConfig.ruby, generator, output)
    assert status.success?, messages
    html = File.read(output)
    assert_equal 11, html.scan('<section ').length
    identifiers = html.scan(/\bid="([^"]+)"/).flatten
    assert_equal identifiers.uniq, identifiers
    html.scan(/href="#([^"]+)"/).flatten.each { |identifier| assert_includes identifiers, identifier }
    refute_match(/<script|<iframe|src="https?:/i, html)
    assert_includes html, 'Configurable'
    assert_includes html, 'Recovery worksheet'
  end
end
