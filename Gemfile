source 'https://rubygems.org'

gem 'aws-sdk-s3', '~> 1' unless dependencies.any? { |dependency| dependency.name == 'aws-sdk-s3' }
gem 'net-sftp', '~> 4' unless dependencies.any? { |dependency| dependency.name == 'net-sftp' }
gem 'pg', '>= 1.5', '< 2' unless dependencies.any? { |dependency| dependency.name == 'pg' }
gem 'rubyzip', '>= 3.0', '< 4' unless dependencies.any? { |dependency| dependency.name == 'rubyzip' }

if File.expand_path(Bundler.default_gemfile) == File.expand_path(__FILE__)
  group :test do
    gem 'activesupport', '~> 8.1' unless dependencies.any? { |dependency| dependency.name == 'activesupport' }
    gem 'minitest', '~> 5.25' unless dependencies.any? { |dependency| dependency.name == 'minitest' }
    gem 'rake', '~> 13.2' unless dependencies.any? { |dependency| dependency.name == 'rake' }
    gem 'rdoc', '>= 6.6', '< 8' unless dependencies.any? { |dependency| dependency.name == 'rdoc' }
  end
end
