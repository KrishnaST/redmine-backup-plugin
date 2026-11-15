# Deployment and release operations

Redmine automatically supervises the plugin's dedicated Ruby worker. No separate backup service or OS scheduler is installed. Configuration, credentials and backup payloads belong to the installed instance and are never checked into the public source repository.

## Installation sequence

1. Inspect the current Redmine/Ruby/PostgreSQL versions, service account, environment-file paths, attachment root and existing dependency lockfile. The reusable `tools/deployment_preflight.rb` performs database diagnostics in an explicit read-only transaction.
2. Package only source-controlled runtime, documentation and template files. Exclude `.git`, `target`, local runtimes, dependency caches, temporary captures and operator records. Keep a short-lived rollback copy of the existing Gemfile.lock until installation verification succeeds.
3. Install into `REDMINE_ROOT/plugins/redmine_backup_plugin` as the Redmine service account. Run `bundle install` using the current Redmine environment. Compare the lockfile and avoid unrelated dependency upgrades. There are no plugin table migrations.
4. For upgrades from 0.3.x, stop the obsolete standalone backup worker before replacing code. Restart Redmine; it starts its managed child with the same account, environment and key. Validate private POSIX permissions or Windows ACLs, managed heartbeat, process exclusion and recovery. Remove the old worker service/job after a verified backup. No Puma configuration additions are needed.
5. Verify the plugin registry, routes, public login response, administrator page, worker heartbeat, private control files, queue and setup checks. Existing SMTP functionality and the gateway remain outside the deployment change.
6. Initial storage is unconnected and backup scheduling is disabled. Select a destination, complete its authorization, choose recipients/retention, run the health check and validate a manual backup before enabling daily scheduling. No operational test email or cloud upload is sent just by loading the plugin.

The [recovery worksheet](RECOVERY-WORKSHEET.md) is a private template for the actual host/service paths, checks and evidence. Live instance addresses, credentials, provider grants, service environment values and deployment archives are not part of the public documentation.

## Rollback

If boot/dependency verification fails, stop Redmine so its managed worker exits, remove only the new plugin source, restore the saved source/lockfile and restart with the original dependencies and worker arrangement. Preserve captured backup/control data. Do not drop Redmine tables or remove other plugins. Remove temporary rollback source after verification.

## Maintainer tooling

- `tools/build_documentation.rb` generates the offline HTML guide from current Markdown using Ruby's RDoc. It has no production-runtime role.
- `python tools/build_release.py` packages the committed runtime, documentation and templates into ignored `tmp/deployment/`, with REVISION, archive checksum and a runtime-file SHA-256 manifest. It excludes tests, maintainer tools, local data and Git metadata; commit the reviewed changes before packaging. Python is a maintainer-workstation tool only.
- `tools/check_sources.rb` validates source/workflow syntax and local documentation links; `test/run.rb` runs the independent unit suite.
- `tools/deployment_preflight.rb` reads the installed Redmine metadata from its own application root/environment.
- `tools/deployment_verify.rb` verifies the installed plugin, disabled initial policy, private state and worker heartbeat using read-only database access.
- `tools/admin_smoke.py` verifies the administrator page through normal HTTPS login; it prompts privately and does not trigger a backup or email.
- `tools/storage_folder_smoke.rb --create-verify-delete`, run from Redmine's application root through its normal Bundler/service environment, creates a uniquely named live canary folder in the primary destination, uploads the non-secret recovery guide, verifies bytes/checksum and ownership, then deletes that file and the empty folder. It acquires the worker lock and requires no active job; it does not delete existing backups or change settings. OAuth renewal is saved privately if needed. This acceptance check intentionally writes to configured storage; it is not part of the offline unit suite or a restore drill.
- `tools/remote_console.py` is an optional maintainer workstation transport using Paramiko and strict existing known_hosts verification. It prompts without echo for SSH credentials, keeps them only in memory and accepts JSON execute/upload requests. Paramiko is a workstation dependency only; the installed Ruby plugin never needs Python or this helper. Close the transport after maintenance.

## Repository identity and history

Use the intended GitHub account for authentication and its verified/noreply address for commit attribution; these are separate settings. A deliberate replacement of published history must use an explicitly expected remote SHA with force-with-lease, so a collaborator's intervening push is not overwritten.

Rewriting a branch removes its old commits from that branch's history. It does not guarantee immediate erasure of GitHub caches, forks, clones or historical workflow references. Secrets must not be committed in the first place; credentials exposed elsewhere require their own remediation.

Public visibility permits reading/cloning/forking and proposing pull requests. Direct pushes still require authorized write access. Repository owners can additionally apply branch/ruleset protection.
