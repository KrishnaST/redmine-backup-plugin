# Redmine recovery guide

This guide is included in every backup. Test it on an isolated replacement host before relying on a backup. Recovery is an administrator operation, not an automatic production restore.

## 1. Select and verify

Choose a complete verified recovery set. In folder mode download the complete backup folder; in ZIP mode download its named ZIP. Unpack ZIP into a new private staging directory after checking that entry names contain no absolute paths or parent traversal. The ZIP contains one top-level backup folder holding `manifest.json`, `database.dump`, `application.tar.gz`, `bootstrap.json` and this guide. Set `BACKUP_ROOT` to the directory containing those five components; for older flat ZIPs this is the extraction directory itself.

Run the repository's standalone verifier with Ruby:

```sh
BACKUP_ROOT="/private/staging/YOUR_BACKUP_FOLDER"
ruby bin/redmine-backup-verify "$BACKUP_ROOT/manifest.json"
pg_restore --list "$BACKUP_ROOT/database.dump" >/dev/null
```

The verifier checks file sizes and SHA256 against the manifest. The dump catalog check does not prove successful restore. The manifest records source roots and external-file archive mappings. Never publish `bootstrap.json`: it includes private database/provider configuration and Rails key material, because archive encryption was deliberately not requested.

## 2. Rebuild the environment

Provision Linux, Windows or macOS with matching supported Ruby, Redmine/Rails, PostgreSQL clients/server and application dependencies using the captured version metadata and lockfile. An OS change may require different native gems and executable paths; review it explicitly. Provision the Redmine account, private POSIX modes or Windows ACLs, required environment and database role. Recreate role privileges deliberately; this is a single-database dump, not a whole-cluster/global-role backup.

Restore the application archive into private staging, not directly over an operating installation. Inspect archive member names, symlinks and `external_roots` before extraction. `application/` maps to the Redmine root, `attachments/` maps to its attachment storage, and each `external/N/` maps to the corresponding external root in the manifest. Restore external state/configuration/service files to reviewed locations with appropriate ownership and modes. Preserve Rails secret/key material and SMTP private state together; without matching keys, encrypted settings/grants cannot be decrypted.

Install the plugin if not already captured and install compatible locked dependencies. Set Recovery Mode before starting Redmine: its worker is automatically managed with the application. Restore target-platform permissions deliberately; TAR modes are not a Windows ACL image.

## 3. Restore the database

Create an empty, correctly encoded database owned by the intended Redmine role. Configure authentication without exposing passwords on command lines. After reviewing the dump and role mapping, restore it using `pg_restore --exit-on-error --no-owner --role=REVIEWED_REDMINE_ROLE --dbname=NEW_DATABASE database.dump` with suitable connection parameters/environment. Do not restore over a running production database. Check every restore error and application compatibility before running any required Redmine migrations.

Use the captured resolved database configuration only as a private reference; update the restored Redmine configuration for the replacement host. Existing Redmine plugin settings will be restored by the database dump. The private bootstrap is available if configuration must be reconstructed outside a working Redmine instance; it is not automatically imported by an unauthenticated endpoint.

## 4. Force Recovery Mode before starting

Set `REDMINE_BACKUP_RECOVERY=1` in the replacement Redmine and worker environments. Alternatively place a file named `RECOVERY` inside the private backup directory's `control/` folder. A different host identity also triggers Recovery Mode, but explicit recovery protection should always be used for test/cloned hosts.

Reconstruct the private plugin control directory from the verified bootstrap using the standalone helper after restoring the same Rails secret and installing the application dependencies:

```sh
bundle exec ruby plugins/redmine_backup_plugin/bin/redmine-backup-bootstrap \
  "$BACKUP_ROOT/bootstrap.json" /private/new-backup-store
```

The destination must be empty with a writable existing parent. This restores encrypted metadata, grants and audit/history with a mandatory Recovery marker. Historical local payloads are marked unavailable because old backup directories are not recursively included in each new backup. Pending jobs are cleared. Review the generated private `restored-plugin-settings.json`, including paths and recipients, and import its non-secret settings through an explicitly controlled Rails maintenance session:

```sh
RAILS_ENV=production bundle exec rails runner \
  'Setting.plugin_redmine_backup_plugin = JSON.parse(File.read(ARGV.fetch(0)))' \
  /private/new-backup-store/restored-plugin-settings.json
```

Keep Redmine stopped or in explicit Recovery Mode during this operation. The restored Rails key must match the bootstrap key. Reconnect expired/rotated grants. Do not create a second active installation managing the original remote namespace.

Start only the web service first. Check administrator login, issue/project data, attachments, themes/plugins, configuration and existing SMTP integration. Inspect the Backups dashboard. Confirm scheduling, cleanup and operational email remain blocked in Recovery Mode. Gateway/HTTPS infrastructure is excluded from this backup and must be provisioned separately.

## 5. Activate deliberately

Fence the old server so it cannot resume jobs. Remove the recovery environment override, then use Activate This Restored Instance. The schedule remains paused. Review storage destinations, recipient selections, keys, retention and source coverage; ensure paths fit the replacement host. Run an isolated backup/upload verification and test notification when appropriate, then enable scheduling.

Record the actual restore time, errors, recovery point and validation results. Checksum verification alone is not a successful restoration drill.
