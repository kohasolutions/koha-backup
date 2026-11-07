# Tested

<!-- Written by `bash tests/live.sh`. Do not edit by hand. -->

Every check below ran against a real Koha with its sample data: backups of the running library, a self-test, and
full restores into a brand-new instance made with `koha-create`.

| | |
|---|---|
| Koha | **26.05.02** (code version 26.05.02.002, database version 26.0600002) |
| Database | 11.8.8-MariaDB-ubu2404 |
| Operating system | Debian GNU/Linux 13 (trixie) |
| Run at | 2026-11-07T18:43:35Z |
| Result | **44 of 44 checks passed** |

| What was checked | |
|---|---|
| Three backups of a running Koha with `KEEP=2` | 2 archives kept, each with its checksum; Koha's own backup folder left as it was |
| Archive contents | database dump (with no database name), configuration, uploads and plugins |
| Self-test | newest backup loaded into a scratch database; tables and row counts of biblio, biblioitems, items, borrowers, issues, old_issues, reserves, accountlines matched; scratch database dropped |
| Damaged archive | refused on restore (checksum) |
| Failed database dump | a `mysqldump` that fails (which `koha-dump` does not notice) makes the backup fail; nothing kept |
| Restore into a new instance | all counts matched; Koha's own code reads 1100 records and 536 patrons from the restored instance; search index rebuilt |
| Safety | restore over a database with data refused without `--overwrite` and a matching confirmation |
| Encryption and off-site copy | `age`-encrypted archives, copied with `rclone`, retention applied at both ends; restored from the off-site copy with the key |

Not covered by this run: the systemd timer over days (the unit file is checked in the unit tests), Elasticsearch
instances (this Koha uses Zebra), and MySQL instead of MariaDB.

The full log of this run is attached to the release as `test-run-v<version>.txt`.
