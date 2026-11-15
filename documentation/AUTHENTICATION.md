# Storage provider authentication

Version 0.3.1 implements the following authentication paths. Application registration, provider-side permissions and real account authorization are still required. Protocol tests do not prove tenant consent, storage quota or a live successful backup. Credentials are write-only inputs stored encrypted in private control storage, separate from Redmine's cached/database settings.

## Google Drive Personal is normal Google OAuth

A personal Google Account (Gmail or another email registered with Google) uses the same user OAuth authorization-code flow as Google Workspace. Select Google Drive, Personal Google Account, and Browser sign-in. Create an External Web OAuth application that permits that account, register the displayed HTTPS callback, enter its client ID/secret and connect. No Workspace subscription or service account is needed for personal My Drive.

## Implemented methods and inputs

| Provider | Method | Inputs and prerequisites |
| --- | --- | --- |
| Google Drive Personal / Workspace | Browser authorization code + S256 PKCE | Web client ID/secret, registered callback, account consent; optional folder ID |
| Google Shared Drive | Service account | Private service-account JSON; existing Shared Drive folder or Shared Drive ID; service-account membership/permissions |
| Google Workspace | Domain-wide delegation | Service-account JSON, explicitly impersonated Workspace user, administrator-authorized Drive scope; optional folder |
| Google Drive | Imported OAuth grant | Existing access token and Unix expiry; matching client ID/secret and refresh token for automatic renewal |
| OneDrive Personal | Browser authorization code + PKCE | Personal-account-capable client registration, callback, user consent; consumers endpoint selected automatically |
| OneDrive Personal | Device code | Public-client-enabled registration/client ID; approve Microsoft's code, then Complete sign-in; no callback/client secret for this flow |
| OneDrive Personal | Imported OAuth grant | Access token/expiry; matching client registration and refresh token for unattended renewal |
| OneDrive for Business / SharePoint | Browser or device code | Business registration/client ID, user consent, tenant; browser Web client secret/callback or device public-client configuration |
| OneDrive for Business / SharePoint | Application client secret | Specific tenant GUID/domain, client ID/secret, Graph application permissions and admin consent; drive or site ID |
| OneDrive for Business / SharePoint | Application certificate | Specific tenant, client ID, registered certificate PEM, matching RSA private-key PEM and optional passphrase; drive or site ID |
| OneDrive for Business / SharePoint | Workload federation | Specific tenant/client ID, private rotating OIDC token-file path, matching Entra federated trust; drive or site ID |
| OneDrive for Business / SharePoint | Managed identity | Azure VM/App Service identity, Graph permissions, optional user-assigned client ID; drive or site ID |
| OneDrive for Business / SharePoint | On-Behalf-Of | Tenant/client ID and confidential client secret; private upstream user-assertion file rotated by an authenticated upstream service |
| OneDrive for Business / SharePoint | Legacy ROPC | Tenant/client ID, Microsoft user name/password, optional confidential-client secret; only accounts/policies that permit ROPC |
| OneDrive for Business / SharePoint | Imported OAuth grant | Access token/expiry and optional offline refresh grant with matching client credentials |
| S3-compatible | SDK chain, access key or STS | Existing worker role/environment/profile credentials, or access key/secret and optional STS session token |
| SFTP | SSH key or password | Host/port/user/directory, verified known_hosts, key path/passphrase or password |

Fields change with provider and method. Application identities get new access tokens from their credentials; they do not require refresh tokens. Browser/device grants renew using refresh tokens. Imported access tokens alone expire and cannot sustain an unattended daily schedule.

## Google setup

