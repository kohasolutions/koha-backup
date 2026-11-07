#!/usr/bin/env bats
# Unit tests: the rules that must hold whatever Koha does. Run as root (CI uses sudo; locally: make test-unit).

setup() {
  # shellcheck source=../koha-backup.sh
  source "$BATS_TEST_DIRNAME/../koha-backup.sh"
  # The script turns on -u and pipefail; bats needs -e left ON, or a failed [ ] check would not fail the test.
  set +u
  WORK=$(mktemp -d)
  T=$(mktemp -d)
}

teardown() {
  rm -rf "$T" "$WORK"
}

archive() { # dir name -> a complete archive (with its checksum file)
  echo "data $2" > "$1/$2"
  (cd "$1" && sha256sum -- "$2" > "$2.sha256")
}

# ── Retention ──────────────────────────────────────────────────────────────────

@test "to_prune lists all but the newest N" {
  run to_prune 2 a-1 a-2 a-3 a-4 a-5
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'a-1\na-2\na-3')" ]
}

@test "to_prune deletes nothing when there are N or fewer" {
  run to_prune 3 a-1 a-2 a-3
  [ -z "$output" ]
  run to_prune 14 a-1
  [ -z "$output" ]
}

@test "to_prune refuses to keep zero" {
  run to_prune 0 a-1 a-2
  [ "$status" -ne 0 ]
  [[ "$output" == *"fewer than 1"* ]]
}

@test "KEEP=0 is refused by the settings check" {
  KEEP=0
  run validate_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"KEEP must be"* ]]
}

@test "prune_local keeps the newest KEEP archives and removes their checksum files with them" {
  for t in 2026-11-01T023000Z 2026-11-02T023000Z 2026-11-03T023000Z; do archive "$T" "lib-$t.tar"; done
  KEEP=2
  prune_local "$T"
  [ ! -e "$T/lib-2026-11-01T023000Z.tar" ]
  [ ! -e "$T/lib-2026-11-01T023000Z.tar.sha256" ]
  [ -e "$T/lib-2026-11-02T023000Z.tar" ]
  [ -e "$T/lib-2026-11-03T023000Z.tar" ]
}

@test "an archive without its checksum file is not counted, so it can never push out a complete one" {
  archive "$T" "lib-2026-11-01T023000Z.tar"
  echo half > "$T/lib-2026-11-02T023000Z.tar"   # interrupted: no .sha256
  KEEP=1
  prune_local "$T"
  [ -e "$T/lib-2026-11-01T023000Z.tar" ]
}

@test "complete_archives sorts by the time in the name and ignores other files" {
  archive "$T" "lib-2026-11-03T023000Z.tar.age"
  archive "$T" "lib-2026-11-01T023000Z.tar"
  archive "$T" "notes.tar"
  echo x > "$T/selftest.log"
  run complete_archives "$T"
  [ "$output" = "$(printf 'lib-2026-11-01T023000Z.tar\nlib-2026-11-03T023000Z.tar.age')" ]
}

# ── Checksums ──────────────────────────────────────────────────────────────────

@test "verify_checksum accepts an intact archive" {
  archive "$T" "lib-2026-11-01T023000Z.tar"
  run verify_checksum "$T/lib-2026-11-01T023000Z.tar"
  [ "$status" -eq 0 ]
}

@test "verify_checksum refuses a damaged archive" {
  archive "$T" "lib-2026-11-01T023000Z.tar"
  echo tampered >> "$T/lib-2026-11-01T023000Z.tar"
  run verify_checksum "$T/lib-2026-11-01T023000Z.tar"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match"* ]]
}

@test "verify_checksum refuses an archive with no checksum file" {
  echo data > "$T/lib-2026-11-01T023000Z.tar"
  run verify_checksum "$T/lib-2026-11-01T023000Z.tar"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No checksum file"* ]]
}

@test "unpack refuses an archive whose database dump does not match its manifest" {
  mkdir "$T/in"
  echo dump | gzip > "$T/in/lib.sql.gz"
  tar -czf "$T/in/lib-files.tar.gz" -C "$T/in" lib.sql.gz
  {
    echo "format=koha-backup/1"; echo "instance=lib"
    echo "sql_sha256=0000"; echo "files_sha256=$(sha256sum "$T/in/lib-files.tar.gz" | cut -d' ' -f1)"
  } > "$T/in/manifest.txt"
  tar -cf "$T/lib-2026-11-01T023000Z.tar" -C "$T/in" manifest.txt lib.sql.gz lib-files.tar.gz
  run unpack "$T/lib-2026-11-01T023000Z.tar" ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"database dump inside"*"damaged"* ]]
}

@test "unpack refuses an encrypted archive when no key is given" {
  echo x > "$T/lib-2026-11-01T023000Z.tar.age"
  age() { :; }
  run unpack "$T/lib-2026-11-01T023000Z.tar.age" ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"encrypted"* ]]
}

# ── Settings and credential files ──────────────────────────────────────────────

