#!/usr/bin/env bash
# koha-backup: scheduled backups of every Koha instance on a server, and a restore you have actually tried.
#
#   sudo bash koha-backup.sh run                         back up every enabled instance now
#   sudo bash koha-backup.sh list                        what is on disk
#   sudo bash koha-backup.sh selftest                    restore the newest backup into a scratch database and check it
#   sudo bash koha-backup.sh restore mylib --to mylib-test
#   sudo bash koha-backup.sh install --keep 14 --time 02:30
#
# Uses Koha's own koha-dump for the database and configuration. https://github.com/kohasolutions/koha-backup
# MIT licence. Not affiliated with or endorsed by the Koha Community.

set -Eeuo pipefail
umask 077

readonly VERSION=1.0.0
readonly FORMAT=koha-backup/1
readonly DEFAULT_CONF=/etc/koha-backup/koha-backup.conf
readonly INSTALL_BIN=/usr/local/sbin/koha-backup
readonly UNIT_DIR=/etc/systemd/system
# Tables whose row counts are recorded at backup time and compared after every restore.
readonly KEY_TABLES=(biblio biblioitems items borrowers issues old_issues reserves accountlines)

# ── Settings (defaults; the config file overrides them) ─────────────────────────────────────────────────────────────
BACKUP_DIR=/var/backups/koha
KEEP=14
INSTANCES=
REMOTE=
REMOTE_KEEP=
RCLONE_CONFIG=/etc/koha-backup/rclone.conf
AGE_RECIPIENT=
AGE_IDENTITY=
INCLUDE_LOGS=no
MYSQL_ADMIN_CNF=/etc/mysql/koha-common.cnf
readonly CONFIG_KEYS=" BACKUP_DIR KEEP INSTANCES REMOTE REMOTE_KEEP RCLONE_CONFIG AGE_RECIPIENT AGE_IDENTITY INCLUDE_LOGS MYSQL_ADMIN_CNF "

WORK=
cleanup() { [ -n "$WORK" ] && [ -d "$WORK" ] && rm -rf "$WORK"; return 0; }

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# One private scratch folder per run, made in main() (never inside $(...), where the assignment would be lost).
workdir() { printf '%s' "$WORK"; }

# ── Config ───────────────────────────────────────────────────────────────────────────────────────────────────────────