1. Enable the Drive API in the Google Cloud project.
2. For personal/Workspace browser login, create a Web application OAuth client and register exactly the callback shown in Redmine. Configure consent-screen audience/test users and review Google's Testing-mode refresh-token lifetime restrictions. Select Browser sign-in, enter the client ID/secret and Save settings and connect storage account.
3. The scope is `https://www.googleapis.com/auth/drive.file` with offline access. Leave folder ID blank to create an application-accessible Redmine Backups folder. An arbitrary preexisting folder ID does not itself authorize the application to use that folder.
4. For a service account, paste its private JSON in the write-only field and add that identity to the intended Shared Drive. Supply the Shared Drive ID to create Redmine Backups there, or an existing folder ID within it. Requests use Shared Drive API flags and folder checks. Service accounts cannot own personal My Drive files and have no personal storage quota.
5. For Workspace domain-wide delegation, authorize the service account's client ID and Drive scope in Workspace administration and enter the exact user to impersonate. The signed assertion contains that user as its subject. This does not impersonate personal Gmail accounts.
6. Connect, Check setup, perform a real upload/read-back and restore drill before relying on scheduled protection.

## Microsoft setup

1. Register an Entra application with the audience appropriate to the account. Personal OneDrive uses `consumers`; business browser/device flows default to `organizations`. App-only client-credential flows require a specific tenant GUID or verified tenant domain.
2. For browser sign-in, register exactly the displayed HTTPS Web callback and configure delegated `Files.ReadWrite` for OneDrive or `Files.ReadWrite.All` for SharePoint, with offline access. Enter the confidential Web secret where required.
3. For device code, enable public-client flows in that registration. Save and connect, open the Microsoft verification link, enter the displayed user code, approve access and select Complete sign-in. The browser does not receive the private device code; it stays encrypted in control storage. Polling observes provider intervals, slow_down, expiry and settings/user binding. Resume Microsoft device sign-in on the dashboard returns to an unfinished flow. A completed grant and created folder remain encrypted if the worker is busy, so retrying does not repeat authorization or folder creation.
4. For application identities, grant suitable Microsoft Graph application permissions and administrator consent. Prefer narrowly scoped site grants where supported by the required APIs. Upload, listing, read-back and deletion/retention all need access; a read-only grant is insufficient. Application permissions do not grant access to personal consumer OneDrive.
5. Client secret mode exchanges the confidential app secret. Certificate mode signs short-lived PS256 assertions with a SHA256 certificate thumbprint; upload the matching public certificate in Entra. Private keys must be RSA, at least 2048 bits, and match a currently valid certificate.
6. Workload identity reads a fresh OIDC assertion from the configured private file on each renewal. Provision matching issuer, subject and audience in Entra. The platform, rather than the plugin, issues/rotates those assertions.
7. Managed identity works on Azure VM IMDS and Azure App Service identity endpoints. The platform must provision the identity and Graph permissions. No configurable arbitrary token endpoint is exposed. Metadata requests bypass HTTP proxies, remain on loopback/link-local HTTP endpoints, use required platform headers and never follow redirects.
8. For On-Behalf-Of, an upstream service must supply and renew a user access token whose audience is this application. ID tokens, app-only tokens and arbitrary Graph tokens are not interchangeable with that assertion. The plugin cannot manufacture a continuing upstream user session.
9. ROPC is explicitly a legacy option. It cannot complete MFA/passwordless login and fails under incompatible Conditional Access/federation policies. Do not weaken tenant policy merely to use this mode. Passwords are encrypted and never rendered back.

## SharePoint and business drive addressing

Choose SharePoint document library for library storage. Enter a drive ID to select a particular document library, or a SharePoint site ID to address its default library. Drive ID takes precedence. In business delegated mode, leaving both blank uses the signed-in user's drive. Application-only modes and SharePoint require one of these explicit destinations; they never call `/me`.

Typical discovery endpoints, using an appropriately authorized Graph tool, are `GET /sites/{hostname}:/{site-path}` followed by `GET /sites/{site-id}/drives`. These identify site/library IDs; they do not grant access. Folder ID refers to a folder inside the selected drive, not a site or library ID. Leave it blank to create Redmine Backups after authorization.

Folder health checks validate accessibility and type. Retention checks the configured parent folder and, when a drive ID is configured, its drive ID. Historical retries keep their captured destination; switching drives does not redirect deletion into another library.

## Callback, credentials and external identity files

Browser OAuth registrations must use the exact displayed HTTPS URL:

```text
https://YOUR-REDMINE-HOST[/relative-root]/admin/backups/oauth/callback
```

