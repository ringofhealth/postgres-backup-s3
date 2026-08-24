.PHONY: lint test integration pgbackrest-build

POSTGRES_VERSION ?= 18
TEST_DATA_PARENT ?= /tmp

lint:
	@for file in src/*.sh tests/*.sh; do bash -n "$$file"; done
	@shellcheck src/*.sh tests/*.sh

test:
	@bash tests/unit.sh
	@bash tests/pgbackrest_unit.sh

integration:
	@POSTGRES_VERSION=$(POSTGRES_VERSION) TEST_DATA_PARENT=$(TEST_DATA_PARENT) bash tests/integration.sh

PGBACKREST_BASE_IMAGE ?= timescale/timescaledb-ha:pg18.4-ts2.28.3

pgbackrest-build:
	@docker build --target pgbackrest \
		--build-arg PGBACKREST_BASE_IMAGE=$(PGBACKREST_BASE_IMAGE) \
		--tag postgres-backup-s3:pgbackrest-local .
