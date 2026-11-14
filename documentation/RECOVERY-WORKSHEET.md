# Private recovery worksheet template

Complete this template privately outside the public source repository. Record paths and evidence, not passwords, tokens, private key contents or customer data.

## Installation inventory

| Item | Private operational value / evidence |
| --- | --- |
| Host identity, public/private addresses and administrator | |
| OS, architecture and source/package repositories | |
| Redmine, Ruby, Rails, Bundler and PostgreSQL versions | |
| Database, owner, encoding, locale, schemas, extensions and required roles | |
| Application/attachment roots and symlink targets | |
| Service user/group IDs, units and environment-file paths | |
| Rails key, SMTP state, provider SSH key and database TLS paths | |
| Additional coverage and exclusions reviewed | |
| Private backup directory and storage capacity/reserve | |
| Primary destination/account/folder and required retention | |
| Optional secondary: disabled / redundant / failover and retention | |
| Versioning/lock policy and effective expiry | |
| Notification user/group IDs, audience and email health | |
| Schedule/timezone and shutdown/maintenance windows | |
| Worker heartbeat, first capture/upload verification and validation run | |
| Independent recovery administrator/access | |
| Isolated restore result and date | |

## Incident and recovery record

| Item | Evidence |
| --- | --- |
| Incident time, recovery owner and failed-host fencing | |
| Selected run ID, capture time and expected data-loss interval | |
| Complete marker, artifact sizes and checksum verification | |
| Replacement host and reproduced software versions | |
| Private bootstrap, original key pairing and Recovery Mode | |
| Database restore result, attachment verification and functional checks | |
| Separately provisioned gateway/HTTPS and cutover readiness | |
| Notification/retention review, deliberate activation and next backup | |
| Measured recovery time and unresolved limitations | |

Retain an accessible private copy outside the source server. The live backup guide is [RECOVERY.md](RECOVERY.md).
