# Installation

Use a staging Redmine first. The [hosted guide](https://krishnast.github.io/redmine-backup-plugin/#installation) and offline `documentation/index.html` are generated from this repository.

1. Check Redmine 7.x, its supported Ruby/Rails version, PostgreSQL and compatible PostgreSQL client tools. Linux, Windows and macOS use the same plugin and configuration page. Preserve the working Redmine installation using your operational procedure.
2. Clone into `REDMINE_ROOT/plugins/redmine_backup_plugin`. The repository basename may differ; the plugin registers its actual directory.
3. As the Redmine account, run `bundle install` from the Redmine root. Review lockfile changes without upgrading unrelated gems. Windows additionally declares `fiddle` for native disk, process and ACL APIs; it adds no service or scheduler.
4. No plugin table migrations are needed. Restart Redmine. Its supervisor automatically starts the Ruby worker under Puma or `rails server`; other Rack hosts activate it on the first request. No separate worker service, cron job, Redis, Sidekiq or Puma configuration changes are required.
5. Open **Administration → Backups**. Choose a persistent, non-public local directory before creating the first backup. Its default is `redmine-backups` under attachment storage. The existing parent must be writable by the Redmine account.
6. Configure destinations, retention and notification users/groups. If PostgreSQL tools are not on PATH, set PostgreSQL bin directory, such as `/usr/pgsql-18/bin` or `C:\Program Files\PostgreSQL\18\bin`. Windows `.exe` suffixes are selected automatically. Add external configuration paths not found through Redmine environment references. Linux service files are optional discovery sources when present, not a runtime dependency.
7. Complete storage authorization using the displayed callback and **Save settings and connect storage account**. Installation does not authorize an account. See [provider authentication](AUTHENTICATION.md).
8. Confirm **Background worker heartbeat**, **Worker managed by Redmine**, private storage and setup checks. Test notification and a manual backup; verify every required destination, checksum and cleanup status.
9. Perform the isolated [restore drill](RECOVERY.md), then enable scheduling. Provider mocks and packaging tests alone do not validate another installation's restore procedure.

## Redmine-managed worker

The web process starts a dedicated Ruby child with the same account, Rails key and environment. The child elects one manager using a private lock under `REDMINE_ROOT/tmp/redmine-backup-manager` before loading Rails, so multiple web workers do not load multiple active backup engines. Backup work has its own database connections and does not occupy HTTP request threads. The process lock remains authoritative across restarts; it does not overtake a living backup.

The supervisor restarts a failed child. Redmine shutdown closes the child's control pipe; the child also watches its parent's liveness. Interrupted work keeps durable job state and is recovered as a fresh backup when Redmine returns. A dead Redmine/server cannot run backups or send immediate alerts.

No background work starts from test environments, console/runner commands or the managed child itself. A custom Rack host first activates management through its first request; use a normal readiness request when booting such a host. Subsequent scheduling runs without web traffic.

## Upgrade from version 0.3.x

Remove the obsolete dedicated backup-worker service/job after validating the managed worker. On a Linux installation previously using the old template, stop/disable that backup service before restarting Redmine with the new plugin. Validate the managed heartbeat and a full upload before removing its obsolete unit file. This is a one-time removal of old infrastructure, not a new installation dependency. Keep the Redmine application's normal hosting arrangement.

## Private storage and platform details

Linux/macOS use owner-only POSIX modes and built-in `df -Pk` for disk reserve checks. Windows uses native free-space APIs and protected NTFS DACLs allowing the Redmine account, SYSTEM and local administrators. New control/payload files inherit those private ACLs. DOS chmod bits are not accepted as ACL verification. Existing external credential files must also have restricted permissions; the plugin validates but does not rewrite their ACLs.

Application/storage paths with spaces and Unicode are supported. State/coordination directories cannot be symlinks or Windows reparse points. A source junction/reparse point requires reviewed explicit coverage of a regular target rather than implicit traversal. Use a reliable local filesystem for process locks; no distributed multi-host lock is claimed.

## Manual diagnostics

The application manages the worker. For operator diagnostics, `bundle exec rake redmine_backup:tick` attempts one locked cycle and `bundle exec rake redmine_backup:worker` runs a foreground loop from the Redmine root. Both obey the same manager lock; they do not start a second active worker. Set `RAILS_ENV=production` in that shell as appropriate for its OS. These commands do not need an OS service or schedule.

## Local directory migration

Before history exists, the local directory can be selected in the UI. For an established installation, pause scheduling and stop Redmine, copy the complete private state directory preserving its keys and appropriate destination-platform permissions, update the non-secret local directory through an authorized maintenance session, then restart and validate. State is not automatically moved. Keep the original until verification succeeds; never initialize an empty state directory against an existing remote namespace.

## Uninstall

Pause scheduling, stop Redmine and remove the plugin through normal maintenance. Its managed child stops with the app. Preserve backup state, recovery keys and remote data deliberately. No database tables or stored backups are automatically deleted.
