# frozen_string_literal: true

require 'json'
require File.expand_path('config/environment', Dir.pwd)
require File.join(Rails.root, 'plugins/redmine_backup_plugin/lib/redmine_backup/runtime')

ActiveRecord::Base.connection_pool.with_connection do |connection|
  connection.transaction do
    connection.execute('SET TRANSACTION READ ONLY')
    runtime = RedmineBackup::Runtime.new
    results = runtime.health
    raise 'Unexpected recovery mode' if runtime.recovery?
    raise 'Worker heartbeat missing' unless results.any? { |result| result['name'] == 'Background worker heartbeat' && result['ok'] }
    puts JSON.pretty_generate(
      plugin_version: RedmineBackup::VERSION,
      schedule_enabled: runtime.config['enabled'],
      secondary_enabled: runtime.config['secondary']['enabled'],
      local_keep_dates: runtime.config['local_keep_dates'],
      remote_keep_dates: runtime.config['remote_keep_dates'],
      configured_alert_recipients: runtime.config['user_ids'].length + runtime.config['group_ids'].length,
      local_store_private: (File.stat(runtime.store.root).mode & 0o077).zero?,
      heartbeat_healthy: true,
      health: results,
      backup_records: runtime.store.read('runs', []).length
    )
  end
end