# A file holding settings or credentials must belong to root and be readable by nobody else.
check_private_file() {
  local f=$1 mode owner
  [ -f "$f" ] || die "$f does not exist."
  # -L: judge the file a link points to. On Debian, /etc/mysql/koha-common.cnf is a symlink to debian.cnf, and a
  # symlink's own mode is always 777.
  mode=$(stat -L -c '%a' "$f")
  owner=$(stat -L -c '%u' "$f")
  if [ "$owner" != "0" ]; then die "$f must belong to root (it belongs to user id $owner)."; fi
  if (( 8#$mode & 8#077 )); then die "$f can be read by other users (mode $mode). Run: sudo chmod 600 $f"; fi
}

# KEY=value lines, read as text and never executed. Unknown keys are refused so a typo cannot silently do nothing.
load_config() {
  local f=$1 explicit=$2 line key value n=0
  if [ ! -e "$f" ]; then
    [ "$explicit" = yes ] && die "Config file $f not found."
    return 0
  fi
  check_private_file "$f"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ''|'#'*) continue ;; esac
    [[ "$line" == *=* ]] || die "$f line $n: expected KEY=value."
    key="${line%%=*}"; value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    case "$value" in
      \"*) value="${value#\"}"; [[ "$value" == *\"* ]] || die "$f line $n: unclosed quote."; value="${value%%\"*}" ;;
      \'*) value="${value#\'}"; [[ "$value" == *\'* ]] || die "$f line $n: unclosed quote."; value="${value%%\'*}" ;;
      *) value="${value%%[[:space:]]#*}"; value="${value%"${value##*[![:space:]]}"}" ;;
    esac
    [[ "$CONFIG_KEYS" == *" $key "* ]] || die "$f line $n: unknown setting '$key'."
    printf -v "$key" '%s' "$value"
  done < "$f"
}

validate_config() {
  [[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || die "KEEP must be a whole number of 1 or more (got '$KEEP'): a backup tool that keeps none is not one."
  [ -z "$REMOTE_KEEP" ] && REMOTE_KEEP=$KEEP
  [[ "$REMOTE_KEEP" =~ ^[1-9][0-9]*$ ]] || die "REMOTE_KEEP must be a whole number of 1 or more (got '$REMOTE_KEEP')."
  [[ "$BACKUP_DIR" == /* ]] || die "BACKUP_DIR must be an absolute path (got '$BACKUP_DIR')."
  case "$INCLUDE_LOGS" in yes|no) ;; *) die "INCLUDE_LOGS must be yes or no." ;; esac
  return 0
}

# ── Koha instance helpers ────────────────────────────────────────────────────────────────────────────────────────────

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is not installed. $2"; }

koha_conf() { printf '/etc/koha/sites/%s/koha-conf.xml' "$1"; }

is_instance() { koha-list 2>/dev/null | grep -qx -- "$1"; }

conf_get() { # file xpath-under-config
  xmlstarlet sel -t -v "(yazgfs/config/$2)[1]" "$1" 2>/dev/null || true
}

# A MySQL option value in double quotes, with \ and " escaped, so any password works.
cnf_quote() {
  local v=$1
  v=${v//\\/\\\\}
  v=${v//\"/\\\"}
  printf '"%s"' "$v"
}

# Writes a client option file for an instance's own database user. Credentials never appear on a command line.
instance_cnf() {
  local name=$1 conf f host port user pass
  conf=$(koha_conf "$name")
  host=$(conf_get "$conf" hostname); port=$(conf_get "$conf" port)
  user=$(conf_get "$conf" user); pass=$(conf_get "$conf" pass)
  f="$(workdir)/$name.cnf"
  {
    echo '[client]'
    echo "host = $(cnf_quote "${host:-localhost}")"
    [ -n "$port" ] && echo "port = $port"
    echo "user = $(cnf_quote "$user")"
    echo "password = $(cnf_quote "$pass")"
  } > "$f"
  printf '%s' "$f"
}

sql() { # cnf db query
  mysql --defaults-extra-file="$1" -N -B -e "$3" "$2"
}

# "table count" lines for the key tables that exist, plus "_tables N" (how many tables the database has).
db_counts() {
  local cnf=$1 db=$2 existing t q=
  existing=$(sql "$cnf" "$db" "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE()")
  printf '_tables %s\n' "$(printf '%s\n' "$existing" | grep -c . || true)"
  for t in "${KEY_TABLES[@]}"; do
    if printf '%s\n' "$existing" | grep -qx "$t"; then
      q+="${q:+ UNION ALL }SELECT '$t', COUNT(*) FROM \`$t\`"
    fi
  done
  [ -n "$q" ] && sql "$cnf" "$db" "$q"
  return 0
}

# ── Archive names, manifest, checks ──────────────────────────────────────────────────────────────────────────────────

# <instance>-YYYY-MM-DDTHHMMSSZ.tar[.age]: the UTC time in the name sorts in date order.
is_archive_name() { [[ "$1" =~ ^.+-[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z\.tar(\.age)?$ ]]; }

# Complete archives (with their checksum file) of one directory, oldest first.
complete_archives() {
  local dir=$1 f
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.tar "$dir"/*.tar.age; do
    [ -f "$f" ] || continue
    is_archive_name "$(basename "$f")" || continue
    [ -f "$f.sha256" ] || continue
    basename "$f"
  done | sort
}

# Which archives fall outside the newest $keep. Prints nothing when there are $keep or fewer, so the last copy is
# never deleted, whatever the setting.
to_prune() {
  local keep=$1; shift
  local n=$# i=0 a
  (( keep >= 1 )) || die "refusing to keep fewer than 1 backup"
  (( n > keep )) || return 0
  for a in "$@"; do
    (( i < n - keep )) && printf '%s\n' "$a"
    i=$((i + 1))
  done
}

prune_local() {
  local dir=$1 a
  local -a all
  mapfile -t all < <(complete_archives "$dir")
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    rm -f -- "$dir/$a" "$dir/$a.sha256"
    say "  removed old backup $a"
  done < <(to_prune "$KEEP" "${all[@]}")
}

verify_checksum() {
  local archive=$1 dir base
  dir=$(dirname "$archive"); base=$(basename "$archive")
  [ -f "$archive.sha256" ] || die "No checksum file next to $archive ($base.sha256). Without it the archive cannot be trusted."
  if ! (cd "$dir" && sha256sum --check --status -- "$base.sha256"); then
    die "Checksum does not match for $base: the file is damaged or incomplete. It will not be restored."
  fi
}

manifest_get() { grep -m1 "^$1=" "$2" | cut -d= -f2- || true; }

# Accept a restored count when it lies between the counts taken just before and just after the dump: a library that
# was issuing books while the backup ran can change a count by a few rows, and both ends are honest.
count_ok() {
  local before=$1 after=$2 got=$3 lo hi
  lo=$(( before < after ? before : after )); hi=$(( before > after ? before : after ))
  (( got >= lo && got <= hi ))
}

# Unpacks an archive into a fresh directory and checks the files inside against the manifest. Prints the directory.
unpack() {
  local archive=$1 identity=$2 out tarfile
  out=$(mktemp -d "$(workdir)/unpack.XXXXXX")
  tarfile=$archive
  if [[ "$archive" == *.age ]]; then
    need age "Install it to read encrypted backups (https://github.com/FiloSottile/age)."
    [ -n "$identity" ] || die "$(basename "$archive") is encrypted. Give the private key with --identity FILE (or AGE_IDENTITY in the config)."
    tarfile="$out/archive.tar"
    age --decrypt -i "$identity" -o "$tarfile" "$archive" || die "Could not decrypt $(basename "$archive") with $identity."
  fi
  tar -xf "$tarfile" -C "$out" || die "$(basename "$archive") is not a readable archive."
  [ "$tarfile" = "$out/archive.tar" ] && rm -f "$tarfile"
  [ -f "$out/manifest.txt" ] || die "$(basename "$archive") has no manifest.txt: not a koha-backup archive."
  [ "$(manifest_get format "$out/manifest.txt")" = "$FORMAT" ] || die "$(basename "$archive") was written by an unknown version of this tool."
  local name sql files
  name=$(manifest_get instance "$out/manifest.txt")
  sql="$out/$name.sql.gz"; files="$out/$name-files.tar.gz"
  [ "$(sha256sum "$sql" | cut -d' ' -f1)" = "$(manifest_get sql_sha256 "$out/manifest.txt")" ] || die "The database dump inside $(basename "$archive") is damaged."
  [ "$(sha256sum "$files" | cut -d' ' -f1)" = "$(manifest_get files_sha256 "$out/manifest.txt")" ] || die "The files inside $(basename "$archive") are damaged."
  printf '%s' "$out"
}

# Compare a database against the manifest. Prints one line per check; returns 1 if any failed.
compare_counts() {
  local manifest=$1 counts=$2 failed=0 t want got before after
  want=$(manifest_get tables "$manifest")
  got=$(awk '$1 == "_tables" { print $2 }' <<<"$counts")
  if [ "$want" = "$got" ]; then say "  ok    tables: $got"; else say "  FAIL  tables: $got, expected $want"; failed=1; fi
  while IFS= read -r line; do
    t=${line#count.}; t=${t%%=*}
    before=${line#*=}; after=${before#*:}; before=${before%%:*}
    got=$(awk -v t="$t" '$1 == t { print $2 }' <<<"$counts")
    if [ -z "$got" ]; then say "  FAIL  $t: table missing"; failed=1
    elif count_ok "$before" "$after" "$got"; then say "  ok    $t: $got rows"
    else say "  FAIL  $t: $got rows, expected $before$( [ "$before" != "$after" ] && printf '..%s' "$after")"; failed=1
    fi
  done < <(grep '^count\.' "$manifest")
  return "$failed"
}

# ── run ──────────────────────────────────────────────────────────────────────────────────────────────────────────────

target_instances() {
  if [ $# -gt 0 ]; then printf '%s\n' "$@"
  elif [ -n "$INSTANCES" ]; then tr -s ' ,' '\n' <<<"$INSTANCES" | grep .
  else koha-list --enabled
  fi
}

backup_instance() {
  local name=$1 conf db cnf ts dir stage marker='' spool='' before after f done_ok=no sqlf='' filesf='' base archive
  conf=$(koha_conf "$name")
  is_instance "$name" || { warn "$name is not a Koha instance on this server."; return 1; }
  db=$(conf_get "$conf" database)
  cnf=$(instance_cnf "$name")
  ts=$(date -u +%Y-%m-%dT%H%M%SZ)
  base="$name-$ts.tar"
  dir="$BACKUP_DIR/$name"
  mkdir -p "$dir"; chmod 700 "$dir"
  stage="$dir/.partial-$ts"
  mkdir -m 0700 "$stage"
  local -a preexisting=()
  # On the way out (failure or success) backup_cleanup tidies up; see there.
  trap backup_cleanup RETURN

  say "Backing up $name"
  local avail need_bytes
  need_bytes=$(sql "$cnf" "$db" "SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables WHERE table_schema = DATABASE()")
  avail=$(df -P -B1 "$dir" | awk 'NR == 2 { print $4 }')
  if (( avail < need_bytes / 4 )); then
    warn "only $((avail / 1048576)) MB free in $dir for a $((need_bytes / 1048576)) MB database; the backup may not fit."
  fi

  before=$(db_counts "$cnf" "$db")

  # koha-dump writes into the instance's own backup folder. Take what it writes there now and leave anything that
  # was already there (for example Koha's own nightly koha-run-backups file) where it was.
  spool=$(conf_get "$conf" backupdir); [ -n "$spool" ] || spool="/var/spool/koha/$name"
  marker="$stage/.started"; touch "$marker"
  # Not --quiet: koha-dump --quiet exits 1 even when it succeeds (its last line is `[ "$quiet" = "no" ] && echo`), so
  # its normal output is discarded instead. Errors still reach stderr.
  local -a opts=(--without-db-name --uploaded_files --exclude-indexes)
  mapfile -t preexisting < <(find "$spool" -maxdepth 1 -type f -name "$name-*" -printf '%f\n' 2>/dev/null)
  if [ "$INCLUDE_LOGS" = no ] && koha-dump --help 2>&1 | grep -q -- '--exclude-logs'; then opts+=(--exclude-logs); fi
  koha-dump "${opts[@]}" "$name" >/dev/null || { warn "koha-dump failed for $name."; return 1; }
  after=$(db_counts "$cnf" "$db")

  while IFS= read -r f; do
    case "$f" in
      "$name"-schema-*) continue ;;
      *.sql.gz) sqlf=$f ;;
      *.tar.gz) filesf=$f ;;
    esac
  done < <(find "$spool" -maxdepth 1 -type f -name "$name-*" -newer "$marker" -printf '%f\n')
  if [ -z "$sqlf" ] || [ -z "$filesf" ]; then warn "koha-dump did not leave a database dump and a files archive in $spool."; return 1; fi
  for f in "$sqlf" "$filesf"; do
    local dest="$stage/$name.sql.gz"; [ "$f" = "$filesf" ] && dest="$stage/$name-files.tar.gz"
    if printf '%s\n' "${preexisting[@]}" | grep -qx -- "$f"; then cp -- "$spool/$f" "$dest"; else mv -- "$spool/$f" "$dest"; fi
  done

  # koha-dump pipes mysqldump into gzip and never checks mysqldump's status, so a failed dump still says "Done." and
  # leaves a few-byte file. mysqldump's last line on success is "-- Dump completed": no line, no backup.
  if ! gzip -t "$stage/$name.sql.gz" 2>/dev/null || ! zcat "$stage/$name.sql.gz" | tail -n 1 | grep -q '^-- Dump completed'; then
    warn "the database dump of $name is incomplete (mysqldump failed; koha-dump does not notice). Check the database password in $conf and the free space."
    return 1
  fi
  {
    echo "format=$FORMAT"
    echo "tool_version=$VERSION"
    echo "instance=$name"
    echo "created=$ts"
    echo "host=$(hostname -f 2>/dev/null || hostname)"
    echo "database=$db"
    echo "koha_db_version=$(sql "$cnf" "$db" "SELECT value FROM systempreferences WHERE variable = 'Version'" 2>/dev/null || true)"
    echo "koha_package=$(dpkg-query -W -f '${Version}' koha-common 2>/dev/null || echo unknown)"
    echo "upload_path=$(conf_get "$conf" upload_path)"
    echo "pluginsdir=$(conf_get "$conf" pluginsdir)"
    echo "tables=$(awk '$1 == "_tables" { print $2 }' <<<"$after")"
    for t in "${KEY_TABLES[@]}"; do
      local b a
      b=$(awk -v t="$t" '$1 == t { print $2 }' <<<"$before"); a=$(awk -v t="$t" '$1 == t { print $2 }' <<<"$after")
      [ -n "$b" ] && [ -n "$a" ] && echo "count.$t=$b:$a"
    done
    echo "sql_sha256=$(sha256sum "$stage/$name.sql.gz" | cut -d' ' -f1)"
    echo "files_sha256=$(sha256sum "$stage/$name-files.tar.gz" | cut -d' ' -f1)"
  } > "$stage/manifest.txt"

  local pdir; pdir=$(conf_get "$conf" pluginsdir)
  if [ -n "$pdir" ] && [[ "$pdir" != /var/lib/koha/"$name"/* ]]; then
    warn "plugins folder $pdir is outside /var/lib/koha/$name, so koha-dump does not include it. Back it up separately."
  fi

  tar -cf "$stage/$base" -C "$stage" manifest.txt "$name.sql.gz" "$name-files.tar.gz"
  rm -f "$stage/manifest.txt" "$stage/$name.sql.gz" "$stage/$name-files.tar.gz"
  archive=$base
  if [ -n "$AGE_RECIPIENT" ]; then
    need age "Install it or remove AGE_RECIPIENT from the config."
    if [[ "$AGE_RECIPIENT" == /* ]]; then age --encrypt -R "$AGE_RECIPIENT" -o "$stage/$base.age" "$stage/$base"
    else age --encrypt -r "$AGE_RECIPIENT" -o "$stage/$base.age" "$stage/$base"; fi
    rm -f "$stage/$base"
    archive="$base.age"
  fi
  (cd "$stage" && sha256sum -- "$archive" > "$archive.sha256")
  mv -- "$stage/$archive" "$dir/$archive"
  mv -- "$stage/$archive.sha256" "$dir/$archive.sha256"
  say "  saved $dir/$archive ($(du -h "$dir/$archive" | cut -f1))"
  say "  rows: $(awk '$1 == "biblio" || $1 == "items" || $1 == "borrowers" { printf "%s %s  ", $1, $2 }' <<<"$after")"

  if [ -n "$REMOTE" ]; then
    push_remote "$name" "$dir" "$archive" || return 1
  fi
  done_ok=yes
  prune_local "$dir"
  return 0
}

# Runs when backup_instance returns (bash's dynamic scope gives it that function's locals). After a failure it removes
# the files koha-dump wrote in this run, but never one that was already in Koha's folder; then the staging folder.
backup_cleanup() {
  local f
  if [ "${done_ok:-no}" != yes ] && [ -f "${marker:-}" ]; then
    while IFS= read -r f; do
      printf '%s\n' "${preexisting[@]}" | grep -qx -- "$f" || rm -f -- "$spool/$f"
    done < <(find "$spool" -maxdepth 1 -type f -name "$name-*" -newer "$marker" -printf '%f\n' 2>/dev/null)
  fi
  rm -rf -- "$stage"
}

rclone_() { rclone --config "$RCLONE_CONFIG" "$@"; }

push_remote() {
  local name=$1 dir=$2 archive=$3 a dest
  need rclone "Install it (https://rclone.org/install/) or remove REMOTE from the config."
  [[ "$REMOTE" == :* ]] || check_private_file "$RCLONE_CONFIG"
  dest="${REMOTE%/}/$name"
  rclone_ copyto "$dir/$archive.sha256" "$dest/$archive.sha256" || { warn "could not copy to $dest."; return 1; }
  rclone_ copyto "$dir/$archive" "$dest/$archive" || { warn "could not copy to $dest."; return 1; }
  say "  copied to $dest"
  local -a all
  mapfile -t all < <(rclone_ lsf --files-only "$dest" 2>/dev/null | while IFS= read -r a; do
    is_archive_name "$a" && printf '%s\n' "$a"; done | sort)
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    rclone_ deletefile "$dest/$a" || { warn "could not remove old off-site copy $a"; continue; }
    rclone_ deletefile "$dest/$a.sha256" 2>/dev/null || true
    say "  removed old off-site copy $a"
  done < <(to_prune "$REMOTE_KEEP" "${all[@]}")
}

cmd_run() {
  need koha-dump "This server has no Koha packages (koha-common)."
  need xmlstarlet "It comes with koha-common; install it with: sudo apt install xmlstarlet"
  local name failed=0 total=0
  lock
  find "$BACKUP_DIR" -mindepth 2 -maxdepth 2 -type d -name '.partial-*' -exec rm -rf {} + 2>/dev/null || true
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    total=$((total + 1))
    # Each instance in its own subshell so one failure cannot stop the others. set -e is switched back on inside:
    # bash ignores it in a subshell that is part of an if or || test.
    local rc; set +e; ( set -e; backup_instance "$name" ); rc=$?; set -e
    if (( rc != 0 )); then failed=$((failed + 1)); warn "backup of $name FAILED."; fi
  done < <(target_instances "$@")
  (( total > 0 )) || die "No Koha instances to back up."
  if (( failed > 0 )); then
    say "$failed of $total backups failed."
    exit 1
  fi
  say "$total of $total backups done."
}

lock() {
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  exec 9>"$BACKUP_DIR/.lock"
  flock -n 9 || die "Another koha-backup is running (lock $BACKUP_DIR/.lock)."
}

# ── list ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

cmd_list() {
  local dir name a last any=no
  [ -d "$BACKUP_DIR" ] || die "No backups yet: $BACKUP_DIR does not exist."
  for dir in "$BACKUP_DIR"/*/; do
    [ -d "$dir" ] || continue
    name=$(basename "$dir")
    if [ $# -gt 0 ] && [ "$1" != "$name" ]; then continue; fi
    any=yes
    say "$name"
    while IFS= read -r a; do
      [ -n "$a" ] && printf '  %-48s %8s\n' "$a" "$(du -h "$dir$a" | cut -f1)"
    done < <(complete_archives "$dir" | sort -r)
    if [ -f "$dir/selftest.log" ]; then
      last=$(tail -n 1 "$dir/selftest.log"); say "  last self-test: $last"
    else
      say "  last self-test: never (run: koha-backup selftest $name)"
    fi
  done
  [ "$any" = yes ] || say "No backups in $BACKUP_DIR."
}

# ── selftest ─────────────────────────────────────────────────────────────────────────────────────────────────────────

newest_archive() { complete_archives "$BACKUP_DIR/$1" | tail -n 1; }

selftest_one() {
  local name=$1 identity=$2 a archive out manifest scratch result=PASS counts
  a=$(newest_archive "$name")
  [ -n "$a" ] || { warn "$name has no backups to test."; return 1; }
  archive="$BACKUP_DIR/$name/$a"
  say "Self-test of $name: $a"
  verify_checksum "$archive"
  say "  ok    checksum"
  if [[ "$archive" == *.age ]] && [ -z "$identity" ]; then
    say "  skip  restore: the backup is encrypted and no --identity was given (checksum only)"
    printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "CHECKSUM-ONLY" "$a" >> "$BACKUP_DIR/$name/selftest.log"
    return 0
  fi
  out=$(unpack "$archive" "$identity")
  manifest="$out/manifest.txt"
  say "  ok    archive opens; contents match their checksums"
  tar -tzf "$out/$name-files.tar.gz" >/dev/null || { say "  FAIL  files archive unreadable"; result=FAIL; }

  check_private_file "$MYSQL_ADMIN_CNF"
  scratch="koha_backup_selftest_$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  mysql --defaults-extra-file="$MYSQL_ADMIN_CNF" -e "CREATE DATABASE \`$scratch\`" \
    || die "Could not create a scratch database with $MYSQL_ADMIN_CNF (it needs a user that may CREATE and DROP databases)."
  # shellcheck disable=SC2064 # expand now: the scratch name is fixed
  trap "mysql --defaults-extra-file='$MYSQL_ADMIN_CNF' -e 'DROP DATABASE IF EXISTS \`$scratch\`' || true" RETURN
  if zcat "$out/$name.sql.gz" | mysql --defaults-extra-file="$MYSQL_ADMIN_CNF" "$scratch"; then
    say "  ok    database dump loads into a scratch database"
    counts=$(db_counts "$MYSQL_ADMIN_CNF" "$scratch")
    compare_counts "$manifest" "$counts" || result=FAIL
  else
    say "  FAIL  database dump does not load"; result=FAIL
  fi
  say "  $result"
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$result" "$a" >> "$BACKUP_DIR/$name/selftest.log"
  [ "$result" = PASS ]
}

cmd_selftest() {
  local identity=$AGE_IDENTITY name failed=0 total=0
  local -a names=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --identity) identity=${2:?--identity needs a file}; shift 2 ;;
      -*) die "Unknown option $1" ;;
      *) names+=("$1"); shift ;;
    esac
  done
  need mysql "Install the MariaDB/MySQL client."
  lock
  if [ ${#names[@]} -eq 0 ]; then
    local d; for d in "$BACKUP_DIR"/*/; do [ -d "$d" ] && names+=("$(basename "$d")"); done
  fi
  (( ${#names[@]} > 0 )) || die "No backups in $BACKUP_DIR to test."
  for name in "${names[@]}"; do
    total=$((total + 1))
    local rc; set +e; ( set -e; selftest_one "$name" "$identity" ); rc=$?; set -e
    (( rc == 0 )) || failed=$((failed + 1))
  done
  if (( failed > 0 )); then say "$failed of $total self-tests failed."; exit 1; fi
  say "$total of $total self-tests passed."
}

# Koha's own test (koha-functions.sh), run in a subshell so its helpers do not leak into this script.
plack_enabled() {
  [ -f /usr/share/koha/bin/koha-functions.sh ] || return 1
  # shellcheck disable=SC1091 # Koha's helper file, present wherever koha-common is installed
  (. /usr/share/koha/bin/koha-functions.sh && is_plack_enabled "$1") >/dev/null 2>&1
}

# ── restore ──────────────────────────────────────────────────────────────────────────────────────────────────────────

resolve_archive() {
  local arg=$1 a
  if [ -f "$arg" ]; then readlink -f -- "$arg"; return; fi
  if [ -d "$BACKUP_DIR/$arg" ]; then
    a=$(newest_archive "$arg"); [ -n "$a" ] || die "$arg has no backups."
    printf '%s' "$BACKUP_DIR/$arg/$a"; return
  fi
  for a in "$BACKUP_DIR"/*/"$arg"; do [ -f "$a" ] && { printf '%s' "$a"; return; }; done
  die "No backup called $arg (give a file, an archive name from 'koha-backup list', or an instance name for its newest)."
}

cmd_restore() {
  local src_arg='' target='' overwrite=no confirm='' identity=$AGE_IDENTITY reindex=yes
  while [ $# -gt 0 ]; do
    case "$1" in
      --to) target=${2:?--to needs an instance name}; shift 2 ;;
      --overwrite) overwrite=yes; shift ;;
      --confirm) confirm=${2:?--confirm needs the instance name}; shift 2 ;;
      --identity) identity=${2:?--identity needs a file}; shift 2 ;;
      --no-reindex) reindex=no; shift ;;
      -*) die "Unknown option $1" ;;
      *) [ -z "$src_arg" ] || die "Give one backup to restore."; src_arg=$1; shift ;;
    esac
  done
  [ -n "$src_arg" ] || die "Usage: koha-backup restore <backup> --to <instance> [--overwrite]"
  [ -n "$target" ] || die "Say where to restore with --to <instance>. Restore into a new test instance first."
  need koha-list "This server has no Koha packages (koha-common)."
  need xmlstarlet "It comes with koha-common."
  lock

  local archive out manifest src tconf tdb tcnf ntables
  archive=$(resolve_archive "$src_arg")
  say "Restoring $(basename "$archive") into $target"
  verify_checksum "$archive"
  say "  ok    checksum"
  out=$(unpack "$archive" "$identity")
  manifest="$out/manifest.txt"
  src=$(manifest_get instance "$manifest")

  if ! is_instance "$target"; then
    die "There is no Koha instance called $target. Create an empty one first:  sudo koha-create --create-db $target"
  fi
  tconf=$(koha_conf "$target"); tdb=$(conf_get "$tconf" database); tcnf=$(instance_cnf "$target")
  ntables=$(sql "$tcnf" "$tdb" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()")

  if [ "$target" = "$src" ] || (( ntables > 0 )); then
    [ "$overwrite" = yes ] || die "$target already has a database ($ntables tables)$( [ "$target" = "$src" ] && printf ', and it is the library this backup came from'). Restoring would replace all of it. Restore into a new instance instead, or add --overwrite if that is what you mean."
    if [ -z "$confirm" ]; then
      [ -t 0 ] || die "--overwrite needs a typed confirmation; when not at a terminal, add --confirm $target."
      printf 'This REPLACES every table in %s (%s tables) with the backup from %s.\nType the instance name to continue: ' "$target" "$ntables" "$(manifest_get created "$manifest")"
      read -r confirm
    fi
    [ "$confirm" = "$target" ] || die "Confirmation did not match '$target'. Nothing was changed."
  fi

  # 1. Database: empty the target, then load the dump.
  local drop
  drop=$(sql "$tcnf" "$tdb" "SELECT GROUP_CONCAT(CONCAT('\`', table_name, '\`')) FROM information_schema.tables WHERE table_schema = DATABASE()")
  if [ -n "$drop" ] && [ "$drop" != NULL ]; then
    sql "$tcnf" "$tdb" "SET FOREIGN_KEY_CHECKS = 0; DROP TABLE IF EXISTS $drop; SET FOREIGN_KEY_CHECKS = 1"
  fi
  { echo 'SET FOREIGN_KEY_CHECKS = 0;'; zcat "$out/$src.sql.gz"; echo 'SET FOREIGN_KEY_CHECKS = 1;'; } | mysql --defaults-extra-file="$tcnf" "$tdb" \
    || die "Loading the database into $target failed (see the message above). $target's database may now be incomplete: restore again."
  say "  ok    database loaded into $tdb"

  # 2. Files Koha keeps outside the database: uploads and plugins. The target keeps its own koha-conf.xml.
  local files="$out/files"; mkdir -p "$files"
  tar -xzf "$out/$src-files.tar.gz" -C "$files"
  local kind from to
  for kind in upload_path pluginsdir; do
    from=$(manifest_get "$kind" "$manifest"); to=$(conf_get "$tconf" "$kind")
    if [ -z "$from" ] || [ -z "$to" ] || [ ! -d "$files/${from#/}" ]; then continue; fi
    mkdir -p "$to"
    cp -a "$files/${from#/}/." "$to/"
    chown -R "$target-koha:$target-koha" "$to" 2>/dev/null || true
    say "  ok    $kind copied to $to"
  done
  local skey tkey
  skey=$(conf_get "$files/etc/koha/sites/$src/koha-conf.xml" encryption_key); tkey=$(conf_get "$tconf" encryption_key)
  if [ -n "$skey" ] && [ "$skey" != "$tkey" ]; then
    warn "$target has a different <encryption_key> from $src. Data Koha encrypts with it (for example two-factor"
    warn "authentication secrets) will not open on $target. If $target is to replace $src, copy $src's key into"
    warn "$tconf; the original file is inside the backup at etc/koha/sites/$src/koha-conf.xml."
  fi

  # 3. Search index and caches.
  if [ "$reindex" = yes ]; then
    local engine; engine=$(sql "$tcnf" "$tdb" "SELECT value FROM systempreferences WHERE variable = 'SearchEngine'" 2>/dev/null || true)
    if [ "$engine" = Elasticsearch ]; then
      if koha-elasticsearch --rebuild "$target" >/dev/null; then say "  ok    Elasticsearch index rebuilt"
      else warn "Elasticsearch rebuild failed; run: sudo koha-elasticsearch --rebuild $target"; fi
    else
      if koha-rebuild-zebra --full "$target" >/dev/null 2>&1; then say "  ok    Zebra search index rebuilt"
      else warn "Zebra rebuild failed; run: sudo koha-rebuild-zebra --full -v $target"; fi
    fi
  fi
  # Restart Plack if this instance uses it (koha-functions.sh's own test), so it does not serve cached old data.
  if command -v koha-plack >/dev/null && plack_enabled "$target"; then
    if koha-plack --restart "$target" >/dev/null 2>&1; then say "  ok    Plack restarted"
    else warn "Plack restart failed; run: sudo koha-plack --restart $target"; fi
  fi
  if [ -f /usr/share/koha/bin/clear_cache.pl ]; then koha-shell -c 'perl /usr/share/koha/bin/clear_cache.pl' "$target" >/dev/null 2>&1 || true; fi

  # 4. Check what arrived.
  local counts; counts=$(db_counts "$tcnf" "$tdb")
  if compare_counts "$manifest" "$counts"; then
    say "Restored. $target now holds the data of $src as it was at $(manifest_get created "$manifest")."
  else
    die "The restored database does not match the backup's record (see FAIL lines)."
  fi
  say "Backup's Koha database version: $(manifest_get koha_db_version "$manifest"). If $target runs a newer Koha, open its staff interface: Koha will offer to update the database."
}

# ── install / uninstall ──────────────────────────────────────────────────────────────────────────────────────────────

unit_files() { # time selftest
  local time=$1 selftest=$2 cal
  cat <<EOF
### koha-backup.service
[Unit]
Description=Back up Koha instances (koha-backup)
After=network-online.target mariadb.service mysql.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_BIN run
Nice=10
IOSchedulingClass=idle

### koha-backup.timer
[Unit]
Description=Daily Koha backup at $time

[Timer]
OnCalendar=*-*-* $time:00
Persistent=true
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
EOF
  [ "$selftest" = off ] && return 0
  case "$selftest" in weekly) cal="Sun *-*-* 04:00:00" ;; *) cal="*-*-01 04:00:00" ;; esac
  cat <<EOF
### koha-backup-selftest.service
[Unit]
Description=Restore the newest Koha backup into a scratch database and check it (koha-backup)
After=koha-backup.service mariadb.service mysql.service

[Service]
Type=oneshot
ExecStart=$INSTALL_BIN selftest
Nice=10
IOSchedulingClass=idle

### koha-backup-selftest.timer
[Unit]
Description=$selftest self-test of the newest Koha backup

[Timer]
OnCalendar=$cal
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

cmd_units() { unit_files "${1:-02:30}" "${2:-monthly}"; }

cmd_install() {
  local keep=$KEEP time=02:30 selftest=monthly
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep) keep=${2:?}; shift 2 ;;
      --time) time=${2:?}; shift 2 ;;
      --selftest) selftest=${2:?}; shift 2 ;;
      *) die "Unknown option $1" ;;
    esac
  done
  [[ "$keep" =~ ^[1-9][0-9]*$ ]] || die "--keep must be 1 or more."
  [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "--time must be HH:MM (24-hour), e.g. 02:30."
  case "$selftest" in monthly|weekly|off) ;; *) die "--selftest must be monthly, weekly or off." ;; esac
  need systemctl "This server does not use systemd; run 'koha-backup run' from cron instead (see the README)."

  install -m 0755 "$(readlink -f "$0")" "$INSTALL_BIN"
  mkdir -p "$(dirname "$DEFAULT_CONF")"; chmod 700 "$(dirname "$DEFAULT_CONF")"
  if [ -f "$DEFAULT_CONF" ]; then
    sed -i "s/^KEEP=.*/KEEP=$keep/" "$DEFAULT_CONF"
    say "Kept your settings in $DEFAULT_CONF (KEEP set to $keep)."
  else
    cat > "$DEFAULT_CONF" <<EOF
# koha-backup settings. KEY=value; this file is read as text, never run. Keep it mode 600.
BACKUP_DIR=$BACKUP_DIR
KEEP=$keep
# Instances to back up, separated by spaces. Empty: every enabled instance (koha-list --enabled).
INSTANCES=
# Off-site copy with rclone, e.g. REMOTE=r2:library-backups/koha (credentials in RCLONE_CONFIG, mode 600).
REMOTE=
REMOTE_KEEP=
RCLONE_CONFIG=$RCLONE_CONFIG
# Encrypt each archive to this age public key (age1...) or recipients file. Keep the private key OFF this server.
AGE_RECIPIENT=
# Private key for the self-test and restore of encrypted backups (optional; see the README before setting it).
AGE_IDENTITY=
INCLUDE_LOGS=no
# A MySQL user that may create and drop a scratch database, for the self-test.
MYSQL_ADMIN_CNF=$MYSQL_ADMIN_CNF
EOF
    chmod 600 "$DEFAULT_CONF"
    say "Wrote $DEFAULT_CONF"
  fi
  local unit='' line
  while IFS= read -r line; do
    if [[ "$line" == '### '* ]]; then unit="$UNIT_DIR/${line#'### '}"; : > "$unit"; chmod 644 "$unit"; continue; fi
    printf '%s\n' "$line" >> "$unit"
  done < <(unit_files "$time" "$selftest")
  [ "$selftest" = off ] && rm -f "$UNIT_DIR/koha-backup-selftest.service" "$UNIT_DIR/koha-backup-selftest.timer"
  systemctl daemon-reload
  systemctl enable --now koha-backup.timer >/dev/null
  [ "$selftest" != off ] && systemctl enable --now koha-backup-selftest.timer >/dev/null
  say "Installed. Backups run daily at $time and keep the newest $keep; self-test: $selftest."
  say "Run one now:   sudo koha-backup run"
  say "Logs:          journalctl -u koha-backup"
  systemctl list-timers 'koha-backup*' --no-pager || true
}

cmd_uninstall() {
  need systemctl "systemd is not in use."
  systemctl disable --now koha-backup.timer koha-backup-selftest.timer >/dev/null 2>&1 || true
  rm -f "$UNIT_DIR"/koha-backup.service "$UNIT_DIR"/koha-backup.timer "$UNIT_DIR"/koha-backup-selftest.service "$UNIT_DIR"/koha-backup-selftest.timer
  systemctl daemon-reload
  rm -f "$INSTALL_BIN"
  say "Timers removed. Your settings ($DEFAULT_CONF) and backups ($BACKUP_DIR) were left in place."
}

usage() {
  cat <<EOF
koha-backup $VERSION: backups of Koha instances, and a restore you have actually tried.

Usage: koha-backup [--config FILE] COMMAND [options]

  run [INSTANCE...]                 back up now (default: INSTANCES from the config, else every enabled instance)
  list [INSTANCE]                   backups on disk, newest first, and the last self-test result
  selftest [INSTANCE...] [--identity FILE]
                                    restore the newest backup into a scratch database, compare row counts, drop it
  restore BACKUP --to INSTANCE [--overwrite] [--confirm INSTANCE] [--identity FILE] [--no-reindex]
                                    BACKUP is a file, an archive name, or an instance name (its newest backup)
  install [--keep N] [--time HH:MM] [--selftest monthly|weekly|off]
                                    install to $INSTALL_BIN with a daily systemd timer
  uninstall                         remove the timers (backups and settings are kept)
  units [HH:MM] [monthly|weekly|off]  print the systemd units install would write
  version

Settings: $DEFAULT_CONF (KEY=value, mode 600). https://github.com/kohasolutions/koha-backup
EOF
}

main() {
  local conf=${KOHA_BACKUP_CONF:-$DEFAULT_CONF} explicit=no
  [ -n "${KOHA_BACKUP_CONF:-}" ] && explicit=yes
  if [ "${1:-}" = --config ]; then conf=${2:?--config needs a file}; explicit=yes; shift 2; fi
  local cmd=${1:-help}; shift || true
  case "$cmd" in
    help|-h|--help) usage; return 0 ;;
    version|--version) say "koha-backup $VERSION"; return 0 ;;
    units) cmd_units "$@"; return 0 ;;
  esac
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/koha-backup.XXXXXX")
  trap cleanup EXIT   # set here, not at the top: sourcing the file (the unit tests) must not take over EXIT
  [ "$(id -u)" = 0 ] || die "Run as root (sudo): koha-backup reads every instance's database password."
  load_config "$conf" "$explicit"
  validate_config
  case "$cmd" in
    run) cmd_run "$@" ;;
    list) cmd_list "$@" ;;
    selftest) cmd_selftest "$@" ;;
    restore) cmd_restore "$@" ;;
    install) cmd_install "$@" ;;
    uninstall) cmd_uninstall ;;
    *) usage >&2; die "Unknown command '$cmd'." ;;
  esac
}

# Sourcing the file (the unit tests do) loads the functions without running anything.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
