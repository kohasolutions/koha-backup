#!/usr/bin/env bash
# Downloads the pinned test tools into tests/.cache (not committed): bats for the unit tests, age and rclone for the
# live test. Checksums pinned so a changed download fails loudly.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .cache && cd .cache
fetch() { # url sha256 file
  [ -f "$3" ] && echo "$2  $3" | sha256sum -c --status && return 0
  curl -fsSL -o "$3" "$1"
  echo "$2  $3" | sha256sum -c - >/dev/null || { echo "checksum mismatch for $1" >&2; rm -f "$3"; exit 1; }
}
fetch https://github.com/bats-core/bats-core/archive/refs/tags/v1.11.1.tar.gz 5c57ed9616b78f7fd8c553b9bae3c7c9870119edd727ec17dbd1185c599f79d9 bats.tar.gz
fetch https://github.com/FiloSottile/age/releases/download/v1.2.1/age-v1.2.1-linux-amd64.tar.gz 7df45a6cc87d4da11cc03a539a7470c15b1041ab2b396af088fe9990f7c79d50 age.tar.gz
fetch https://downloads.rclone.org/v1.68.2/rclone-v1.68.2-linux-amd64.zip 0e6fa18051e67fc600d803a2dcb10ddedb092247fc6eee61be97f64ec080a13c rclone.zip
[ -x bats-core-1.11.1/bin/bats ] || tar -xzf bats.tar.gz
[ -x age/age ] || tar -xzf age.tar.gz
[ -x rclone ] || { python3 -c "import zipfile; z = zipfile.ZipFile('rclone.zip'); open('rclone', 'wb').write(z.read('rclone-v1.68.2-linux-amd64/rclone'))"; chmod +x rclone; }
echo "tools ready in tests/.cache"
