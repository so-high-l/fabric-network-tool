CONFIG ?= examples/carbon-kind.yaml
CHAINCODE_IMAGE ?=
DELETE_CONFIRM ?=

.PHONY: validate plan render test security-check kind-up kind-deploy verify kind-down

validate:
	./fabricctl.sh validate --file "$(CONFIG)"

plan:
	./fabricctl.sh plan --file "$(CONFIG)"

render:
	./fabricctl.sh render --file "$(CONFIG)" --to 10

test:
	./tests/test-fabricctl.sh

security-check:
	./tests/security-check.sh

kind-up:
	./local-kind/setup.sh --file "$(CONFIG)"

kind-deploy:
	@if [ -n "$(CHAINCODE_IMAGE)" ]; then \
		./local-kind/deploy.sh --file "$(CONFIG)" --chaincode-image "$(CHAINCODE_IMAGE)"; \
	else \
		./local-kind/deploy.sh --file "$(CONFIG)"; \
	fi

verify:
	./local-kind/verify.sh --file "$(CONFIG)"

kind-down:
	@test -n "$(DELETE_CONFIRM)" || { echo 'Set DELETE_CONFIRM=<network>:<kind-context>:DELETE'; exit 2; }
	./local-kind/destroy.sh --file "$(CONFIG)" --confirm "$(DELETE_CONFIRM)"
