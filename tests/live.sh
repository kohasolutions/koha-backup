#!/usr/bin/env bash
# Live test: koha-backup against a real Koha with real data, end to end. Writes TESTED.md and test-run.txt (the log
# attached to each release). Run on a machine with Docker and a koha-testing-docker Koha (container KOHA, instance
# kohadev); see "Testing" in the README.
#
#   bash tests/live.sh                 KOHA=koha-koha-1 by default
#   KOHA_ROOT_CNF=/path bash tests/live.sh   a MySQL option file for a user that may create and drop databases
#
# What it touches:
#   - the running Koha: reads only. Backups go to /tmp/koha-backup-live inside it and are removed at the end; the
#     self-test's scratch database is created and dropped. No restore is ever pointed at it.
#   - a sandbox it creates and removes: a MariaDB container and a second container from the same Koha image, where
#     a NEW empty instance is made with koha-create and every restore runs.

set -Eeuo pipefail
cd "$(dirname "$0")/.."

KOHA=${KOHA:-koha-koha-1}
INSTANCE=${INSTANCE:-kohadev}
IMAGE=${IMAGE:-$(docker inspect -f '{{.Config.Image}}' "$KOHA")}
KOHA_SRC=${KOHA_SRC:-$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/kohadevbox/koha"}}{{.Source}}{{end}}{{end}}' "$KOHA")}
NET=kb-live-$$
SDB=kb-live-db-$$
SKOHA=kb-live-koha-$$
TARGET=kbrestore
LOG=test-run.txt
LIVE_DIR=/tmp/koha-backup-live

PASS=0
FAIL=0
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

section() { printf '\n== %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
check() { local what=$1; shift; if "$@"; then pass "$what"; else fail "$what"; fi; }
has() { grep -qF -- "$2" <<<"$1"; }
lacks() { ! grep -qF -- "$2" <<<"$1"; }
lk() { docker exec "$KOHA" bash -c "$1"; }
sk() { docker exec "$SKOHA" bash -c "$1"; }

cleanup() {
  docker rm -f "$SKOHA" "$SDB" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker exec "$KOHA" rm -rf "$LIVE_DIR" /tmp/koha-backup.sh >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ── What we are testing on ──────────────────────────────────────────────────────────────────────────────────────
section "Environment"
lk 'true' || { echo "Koha container $KOHA is not running."; exit 2; }
KOHA_VERSION=$(lk "cd /kohadevbox/koha && PERL5LIB=/kohadevbox/koha perl -MKoha -e 'print Koha::version()'" 2>/dev/null)
RELEASE=$(cut -d. -f1-3 <<<"$KOHA_VERSION")
DB_SCHEMA=$(lk "mysql --defaults-extra-file=<(printf '[client]\nhost=%s\nuser=%s\npassword=\"%s\"\n' \$(xmlstarlet sel -t -v 'yazgfs/config/hostname' -o ' ' -v 'yazgfs/config/user' -o ' ' -v 'yazgfs/config/pass' /etc/koha/sites/$INSTANCE/koha-conf.xml)) -N -e \"SELECT value FROM systempreferences WHERE variable='Version'\" koha_$INSTANCE")
DB_SERVER=$(lk "mysql --defaults-extra-file=<(printf '[client]\nhost=%s\nuser=%s\npassword=\"%s\"\n' \$(xmlstarlet sel -t -v 'yazgfs/config/hostname' -o ' ' -v 'yazgfs/config/user' -o ' ' -v 'yazgfs/config/pass' /etc/koha/sites/$INSTANCE/koha-conf.xml)) -N -e 'SELECT VERSION()'")
# shellcheck disable=SC2016  # $PRETTY_NAME expands inside the Koha container, not here
OS=$(lk '. /etc/os-release; echo "$PRETTY_NAME"')
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "koha-backup $(bash koha-backup.sh version | cut -d' ' -f2)"
echo "Koha $KOHA_VERSION (database version $DB_SCHEMA), $DB_SERVER, $OS"
echo "started $STARTED"

if [ -z "${KOHA_ROOT_CNF:-}" ]; then
  # koha-testing-docker: the root password is in the compose project's .env next to koha-src.
  pw=$(grep -m1 '^MYSQL_ROOT_PASSWORD=' "$(dirname "$KOHA_SRC")/.env" 2>/dev/null | cut -d= -f2- || true)
  [ -n "$pw" ] || pw=password
  KOHA_ROOT_CNF=$(mktemp); trap 'rm -f "$KOHA_ROOT_CNF"; cleanup' EXIT
  printf '[client]\nhost = db\nuser = root\npassword = "%s"\n' "$pw" > "$KOHA_ROOT_CNF"
fi

# ── 1. Backups of the running Koha ──────────────────────────────────────────────────────────────────────────────
section "1. Backups of the running Koha ($INSTANCE)"
docker cp koha-backup.sh "$KOHA:/tmp/koha-backup.sh" >/dev/null
lk "mkdir -p $LIVE_DIR && chmod 700 $LIVE_DIR"
docker cp "$KOHA_ROOT_CNF" "$KOHA:$LIVE_DIR/admin.cnf" >/dev/null
lk "chown root:root $LIVE_DIR/admin.cnf && chmod 600 $LIVE_DIR/admin.cnf"
lk "printf 'BACKUP_DIR=$LIVE_DIR/backups\nKEEP=2\nMYSQL_ADMIN_CNF=$LIVE_DIR/admin.cnf\n' > $LIVE_DIR/conf && chmod 600 $LIVE_DIR/conf"
KB="bash /tmp/koha-backup.sh --config $LIVE_DIR/conf"
SPOOL=$(lk "xmlstarlet sel -t -v 'yazgfs/config/backupdir' /etc/koha/sites/$INSTANCE/koha-conf.xml || echo /var/spool/koha/$INSTANCE")
spool_before=$(lk "ls -l --time-style=+%s $SPOOL 2>/dev/null | sort")

for i in 1 2 3; do
  out=$(lk "$KB run $INSTANCE" 2>&1) && rc=0 || rc=$?
  echo "$out"
  check "backup $i of $INSTANCE exits 0" [ "$rc" -eq 0 ]
  sleep 1
done
n=$(lk "ls $LIVE_DIR/backups/$INSTANCE/*.tar | wc -l")
check "KEEP=2 after three backups leaves 2 archives (found $n)" [ "$n" -eq 2 ]
n=$(lk "ls $LIVE_DIR/backups/$INSTANCE/*.tar.sha256 | wc -l")
check "each archive has its checksum file" [ "$n" -eq 2 ]
check "Koha's own backup folder $SPOOL is as it was" [ "$spool_before" = "$(lk "ls -l --time-style=+%s $SPOOL 2>/dev/null | sort")" ]
check "the backup folder is private (mode 700)" [ "$(lk "stat -c %a $LIVE_DIR/backups/$INSTANCE")" = 700 ]
ARCHIVE=$(lk "ls $LIVE_DIR/backups/$INSTANCE/*.tar | tail -n 1")
MANIFEST=$(lk "tar -xOf $ARCHIVE manifest.txt")
echo "$MANIFEST"
check "archive holds manifest, database dump and files" has "$(lk "tar -tf $ARCHIVE")" "$INSTANCE-files.tar.gz"
check "files archive holds the instance's koha-conf.xml" has "$(lk "tar -xOf $ARCHIVE $INSTANCE-files.tar.gz | tar -tz")" "etc/koha/sites/$INSTANCE/koha-conf.xml"
check "the database dump names no database (restorable under another name)" \
  bash -c "! docker exec $KOHA bash -c 'tar -xOf $ARCHIVE $INSTANCE.sql.gz | zcat | head -n 40' | grep -qE '^(CREATE DATABASE|USE )'"
out=$(lk "$KB list" 2>&1); echo "$out"
check "list shows the archives" has "$out" "$(basename "$ARCHIVE")"

# ── 2. Self-test on the running Koha's server ───────────────────────────────────────────────────────────────────
section "2. Self-test: newest backup into a scratch database"
out=$(lk "$KB selftest $INSTANCE" 2>&1) && rc=0 || rc=$?
echo "$out"
check "self-test passes" [ "$rc" -eq 0 ]
check "self-test compared biblio counts" has "$out" "ok    biblio:"
check "self-test recorded its result" has "$(lk "tail -n 1 $LIVE_DIR/backups/$INSTANCE/selftest.log")" "PASS"
left=$(lk "mysql --defaults-extra-file=$LIVE_DIR/admin.cnf -N -e \"SHOW DATABASES LIKE 'koha_backup_selftest%'\"")
check "self-test dropped its scratch database" [ -z "$left" ]

section "3. A damaged archive is refused"
lk "mkdir -p $LIVE_DIR/bad && cp $ARCHIVE $ARCHIVE.sha256 $LIVE_DIR/bad/ && printf 'X' | dd of=$LIVE_DIR/bad/$(basename "$ARCHIVE") bs=1 seek=4096 conv=notrunc status=none"
out=$(lk "$KB restore $LIVE_DIR/bad/$(basename "$ARCHIVE") --to no-such-instance" 2>&1) && rc=0 || rc=$?
echo "$out"
check "restore of a damaged archive exits non-zero" [ "$rc" -ne 0 ]
check "and says the checksum does not match" has "$out" "Checksum does not match"

# ── 4. Restore into a NEW instance (sandbox) ────────────────────────────────────────────────────────────────────
section "4. Restore into a new, empty Koha instance"
docker network create "$NET" >/dev/null
docker run -d --rm --name "$SDB" --network "$NET" --network-alias db -e MARIADB_ROOT_PASSWORD=sandboxroot mariadb:11.8 >/dev/null
docker run -d --rm --name "$SKOHA" --network "$NET" --entrypoint sleep -v "$KOHA_SRC:/kohadevbox/koha:ro" "$IMAGE" infinity >/dev/null
sk 'printf "[client]\nhost = db\nuser = root\npassword = sandboxroot\n" > /etc/mysql/koha-common.cnf; chmod 600 /etc/mysql/koha-common.cnf'
for _ in $(seq 60); do sk 'mysql --defaults-extra-file=/etc/mysql/koha-common.cnf -e "select 1"' >/dev/null 2>&1 && break; sleep 2; done
echo "koha-create --create-db $TARGET"
sk "koha-create --create-db --dbhost db $TARGET" >/dev/null 2>&1
# koha-create grants the instance's database user from localhost only; this database is on another host.
sk "P=\$(xmlstarlet sel -t -v '(yazgfs/config/pass)[1]' /etc/koha/sites/$TARGET/koha-conf.xml); P=\${P//\\\\/\\\\\\\\}; P=\${P//\\'/\\\\\\'}
    mysql --defaults-extra-file=/etc/mysql/koha-common.cnf -e \"CREATE USER IF NOT EXISTS 'koha_$TARGET'@'%' IDENTIFIED BY '\$P'; GRANT ALL ON koha_$TARGET.* TO 'koha_$TARGET'@'%'\""
check "a new empty instance $TARGET exists" has "$(sk koha-list)" "$TARGET"
sk 'mkdir -p /root/in /etc/koha-backup && printf "BACKUP_DIR=/root/backups\n" > /etc/koha-backup/koha-backup.conf && chmod 600 /etc/koha-backup/koha-backup.conf'
docker cp koha-backup.sh "$SKOHA:/root/koha-backup.sh" >/dev/null
tmp=$(mktemp -d)
docker cp "$KOHA:$ARCHIVE" "$tmp/" >/dev/null; docker cp "$KOHA:$ARCHIVE.sha256" "$tmp/" >/dev/null
docker cp "$tmp/." "$SKOHA:/root/in/" >/dev/null; rm -rf "$tmp"
A=/root/in/$(basename "$ARCHIVE")

out=$(sk "bash /root/koha-backup.sh restore $A --to $TARGET" 2>&1) && rc=0 || rc=$?
echo "$out"
check "restore into the new instance exits 0" [ "$rc" -eq 0 ]
check "every count matched" lacks "$out" "FAIL"
check "uploads and plugins copied" has "$out" "pluginsdir copied"
check "search index rebuilt" has "$out" "search index rebuilt"
want_b=$(sed -n 's/^count.biblio=\([0-9]*\):.*/\1/p' <<<"$MANIFEST"); want_p=$(sed -n 's/^count.borrowers=\([0-9]*\):.*/\1/p' <<<"$MANIFEST")
got=$(sk "PERL5LIB=/kohadevbox/koha KOHA_CONF=/etc/koha/sites/$TARGET/koha-conf.xml perl -MKoha::Biblios -MKoha::Patrons -e 'print Koha::Biblios->search->count, q{ }, Koha::Patrons->search->count' 2>/dev/null")
echo "Koha's own code on $TARGET: biblios patrons = $got (backup: $want_b $want_p)"
check "Koha's code reads the restored instance: $got" [ "$got" = "$want_b $want_p" ]

section "5. Safety: restoring over a database that has data"
out=$(sk "bash /root/koha-backup.sh restore $A --to $TARGET < /dev/null" 2>&1) && rc=0 || rc=$?
echo "$out"
check "refused without --overwrite" [ "$rc" -ne 0 ]
check "and explains why" has "$out" "Restoring would replace all of it"
out=$(sk "bash /root/koha-backup.sh restore $A --to $TARGET --overwrite < /dev/null" 2>&1) && rc=0 || rc=$?
check "--overwrite without a typed confirmation is refused when not at a terminal" [ "$rc" -ne 0 ]
out=$(sk "bash /root/koha-backup.sh restore $A --to $TARGET --overwrite --confirm wrong-name" 2>&1) && rc=0 || rc=$?
echo "$out"
check "a confirmation that does not match is refused" [ "$rc" -ne 0 ]
check "and nothing was changed" has "$out" "Nothing was changed"
out=$(sk "bash /root/koha-backup.sh restore $A --to not-an-instance" 2>&1) && rc=0 || rc=$?
check "an instance that does not exist is refused with the koha-create command" has "$out" "koha-create --create-db not-an-instance"

section "5b. A failed database dump is not taken for a backup"
# koha-dump does not check mysqldump's exit status. A stand-in mysqldump that writes half a dump and fails, first on
# PATH in the sandbox only, must make the backup fail and leave no archive and nothing in Koha's folder.
sk 'mkdir -p /root/fakebin && printf "#!/bin/sh\necho \"-- half a dump\"\nexit 2\n" > /root/fakebin/mysqldump && chmod +x /root/fakebin/mysqldump'
out=$(sk "PATH=/root/fakebin:\$PATH bash /root/koha-backup.sh run $TARGET" 2>&1) && rc=0 || rc=$?
echo "$out"
check "a failed mysqldump makes the backup fail" [ "$rc" -ne 0 ]
check "and says the dump is incomplete" has "$out" "incomplete"
check "no archive was kept" [ "$(sk "ls /root/backups/$TARGET 2>/dev/null | grep -c tar || true")" -eq 0 ]
check "nothing left in Koha's backup folder" [ -z "$(sk "ls /var/spool/koha/$TARGET 2>/dev/null")" ]

# ── 6. Encrypted off-site copies (sandbox, backing up the restored instance) ────────────────────────────────────
section "6. Encryption (age) and an off-site copy (rclone)"
# Pinned release binaries (tests/fetch-tools.sh), copied in: no apt, no network inside the sandbox. /usr/bin, because
# this image's PATH has no /usr/local/bin.
bash tests/fetch-tools.sh >/dev/null
docker cp tests/.cache/age/age "$SKOHA:/usr/bin/age" >/dev/null
docker cp tests/.cache/age/age-keygen "$SKOHA:/usr/bin/age-keygen" >/dev/null
docker cp tests/.cache/rclone "$SKOHA:/usr/bin/rclone" >/dev/null
check "age and rclone available" sk 'command -v age >/dev/null && command -v age-keygen >/dev/null && command -v rclone >/dev/null'
sk 'age-keygen -o /root/key.txt && chmod 600 /root/key.txt'
PUB=$(sk "age-keygen -y /root/key.txt")
sk "printf 'BACKUP_DIR=/root/backups\nKEEP=1\nREMOTE=:local:/root/offsite\nAGE_RECIPIENT=$PUB\nMYSQL_ADMIN_CNF=/etc/mysql/koha-common.cnf\n' > /etc/koha-backup/koha-backup.conf"
for i in 1 2; do
  out=$(sk "bash /root/koha-backup.sh run $TARGET" 2>&1) && rc=0 || rc=$?
  echo "$out"; check "encrypted backup $i exits 0" [ "$rc" -eq 0 ]; sleep 1
done
check "local folder keeps 1 encrypted archive" [ "$(sk "ls /root/backups/$TARGET/*.tar.age | wc -l")" -eq 1 ]
check "no unencrypted archive is left behind" [ "$(sk "ls /root/backups/$TARGET/ | grep -c '\.tar\$' || true")" -eq 0 ]
check "off-site copy keeps 1 archive and its checksum" [ "$(sk "ls /root/offsite/$TARGET/ | wc -l")" -eq 2 ]
check "the archive is really encrypted (age header)" has "$(sk "head -c 40 /root/backups/$TARGET/*.tar.age")" "age-encryption.org"
out=$(sk "bash /root/koha-backup.sh selftest $TARGET" 2>&1); echo "$out"
check "self-test without the key checks the checksum only" has "$out" "checksum only"
out=$(sk "bash /root/koha-backup.sh selftest $TARGET --identity /root/key.txt" 2>&1) && rc=0 || rc=$?
echo "$out"
check "self-test with the key restores and passes" [ "$rc" -eq 0 ]
out=$(sk "bash /root/koha-backup.sh restore $TARGET --to $TARGET --overwrite --confirm $TARGET" 2>&1) && rc=0 || rc=$?
check "restore of an encrypted backup without the key is refused" has "$out" "--identity"
out=$(sk "bash /root/koha-backup.sh restore /root/offsite/$TARGET/\$(ls /root/offsite/$TARGET | grep 'age\$') --to $TARGET --overwrite --confirm $TARGET --identity /root/key.txt --no-reindex" 2>&1) && rc=0 || rc=$?
echo "$out"
check "restore from the off-site copy, decrypted, over the instance (--overwrite --confirm)" [ "$rc" -eq 0 ]

# ── Result ──────────────────────────────────────────────────────────────────────────────────────────────────────
section "Result"
FINISHED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "$PASS passed, $FAIL failed ($STARTED to $FINISHED)"

if [ "$FAIL" -eq 0 ]; then
  cat > TESTED.md <<EOF
# Tested

<!-- Written by \`bash tests/live.sh\`. Do not edit by hand. -->

Every check below ran against a real Koha with its sample data: backups of the running library, a self-test, and
full restores into a brand-new instance made with \`koha-create\`.

| | |
|---|---|
| Koha | **$RELEASE** (code version $KOHA_VERSION, database version $DB_SCHEMA) |
| Database | $DB_SERVER |
| Operating system | $OS |
| Run at | $FINISHED |
| Result | **$PASS of $PASS checks passed** |

| What was checked | |
|---|---|
| Three backups of a running Koha with \`KEEP=2\` | 2 archives kept, each with its checksum; Koha's own backup folder left as it was |
| Archive contents | database dump (with no database name), configuration, uploads and plugins |
| Self-test | newest backup loaded into a scratch database; tables and row counts of $(sed -n 's/^count\.\([a-z_]*\)=.*/\1/p' <<<"$MANIFEST" | paste -sd, - | sed 's/,/, /g') matched; scratch database dropped |
| Damaged archive | refused on restore (checksum) |
| Failed database dump | a \`mysqldump\` that fails (which \`koha-dump\` does not notice) makes the backup fail; nothing kept |
| Restore into a new instance | all counts matched; Koha's own code reads $want_b records and $want_p patrons from the restored instance; search index rebuilt |
| Safety | restore over a database with data refused without \`--overwrite\` and a matching confirmation |
| Encryption and off-site copy | \`age\`-encrypted archives, copied with \`rclone\`, retention applied at both ends; restored from the off-site copy with the key |

Not covered by this run: the systemd timer over days (the unit file is checked in the unit tests), Elasticsearch
instances (this Koha uses Zebra), and MySQL instead of MariaDB.

The full log of this run is attached to the release as \`test-run-v<version>.txt\`.
EOF
  echo "TESTED.md written."
fi
[ "$FAIL" -eq 0 ]
