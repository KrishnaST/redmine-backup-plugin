# Redmine backup plan

This is the current scope of the native Ruby implementation. Installation/configuration instructions are in [INSTALLATION.md](INSTALLATION.md) and [CONFIGURATION.md](CONFIGURATION.md); the provider catalog is in [STORAGE.md](STORAGE.md). The earlier Python/rclone/timer/Apps Script prototypes are superseded and are not part of this project.

## Policy

| Item | Policy |
| --- | --- |
| Database | Full PostgreSQL backup every day |
| Application/files | Full backup every day, with no incremental dependency chains |
| Schedule | Configurable time and timezone; default 20:00 Asia/Kolkata |
| Availability | Redmine stays online during capture |
| Local retention | Configurable successful dates; default 3 |
| Remote retention | Configurable successful dates per destination; default 10, with per-target override |
| Secondary | Optional, disabled by default; Redundant or Failover when enabled |
| Packaging | Separate components or a single ZIP/ZIP64; no 7z |
| Encryption | No additional archive encryption; private control credentials remain encrypted |
| Bandwidth | No plugin throttle; provider-directed retry/backoff still applies |
| Management | Redmine administrator UI with an automatically supervised Ruby child; no separate service/scheduler |
| Database credentials | Derived from Redmine's resolved primary configuration |
| Alerts | Existing Redmine mail delivery; selected existing users/groups |
| Gateway | Excluded |

## Recovery coverage

Each recovery point includes the full Redmine database, application source/customizations, plugins, themes, assets, dependency lockfiles, snapshot-referenced attachments, required external configuration/environment files, Rails key material, SMTP state/secrets and Redmine service definitions. Configured provider SSH key/known-host files and PostgreSQL TLS files are included when applicable/readable.

Automatic discovery is supplemented by explicit additional paths. Newly discovered coverage is flagged. Missing required paths fail capture rather than being silently omitted. Gateway applications/settings/services, Let's Encrypt material, disposable logs/caches and the local backup store itself are excluded.

A manifest records runtime versions, source/archive mappings, captured files, artifact sizes and SHA256 hashes. A private bootstrap preserves effective settings, required key/configuration material, grants and plugin control history for offline recovery. No completed historical backup directories are recursively included in a new backup.

## Scheduling and execution

Redmine starts, monitors and stops its Ruby child, which evaluates the durable schedule/queue. A private manager lock is acquired before Rails loads; a second web process does not load a second active engine. Parent shutdown interrupts child work and terminates active dump subprocesses. A missed schedule after an outage triggers a fresh current backup once the app/database/worker are ready. Explicit Pause is respected; manual work does not suppress the next scheduled slot.

A process lock prevents concurrent writers across startup hooks/workers/admin clicks. Heartbeats show liveness; durable state identifies interrupted work. Interrupted capture/upload recovery starts a fresh full capture with current configuration, sharing an already queued current backup where available. A still-running hung process is not automatically overtaken by another writer.

Capture uses an exported PostgreSQL repeatable-read, read-only snapshot for the dump and referenced-attachment inventory. Attachment data is checked for size and available stored digest while copying; archive components receive SHA256 checksums. Streaming, disk reserve checks, process timeouts and worker CPU/I/O priority limit impact. The snapshot does not claim an atomic whole-filesystem image.

## Packaging and upload

One remote backup folder per run is the default. Single-ZIP mode places the five components inside one top-level backup folder in the ZIP, uploads the named archive directly in the destination root, and checks the resulting archive. Already compressed components are stored without recompression. Recovery after a missed/failed backup/upload takes a new full backup. Bounded chunk retries within an active run can resume that run's upload; a restarted recovery run never borrows old sessions or artifacts.

Adapters cover Google My Drive/Shared Drives, OneDrive Personal/Business, SharePoint document libraries, SFTP and S3-compatible endpoints. Authentication choices and provider prerequisites are indexed in [provider authentication](AUTHENTICATION.md). Other Ruby-capable services are cataloged as future adapters, not implied implemented support. Authentication, resumability, integrity checks and ownership-scoped retention are provider-specific. A completion marker is published only after all required artifacts verify.

The optional secondary supports:

- **Disabled:** primary verification is sufficient; secondary fields, checks, uploads and alerts are not required.
- **Redundant:** attempt both copies every run, even after primary failure; both must verify. One success is Partially Protected and pending local artifacts stay protected.
- **Failover:** exhaust primary upload retries, then use the same payload at secondary. Report Failover Used, alert on primary failure, and try primary first on the next run.

Each destination has separate credentials, sessions, completion status and retention. Recovery takes a fresh capture using current destinations and credentials. Historical copies retain their original target identity so reconfiguration cannot redirect retention deletion into another namespace.

## Retention and provider protection

Counts are distinct successful backup dates, not wall-clock age. Zero, negative, fractional and malformed retention inputs are rejected. Pending/unuploaded local sets and the last good recovery point are protected even if limits are exceeded.

Provider versioning and immutable retention locks are separate opt-in capabilities. The initial implementation checks existing S3 versioning/Object Lock support and verifies requested object protection. It does not enable irreversible bucket-wide policies or broaden credentials. Unsupported/failed protection is reported separately.

Locked cleanup is deferred without invalidating a verified upload. Retention can exceed configured counts while locks apply. Old versions, provider recycle bins, duplicate markers and orphaned partials can consume additional storage. Cleanup never blindly sweeps a bucket/folder or bypasses a hold.

## Alerts, visibility and recovery

Alerts use the existing Redmine mailer and simple HTML/plain-text templates. Existing users/groups resolve to active deduplicated recipients. Failure notifications use bounded retry and per-recipient delivery tracking. Test Notification is available; recovery confirmations and scheduled daily-success notifications are optional/off by default.

The dashboard separates capture/packaging, primary/secondary upload verification, requested protection and cleanup. It shows safe failure codes, heartbeat, coverage changes, audit history and setup checks. Selecting an alert recipient grants no backup-administration privilege. Native alerts cannot be sent while the server/worker itself is down.

The offline verifier and bootstrap helper work without the original Redmine database. Recovery Mode blocks scheduling, cleanup/uploads and operational notifications on a restored/test instance until deliberate activation. The restored schedule remains paused. A recovery drill must also verify the separately provisioned gateway/HTTPS infrastructure.

## Acceptance

Validate administrator access, settings persistence, configurable retention, both secondary modes, scheduling/catch-up, lock exclusion, encrypted state, interrupted upload/packaging retry, integrity checks, ownership-safe cleanup/lock deferral, existing mail delivery, actual PostgreSQL capture and attachment recovery. Unit/isolated integration checks are documented in [VALIDATION.md](VALIDATION.md). A chosen-provider live upload and full restore drill remain separate operational validations.

Manually pinned recovery points and more proactive storage/credential-expiry warnings remain optional future enhancements. Current implemented boundaries are recorded in [IMPLEMENTATION.md](IMPLEMENTATION.md).
