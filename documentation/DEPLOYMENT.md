# Deployment and release operations

This plugin runs inside Redmine; its background worker is a separate native Ruby process. Configuration, credentials and backup payloads belong to the installed instance and are never checked into the public source repository.

## Installation sequence

1. Inspect the current Redmine/Ruby/PostgreSQL versions, service account, environment-file paths, attachment root and existing dependency lockfile. The reusable `tools/deployment_preflight.rb` performs database diagnostics in an explicit read-only transaction.
2. Package only source-controlled runtime, documentation and template files. Exclude `.git`, `target`, local runtimes, dependency caches, temporary captures and operator records. Keep a short-lived rollback copy of the existing Gemfile.lock until installation verification succeeds.
3. Install into `REDMINE_ROOT/plugins/redmine_backup_plugin` as the Redmine service account. Run `bundle install` using the current Redmine environment. Compare the lockfile and avoid unrelated dependency upgrades. There are no plugin table migrations.
4. Install the reviewed worker unit with the same service account, working directory, Ruby/Bundler and environment inputs as Redmine. Give the discovered local store private permissions. Restart Redmine and start the worker.
5. Verify the plugin registry, routes, public login response, administrator page, worker heartbeat, private control files, queue and setup checks. Existing SMTP functionality and the gateway remain outside the deployment change.
6. Initial storage is unconnected and backup scheduling is disabled. Select a destination, complete its authorization, choose recipients/retention, run the health check and validate a manual backup before enabling daily scheduling. No operational test email or cloud upload is sent just by loading the plugin.

The [recovery worksheet](RECOVERY-WORKSHEET.md) is a private template for the actual host/service paths, checks and evidence. Live instance addresses, credentials, provider grants, service environment values and deployment archives are not part of the public documentation.

## Rollback

If boot/dependency verification fails, stop the backup worker, remove only the newly installed plugin directory, restore the saved lockfile and restart Redmine with its original dependencies. Preserve any actual captured backup/control data separately. Do not drop Redmine tables or remove existing plugins. Remove the short-lived rollback lockfile and source upload after a verified installation.

## Maintainer tooling

- `tools/build_documentation.rb` generates the offline HTML guide from current Markdown using Ruby's RDoc. It has no production-runtime role.
- `tools/check_sources.rb` validates source/workflow syntax and local documentation links; `test/run.rb` runs the independent unit suite.
- `tools/deployment_preflight.rb` reads the installed Redmine metadata from its own application root/environment.
- `tools/deployment_verify.rb` verifies the installed plugin, disabled initial policy, private state and worker heartbeat using read-only database access.
- `tools/admin_smoke.py` verifies the administrator page through normal HTTPS login; it prompts privately and does not trigger a backup or email.
- `tools/remote_console.py` is an optional maintainer workstation transport using Paramiko and strict existing known_hosts verification. It prompts without echo for SSH credentials, keeps them only in memory and accepts JSON execute/upload requests. Paramiko is a workstation dependency only; the installed Ruby plugin never needs Python or this helper. Close the transport after maintenance.

## Repository identity and history

Use the intended GitHub account for authentication and its verified/noreply address for commit attribution; these are separate settings. A deliberate replacement of published history must use an explicitly expected remote SHA with force-with-lease, so a collaborator's intervening push is not overwritten.

Rewriting a branch removes its old commits from that branch's history. It does not guarantee immediate erasure of GitHub caches, forks, clones or historical workflow references. Secrets must not be committed in the first place; credentials exposed elsewhere require their own remediation.

Public visibility permits reading/cloning/forking and proposing pull requests. Direct pushes still require authorized write access. Repository owners can additionally apply branch/ruleset protection.
