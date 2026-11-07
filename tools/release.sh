#!/usr/bin/env bash
# Publishes a release: refuses unless the live test of this exact commit passed, then tags it and attaches the run
# log as test-run-v<version>.txt (the proof kohasolutions.com links to).
#   bash tools/release.sh 1.0.0
set -euo pipefail
cd "$(dirname "$0")/.."
V=${1:?usage: tools/release.sh <version>}
TAG="v$V"
[ -z "$(git status --porcelain)" ] || { echo "Commit everything first."; exit 1; }
grep -q "^readonly VERSION=$V\$" koha-backup.sh || { echo "koha-backup.sh says a different VERSION."; exit 1; }
[ -f test-run.txt ] || { echo "No test-run.txt: run make test-live first."; exit 1; }
grep -q ' 0 failed ' test-run.txt || { echo "test-run.txt does not show a passing run."; exit 1; }
[ test-run.txt -nt koha-backup.sh ] || { echo "koha-backup.sh changed after the live test: run make test-live again."; exit 1; }
grep -q "koha-backup $V" test-run.txt || { echo "test-run.txt is from another version."; exit 1; }
grep -q "^## $V " CHANGELOG.md || { echo "CHANGELOG.md has no '## $V' entry."; exit 1; }
cp test-run.txt "/tmp/test-run-$TAG.txt"
notes=$(awk -v v="## $V " 'index($0, v) == 1 { on = 1; next } /^## / && on { exit } on' CHANGELOG.md)
git tag -a "$TAG" -m "koha-backup $V"
git push origin main "$TAG"
gh release create "$TAG" "koha-backup.sh" "/tmp/test-run-$TAG.txt" --title "koha-backup $V" --notes "$notes"
echo "Released $TAG"
