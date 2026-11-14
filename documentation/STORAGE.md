# Ruby storage catalog

| Provider / protocol | Ruby route | Adapter status |
| --- | --- | --- |
| Google Drive | Google HTTPS API; a Google-maintained Ruby client also exists | Initial adapter using direct HTTPS |
| OneDrive | Microsoft Graph HTTPS API | Initial adapter for signed-in `/me/drive` |
| AWS S3 | Official aws-sdk-s3 | Initial adapter |
| Cloudflare R2 / Backblaze B2 | S3-compatible API with aws-sdk-s3 | Initial adapter; provider capability tests required |
| SFTP | net-sftp / net-ssh | Initial adapter |
| Google Cloud Storage | Official google-cloud-storage | Future adapter |
| Azure Blob | HTTPS REST; old Azure Storage Ruby SDK retired | Future REST adapter |
| Dropbox | HTTPS REST or reviewed community Ruby SDK | Future adapter |
| Box | HTTPS REST | Future adapter |
| Nextcloud / ownCloud | WebDAV over HTTPS | Future adapter |
| FTPS | Ruby net-ftp with TLS | Future adapter |
| Mounted SMB3 / NFSv4 | Ruby filesystem operations after OS mounting | Future destination adapter |
| SharePoint libraries | Microsoft Graph with explicit drive/library routing | Future extension; not arbitrary `/me/drive` folder IDs |

The core already uses local filesystem storage for capture. That is not evidence of an independent mounted-share/offsite-copy adapter. Secondary storage remains optional and disabled by default.

No listed service is fundamentally inaccessible from Ruby just because there is no official Ruby SDK. A complete adapter still needs authentication, upload/resume, integrity, namespace listing and safe retention tests.

Excluded paths: retired SDK dependencies; rsync/rclone/CLI-only transfer integrations; plugin-controlled SMB/NFS mounting; plain FTP/HTTP; services exposing no usable transfer API; and upload-only URLs without the operations required for a managed backup destination.

See [configuration](CONFIGURATION.md) for supported operations and [references](REFERENCE.md) for primary sources. Existing S3 lock/versioning APIs are supported only where the endpoint actually implements them; no universal immutable protection is claimed.
