# Implementation coverage

Current native plugin version: 0.3.1. This describes source implementation, not proof of live provider authorization or a successful restore.

| Requirement | Implementation |
| --- | --- |
| Admin UI | Administrator-only dashboard, settings, queued actions, history, health and audit |
| Homepage | Optional administrator-only latest result, last local/remote success, worker heartbeat and schedule summary |
| Authentication | Provider/method-specific inputs; Google user OAuth/service accounts/Workspace delegation; Microsoft browser/device/app secret/certificate/workload/managed/OBO/legacy ROPC; imported grants; S3 SDK chain/static/STS; SFTP key/password |
| Database configuration | Reads Redmine's resolved ActiveRecord primary configuration; no duplicate editable credentials |
| Full daily database/files | Exported PostgreSQL read-only snapshot, custom dump, full application archive and snapshot-referenced attachments |
| Discovery/coverage | Application/attachment roots and Redmine file/directory environment references on every OS; optional existing Linux unit/environment files; configured additional paths and coverage-change reporting |
| Local storage | Private subdirectory of attachment storage by default; editable at first setup, controlled migration for existing history |
| Retention | Configurable local/default remote/per-target override; 1–3650 distinct successful dates; defaults 3/10 |
| Safe cleanup | Protected pending copies, ownership/reference checks, per-target history, last good copy, lock deferral |
| Scheduling and catch-up | Redmine-supervised Ruby child, one manager elected before Rails loads, persistent queue, latest missed slot, explicit pause; settings cache refreshed on every runtime load |
| Platforms | Linux/macOS POSIX operations and native Windows disk/process/ACL adapters; executable suffixes and path containment adapted per OS |
| One-run lock | Kernel process lock, heartbeat and interrupted-job reconciliation |
| Packaging | One owned remote folder per run, or a named ZIP64 with one top-level backup folder; component/wrapper integrity checks |
| Missed upload recovery | Fresh full capture with current configuration and a new run ID; old queued retries converted; historical copies unchanged |
| History clearing | Administrator-only per-category controls; backup visibility reset without deleting files/retention metadata; pending alerts preserved |
| Providers | Google My Drive/Shared Drives, OneDrive Personal/Business, explicit SharePoint libraries, SFTP and S3-compatible adapters |
| Secondary | Optional/disabled by default; explicit Redundant or Failover |
| Versioning/locks | Existing S3 capability checks, opt-in object protection and locked-cleanup deferral |
| Status | Local capture/packaging, each target, protection and cleanup tracked separately |
| Mail | Existing Redmine Mailer, active user/group audience, test notification, per-recipient retry/deduplication |
| Bootstrap/recovery | Private bootstrap includes key/configuration and control history; standalone verifier/import helper; forced Recovery Mode |
| Gateway | Gateway applications/settings/services and Let's Encrypt paths excluded |
| Bandwidth/encryption | No plugin bandwidth throttle; no added archive encryption |

## Deliberate initial boundaries

- PostgreSQL remains the supported database engine. Linux, Windows and macOS platform paths are implemented; acceptance still requires compatible PostgreSQL clients, private local storage and a full restore drill on the actual installation. Windows ACLs are provisioned/checked through native APIs. Source POSIX modes do not recreate Windows ACL policies during an OS migration; provision target permissions deliberately.
- Additional Ruby-capable providers are cataloged, not implemented adapters. Shared Drive and SharePoint authorization require actual tenant/account permissions and live compatibility tests. Google limited-input device flow and native-app callbacks are not applicable to this web plugin; legacy browser access tokens are supported through explicit expiring-token import.
- No public download or automatic production-restore endpoint. Restoration remains an administrator-controlled offline process. The helper reconstructs control state and emits reviewed non-secret settings for an explicit Rails maintenance import.
- Previously captured full backup directories are excluded from each new full backup. Bootstrap preserves their history as historical/unavailable when restored; it does not pretend their old local payloads exist.
- Native alerts cannot report while Redmine/server is down. The managed worker follows the application lifecycle and recovers durable work; recovery confirmations and scheduled success mail remain optional/off by default. Custom Rack hosts activate supervision on the first readiness/request; Puma and rails-server startup are recognized automatically.
- Locked cleanup, duplicate markers, orphaned partial uploads and provider old versions may exceed retention counts. No blind remote orphan sweeping or forced hold removal occurs.
- A started `pg_dump` is terminated on timeout/disk-check failure. Cloud requests have bounded per-request timeouts/retries. No global hard upload-duration limit is imposed across a large multipart upload; supervisor cancellation leaves resumable state.
- Filesystem control locks require a reliable shared local filesystem. No multi-host distributed locking or unsafe hung-worker takeover is claimed.
- Run/audit records contain safe status/identity metadata, not raw provider error bodies. Captured private bootstrap/configuration is intentionally sensitive and must remain private.

## Verification boundary

The test suite covers algorithm behavior, capture with a mocked PostgreSQL snapshot, SDK-stubbed S3 requests, fake Drive/Graph sessions, private state, recovery, documentation and orchestration. The GitHub workflow additionally prepares a disposable Redmine/PostgreSQL installation for route/settings/native-mail, production-style eager loading and actual snapshot/dump/attachment-capture integration. See [validation evidence](VALIDATION.md) and the current workflow for results.

The plugin and worker have been installed with boot/heartbeat/private-permission checks. Before enabling scheduled protection, run a real backup, interruption/retry tests against the chosen provider/account, a restore drill and the existing Microsoft 365 mail integration. Source publication itself never authorizes an unattended deployment.
