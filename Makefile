# Local entry points for the scripts in scripts/ (CI calls the scripts directly).
# Works with the GNU make 3.81 that ships with macOS.
#
#   make build                                   # 8.0 noble-chiseled-extra for this machine's arch
#   make build VERSION=10.0 VARIANT=noble        # another chain
#   make build-all SCAN=0                        # every chain in images.json, no Trivy

VERSION ?= 8.0
VARIANT ?= noble-chiseled-extra
ARCH    ?= $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')
IMAGE   ?= aspnet
SCAN    ?= 1
PREFIX  ?= docker.io/quantifisol/dotnet-

BUILDS      := $(shell jq -r '.builds[] | "\(.version)/\(.variant)"' images.json)
SCAN_FLAG   := $(if $(filter 0,$(SCAN)),--no-scan,)
LOCAL_IMAGE := local/dotnet/$(IMAGE):$(VERSION)-$(VARIANT)-$(ARCH)
FETCHED     := upstream/.fetched

.DEFAULT_GOAL := help
.PHONY: help fetch check plan build build-all info latest images clean clean-images

help: ## Show this help
	@echo "Usage: make <target> [VERSION=$(VERSION)] [VARIANT=$(VARIANT)] [ARCH=$(ARCH)] [IMAGE=$(IMAGE)] [SCAN=$(SCAN)]"
	@echo
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN { FS = ":.*## " } { printf "  %-13s %s\n", $$1, $$2 }'
	@echo
	@echo "Builds in images.json: $(BUILDS)"

# Re-fetch only when the pinned revision or the patches change.
$(FETCHED): upstream.env $(wildcard patches/*.patch)
	scripts/fetch-upstream.sh
	@touch $@

fetch: ## Force a fresh upstream checkout + patches
	scripts/fetch-upstream.sh
	@touch $(FETCHED)

check: ## Lint: patch/overlay expiry, script syntax, images.json
	scripts/check-expiry.sh
	@for f in scripts/*.sh; do bash -n $$f || exit 1; done
	@jq empty images.json
	@if command -v shellcheck >/dev/null; then shellcheck scripts/*.sh; else echo "shellcheck not installed, skipped"; fi
	@echo "check OK"

plan: $(FETCHED) ## Dry-run every chain in images.json (no docker needed)
	@for b in $(BUILDS); do \
	    scripts/build-chain.sh --version $${b%%/*} --variant $${b#*/} --arch $(ARCH) --dry-run || exit 1; \
	done

build: $(FETCHED) ## Build, smoke-test and scan one chain (VERSION, VARIANT, ARCH)
	scripts/build-chain.sh --version $(VERSION) --variant $(VARIANT) --arch $(ARCH) $(SCAN_FLAG)

build-all: $(FETCHED) ## Build every chain in images.json for ARCH (keeps going, summarises failures)
	@failed=""; \
	for b in $(BUILDS); do \
	    scripts/build-chain.sh --version $${b%%/*} --variant $${b#*/} --arch $(ARCH) $(SCAN_FLAG) || failed="$$failed $$b"; \
	done; \
	echo; \
	if [ -n "$$failed" ]; then echo "FAILED:$$failed"; exit 1; else echo "All chains OK: $(BUILDS)"; fi

info: ## Run `dotnet --info` in a built image (IMAGE=runtime|aspnet|sdk)
	docker run --rm --platform linux/$(ARCH) --entrypoint /usr/bin/dotnet $(LOCAL_IMAGE) --info

latest: ## Show which build a published tag points at (IMAGE, VERSION, VARIANT, PREFIX)
	@scripts/show-build.sh $(PREFIX)$(IMAGE):$(VERSION)-$(VARIANT)

images: ## List locally built images
	@docker image ls --filter 'reference=local/dotnet/*'

clean: ## Remove the upstream checkout and build output
	rm -rf upstream out

clean-images: ## Remove locally built images
	@ids="$$(docker image ls -q --filter 'reference=local/dotnet/*' | sort -u)"; \
	if [ -n "$$ids" ]; then docker image rm -f $$ids; else echo "no local/dotnet images"; fi
