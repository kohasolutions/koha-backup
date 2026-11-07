# koha-backup

Scheduled backups for every Koha instance on a server, and a restore you have actually tried. One shell script runs
Koha's own `koha-dump`, keeps the newest copies, can encrypt them and copy them off the server, and once a month
restores the newest backup into a scratch database to prove it still opens.

[![Checks](https://github.com/kohasolutions/koha-backup/actions/workflows/ci.yml/badge.svg)](https://github.com/kohasolutions/koha-backup/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/kohasolutions/koha-backup)](https://github.com/kohasolutions/koha-backup/releases)
[![Tested on Koha 26.05](https://img.shields.io/badge/tested%20on-Koha%2026.05-2ea44f)](TESTED.md)
[![MIT licence](https://img.shields.io/badge/licence-MIT-blue)](LICENSE)

> A backup you have never restored is a hope, not a backup.

## Who this is for

- Anyone who runs Koha from the Debian/Ubuntu packages (`koha-common`) and is responsible for not losing it.
- You need root (`sudo`) on the Koha server. Nothing else to install: `koha-dump`, `xmlstarlet` and the MariaDB
  client already come with Koha. `age` and `rclone` only if you want encryption or off-site copies.

## Quick start

```bash
curl -fsSLO https://github.com/kohasolutions/koha-backup/releases/latest/download/koha-backup.sh
sudo bash koha-backup.sh install --keep 14 --time 02:30
sudo koha-backup run
```

`install` copies the script to `/usr/local/sbin/koha-backup`, writes `/etc/koha-backup/koha-backup.conf` and turns
on a daily systemd timer. `run` makes a backup now. On our test Koha (26.05.02 with its sample data; test settings `BACKUP_DIR=/tmp/koha-backup-live/backups`, `KEEP=2`,
third run) it printed:

```text
Backing up kohadev
  saved /tmp/koha-backup-live/backups/kohadev/kohadev-2026-11-07T183521Z.tar (5.6M)
  rows: biblio 1100  items 1690  borrowers 536
  removed old backup kohadev-2026-11-07T183515Z.tar
1 of 1 backups done.
```

## What goes in a backup

One file per instance per run, `/var/backups/koha/<instance>/<instance>-<UTC time>.tar`, with a `.sha256` file
beside it. Inside:

| File | What it holds |
|---|---|
| `<instance>.sql.gz` | the whole database, from `koha-dump`, written without a database name so it can be restored under any name |
| `<instance>-files.tar.gz` | `koha-conf.xml` and the instance's other configuration, the Apache site, `/var/lib/koha/<instance>` (uploads, plugins) |
| `manifest.txt` | when, which Koha, how many tables, and the row counts of `biblio`, `items`, `borrowers`, `issues` and four more, taken just before and just after the dump; checksums of the two files above |

Cover images uploaded into Koha are in the database. The search index is not kept: it is rebuilt on restore.

## Usage

```bash
sudo koha-backup run                     # every enabled instance (or INSTANCES in the settings)
sudo koha-backup run mylib               # one instance
sudo koha-backup list                    # what is on disk, newest first, and the last self-test
sudo koha-backup selftest                # restore the newest backup into a scratch database and check it
sudo koha-backup restore mylib --to mylib-test     # newest backup of mylib into the instance mylib-test
```

`list` on the test server:

```text
kohadev
  kohadev-2026-11-07T183521Z.tar                       5.6M
  kohadev-2026-11-07T183518Z.tar                       5.6M
  last self-test: never (run: koha-backup selftest kohadev)
```

## Testing a backup: the self-test

`selftest` takes the newest backup of each instance, checks its checksum, loads the database into a new scratch
database, compares the table count and the row counts with the manifest, then drops the scratch database. Your
library is not touched. `install` runs it on the first of every month at 04:00 (`--selftest weekly` or `off` to
change that); the result goes into `list` and the journal.

```text
Self-test of kohadev: kohadev-2026-11-07T183521Z.tar
  ok    checksum
  ok    archive opens; contents match their checksums
  ok    database dump loads into a scratch database
  ok    tables: 299
  ok    biblio: 1100 rows
  ok    biblioitems: 1096 rows
  ok    items: 1690 rows
  ok    borrowers: 536 rows
  ok    issues: 117 rows
  ok    old_issues: 372 rows
  ok    reserves: 54 rows
  ok    accountlines: 230 rows
  PASS
1 of 1 self-tests passed.
```

It needs a MySQL user that may create and drop a database. On a standard Koha server that is
`/etc/mysql/koha-common.cnf`; set `MYSQL_ADMIN_CNF` if yours is elsewhere.

## Restoring

**Restore into a new instance first.** Create an empty one with Koha's own tool, then restore into it:

```bash
sudo koha-create --create-db mylib-test
sudo koha-backup restore mylib --to mylib-test
```

The restore checks the checksum, loads the database, copies uploads and plugins, rebuilds the search index (Zebra or
Elasticsearch, whichever the library uses), restarts Plack where it is on, clears Koha's cache and compares the row counts with the backup:

```text
Restoring kohadev-2026-11-07T183521Z.tar into kbrestore
  ok    checksum
  ok    database loaded into koha_kbrestore
  ok    upload_path copied to /var/lib/koha/kbrestore/uploads
  ok    pluginsdir copied to /var/lib/koha/kbrestore/plugins
WARNING: kbrestore has a different <encryption_key> from kohadev. Data Koha encrypts with it (for example two-factor
WARNING: authentication secrets) will not open on kbrestore. If kbrestore is to replace kohadev, copy kohadev's key into
WARNING: /etc/koha/sites/kbrestore/koha-conf.xml; the original file is inside the backup at etc/koha/sites/kohadev/koha-conf.xml.
  ok    Zebra search index rebuilt
  ok    tables: 299
  ok    biblio: 1100 rows
  ok    biblioitems: 1096 rows
  ok    items: 1690 rows
  ok    borrowers: 536 rows
  ok    issues: 117 rows
  ok    old_issues: 372 rows
  ok    reserves: 54 rows
  ok    accountlines: 230 rows
Restored. kbrestore now holds the data of kohadev as it was at 2026-11-07T183521Z.
Backup's Koha database version: 26.0600002. If kbrestore runs a newer Koha, open its staff interface: Koha will offer to update the database.
```

Open `mylib-test`'s staff interface and look around. When you are sure, restore over the live library:

```bash
sudo koha-backup restore mylib-2026-11-07T023000Z.tar --to mylib --overwrite
```

Restoring over an instance that has data (or over the library the backup came from) always needs `--overwrite` and
then the instance name typed again. In a script, pass `--confirm mylib` instead of typing it.

**The encryption key.** Koha encrypts a few things (two-factor authentication secrets, for one) with the
`<encryption_key>` in `koha-conf.xml`. A new instance gets a new key, and the restore warns about it. If the new
instance is going to replace the old one, copy the old key across; the old `koha-conf.xml` is inside the backup.

## Off-site copies and encryption

A backup on the same disk as the library is lost with the disk. Set `REMOTE` to any [rclone](https://rclone.org)
destination (Amazon S3, Cloudflare R2, Backblaze B2, MinIO, an SFTP server) and every archive is copied there;
`REMOTE_KEEP` copies are kept there (default: the same as `KEEP`).

```ini
# /etc/koha-backup/koha-backup.conf  (mode 600)
KEEP=14
REMOTE=r2:library-backups/koha
RCLONE_CONFIG=/etc/koha-backup/rclone.conf
AGE_RECIPIENT=age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
```

```ini
# /etc/koha-backup/rclone.conf  (mode 600)
[r2]
type = s3
provider = Cloudflare
access_key_id = …
secret_access_key = …
endpoint = https://<account id>.r2.cloudflarestorage.com
```

With `AGE_RECIPIENT` set, every archive is encrypted with [age](https://github.com/FiloSottile/age) before it leaves
the script, and only the `.tar.age` file is kept. Make the key pair on another computer (`age-keygen -o key.txt`),
put only the public key (`age1…`) in the settings, and keep `key.txt` somewhere safe that is not the Koha server. To
restore or self-test, copy the key over for that job and pass `--identity key.txt`. Without it, the monthly self-test
of an encrypted backup can only check the checksum; set `AGE_IDENTITY` if you accept keeping the key on the server.

## Settings

`/etc/koha-backup/koha-backup.conf`, `KEY=value` lines. It is read as text, never run, must belong to root with mode
600, and an unknown key is an error rather than silently ignored.

| Setting | Default | What it does |
|---|---|---|
| `BACKUP_DIR` | `/var/backups/koha` | where backups are kept, one folder per instance |
| `KEEP` | `14` | backups kept per instance; at least 1, so the newest is never removed |
| `INSTANCES` | every enabled instance | instances to back up, separated by spaces |
| `REMOTE` | (none) | rclone destination for off-site copies |
| `REMOTE_KEEP` | same as `KEEP` | backups kept at `REMOTE` |
| `RCLONE_CONFIG` | `/etc/koha-backup/rclone.conf` | rclone's settings and credentials (mode 600) |
| `AGE_RECIPIENT` | (none) | age public key, or a file of them; encrypts every archive |
| `AGE_IDENTITY` | (none) | age private key file, for `selftest` and `restore` |
| `INCLUDE_LOGS` | `no` | also keep `/var/log/koha/<instance>` (Koha 24.05 and later can leave them out) |
| `MYSQL_ADMIN_CNF` | `/etc/mysql/koha-common.cnf` | MySQL user for the self-test's scratch database |

`install` options: `--keep N`, `--time HH:MM` (server time), `--selftest monthly|weekly|off`. Without systemd, run
`koha-backup run` from root's crontab; `koha-backup units` prints the units `install` would write.

## Troubleshooting

| What you see | Why | What to do |
|---|---|---|
| `ERROR: … can be read by other users (mode 644)` | the settings or rclone file is readable by everyone | `sudo chmod 600 <file>` |
| `WARNING: only N MB free … the backup may not fit` | the backup disk is nearly full | free space or point `BACKUP_DIR` at a bigger disk; lower `KEEP` |
| `ERROR: Checksum does not match` | the archive was damaged or only half copied | use an older backup or the off-site copy; check the disk |
| `Could not create a scratch database with /etc/mysql/koha-common.cnf` | that MySQL user may not create databases | set `MYSQL_ADMIN_CNF` to a file for a user that may |
| `There is no Koha instance called …` | restore needs the instance to exist | `sudo koha-create --create-db <name>` first |
| `koha-dump failed` with `Access denied` | the instance's database password in `koha-conf.xml` no longer works | fix the password in MySQL or in `koha-conf.xml`, then run again |

The backup and its failures are in the journal: `journalctl -u koha-backup`. A failed run exits non-zero, so a
monitoring system that watches the unit sees it.

## Compatibility

| | |
|---|---|
| Tested end to end | Koha **26.05.02** on Debian 13, MariaDB 11.8: see [`TESTED.md`](TESTED.md) |
| Needs | Koha's Debian packages (`koha-common`) 22.11 or later (for `koha-dump --without-db-name`), bash 4.4+, systemd for `install` |
| Search engines | Zebra (tested); Elasticsearch through `koha-elasticsearch --rebuild` |

A note for the curious: `koha-dump --quiet` exits with status 1 even when it succeeds (its last line is
`[ "$quiet" = "no" ] && echo "Done."`), so this tool runs it without `--quiet` and discards the normal output.

## Security

- Runs as root, because it reads every instance's database password from `koha-conf.xml`. The passwords go into a
  private temporary file for the MySQL client, never onto a command line.
- Backups, the backup folders and the settings file are readable by root only.
- It never changes a running library unless you ask for `restore --overwrite` and type the instance's name.
- The self-test creates one scratch database named `koha_backup_selftest_…` and drops it when done.

## Testing

`make test-unit` runs the bats unit tests (retention, checksums, settings and permission rules) in a throwaway
Debian container. `make test-live` runs the whole round trip on a [koha-testing-docker](https://gitlab.com/koha-community/koha-testing-docker)
Koha: three backups, a self-test, a damaged archive, a restore into a brand-new instance made with `koha-create`, the
safety refusals, and an encrypted off-site copy restored back. It writes [`TESTED.md`](TESTED.md) and the log that is
attached to each release.

## Contributing

Issues and pull requests are welcome; see [CONTRIBUTING](https://github.com/kohasolutions/.github/blob/main/CONTRIBUTING.md).
Please run `make lint test-unit` before sending a change.

## Related

- Knowledge base: [Backing up Koha with koha-dump, and restoring it](https://kohasolutions.com/knowledge-base/koha-backup-and-restore-koha-dump)
- Koha manual, command-line tools: https://koha-community.org/manual/latest/en/html/cron_jobs.html
- [koha-sql-reports](https://github.com/kohasolutions/koha-sql-reports): ready-to-use SQL reports for Koha

<!-- about:start -->
## About Koha Solutions

**Koha Solutions** helps libraries run Koha well: Koha hosting, migration and support for libraries worldwide.
Our mission: empowering libraries with smart digital solutions.

We work with college, university, school and public libraries, entirely online. What we do:

- **Koha Cloud** ([myopac.com](https://myopac.com)): Koha's library workflows as a fully managed service. We set it
  up, host it, back it up and upgrade it, so the library can look after its readers instead of a server.
- **Koha Certificate** ([kohasolutions.com/koha-certificate](https://kohasolutions.com/koha-certificate)): Koha
  training on a running library system, with assignments scored from the work trainees actually do.
- **Custom websites** for libraries and institutions, built by the same team
  ([kohasolutions.com/custom-website](https://kohasolutions.com/custom-website)).
- **Services** for libraries that run their own Koha: installation, migration from other systems, support,
  customisation, RFID and multilingual catalogues ([kohasolutions.com/koha-services](https://kohasolutions.com/koha-services)).

The tools in this organisation are free and open source, built from the problems we solve for libraries every day.
Practical answers to everyday Koha questions are in our [knowledge base](https://kohasolutions.com/knowledge-base).

**Talk to us:** [kohasolutions.com/contact](https://kohasolutions.com/contact) ·
[LinkedIn](https://www.linkedin.com/company/kohasolutions) · [YouTube](https://www.youtube.com/@kohasolutions) ·
[GitHub](https://github.com/kohasolutions)
<!-- about:end -->

## Licence

[MIT](LICENSE).

---
Not affiliated with or endorsed by the Koha Community. Koha is free software: https://koha-community.org/
