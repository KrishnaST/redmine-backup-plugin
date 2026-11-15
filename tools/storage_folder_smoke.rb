# frozen_string_literal: true

# Live maintainer acceptance check, run from Redmine root with its normal environment.
require File.expand_path('config/environment', Dir.pwd)
require File.join(Rails.root, 'plugins/redmine_backup_plugin/lib/redmine_backup/runtime')

raise 'Explicit create/verify/delete operation required' unless ARGV == ['--create-verify-delete']

ActiveRecord::Base.connection.transaction do
  ActiveRecord::Base.connection.execute('SET TRANSACTION READ ONLY')
  runtime = RedmineBackup::Runtime.new
  raise RedmineBackup::Error, 'RECOVERY_MODE_REQUIRES_ACTIVATION' if runtime.recovery?
  runtime.store.lock('worker', nonblock: true) do
    raise RedmineBackup::Error, 'ACTIVE_JOB_PRESENT' unless runtime.store.read('active_job').empty?
    target = JSON.parse(JSON.generate(runtime.config['primary']))
    checkpoint = lambda do |key, tokens|
      next unless key == 'oauth_tokens'
      secrets = runtime.store.read('secrets')
      secrets['primary'] = secrets.fetch('primary', {}).merge(tokens)
      runtime.store.write('secrets', secrets)
    end
    provider = RedmineBackup::Providers.build(target, checkpoint: checkpoint)
    name = "validation-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(6)}"
    folder = provider.prepare_run(name)
    path = File.join(Rails.root, 'plugins/redmine_backup_plugin/documentation/RECOVERY.md')
    reference = provider.upload(path, "#{name}/RECOVERY.md")
    provider.verify!(reference, 'bytes' => File.size(path), 'sha256' => Digest::SHA256.file(path).hexdigest)
    provider.assert_folder!(folder, name)
    provider.assert_reference!(reference, name + '-')
    provider.delete(reference)
    provider.delete_folder(folder)
    puts JSON.generate(folder_created: true, component_uploaded: true, checksum_verified: true,
                       ownership_verified: true, canary_file_and_empty_folder_removed: true)
  ensure
    provider&.close
  end || raise(RedmineBackup::Error, 'WORKER_BUSY_RETRY_CANARY')
end
