# Authentic source and API references

The capture query uses the authentic Redmine attachment schema rather than inferring columns from sample data. Read-only inspection of the actual deployment and authentic Redmine 7.0.2 sources informed the plan. Runtime capture validates column presence and filesize type again inside an explicit read-only transaction. A production schema check remains required before enabling this implementation.

Retained authoritative source copies under `reference/`:

- `001_setup.rb`: original attachment columns/primary identifier.
- `20121213084931_add_attachments_disk_directory.rb`: attachment subdirectory metadata.
- `20151020182334_change_attachments_filesize_limit_to_8.rb`: 64-bit filesize mapping.
- `20170302015225_change_attachments_digest_limit_to_64.rb`: digest field width.
- `Redmine-attachment.rb`: authoritative file storage, digest and attachment lifecycle behavior.
- `Redmine-Gemfile`, `Redmine-plugin.rb`, `Redmine-mailer.rb`, `Redmine-group.rb`, `Redmine-utils.rb`: host dependency, registration, notification audience and URL conventions.

Source: [Redmine 7.0.2 official mirror](https://github.com/redmine/redmine/tree/7.0.2). Original copyright notices remain; original code is GPL-licensed. No copied migration is executed by this plugin, and no production DDL is performed by the tests or publication.

Operational primary references:

- [Redmine plugin tutorial](https://www.redmine.org/projects/redmine/wiki/Plugin_Tutorial), [Rails resolved database configuration](https://api.rubyonrails.org/classes/ActiveRecord/ConnectionHandling.html#method-i-connection_db_config).
- [PostgreSQL 18 pg_dump](https://www.postgresql.org/docs/18/app-pgdump.html), [snapshot synchronization](https://www.postgresql.org/docs/18/functions-admin.html#FUNCTIONS-SNAPSHOT-SYNCHRONIZATION), [pg_restore](https://www.postgresql.org/docs/18/app-pgrestore.html).
- [Google Drive uploads](https://developers.google.com/workspace/drive/api/guides/manage-uploads), [Microsoft Graph upload sessions](https://learn.microsoft.com/en-us/graph/api/driveitem-createuploadsession?view=graph-rest-1.0).
- [Google Drive folder creation and parents](https://developers.google.com/workspace/drive/api/guides/folder), [Microsoft Graph child folders](https://learn.microsoft.com/en-us/graph/api/driveitem-post-children?view=graph-rest-1.0), [Graph item metadata](https://learn.microsoft.com/en-us/graph/api/driveitem-get?view=graph-rest-1.0).
- [AWS Ruby SDK](https://github.com/aws/aws-sdk-ruby), [S3 multipart uploads](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html), [S3 Object Lock](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html).
- [R2 Ruby example](https://developers.cloudflare.com/r2/examples/aws/aws-sdk-ruby/), [B2 Ruby integration](https://www.backblaze.com/docs/cloud-storage-use-the-aws-sdk-for-ruby-with-backblaze-b2).
- [Net::SFTP](https://github.com/net-ssh/net-sftp), [Rubyzip](https://github.com/rubyzip/rubyzip).
- [Windows free space](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getdiskfreespaceexw), [file security](https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-setfilesecurityw), [process termination](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-terminateprocess), [Ruby subprocess lifecycle](https://ruby-doc.org/3.4/Process.html).
- [Google Cloud Storage Ruby client](https://docs.cloud.google.com/ruby/docs/reference/google-cloud-storage/latest), [Graph SDK languages](https://learn.microsoft.com/en-us/graph/sdks/sdks-overview), [Dropbox community SDKs](https://docs.dropboxapi.com/dropbox-api/docs/sdks/community-sdks), [Box maintained SDKs](https://developer.box.com/guides/tooling/sdks/).

Provider APIs and package versions change. Lock and test compatible dependencies in the actual Redmine installation; do not automatically upgrade the host application.

Redmine's [Setting model and cross-process cache refresh](https://github.com/redmine/redmine/blob/7.0.2/app/models/setting.rb) is the authoritative source for `Setting.check_cache`. Web requests call it through the host controller; the backup runtime calls it explicitly for the supervised Rake worker as well. This fixes mixed stale destination IDs and fresh private tokens after an administrator changes settings.
