# frozen_string_literal: true

# Run from the Redmine root using the same environment/service account as Puma.
require 'json'
require File.expand_path('config/environment', Dir.pwd)

ActiveRecord::Base.connection_pool.with_connection do |connection|
  connection.transaction do
    connection.execute('SET TRANSACTION READ ONLY')
    details = {
      redmine_version: Redmine::VERSION.to_s,
      ruby_version: RUBY_VERSION,
      database_adapter: ActiveRecord::Base.connection_db_config.adapter,
      database_version: connection.select_value('SHOW server_version'),
      attachment_storage: Attachment.storage_path,
      attachment_count: Attachment.count,
      attachment_bytes: Attachment.sum(:filesize),
      plugin_ids: Redmine::Plugin.all.map { |plugin| plugin.id.to_s },
      required_gems: Gem.loaded_specs.slice('rails', 'pg', 'rubyzip', 'aws-sdk-s3', 'net-sftp').transform_values { |spec| spec.version.to_s }
    }
    puts JSON.pretty_generate(details)
  end
end