@test "a settings file readable by other users is refused" {
  printf 'KEEP=3\n' > "$T/conf"; chmod 644 "$T/conf"
  run load_config "$T/conf" yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"can be read by other users"* ]]
}

@test "a settings file not owned by root is refused" {
  printf 'KEEP=3\n' > "$T/conf"; chmod 600 "$T/conf"; chown 65534 "$T/conf"
  run load_config "$T/conf" yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"must belong to root"* ]]
}

@test "a symlink to a private file is accepted (Debian's koha-common.cnf -> debian.cnf)" {
  printf '[client]\n' > "$T/debian.cnf"; chmod 600 "$T/debian.cnf"
  ln -s "$T/debian.cnf" "$T/koha-common.cnf"
  run check_private_file "$T/koha-common.cnf"
  [ "$status" -eq 0 ]
}

@test "a symlink to a file others can read is refused" {
  printf '[client]\n' > "$T/open.cnf"; chmod 644 "$T/open.cnf"
  ln -s "$T/open.cnf" "$T/link.cnf"
  run check_private_file "$T/link.cnf"
  [ "$status" -ne 0 ]
}

@test "the rclone credentials file is held to the same rule" {
  printf '[r2]\n' > "$T/rclone.conf"; chmod 640 "$T/rclone.conf"
  run check_private_file "$T/rclone.conf"
  [ "$status" -ne 0 ]
}

@test "settings are read as text: quotes, inline comments, and nothing is executed" {
  cat > "$T/conf" <<EOF
# a comment
KEEP=7   # keep a week
BACKUP_DIR="/srv/koha backups"
INSTANCES='lib1 lib2'
REMOTE=\$(touch $T/pwned)
EOF
  chmod 600 "$T/conf"
  load_config "$T/conf" yes
  [ "$KEEP" = 7 ]
  [ "$BACKUP_DIR" = "/srv/koha backups" ]
  [ "$INSTANCES" = "lib1 lib2" ]
  [ "$REMOTE" = "\$(touch $T/pwned)" ]
  [ ! -e "$T/pwned" ]
}

@test "an unknown setting is refused rather than silently ignored" {
  printf 'KEPP=3\n' > "$T/conf"; chmod 600 "$T/conf"
  run load_config "$T/conf" yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown setting 'KEPP'"* ]]
}

@test "a missing default settings file is fine; a named one that is missing is an error" {
  run load_config "$T/none" no
  [ "$status" -eq 0 ]
  run load_config "$T/none" yes
  [ "$status" -ne 0 ]
}

@test "INSTANCES accepts spaces or commas" {
  INSTANCES="lib1, lib2  lib3"
  run target_instances
  [ "$output" = "$(printf 'lib1\nlib2\nlib3')" ]
}

@test "passwords with quotes, backslashes, backticks and semicolons are written safely" {
  run cnf_quote 'a"b\c`d;e#f'
  [ "$output" = '"a\"b\\c`d;e#f"' ]
}

# ── Restore checks ─────────────────────────────────────────────────────────────

@test "count_ok accepts a count between the before and after counts" {
  count_ok 100 100 100
  count_ok 100 103 101
  count_ok 103 100 102
  run count_ok 100 100 99
  [ "$status" -ne 0 ]
  run count_ok 100 103 104
  [ "$status" -ne 0 ]
}

@test "compare_counts fails on a missing table or a wrong row count" {
  printf 'tables=3\ncount.biblio=10:10\ncount.items=20:21\ncount.issues=5:5\n' > "$T/m"
  run compare_counts "$T/m" "$(printf '_tables 3\nbiblio 10\nitems 21\nissues 5')"
  [ "$status" -eq 0 ]
  run compare_counts "$T/m" "$(printf '_tables 3\nbiblio 9\nitems 21\nissues 5')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL  biblio: 9 rows, expected 10"* ]]
  run compare_counts "$T/m" "$(printf '_tables 2\nbiblio 10\nitems 20')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL  issues: table missing"* ]]
}

@test "archive names carry a sortable UTC time" {
  is_archive_name lib-2026-11-07T023000Z.tar
  is_archive_name my-lib-2026-11-07T023000Z.tar.age
  run is_archive_name lib-2026-11-07.tar
  [ "$status" -ne 0 ]
}

# ── Install ────────────────────────────────────────────────────────────────────

@test "units writes a daily timer at the chosen time and a monthly self-test" {
  run cmd_units 01:15 monthly
  [[ "$output" == *"OnCalendar=*-*-* 01:15:00"* ]]
  [[ "$output" == *"OnCalendar=*-*-01 04:00:00"* ]]
  [[ "$output" == *"Persistent=true"* ]]
  run cmd_units 01:15 off
  [[ "$output" != *"selftest"* ]]
}

@test "install refuses a bad time or KEEP before touching anything" {
  run cmd_install --time 25:00
  [ "$status" -ne 0 ]
  run cmd_install --keep 0
  [ "$status" -ne 0 ]
}
