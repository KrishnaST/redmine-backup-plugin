# Validation

Local result on 15 November 2026: 90 independent unit tests, 366 assertions, zero failures/errors/skips on portable Ruby 4.0.9. Ruby syntax, workflow YAML indentation, offline-document generation, JavaScript syntax and documentation-link checks passed. Provider-form regression checks cover disabled irrelevant inputs, authentication changes and optional secondary storage. Adapter tests assert the selected S3/STS and SFTP key/password authentication options without contacting providers. RDoc is an explicit standalone test/documentation dependency and is not injected into Redmine's production dependency set.

The [current CI workflow](https://github.com/KrishnaST/redmine-backup-plugin/actions/workflows/test.yml) runs the unit suite on Ruby 3.3, 3.4 and 4.0 and an isolated Redmine/PostgreSQL integration job. The integration cases cover administrator authorization, homepage privacy, provider form rendering, one-click save/connect, state-checked encrypted OAuth callback persistence/replay protection, settings persistence, native test-mail delivery, an actual exported snapshot/database dump, referenced attachment capture and production-style eager loading. CI results are attached to the current repository history rather than obsolete rewritten commit links.

The CI PostgreSQL client wrappers use the isolated test container's matching binaries. They are test infrastructure only and are not installed or required by the production plugin. Native mail uses the in-memory test delivery transport; it sends no external email.

Version 0.2.0 Redmine integration passed 11 tests and 59 assertions, including a regression for private credentials leaking into Redmine's mutable in-process settings cache. Runtime settings are now copied before merging private grants; both the cached settings object and reloaded database settings remain sanitized. No live cloud-account consent is implied by the mocked OAuth exchange.

Run the independent unit suite with `bundle exec ruby -Ilib test/run.rb`. Run `ruby tools/check_sources.rb` for Ruby syntax, workflow YAML indentation and local documentation links.

The initial local suite is executed with a private portable Ruby runtime under ignored `tools/runtime/`. Runtime downloads, installed test gems, temporary backups and credentials are excluded from Git. Tests create scratch files only under ignored `tmp/test` within this repository.

Test scope includes configurable retention/validation, protected pending sets, same-date selection, optional secondary modes, failover/redundant orchestration, retry target selection, destination isolation, encrypted state/wrong-key failure, lock exclusion, scheduling/catch-up/DST, mocked read-only capture/snapshot/attachment validation, ZIP repackaging/integrity, offline bootstrap and SDK/HTTP adapter behavior.

S3 tests use the actual AWS Ruby SDK with stubbed responses. Drive/Graph tests use fake HTTP responses. These tests do not demonstrate live provider compatibility, existing SMTP-plugin delivery or a successful production restore. Installed-instance checks separately verify Linux private-directory permissions, plugin registration, application boot, public access guarding and worker heartbeat.

The GitHub workflow runs unit tests on Ruby 3.3, 3.4 and 4.0, then prepares a disposable Redmine 7.0.2/PostgreSQL 18 installation for route/admin/settings/native-mail and real capture integration. It creates only a dedicated `_test` database. The integration entry point refuses non-test environments/databases. It does not contact any production server or cloud account.

Installed-instance verification on 15 November 2026 used Redmine 7.0.2, Rails 8.1.4, Ruby 4.0.9 and PostgreSQL 18.7. Production eager loading passed after correcting the provider namespace path; this behavior now has an integration regression test. Both Redmine and its enabled backup worker are running. Existing locked gem versions were compared before/after and remained unchanged. The local store is mode 0700, control files are mode 0600 and the worker heartbeat is healthy. The public login returns 200 and anonymous backup administration redirects to login. A normal administrator HTTPS sign-in successfully rendered the backup page with HTTP 200 and the expected retention/secondary controls.

Backup scheduling and the optional secondary remain disabled. Storage authorization and alert recipients are not configured. No production backup, cloud upload, operational notification or full restore drill was performed by deploying the plugin.
