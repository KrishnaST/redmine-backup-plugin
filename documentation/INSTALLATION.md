# Installation

Use a staging Redmine first. This repository does not deploy itself.

The [hosted reference](https://krishnast.github.io/redmine-backup-plugin/#installation) and offline `documentation/index.html` are generated from the same repository documentation. Keep all procedure changes here.

1. Check Redmine 7.x, its Ruby/Rails versions, PostgreSQL, free space and the existing lockfile. Preserve the working Redmine installation using your existing operational procedure.
2. Clone this repository into `REDMINE_ROOT/plugins/redmine_backup_plugin`. The repository basename may differ; the plugin explicitly registers its actual directory.
3. As the Redmine service account, run `bundle install` from `REDMINE_ROOT`. Inspect the dependency changes; do not automatically upgrade unrelated Redmine gems. S3 and SFTP require their declared gems; ZIP and PostgreSQL must match Redmine's current lockfile.
4. No plugin table migrations are needed. Restart the Redmine web service so the routes, menu and mailer are loaded.
5. Open **Administration → Backups**. Choose the local directory before creating the first backup. It defaults to a private `redmine-backups` subdirectory of `Attachment.storage_path`. Its existing parent must be writable, persistent and non-public.
6. Configure provider settings, retention and alert recipients. Add any external Redmine paths the discovery preview cannot identify. For Google Drive/OneDrive, register the exact displayed callback and use **Save settings and connect storage account**; follow [provider authentication](AUTHENTICATION.md). Installation alone does not authorize a storage account.
7. Configure the native worker as a supervised process. Copy the template only after replacing its absolute paths/service user and adding the same environment files used by the web service. Do not run the worker as root.
8. Confirm the heartbeat and path checks. Queue a test notification and a manual backup. Check capture, every required destination, integrity verification and cleanup status independently.
9. Perform the documented isolated restore drill, then enable the schedule. The initial implementation is not production-validated merely because unit tests pass.

## Worker systemd example

Example install commands (replace paths, service names and account for the actual host):

```sh
cd /path/to/redmine/plugins
git clone https://github.com/KrishnaST/redmine-backup-plugin.git redmine_backup_plugin
cd /path/to/redmine
bundle install
sudo systemctl restart redmine.service
```

Copy `plugins/redmine_backup_plugin/templates/redmine-backup-worker.service` to `/etc/systemd/system/redmine-backup-worker.service`, edit it as described below, then run the service commands. The worker must share the web service's Rails key, environment and account; a clone and web restart alone do not start scheduled backups.

Edit `templates/redmine-backup-worker.service` for the actual service account, Redmine root and absolute Bundler executable. Include the environment/secret inputs required by Redmine and its SMTP delivery plugin. OS service configuration is installation infrastructure; daily operation and backup policy are administered in Redmine.

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now redmine-backup-worker.service
sudo systemctl status redmine-backup-worker.service
```

The worker evaluates the schedule every 15 seconds and writes a heartbeat during long operations. It uses a filesystem process lock, not a lease that lets a second writer overtake a still-running job. A crashed process releases the kernel lock; durable job state guides recovery. A hung process requires supervisor/operator intervention.

## Local directory migration

The directory is editable through the UI before there are queued jobs or backup records. Existing data is not moved automatically. For an existing installation, pause scheduling, stop the worker and web writes, copy the entire private directory preserving ownership/modes to the reviewed destination, update the plugin's non-secret `local_directory` setting through a controlled Rails maintenance session, then restart and validate history/keys/paths. Keep the original until validation succeeds. Do not point a new empty state directory at an existing remote namespace.

## Uninstall

Pause scheduling, stop/disable the backup worker and remove the plugin directory using the normal Redmine maintenance procedure. Preserve the private backup state, recovery keys and remote backups deliberately; uninstall does not automatically delete them. No database tables are dropped. The Redmine plugin settings entry can be removed through an explicitly authorized maintenance action if desired.