Callback state is one-use, time-limited and administrator/session/settings bound. Storage registrations are independent of SMTP OAuth. Blank credential inputs preserve existing encrypted values; changing authentication identity invalidates the old cached access/refresh grant. Tokens, passwords, service-account JSON and certificate/private-key inputs never appear in public plugin settings or rendered form values.

Workload/OBO assertion files must be readable by the worker, private on the current OS (owner-only POSIX permissions, or a restricted Windows ACL), bounded in size and rotated by their owning platform/service. They are ephemeral credentials, not a portable identity system: re-provision their issuer/rotation after disaster recovery. They are not automatically added as durable archive sources; add only appropriate long-lived deployment configuration to additional backup paths. Embedded private key/secret configuration is already in the private recovery bootstrap.

Azure App Service supplies `IDENTITY_ENDPOINT` and `IDENTITY_HEADER`; do not manually fill these on a non-Azure host. For Azure VM identities, the fixed IMDS endpoint is used. These variables must be available consistently to the web service (Connect) and supervised worker (renewal).

## Flows that do not fit this web backup application

- Google device authorization is for TVs/limited-input devices with the corresponding client type; Google's policy requires using a client appropriate to the platform. Redmine is a web application, so a misleading Google device-login button is not provided.
- Desktop/native loopback redirects are for native clients, not this remotely hosted HTTPS web callback.
- Implicit/browser-only token acquisition has no unattended refresh grant. Externally obtained access tokens can be imported explicitly with expiry; the plugin does not expose tokens in a URL fragment or pretend they provide permanent backup authorization.
- OAuth refresh tokens and PKCE are renewal/security mechanisms, not additional account types. Personal Google Drive is already covered by user OAuth.

## Troubleshooting

A successful connection queues a new setup health check. Refresh the dashboard after the worker processes it. Saving configuration invalidates previous setup results; a warning from before authorization does not describe the newly saved grant. The supervised worker refreshes Redmine's settings cache on every runtime load, keeping public destination IDs and private credentials in sync. A cloud check cannot pass without a destination folder.

- Callback mismatch: copy the exact Redmine callback, not the GitHub Pages documentation URL.
- Invalid client: check app audience, client ID, secret expiry, certificate registration or federated trust.
- Missing refresh grant: reconnect with offline consent using a matching client type.
- Google folder returns `PROVIDER_HTTP_404`: the folder ID is wrong, deleted, or inaccessible to this application. Successful account consent alone does not grant access to an arbitrary folder under `drive.file`. Use the application-created Redmine Backups folder; alternatively clear the folder field and reconnect to create one. After correcting settings, use a latest-run retry action or Back up now. Recovery captures current data and configuration rather than uploading an old snapshot; historical copies retain their original references.
- Device flow pending: finish Microsoft sign-in and wait for the displayed polling interval; expired/denied codes require a new flow.
- Shared Drive quota/folder errors: use a team-owned folder for a service account, or delegate to an authorized Workspace user.
- Graph app-only errors: supply the correct tenant and drive/site ID; verify Graph permissions and actual site grants for every required operation.
- Managed identity unavailable: verify Azure hosting/identity configuration; an ordinary client ID on a non-Azure server is insufficient.
- WORKER BUSY RETRY SETTINGS: let the active backup finish, then retry; a completed device grant remains private until its pending flow expires.

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

Additional authentication references:

- [Google OAuth client policies](https://developers.google.com/identity/protocols/oauth2/policies), [service-account/delegation assertions](https://developers.google.com/identity/protocols/oauth2/service-account), [Shared Drive storage and service-account limits](https://developers.google.com/workspace/drive/api/guides/about-shareddrives).
- [Microsoft device authorization](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-device-code), [client credentials](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-client-creds-grant-flow), [certificate assertions](https://learn.microsoft.com/en-us/entra/identity-platform/certificate-credentials).
- [Managed identity VM tokens](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/how-to-use-vm-token), [Azure App Service identity](https://learn.microsoft.com/en-us/azure/app-service/overview-managed-identity), [On-Behalf-Of](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-on-behalf-of-flow), [ROPC limitations](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth-ropc).
