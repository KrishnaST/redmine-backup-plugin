# Storage provider authentication

Authentication is provider-specific. Browser OAuth is implemented for Google Drive and OneDrive; an application registration and consent from the actual storage account are still required. No provider becomes connected merely by installing this plugin. Tokens and client secrets are never shown in the page source or stored as plaintext Redmine settings.

## Implemented providers and visible inputs

| Provider / authentication | Inputs shown in the plugin |
| --- | --- |
| Google Drive — browser OAuth 2.0 + S256 PKCE | Client ID, confidential Web client secret, registered HTTPS callback (read-only), destination folder ID (optional), connection status and Save and Connect |
| OneDrive — delegated browser OAuth 2.0 + S256 PKCE | Client ID, Web client secret where required, Microsoft tenant, callback, optional destination folder, connection status and Save and Connect |
| S3 — IAM role / default SDK credential chain | Region, bucket, optional HTTPS endpoint/prefix; credentials supplied to the worker outside the form |
| S3 — access key | Destination fields plus access key ID and secret access key |
| S3 — temporary STS credentials | Destination fields plus access key ID, secret and session token |
| SFTP — SSH private key | Host, port, SSH username, directory, known_hosts file, private-key path and optional key passphrase |
| SFTP — SSH password | Host, port, SSH username, directory, known_hosts file and password |

The form changes when provider/authentication selection changes. Irrelevant fields are hidden and disabled; server-side allowlists reject unrelated provider fields. Versioning/Object Lock controls are shown only for S3-compatible destinations. Secondary configuration remains optional and is disabled unless explicitly enabled.

S3-compatible services such as Cloudflare R2 and Backblaze B2 normally use their scoped S3 access keys and endpoint. S3 requests use request signing, not a universal browser OAuth login. The default AWS SDK chain can use supported role, environment, profile, web-identity or other SDK credential sources already provisioned for the service account; this is not an interactive plugin sign-in flow.

## Google Drive setup

1. In Google Cloud, create/select a project, enable the Drive API and configure the OAuth consent screen. If the application is in testing, add the account that will connect as a test user. Review Google's testing/refresh-token lifetime rules before relying on unattended backups.
2. Create an OAuth client of type Web application. Register exactly the HTTPS callback displayed on the plugin page, including any Redmine relative root.
3. Select Google Drive and Browser Sign-in in Redmine. Enter the client ID and Web client secret. Leave destination folder ID blank to create an application-accessible Redmine Backups folder after consent, or supply a folder already authorized for the application.
4. Click Save Settings and Connect Storage Account. Choose the Google account, review the requested access, and consent. The callback verifies administrator/session/state/expiry, exchanges the code using the PKCE verifier and stores the refresh grant encrypted in private control storage.
5. Confirm Connected and the destination folder ID, run Check Setup, then validate a backup/upload before enabling the schedule.

Scope is `https://www.googleapis.com/auth/drive.file`, with offline access. It is narrower than unrestricted Drive access. Typing an arbitrary folder ID does not automatically authorize access to that folder. If in doubt, use the auto-created application folder. Workspace/Shared Drive membership, policy and storage/quota constraints require tenant-specific validation. This plugin's current browser flow is user-delegated; a service-account/domain-delegation UI is not implemented.

## OneDrive setup

1. Register a Microsoft Entra Web application for the intended account audience. Configure the displayed HTTPS callback and delegated Microsoft Graph `Files.ReadWrite` permission with offline access; satisfy the tenant's consent policy.
2. Create a client secret if required by the confidential Web registration. Enter client ID, secret and tenant ID in the plugin. Blank tenant defaults to `organizations`; consumer registrations may use `consumers` or `common` with the matching audience.
3. Leave folder ID blank to create Redmine Backups after consent, or select an accessible existing folder in the signed-in user's drive.
4. Save and Connect, select the sending storage account and grant access. The plugin stores a private refresh grant and resumes unattended access by refresh-token renewal.
5. Validate Check Setup and an actual upload. The initial adapter uses `/me/drive`; arbitrary SharePoint library routing and app-only client-credentials/certificate authentication are not implemented.

Storage authorization is separate from SMTP OAuth. A tenant/client ID configured for a mail plugin does not automatically grant file-storage access. Registration/consent cannot be skipped, and end-to-end connection is not claimed until the intended provider account actually authorizes the application.

## OAuth troubleshooting

- Callback mismatch: copy the exact displayed callback to the provider's Web application registration. GitHub Pages is documentation hosting, not the Redmine callback host.
- Client credentials rejected: verify the client/application ID, secret value (not secret ID), expiry and application type.
- Expired/mismatched state: start a new Connect flow in the same administrator browser session. Completing another destination's concurrent sign-in can replace the pending state.
- Missing refresh grant: request offline access and reconnect with consent. The plugin does not claim an unattended connection from an access token alone.
- Folder access denied: use an application-authorized folder or let Connect create one; verify account/tenant policies.
- Changing provider, client or tenant invalidates the old saved grant. Secrets remain write-only; a blank secret field preserves the configured value.

## Other cataloged providers

These mechanisms exist at the providers but their adapters are not implemented in this release.

| Provider / protocol | Available authentication families | Plugin status |
| --- | --- | --- |
| Google Cloud Storage | Service-account/attached identity, workload identity federation, Application Default Credentials, delegated OAuth where appropriate | Future adapter; separate from Drive |
| Azure Blob Storage | Microsoft Entra identity/managed identity, SAS, Shared Key | Future REST adapter |
| Dropbox | OAuth 2.0 authorization code, PKCE where appropriate, offline refresh tokens | Future adapter |
| Box | User OAuth 2.0; enterprise-approved client-credentials/JWT flows depending on app type | Future adapter |
| Nextcloud / ownCloud / WebDAV | HTTPS username/app password or a server-supported identity integration | Future adapter |
| FTPS | Username/password over TLS; additional server-supported certificate policies | Future adapter |
| Mounted SMB/NFS | OS-managed share credentials, Kerberos or filesystem identity/permissions | Future destination; mount provisioning remains outside the plugin |

## Primary references

- [Google Web-server OAuth](https://developers.google.com/identity/protocols/oauth2/web-server) and [Drive scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth).
- [Microsoft delegated Graph access](https://learn.microsoft.com/en-us/graph/auth-v2-user).
- [AWS Ruby SDK credential chain](https://docs.aws.amazon.com/sdk-for-ruby/v3/developer-guide/credential-providers.html).
- [Azure data authorization](https://learn.microsoft.com/en-us/azure/storage/common/authorize-data-access), [Google Application Default Credentials](https://cloud.google.com/docs/authentication/provide-credentials-adc).
- [Dropbox OAuth](https://developers.dropbox.com/oauth-guide), [Box authentication](https://developer.box.com/guides/authentication/), [Nextcloud WebDAV](https://docs.nextcloud.com/server/latest/developer_manual/client_apis/WebDAV/basic.html).
