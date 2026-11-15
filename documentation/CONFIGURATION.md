# Configuration and storage

All routine settings are on **Administration → Backups**. Secret inputs are write-only: blank preserves the stored value within the same provider/application. Changing the provider, client ID or tenant requires matching application credentials; a blank field cannot inherit another application's secret. Non-secret settings use Redmine's plugin Setting entry. Credentials, refresh grants, upload sessions, audit and queue state are encrypted in a private filesystem directory using a key derived from the existing Rails secret.

## Worker management and operating system

The worker is started and supervised automatically by Redmine. No worker-service configuration is needed on this page or in the operating system. The dashboard reports both its heartbeat and whether it is Redmine-managed. Keep Redmine running for schedules and alerts; after an outage the durable queue and schedule catch-up recover using a fresh backup. The internal child flag is not a web-service setting.

The default local directory remains a private subdirectory of Redmine's attachment storage. Windows validates native DACLs and uses `.exe` PostgreSQL client names; Linux/macOS use private POSIX modes. Configure PostgreSQL bin directory only when its tools are not on PATH, and list external deployment files under Additional Redmine paths. Do not use a public web-served directory for backup state.

## Retention

| Field | Default | Meaning |
| --- | --- | --- |
| Local successful dates to keep | 3 | Keep the newest verified local capture for each retained successful date |
| Default remote successful dates to keep | 10 | Default for each destination independently |
| Destination remote dates to keep | Blank | Override the remote default for that specific destination |

Each count accepts an integer from 1 to 3650. Zero, negative, fractional and malformed values are rejected. Counts represent distinct successful backup dates, not a wall-clock expiry. Multiple successes on one date do not each consume a date slot. Changes take effect during the next successful upload/retention pass, not immediately on Save.

Retention protects unuploaded local sets, local sets awaiting a required redundant copy, the latest local capture, and the last recognized complete remote point. Limits can be exceeded while uploads/locks are pending. Deleting one remote set never means deleting unrelated directories or another destination. Provider versions, deleted-file bins and duplicate markers may consume additional remote storage outside the visible successful-date count.

## Secondary destination

Disabled by default: no secondary settings/checks/uploads/alerts are required. When enabled choose:

- **Redundant:** attempt both destinations on every run, including when primary fails. Both verified copies satisfy protection. One verified copy is Partially Protected; its local payload remains protected for retry.
- **Failover:** exhaust bounded primary upload retries, then upload to secondary using the same artifacts. Next run tries primary first. A valid fallback gives Failover Used status while the primary failure generates an alert.

Within an active run, bounded transfer retries skip already verified targets. Recovery from a missed/failed backup or upload creates a fresh full database/files capture with a new run ID and the currently saved destinations and credentials. **Retry backup** appears only on the latest run when an upload failed, including a missing required redundant copy. Successful or still-running uploads have no retry button; there is no separate packaging retry control. Older queued retry requests are converted to fresh captures. Historical copies keep their original locations, checksums and marker references; old remote partials are not blindly removed.

## Storage reconfiguration

Changing provider/application/account identity or the selected drive, site or Shared Drive clears an inherited folder ID. A different folder explicitly entered with the new settings is retained. New providers do not inherit shared client IDs, folders or private credentials from the previous provider. Switching libraries retains the same account's grant; switching application identity invalidates its old grant. Secret rotation for the same application retains its folder.

Application-created folders are marked internally. Reconnecting checks an automatic folder with the newly authorized account, reuses it when accessible and creates a replacement after HTTP 404. Transient errors do not trigger replacement. Explicitly entered folder IDs are never silently substituted. Existing folder IDs from older plugin versions are treated as explicit until a new automatic folder is created.

Each settings save updates Redmine settings, encrypted secrets and private bootstrap references, clears old health results and queues a fresh setup check. Workers refresh their settings cache before loading those values. New captures, including recovery after a missed upload, use current settings. Previously captured archives/bootstrap files remain immutable capture-time evidence.

## Google Drive

Register a Web OAuth client with the callback shown below. Enter client ID and Web client secret, then click **Save settings and connect storage account**. Leave folder ID blank to create an application-owned **Redmine Backups** folder after consent. Scope is `drive.file` with offline authorization; it grants access to files created/authorized for this application, not unrestricted Drive access. An existing folder must be explicitly accessible to this application; entering its ID alone does not grant access. See [provider authentication](AUTHENTICATION.md) for setup and supported mechanisms.

The adapter uses resumable upload sessions. Shared Drive authorization and tenant-specific behavior require a live compatibility test; do not assume consumer Drive behavior proves Shared Drive support. Reconnect through the same slot if an expired/revoked grant prevents refresh.

## OneDrive and SharePoint

Register a Microsoft Entra HTTPS Web application with delegated `Files.ReadWrite` and offline access. Enter client ID, tenant ID (blank means organizations) and Web client secret. Click **Save settings and connect storage account** for browser sign-in with S256 PKCE. Leave folder ID blank to create **Redmine Backups** after consent. Microsoft consumer accounts may need `consumers` or `common` and a matching registration audience.

