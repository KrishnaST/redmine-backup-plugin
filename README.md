# Redmine Backup

Native Ruby plugin for full daily PostgreSQL and Redmine file backups, verified uploads and configurable retention. Version 0.5.0 adds a single TAR.GZ package containing application files, attachments, database and recovery metadata directly, without a nested application archive. Linux, Windows and macOS platform operations are supported and Redmine supervises its worker. No separate backup service, OS scheduler, Redis or Sidekiq is required. A chosen-provider upload and full restore drill remain installation acceptance checks.

## Features

- Admin UI under **Administration → Backups**; no manually maintained backup configuration file.
- Optional administrator-only homepage summary: latest result, last verified local/remote backup, worker health and schedule state.
- Full database and file backup every day, default 20:00 Asia/Kolkata. Online capture uses an exported read-only PostgreSQL snapshot and validates referenced attachments.
- Configurable retention: local successful dates, default remote successful dates, and an optional override for each destination. Defaults are 3 local / 10 remote dates; valid range 1–3650. Pending copies and the last good copy are protected.
- Primary destination with an optional secondary, disabled by default. **Redundant** requires both verified copies. **Failover** attempts secondary only after primary retries fail.
- Google Drive, OneDrive Personal/Business, SharePoint document libraries, SFTP and S3-compatible adapters. Resumability is provider-specific; verification uses streamed SHA256 read-back. No plugin bandwidth throttle.
- A single TAR.GZ (recommended), one folder per backup, or one named ZIP; verified completion markers and ownership-safe retention. TAR.GZ streams application files directly and verifies all file checksums before upload. No additional archive encryption. No 7z, Python, Java or rclone dependency.
- Startup catch-up, durable queue, process lock, heartbeat, crash reconciliation, encrypted control state, coverage-change indication and audit history.
- Missed schedules, interrupted transfers and manual recovery take a fresh full backup using current configuration. Retry backup appears only for a failed upload on the latest run; successful uploads have no retry control. Bounded retries within an active upload can still resume chunks.
- Storage changes clear incompatible application/folder references. Historical copies retain their original references and checksums.
- Clear backup, audit or notification history independently; backup files, retention metadata, pending work and alerts awaiting delivery are protected.
- Existing Redmine mail delivery, selected existing users/groups, test notification and bounded mail retries.
- S3 versioning/Object Lock capability checks and retention deferral. Equivalent protection is not assumed for other providers.
- Offline recovery manifest, private bootstrap and recovery guide. Gateway applications/certificates/services are excluded.

## Install and configure

