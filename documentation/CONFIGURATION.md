# Configuration and storage

All routine settings are on **Administration → Backups**. Secret inputs are write-only: blank preserves the stored value. Non-secret settings use Redmine's plugin Setting entry. Credentials, refresh grants, upload sessions, audit and queue state are encrypted in a private filesystem directory using a key derived from the existing Rails secret.

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

An upload retry skips already verified targets. Deliberate primary backfill of a failover set is supported while its local artifacts remain available. Changing provider/destination does not redirect historical retries: each run retains its original configuration. Remote cleanup is skipped when the current destination identity differs from that historical target.

## Google Drive

Register a browser OAuth client with the callback shown below. Enter client ID, client secret where required, and a destination folder ID. Save, then use Connect Storage. Scope is `drive.file` with offline authorization; it grants access to files created/authorized for this application, not unrestricted Drive access. Existing destination folders/Shared Drive policies must permit the application identity; select/provision an application-accessible folder and validate the actual tenant.

The adapter uses resumable upload sessions. Shared Drive authorization and tenant-specific behavior require a live compatibility test; do not assume consumer Drive behavior proves Shared Drive support. Reconnect through the same slot if an expired/revoked grant prevents refresh.

## OneDrive

Register a Microsoft Entra HTTPS Web application with delegated `Files.ReadWrite` and offline access. Enter client ID, tenant ID (blank means organizations), client secret if required by the application type, and the destination drive item/folder ID. Save and connect through browser sign-in with S256 PKCE. Microsoft consumer accounts may need `consumers` or `common` and a matching registration audience.

The initial adapter addresses the signed-in user's `/me/drive`. SharePoint document-library routing is a future adapter extension, not implemented by accepting an arbitrary SharePoint folder ID. Upload sessions and preauthenticated downloads are stored privately; Graph bearer tokens are not forwarded to signed download hosts.

For both OAuth providers register exactly:

```text
https://YOUR-REDMINE-HOST[/relative-root]/admin/backups/oauth/callback
```

The callback is derived from Redmine's HTTPS host and relative-root settings. OAuth state is one-use, time-limited and bound to the selected destination. These upload registrations are separate from any SMTP OAuth application.

## SFTP

Configure host, SSH port, username, existing remote directory and a local known_hosts file. Supply a readable private-key path or a password. Host-key verification is mandatory; populate and verify known_hosts independently. The plugin does not trust keys on first use, create remote directory trees or run remote shell commands. Existing partial bytes are compared with the local source before offset resume; final verification uses streamed read-back.

## S3 compatible

Configure bucket, region and optional key prefix. Leave endpoint blank for AWS; R2/B2 require the provider's HTTPS endpoint. Use an IAM role/default SDK credential chain or access key/secret/session token. Only the installation-owned namespace is managed. Multipart sessions are checkpointed; multipart ETags are not treated as MD5 checksums. Verification reads back the actual bytes.

**Require versioning** checks that bucket versioning already exists. **Require retention lock** additionally checks pre-enabled Object Lock and requests a COMPLIANCE retain-until period. These are opt-in per destination; the plugin never enables bucket-wide irreversible policies. Verify that the intended lock period and cost are acceptable before use. Protected uploads are checked again through object metadata.

Locked cleanup shows Deferred Locked. It does not invalidate a verified upload. Noncurrent versions and deleted-marker history may remain subject to provider lifecycle policies. S3-compatible endpoints do not automatically support AWS's versioning/Object Lock APIs; capability failures are reported.

## Retry and history

Back Up Now, Retry Upload, Retry Packaging and Test Notification enqueue durable work. The browser does not perform long-running capture or transfer. History separates local capture, packaging, primary/secondary verification, requested protection and cleanup. Retry Packaging checks the preserved manifest/components before creating a new wrapper. No bandwidth throttle is configured, but provider Retry-After/backoff remains in effect.

Check Setup queues tool/path/disk/provider capability checks and shows their results on the dashboard. Backup/upload failures always generate a deduplicated notification request. Recovery confirmations and scheduled daily-success summaries are optional/off by default. Emails include the run/event, timestamp, last local/remote success and one administrator details link. Recipient selection is resolved against active current users/group members at delivery time.
