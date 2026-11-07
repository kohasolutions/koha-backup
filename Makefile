# make lint        shellcheck (Docker)
# make test-unit   bats unit tests (Docker, as root in a throwaway Debian container)
# make test-live   the live round trip against a koha-testing-docker Koha; writes TESTED.md and test-run.txt
# make release V=1.0.0   tag and publish, attaching test-run.txt as test-run-v1.0.0.txt (tools/release.sh)
.PHONY: lint test-unit test-live release
lint:
	docker run --rm -v "$(CURDIR):/mnt:ro" koalaman/shellcheck:v0.10.0 /mnt/koha-backup.sh /mnt/tests/live.sh /mnt/tests/fetch-tools.sh /mnt/tools/release.sh
test-unit:
	bash tests/fetch-tools.sh
	docker run --rm -v "$(CURDIR):/src:ro" debian:trixie bash -c 'cp -r /src /w && /w/tests/.cache/bats-core-1.11.1/bin/bats /w/tests/unit.bats'
test-live:
	bash tests/live.sh
release:
	bash tools/release.sh $(V)