See the [hosted installation and configuration guide](https://krishnast.github.io/redmine-backup-plugin/), [full plan](documentation/PLAN.md), [offline HTML guide](documentation/index.html), [installation](documentation/INSTALLATION.md), [provider authentication](documentation/AUTHENTICATION.md), [configuration](documentation/CONFIGURATION.md), [recovery](documentation/RECOVERY.md), [security and operational limits](documentation/SECURITY.md), and [validation](documentation/VALIDATION.md). The [documentation index](documentation/README.md) includes deployment operations, the recovery worksheet and source/schema references. All durable documentation is maintained in this repository; GitHub Pages publishes only `documentation/`.

Clone into `REDMINE_ROOT/plugins/redmine_backup_plugin`, run `bundle install` from the Redmine root after reviewing dependency resolution, restart Redmine, then configure **Administration → Backups**. No plugin schema migrations are needed: Redmine stores the non-secret plugin settings and this plugin uses private encrypted filesystem state for queue, credentials and history.

Redmine starts and monitors a dedicated Ruby child process with its own application/database connections, using the same account, environment and Rails key. The supervisor performs no database work in a preloaded web-server master. A private OS process lock elects one worker before Rails loads, including clustered/preloaded web servers. A failed child is restarted; shutdown closes its control pipe, interrupts active work and stops dump subprocesses. The durable queue recovers interrupted work with a fresh backup. Web requests perform no backup I/O.

Startup is automatic for Puma and `rails server`; other Rack hosts activate management on the first request. The worker lives while Redmine lives. No web request is required for subsequent schedule evaluation. Existing OS services may host Redmine itself, but the plugin never invokes a service manager. Remove obsolete version 0.3.x backup-worker services after validating the managed heartbeat; see [installation](documentation/INSTALLATION.md).

## Requirements

- Linux, Windows or macOS; Redmine 7.x, its supported Ruby/Rails versions, and PostgreSQL as Redmine's primary database.
- Compatible `pg_dump` / `pg_restore`; configure their bin directory when not on PATH. Windows uses `.exe` names automatically. Credentials go through the process environment, never password arguments.
- Windows: NTFS-compatible private ACLs and the Windows-only `fiddle` Ruby binding. Identity, free space, process termination and ACLs use native Win32 APIs; chmod bits are not treated as ACL proof. Linux/macOS use POSIX permissions and their built-in `df -Pk` utility. No PowerShell backup script or additional daemon is needed.
- Gems: `pg`, `rubyzip` 3.x, `aws-sdk-s3` 1.x and `net-sftp` 4.x. The first two are normally supplied by PostgreSQL-backed Redmine; Bundler must verify the actual installed lockfile. HTTPS/OAuth use Ruby Net::HTTP and OpenSSL.
- Writable private persistent local storage, working outbound HTTPS/SSH and the existing Redmine email mechanism. Redmine manages its own worker; no separate worker service or OS scheduler is required.
- Read access to required external configuration/state. The plugin cannot elevate OS permissions or back up unreadable service-account secrets.

## Administration endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/admin/backups` | Dashboard, settings, history and health |
| POST | `/admin/backups/settings` | Validated settings save |
| POST | `/admin/backups/actions` | Queue fresh backup, setup check or test notification; older retry requests also create a fresh backup |
| POST | `/admin/backups/history/clear` | Clear the selected backup, audit or terminal notification history |
| POST | `/admin/backups/connect/:slot` | Connect browser/device/application identity for a destination |
| GET | `/admin/backups/oauth/device` | Resume the signed-in administrator's pending device authorization |
| POST | `/admin/backups/oauth/device/poll` | Check an administrator-bound Microsoft device authorization |
| GET | `/admin/backups/oauth/callback` | State-checked provider callback |
| POST | `/admin/backups/activate` | Activate a restored host; schedule remains paused |

All endpoints require a Redmine administrator; state-changing requests use Redmine/Rails CSRF protection. Paths follow Redmine's configured relative URL root. OAuth requires a correctly configured HTTPS Redmine host.

## Environment variables

`RAILS_ENV=production` selects the existing Redmine environment. `REDMINE_BACKUP_RECOVERY=1` forces Recovery Mode and must be removed explicitly before activation can take effect. No storage/database password environment variables are required by this plugin: provider secrets are entered on its admin page and stored encrypted outside the database. Existing Redmine authentication/IAM-role environments continue to work through the selected SDK.

`REDMINE_BACKUP_WORKER_CHILD=1` is an internal flag set only on the managed Ruby child to prevent recursive supervisor creation; do not set it on the web service. The supervisor sets `BUNDLE_GEMFILE` to the current Redmine Gemfile. Manager coordination files live under `REDMINE_ROOT/tmp/redmine-backup-manager`, separate from backup contents and excluded from capture.

Azure managed identity uses platform-provided `IDENTITY_ENDPOINT` / `IDENTITY_HEADER` on Azure App Service or the fixed Azure VM IMDS endpoint; these must be available to web and worker services. Workload federation and On-Behalf-Of require private externally rotated assertion files; the plugin does not issue upstream identities. No new production gems are required for these methods.

Existing `REDMINE_*_FILE` and `REDMINE_*_DIRECTORY` variables are inspected for external state coverage; their values are not logged. The private bootstrap contains resolved configuration and key material for disaster recovery and is not suitable for publication.

## Tests

```sh
bundle exec ruby -Ilib test/run.rb
ruby tools/check_sources.rb
```

The independent unit suite uses mocked transports/snapshot connections and temporary local data. Optional PostgreSQL integration uses only a dedicated disposable test database; see [validation instructions](documentation/VALIDATION.md). Tests do not send operational email or contact production cloud accounts.

GPL-2.0-or-later. See [LICENSE](LICENSE).
