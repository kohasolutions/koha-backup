# Changelog

Versions follow [semantic versioning](https://semver.org/). The archive format is versioned separately
(`format=koha-backup/1` in each archive's manifest); a release that changes it says so here, and restore keeps
reading older formats.

## 1.0.0 — 2026-11-07

First release. `run`, `list`, `selftest`, `restore`, `install`/`uninstall` with systemd timers; Koha's own
`koha-dump` for the database, configuration and uploads; retention that never removes the last copy; a SHA-256
checksum per archive, checked before every restore; optional `age` encryption and `rclone` off-site copies; restore
into a new instance by default, with `--overwrite` and a typed confirmation required to replace data.
