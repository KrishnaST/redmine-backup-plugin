# frozen_string_literal: true

require_relative 'test_helper'
require 'bundler'

class GemfileTest < BackupTest
  def test_plugin_reuses_host_dependency_declarations
    builder = Bundler::Dsl.new
    builder.gem('pg', '~> 1.6.2')
    builder.gem('rubyzip', '~> 3.4.0')
    builder.eval_gemfile(File.expand_path('../Gemfile', __dir__))
    assert_equal 1, builder.dependencies.count { |dependency| dependency.name == 'pg' }
    assert_equal 1, builder.dependencies.count { |dependency| dependency.name == 'rubyzip' }
    assert_equal '~> 1.6.2', builder.dependencies.find { |dependency| dependency.name == 'pg' }.requirement.to_s
  end

  def test_host_evaluation_does_not_add_standalone_test_constraints
    host = Pathname.new(File.join(@temporary, 'host', 'Gemfile'))
    builder = Bundler::Dsl.new
    Bundler.stub(:default_gemfile, host) do
      builder.eval_gemfile(File.expand_path('../Gemfile', __dir__))
    end
    refute builder.dependencies.any? { |dependency| dependency.name == 'minitest' }
    refute builder.dependencies.any? { |dependency| dependency.name == 'activesupport' }
    refute builder.dependencies.any? { |dependency| dependency.name == 'rdoc' }
  end
end
