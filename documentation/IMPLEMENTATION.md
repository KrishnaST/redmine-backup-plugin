# Implementation coverage

Current native plugin version: 0.3.0. This describes source implementation, not proof of live provider authorization or a successful restore.

| Requirement | Implementation |
| --- | --- |
| Admin UI | Administrator-only dashboard, settings, queued actions, history, health and audit |
| Homepage | Optional administrator-only latest result, last local/remote success, worker heartbeat and schedule summary |
| Authentication | Provider/method-specific inputs; Google user OAuth/service accounts/Workspace delegation; Microsoft browser/device/app secret/certificate/workload/managed/OBO/legacy ROPC; imported grants; S3 SDK chain/static/STS; SFTP key/password |
| Database configuration | Reads Redmine's resolved ActiveRecord primary configuration; no duplicate editable credentials |
| Full daily database/files | Exported PostgreSQL read-only snapshot, custom dump, full application archive and snapshot-referenced attachments |
| Discovery/coverage | Application and attachment roots, configured Redmine file/directory environment references, readable Redmine systemd units/environment files and additional paths; changes highlighted |
| Local storage | Private subdirectory of attachment storage by default; editable at first setup, controlled migration for existing history |
| Retention | Configurable local/default remote/per-target override; 1–3650 distinct successful dates; defaults 3/10 |
| Safe cleanup | Protected pending copies, ownership/reference checks, per-target history, last good copy, lock deferral |
| Scheduling and catch-up | Supervised native Ruby worker, persistent queue, latest missed slot, explicit pause |
| One-run lock | Kernel process lock, heartbeat and interrupted-job reconciliation |
| Packaging | Separate components or ZIP64; retry packaging without another dump |
| Upload retry | Existing artifact hash validation, provider checkpoints, resume where supported |
| Providers | Google My Drive/Shared Drives, OneDrive Personal/Business, explicit SharePoint libraries, SFTP and S3-compatible adapters |
| Secondary | Optional/disabled by default; explicit Redundant or Failover |
| Versioning/locks | Existing S3 capability checks, opt-in object protection and locked-cleanup deferral |
| Status | Local capture/packaging, each target, protection and cleanup tracked separately |
| Mail | Existing Redmine Mailer, active user/group audience, test notification, per-recipient retry/deduplication |
| Bootstrap/recovery | Private bootstrap includes key/configuration and control history; standalone verifier/import helper; forced Recovery Mode |
| Gateway | Gateway applications/settings/services and Let's Encrypt paths excluded |
| Bandwidth/encryption | No plugin bandwidth throttle; no added archive encryption |

## Deliberate initial boundaries

- PostgreSQL and Linux are the supported capture environment. Unit tests can run on Windows; a Windows production worker is not supported.
- Additional Ruby-capable providers are cataloged, not implemented adapters. Shared Drive and SharePoint authorization require actual tenant/account permissions and live compatibility tests. Google limited-input device flow and native-app callbacks are not applicable to this web plugin; legacy browser access tokens are supported through explicit expiring-token import.
- No public download or automatic production-restore endpoint. Restoration remains an administrator-controlled offline process. The helper reconstructs control state and emits reviewed non-secret settings for an explicit Rails maintenance import.
- Previously captured full backup directories are excluded from each new full backup. Bootstrap preserves their history as historical/unavailable when restored; it does not pretend their old local payloads exist.
- Native alerts cannot report immediately while Redmine/worker/server is down. Recovery confirmations and scheduled daily-success emails are optional/off by default. Manually pinned recovery points remain a future enhancement.
- Locked cleanup, duplicate markers, orphaned partial uploads and provider old versions may exceed retention counts. No blind remote orphan sweeping or forced hold removal occurs.
- A started `pg_dump` is terminated on timeout/disk-check failure. Cloud requests have bounded per-request timeouts/retries. No global hard upload-duration limit is imposed across a large multipart upload; supervisor cancellation leaves resumable state.
- Filesystem control locks require a reliable shared local filesystem. No multi-host distributed locking or unsafe hung-worker takeover is claimed.
- Run/audit records contain safe status/identity metadata, not raw provider error bodies. Captured private bootstrap/configuration is intentionally sensitive and must remain private.

## Verification boundary

The test suite covers algorithm behavior, capture with a mocked PostgreSQL snapshot, SDK-stubbed S3 requests, fake Drive/Graph sessions, private state, recovery, documentation and orchestration. The GitHub workflow additionally prepares a disposable Redmine/PostgreSQL installation for route/settings/native-mail, production-style eager loading and actual snapshot/dump/attachment-capture integration. See [validation evidence](VALIDATION.md) and the current workflow for results.

The plugin and worker have been installed with boot/heartbeat/private-permission checks. Before enabling scheduled protection, run a real backup, interruption/retry tests against the chosen provider/account, a restore drill and the existing Microsoft 365 mail integration. Source publication itself never authorizes an unattended deployment.
