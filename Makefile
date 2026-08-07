.PHONY: lint test integration

POSTGRES_VERSION ?= 18
TEST_DATA_PARENT ?= /tmp

lint:
	@for file in src/*.sh tests/*.sh; do bash -n "$$file"; done
	@shellcheck src/*.sh tests/*.sh

test:
	@bash tests/unit.sh

integration:
	@POSTGRES_VERSION=$(POSTGRES_VERSION) TEST_DATA_PARENT=$(TEST_DATA_PARENT) bash tests/integration.sh