Choose OneDrive Personal, OneDrive for Business or SharePoint document library explicitly. Personal uses the consumers audience. Business/SharePoint support delegated and application identities; configure a drive or site ID for application access. A site selects its default library; drive ID selects a particular library and takes precedence. See [all authentication methods](AUTHENTICATION.md). Upload sessions and preauthenticated downloads are stored privately; Graph bearer tokens are not forwarded to signed download hosts.

For both OAuth providers register exactly:

```text
https://YOUR-REDMINE-HOST[/relative-root]/admin/backups/oauth/callback
```

The callback is derived from Redmine's HTTPS host and relative-root settings. OAuth state is one-use, time-limited and bound to the selected destination. These upload registrations are separate from any SMTP OAuth application.

## SFTP

Configure host, SSH port, username, existing remote directory and a local known_hosts file. Select **SSH private key** (readable private-key path and optional key passphrase) or **SSH password**. Only the selected method's fields are enabled. Host-key verification is mandatory; populate and verify known_hosts independently. The plugin does not trust keys on first use, create remote directory trees or run remote shell commands. Existing partial bytes are compared with the local source before offset resume; final verification uses streamed read-back.

## S3 compatible

Configure bucket, region and optional key prefix. Leave endpoint blank for AWS; R2/B2 require the provider's HTTPS endpoint. Select the IAM role/default SDK credential chain, access keys, or temporary STS credentials. Static key fields are hidden for the default chain; the session-token field appears only for STS. Only the installation-owned namespace is managed. Multipart sessions are checkpointed; multipart ETags are not treated as MD5 checksums. Verification reads back the actual bytes.

**Require versioning** checks that bucket versioning already exists. **Require retention lock** additionally checks pre-enabled Object Lock and requests a COMPLIANCE retain-until period. These are opt-in per destination; the plugin never enables bucket-wide irreversible policies. Verify that the intended lock period and cost are acceptable before use. Protected uploads are checked again through object metadata.

Locked cleanup shows Deferred Locked. It does not invalidate a verified upload. Noncurrent versions and deleted-marker history may remain subject to provider lifecycle policies. S3-compatible endpoints do not automatically support AWS's versioning/Object Lock APIs; capability failures are reported.

## Backup folders and ZIP layout

**One backup folder** uploads each complete set into a separate directory beneath the configured destination. Its name combines the installation ID and unique timestamp/run ID, preventing collisions between installations. It contains `database.dump`, `application.tar.gz`, `bootstrap.json`, `RECOVERY.md`, `manifest.json` and a verified `complete.json` marker. On S3-compatible storage the directory is an object-key prefix; SFTP creates one private child directory in the configured existing destination.

**ZIP of backup folder** uploads `<backup-folder>.zip` directly in the destination root. The ZIP contains one top-level `<backup-folder>/` with the five captured components inside it. A small `<backup-folder>-complete.json` file beside the ZIP records successful verification and enables safe retention. ZIP mode does not create a remote child folder or upload the individual captured components separately.

Retention detects both these layouts and previously uploaded flat sets. It verifies folder ownership/parent, marker and artifact references before removing a retained set. Folder cleanup removes known payloads and its completion marker, then removes only the empty owned directory. Unexpected additional files prevent directory removal; unrelated files are not recursively deleted. Incomplete folders remain protected for investigation. Existing backups are not reorganized when installing this version.

## Retry and history

The **Show backup status on administrator homepage** option is on by default. The homepage panel shows the latest result, last verified local/remote success, worker heartbeat, schedule and recovery mode. It does not expose paths, credentials or backup controls to bank/non-administrator users. Scheduling remains disabled until explicitly enabled.

Back Up Now, Retry Backup, Check Setup and Test Notification enqueue durable work. The browser does not perform long-running capture or transfer. Capture / upload result explicitly reports Upload successful, Upload failed, Upload incomplete or Upload in progress, with separate messages before upload starts. Success requires the configured verified copy/copies. Startup catch-up and interrupted-work recovery take a fresh snapshot; they do not upload a stale historical capture. A failed completed run remains in history and generates an alert; its recovery control or the next scheduled backup starts fresh. No bandwidth throttle is configured, but provider Retry-After/backoff remains in effect.

Check Setup queues tool/path/disk/provider capability checks and shows their results on the dashboard. Backup/upload failures always generate a deduplicated notification request. Recovery confirmations and scheduled daily-success summaries are optional/off by default. Emails include the run/event, timestamp, last local/remote success and one administrator details link. Recipient selection is resolved against active current users/group members at delivery time.

## Clear history

Administrators can use **Clear backup history**, **Clear audit history** and **Clear notification history** on the dashboard. Each requires a confirmed POST through Redmine's CSRF-protected administration route. History changes acquire the worker lock; a busy worker must finish before clearing.

Backup clearing hides finished results from the history table. It does not delete backup files, remote objects, internal restore/retention records, pending jobs or the homepage's last successful backup indicators. Queued retries and active results stay visible. Fresh recovery appears as a new run; old hidden results remain hidden. Audit clearing removes previous events and records the clearing action. Notification clearing removes delivered events and exhausted failures; partially delivered/retryable alerts remain, including their per-recipient progress.
