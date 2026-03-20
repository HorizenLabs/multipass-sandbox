# Multi Pass Sandbox (mps) — Makefile
# All build, test, and lint commands run inside Docker containers
# for reproducibility between local dev and CI/CD.

SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c
.DEFAULT_GOAL := help

# ---------- Docker builder config ----------
BUILDER_IMAGE  := mps-builder
BUILDER_TAG    := latest
LINTER_IMAGE   := mps-linter
LINTER_TAG     := latest
PUBLISHER_IMAGE := mps-publisher
PUBLISHER_TAG   := latest
HOST_UID       := $(shell id -u)
HOST_GID       := $(shell id -g)
WORKDIR        := /workdir

# ---------- Coverage config ----------
COVERAGE_DIR    := coverage

# Docker run for lint/test (uses linter image — no QEMU needed)
DOCKER_RUN := docker run --rm \
	-v "$(CURDIR):$(WORKDIR)" \
	-e HOST_UID=$(HOST_UID) \
	-e HOST_GID=$(HOST_GID) \
	$(LINTER_IMAGE):$(LINTER_TAG)

# Docker run for image builds (uses builder image, with conditional KVM)
# Always pass /dev/kvm if available — arch-config.sh decides KVM vs TCG per-arch
KVM_FLAG := $(shell [ -e /dev/kvm ] && echo "--device /dev/kvm")

# Callable macro: $(call docker_run_image,<arch>)
define docker_run_image
docker run --rm \
	-v "$(CURDIR):$(WORKDIR)" \
	-e HOST_UID=$(HOST_UID) \
	-e HOST_GID=$(HOST_GID) \
	-e TARGET_ARCH=$(1) \
	$(KVM_FLAG) \
	$(BUILDER_IMAGE):$(BUILDER_TAG)
endef

# ---------- File sets ----------
BASH_SCRIPTS    := $(shell find bin/ lib/ commands/ images/ completions/ tests/ .github/scripts/ -type f \( -name '*.sh' -o -name '*.bash' -o -name '*.bats' -o -name 'mps' -o -name 'multipass' \) 2>/dev/null | grep -v '.ps1') install.sh uninstall.sh
CLIENT_SCRIPTS  := $(shell find bin/ lib/ commands/ completions/ tests/ -type f \( -name '*.sh' -o -name '*.bash' -o -name 'mps' -o -name 'multipass' \) 2>/dev/null | grep -v '.ps1' | grep -v 'tests/coverage-') install.sh uninstall.sh
PS_SCRIPTS      := $(shell find . -name '*.ps1' 2>/dev/null)
YAML_FILES      := $(shell find templates/ images/layers/ .github/ISSUE_TEMPLATE/ -name '*.yaml' -o -name '*.yml' 2>/dev/null)
HCL_FILES       := $(shell find images/ -name '*.pkr.hcl' 2>/dev/null)
GHA_FILES       := $(shell find .github/workflows/ -name '*.yml' -o -name '*.yaml' 2>/dev/null)
DOCKERFILES     := docker/Dockerfile.builder docker/Dockerfile.linter docker/Dockerfile.publisher docker/Dockerfile.bash32

STAMP_DIR := .stamps

BUILDER_STAMP := $(STAMP_DIR)/builder
BUILDER_DEPS  := docker/Dockerfile.builder docker/entrypoint.sh

LINTER_STAMP := $(STAMP_DIR)/linter
LINTER_DEPS  := docker/Dockerfile.linter docker/entrypoint.sh docker/lint-bash32-compat.sh $(wildcard docker/bash-3.2/*)

PUBLISHER_STAMP := $(STAMP_DIR)/publisher
PUBLISHER_DEPS  := docker/Dockerfile.publisher docker/entrypoint.sh

# Common deps shared by all image builds
IMAGE_COMMON_DEPS := images/packer.pkr.hcl images/packer-user-data.pkrtpl.hcl \
    images/build.sh images/arch-config.sh images/scripts/post-provision.sh

# Per-flavor layer deps (each flavor depends only on its own layer file)
IMAGE_LAYERS_base                  := images/layers/base.yaml
IMAGE_LAYERS_protocol-dev          := images/layers/protocol-dev.yaml
IMAGE_LAYERS_smart-contract-dev    := images/layers/smart-contract-dev.yaml
IMAGE_LAYERS_smart-contract-audit  := images/layers/smart-contract-audit.yaml

# Image flavors
FLAVORS := base protocol-dev smart-contract-dev smart-contract-audit

ARCHS := amd64 arm64

# Parent flavor for chained builds (base has no parent)
PARENT_protocol-dev          := base
PARENT_smart-contract-dev    := protocol-dev
PARENT_smart-contract-audit  := smart-contract-dev

# Cumulative layers for from-scratch builds (arm64 — no layered chain)
CUMULATIVE_LAYERS_base                  := $(IMAGE_LAYERS_base)
CUMULATIVE_LAYERS_protocol-dev          := $(IMAGE_LAYERS_base) $(IMAGE_LAYERS_protocol-dev)
CUMULATIVE_LAYERS_smart-contract-dev    := $(IMAGE_LAYERS_base) $(IMAGE_LAYERS_protocol-dev) $(IMAGE_LAYERS_smart-contract-dev)
CUMULATIVE_LAYERS_smart-contract-audit  := $(IMAGE_LAYERS_base) $(IMAGE_LAYERS_protocol-dev) $(IMAGE_LAYERS_smart-contract-dev) $(IMAGE_LAYERS_smart-contract-audit)

# Generated .PHONY lists
IMAGE_PHONY       := $(foreach f,$(FLAVORS),image-$(f) $(foreach a,$(ARCHS),image-$(f)-$(a)))
IMPORT_PHONY      := $(foreach f,$(FLAVORS),import-$(f))
UPLOAD_PHONY      := $(foreach f,$(FLAVORS),$(foreach a,$(ARCHS),upload-$(f)-$(a)))
PUBLISH_PHONY     := $(foreach f,$(FLAVORS),publish-$(f) $(foreach a,$(ARCHS),publish-$(f)-$(a)))
CLEAN_IMAGE_PHONY := $(foreach f,$(FLAVORS),clean-image-$(f) $(foreach a,$(ARCHS),clean-image-$(f)-$(a)))

.PHONY: all help install uninstall test clean capture-fixtures \
	test-unit test-unit-bash4 test-unit-bash32 \
	test-integration test-integration-bash4 test-integration-bash32 \
	test-coverage-unit test-coverage-integration test-coverage-report \
	test-e2e test-e2e-report \
	build-docker-builder build-docker-linter build-docker-publisher build-bash32 \
	lint lint-bash lint-bash32 lint-powershell lint-dockerfile lint-makefile lint-yaml lint-hcl lint-actions \
	clean-docker-builder clean-docker-linter clean-docker-publisher clean-images \
	update-manifest publish-release-meta \
	$(IMAGE_PHONY) $(IMPORT_PHONY) $(UPLOAD_PHONY) $(PUBLISH_PHONY) $(CLEAN_IMAGE_PHONY)

# ---------- All ----------
all: $(foreach f,$(FLAVORS),image-$(f)) ## Build all VM image flavors

# ---------- Help ----------
help: ## Show this help
	@echo ""
	@echo "Image targets:"
	@echo "  Flavors: $(FLAVORS)"
	@echo "  Archs:   $(ARCHS)"
	@echo ""
	@echo "  make image-FLAVOR[-ARCH]                  Build VM image (both archs or one)"
	@echo "  make import-FLAVOR                        Import host-arch image into mps cache"
	@echo "  make upload-FLAVOR-ARCH VERSION=x         CI: upload to B2 (no manifest)"
	@echo "  make update-manifest VERSION=x            CI: fan-in manifest update"
	@echo "  make publish-FLAVOR[-ARCH] VERSION=x      Local: upload + manifest"
	@echo "  make clean-image-FLAVOR[-ARCH]            Remove build artifacts"
	@echo ""
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-34s\033[0m %s\n", $$1, $$2}'

# ---------- Docker images ----------
build-docker-builder: $(BUILDER_STAMP) ## Build the mps-builder Docker image

$(BUILDER_STAMP): $(BUILDER_DEPS) | $(STAMP_DIR)
	docker build --progress plain -f docker/Dockerfile.builder -t $(BUILDER_IMAGE):$(BUILDER_TAG) .
	@touch $@

build-docker-linter: $(LINTER_STAMP) ## Build the mps-linter Docker image

$(LINTER_STAMP): $(LINTER_DEPS) | $(STAMP_DIR)
	docker build --progress plain -f docker/Dockerfile.linter -t $(LINTER_IMAGE):$(LINTER_TAG) .
	@touch $@

build-docker-publisher: $(PUBLISHER_STAMP) ## Build the mps-publisher Docker image

$(PUBLISHER_STAMP): $(PUBLISHER_DEPS) | $(STAMP_DIR)
	docker build --progress plain -f docker/Dockerfile.publisher -t $(PUBLISHER_IMAGE):$(PUBLISHER_TAG) .
	@touch $@

# ---------- Bash 3.2 binary (for compat lint) ----------
BASH32_IMAGE := bash-3.2-build
BASH32_ARCH  := $(shell dpkg --print-architecture 2>/dev/null || echo amd64)
BASH32_BIN   := docker/bash-3.2/bash-3.2.57-linux-$(BASH32_ARCH)

build-bash32: $(BASH32_BIN) ## Build Bash 3.2.57 binary for compat linting

$(BASH32_BIN): docker/Dockerfile.bash32
	docker build --progress plain -f docker/Dockerfile.bash32 -t $(BASH32_IMAGE) .
	@mkdir -p docker/bash-3.2
	@cid=$$(docker create $(BASH32_IMAGE)) && docker cp "$$cid":/bash-3.2 $@ && docker rm "$$cid" >/dev/null
	@chmod +x $@

# ---------- Install (runs on host) ----------
install: ## Install mps (symlink to PATH, runs on host)
	@chmod +x bin/mps install.sh
	@./install.sh

uninstall: ## Uninstall mps (remove symlink, cleanup artifacts, runs on host)
	@chmod +x uninstall.sh
	@./uninstall.sh

# ---------- Test ----------
test: $(LINTER_STAMP) ## Run all tests with coverage (Bash 4+ instrumented + Bash 3.2 compat)
	@rm -rf $(COVERAGE_DIR)
	+$(MAKE) test-coverage-unit test-coverage-integration test-unit-bash32 test-integration-bash32 -j4 --output-sync=target
	+$(MAKE) test-coverage-report

test-unit: $(LINTER_STAMP) ## Run unit tests only
	+$(MAKE) test-unit-bash4 test-unit-bash32 -j2 --output-sync=target

test-integration: $(LINTER_STAMP) ## Run integration tests only
	+$(MAKE) test-integration-bash4 test-integration-bash32 -j2 --output-sync=target

test-unit-bash4: $(LINTER_STAMP)
	@echo "==> Unit tests (Bash 4+)"
	$(DOCKER_RUN) bats tests/unit/ | tests/tap-summary.sh

test-unit-bash32: $(LINTER_STAMP)
	@echo "==> Unit tests (Bash 3.2)"
	$(DOCKER_RUN) bash -c '\
		mkdir -p /tmp/bash32-shim && \
		ln -sf /usr/local/bin/bash-3.2 /tmp/bash32-shim/bash && \
		PATH="/tmp/bash32-shim:$$PATH" bats tests/unit/' | tests/tap-summary.sh

test-integration-bash4: $(LINTER_STAMP)
	@echo "==> Integration tests (Bash 4+)"
	$(DOCKER_RUN) bats tests/integration/ | tests/tap-summary.sh

test-integration-bash32: $(LINTER_STAMP)
	@echo "==> Integration tests (Bash 3.2)"
	$(DOCKER_RUN) bash -c '\
		mkdir -p /tmp/bash32-shim && \
		ln -sf /usr/local/bin/bash-3.2 /tmp/bash32-shim/bash && \
		PATH="/tmp/bash32-shim:$$PATH" bats tests/integration/' | tests/tap-summary.sh

capture-fixtures: ## Capture fresh multipass JSON fixtures (requires multipass on host)
	bash tests/capture-fixtures.sh

# ---------- Test coverage helpers (xtrace + grep, Bash 4+ only) ----------
test-coverage-unit: $(LINTER_STAMP)
	@echo "==> Coverage: Unit tests (Bash 4+)"
	$(DOCKER_RUN) bash -c '\
		export _MPS_COV_DIR=$(COVERAGE_DIR)/unit && \
		export BASH_ENV=/workdir/tests/coverage-trap.sh && \
		bats tests/unit/' | tests/tap-summary.sh

test-coverage-integration: $(LINTER_STAMP)
	@echo "==> Coverage: Integration tests (Bash 4+)"
	$(DOCKER_RUN) bash -c '\
		export _MPS_COV_DIR=$(COVERAGE_DIR)/integration && \
		export BASH_ENV=/workdir/tests/coverage-trap.sh && \
		bats tests/integration/' | tests/tap-summary.sh

test-coverage-report:
	$(DOCKER_RUN) bash tests/coverage-report.sh $(COVERAGE_DIR) $(COVERAGE_DIR)/unit $(COVERAGE_DIR)/integration

# ---------- E2E tests (host-native, requires multipass + KVM) ----------
test-e2e: ## Run e2e tests with coverage (requires multipass on host)
	rm -rf $(COVERAGE_DIR)/e2e
	_MPS_COV_DIR=$(CURDIR)/$(COVERAGE_DIR)/e2e \
	_MPS_COV_PREFIX=$(CURDIR) \
	BASH_ENV=$(CURDIR)/tests/coverage-trap.sh \
	bash tests/e2e.sh

test-e2e-report: ## Merge e2e coverage with unit/integration
	_MPS_COV_PREFIX=$(CURDIR) \
	bash tests/coverage-report.sh $(COVERAGE_DIR) $(COVERAGE_DIR)/unit $(COVERAGE_DIR)/integration $(COVERAGE_DIR)/e2e

# ---------- Lint (all) ----------
lint: lint-bash lint-bash32 lint-powershell lint-dockerfile lint-makefile lint-yaml lint-hcl lint-actions ## Run all linters

lint-bash: $(LINTER_STAMP) ## Lint Bash scripts with shellcheck
	$(DOCKER_RUN) bash -c '\
		exit_code=0; \
		for f in $(BASH_SCRIPTS); do \
			echo "shellcheck: $$f"; \
			if ! shellcheck -x -S warning "$$f"; then \
				exit_code=1; \
			fi; \
		done; \
		exit $$exit_code'

lint-bash32: $(LINTER_STAMP) ## Check client scripts for Bash 3.2 compatibility
	$(DOCKER_RUN) bash -c '\
		if command -v lint-bash32-compat.sh >/dev/null 2>&1; then \
			lint-bash32-compat.sh $(CLIENT_SCRIPTS); \
		else \
			echo "WARN: lint-bash32-compat.sh not found, skipping"; \
		fi'

lint-powershell: $(LINTER_STAMP) ## Lint PowerShell scripts with py-psscriptanalyzer
	@if [ -n "$(PS_SCRIPTS)" ]; then \
		$(DOCKER_RUN) bash -c '\
			exit_code=0; \
			for f in $(PS_SCRIPTS); do \
				echo "py-psscriptanalyzer: $$f"; \
				if ! py-psscriptanalyzer "$$f"; then \
					exit_code=1; \
				fi; \
			done; \
			exit $$exit_code'; \
	else \
		echo "No PowerShell scripts found, skipping."; \
	fi

lint-dockerfile: $(LINTER_STAMP) ## Lint Dockerfiles with hadolint
	$(DOCKER_RUN) bash -c '\
		exit_code=0; \
		for f in $(DOCKERFILES); do \
			echo "hadolint: $$f"; \
			if ! hadolint "$$f"; then \
				exit_code=1; \
			fi; \
		done; \
		exit $$exit_code'

lint-makefile: $(LINTER_STAMP) ## Lint Makefile with checkmake
	$(DOCKER_RUN) bash -c '\
		echo "checkmake: Makefile"; \
		checkmake --config checkmake.ini Makefile'

lint-yaml: $(LINTER_STAMP) ## Lint YAML files with yamllint
	@if [ -n "$(YAML_FILES)" ]; then \
		$(DOCKER_RUN) bash -c '\
			exit_code=0; \
			for f in $(YAML_FILES); do \
				echo "yamllint: $$f"; \
				if ! yamllint "$$f"; then \
					exit_code=1; \
				fi; \
			done; \
			exit $$exit_code'; \
	else \
		echo "No YAML files found, skipping."; \
	fi

lint-hcl: $(LINTER_STAMP) ## Lint HCL/Packer files with packer fmt
	@if [ -n "$(HCL_FILES)" ]; then \
		$(DOCKER_RUN) bash -c '\
			exit_code=0; \
			for f in $(HCL_FILES); do \
				echo "packer fmt -check: $$f"; \
				if ! packer fmt -check "$$f"; then \
					echo "  FAIL: $$f needs formatting (run: packer fmt $$f)"; \
					exit_code=1; \
				fi; \
			done; \
			exit $$exit_code'; \
	else \
		echo "No HCL files found, skipping."; \
	fi

lint-actions: $(LINTER_STAMP) ## Lint GitHub Actions workflows with actionlint
	@if [ -n "$(GHA_FILES)" ]; then \
		$(DOCKER_RUN) bash -c '\
			echo "actionlint: $(GHA_FILES)"; \
			actionlint $(GHA_FILES)'; \
	else \
		echo "No GitHub Actions workflow files found, skipping."; \
	fi

# ---------- Image builds ----------
# Templates generate per-flavor, per-arch stamp rules, phony wrappers,
# and both-arch parallel targets.  Adding a new flavor only requires
# entries in FLAVORS, PARENT_*, and IMAGE_LAYERS_*.

# $(STAMP_DIR)/image-<flavor>-<arch>  (the real build rule)
# $(1) = flavor, $(2) = arch
#
# amd64: layered chain — each flavor depends on its parent stamp and uses
#   --base-image to apply only the delta layer on top.
# arm64: from-scratch — no layered chain because arm64 CI runners lack KVM,
#   forcing TCG emulation (~1h per build).  Parallel from-scratch jobs are
#   faster than a serial 4-flavor chain.  Depends on CUMULATIVE_LAYERS
#   (all ancestor layers merged by build.sh) with no parent stamp dep.
define image_stamp_rule
$$(STAMP_DIR)/image-$(1)-$(2): $$(BUILDER_STAMP) $$(IMAGE_COMMON_DEPS) \
        $(if $(filter amd64,$(2)),$$(IMAGE_LAYERS_$(1)),$$(CUMULATIVE_LAYERS_$(1))) \
        $(if $(and $(PARENT_$(1)),$(filter amd64,$(2))),$$(STAMP_DIR)/image-$(PARENT_$(1))-$(2)) | $$(STAMP_DIR)
	$$(call docker_run_image,$(2)) bash -c \
	    'cd images && bash build.sh $(if $(and $(PARENT_$(1)),$(filter amd64,$(2))),--base-image artifacts/mps-$(PARENT_$(1))-$(2).qcow2.img )$(1)'
	@touch $$@
endef
$(foreach f,$(FLAVORS),$(foreach a,$(ARCHS),$(eval $(call image_stamp_rule,$(f),$(a)))))

# image-<flavor>-<arch> → stamp dependency
define image_arch_rule
image-$(1)-$(2): $$(STAMP_DIR)/image-$(1)-$(2)
endef
$(foreach f,$(FLAVORS),$(foreach a,$(ARCHS),$(eval $(call image_arch_rule,$(f),$(a)))))

# image-<flavor> → both archs in parallel
define image_both_rule
image-$(1):
	+$$(MAKE) $(foreach a,$(ARCHS),image-$(1)-$(a)) -j2
endef
$(foreach f,$(FLAVORS),$(eval $(call image_both_rule,$(f))))

# ---------- Image import (local) ----------
define import_rule
import-$(1): image-$(1)
	@arch=$$$$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/'); \
	./bin/mps image import images/artifacts/mps-$(1)-$$$$arch.qcow2.img --name $(1) --tag local
endef
$(foreach f,$(FLAVORS),$(eval $(call import_rule,$(f))))

# ---------- Image publishing (Backblaze B2) ----------
# Runs in the publisher image (no Packer/QEMU) for credential isolation.
# B2 credentials are passed from the host environment (value-less -e).
#
# CI flow (fan-in):
#   1. Runners:  make upload-<flavor>-<arch> VERSION=x  (parallel, image+sidecar only)
#   2. Fan-in:   make update-manifest VERSION=x          (single manifest write)
#
# Local flow (all-in-one):
#   make publish-<flavor>-<arch> VERSION=x   (single arch: upload + manifest)
#   make publish-<flavor> VERSION=x           (both archs: upload + manifest)

# Docker run macro for publisher container
define docker_run_publisher
docker run --rm \
	-v "$(CURDIR):$(WORKDIR)" \
	-e HOST_UID=$(HOST_UID) \
	-e HOST_GID=$(HOST_GID) \
	-e B2_APPLICATION_KEY_ID \
	-e B2_APPLICATION_KEY \
	-e CF_ZONE_ID \
	-e CF_API_TOKEN \
	$(PUBLISHER_IMAGE):$(PUBLISHER_TAG)
endef

# Shared credential validation
define check_publish_env
@test -n "$(VERSION)" || (echo "ERROR: VERSION is required (e.g., VERSION=1.0.0)"; exit 1)
@test -n "$(B2_APPLICATION_KEY_ID)" || (echo "ERROR: B2_APPLICATION_KEY_ID not set (export it or pass inline)"; exit 1)
@test -n "$(B2_APPLICATION_KEY)" || (echo "ERROR: B2_APPLICATION_KEY not set (export it or pass inline)"; exit 1)
endef

# upload-<flavor>-<arch>  (CI: image + sidecar only, no manifest)
# $(1) = flavor, $(2) = arch
define upload_arch_rule
upload-$(1)-$(2): $$(PUBLISHER_STAMP)
	$$(check_publish_env)
	$$(docker_run_publisher) \
		bash -c 'TARGET_ARCH=$(2) bash images/publish.sh --upload-only $(1) $$(VERSION) \
		    images/artifacts/mps-$(1)-$(2).qcow2.img'
endef
$(foreach f,$(FLAVORS),$(foreach a,$(ARCHS),$(eval $(call upload_arch_rule,$(f),$(a)))))

# update-manifest  (CI fan-in: single manifest read-modify-write)
update-manifest: $(PUBLISHER_STAMP)
	$(check_publish_env)
	$(docker_run_publisher) \
		bash images/update-manifest.sh $(VERSION)

# publish-<flavor>-<arch>  (local: upload + manifest in one shot)
# $(1) = flavor, $(2) = arch
define publish_arch_rule
publish-$(1)-$(2): $$(PUBLISHER_STAMP)
	$$(check_publish_env)
	$$(docker_run_publisher) \
		bash -c 'TARGET_ARCH=$(2) bash images/publish.sh $(1) $$(VERSION) \
		    images/artifacts/mps-$(1)-$(2).qcow2.img'
endef
$(foreach f,$(FLAVORS),$(foreach a,$(ARCHS),$(eval $(call publish_arch_rule,$(f),$(a)))))

# publish-<flavor>  (local: both archs)
define publish_both_rule
publish-$(1): $(foreach a,$(ARCHS),publish-$(1)-$(a))
endef
$(foreach f,$(FLAVORS),$(eval $(call publish_both_rule,$(f))))

# ---------- CLI release metadata ----------
# Publishes mps-release.json to B2 so clients can check for newer CLI versions.
# Resolves commit SHA on the host (git not available in publisher container).
publish-release-meta: $(PUBLISHER_STAMP)
	$(check_publish_env)
	@COMMIT_SHA=$$(git rev-parse "mps/v$(VERSION)^0" 2>/dev/null || echo ""); \
	if [ -z "$$COMMIT_SHA" ]; then \
		echo "ERROR: Tag mps/v$(VERSION) not found. Tag the release first."; exit 1; \
	fi; \
	echo "Resolved commit SHA: $$COMMIT_SHA"; \
	$(docker_run_publisher) \
		bash images/publish-release-meta.sh $(VERSION) "$$COMMIT_SHA"

# ---------- Clean ----------
# ---------- Stamp directory ----------
$(STAMP_DIR):
	@mkdir -p $@

clean-docker-builder: ## Remove mps-builder Docker image
	@echo "Removing $(BUILDER_IMAGE):$(BUILDER_TAG) image..."
	@docker rmi $(BUILDER_IMAGE):$(BUILDER_TAG) 2>/dev/null || true
	@rm -f $(BUILDER_STAMP)

clean-docker-linter: ## Remove mps-linter Docker image
	@echo "Removing $(LINTER_IMAGE):$(LINTER_TAG) image..."
	@docker rmi $(LINTER_IMAGE):$(LINTER_TAG) 2>/dev/null || true
	@rm -f $(LINTER_STAMP)

clean-docker-publisher: ## Remove mps-publisher Docker image
	@echo "Removing $(PUBLISHER_IMAGE):$(PUBLISHER_TAG) image..."
	@docker rmi $(PUBLISHER_IMAGE):$(PUBLISHER_TAG) 2>/dev/null || true
	@rm -f $(PUBLISHER_STAMP)

# clean-image-<flavor> (both archs)
define clean_flavor_rule
clean-image-$(1):
	@echo "Removing $(1) image artifacts..."
	@rm -f images/artifacts/mps-$(1)-*
	@rm -f $$(STAMP_DIR)/image-$(1)-*
endef
$(foreach f,$(FLAVORS),$(eval $(call clean_flavor_rule,$(f))))

# clean-image-<flavor>-<arch> (single arch)
define clean_flavor_arch_rule
clean-image-$(1)-$(2):
	@echo "Removing $(1) $(2) image artifacts..."
	@rm -f images/artifacts/mps-$(1)-$(2).qcow2.img
	@rm -f images/artifacts/mps-$(1)-$(2).qcow2.img.sha256
	@rm -f $$(STAMP_DIR)/image-$(1)-$(2)
endef
$(foreach f,$(FLAVORS),$(foreach a,$(ARCHS),$(eval $(call clean_flavor_arch_rule,$(f),$(a)))))

clean-images: $(foreach f,$(FLAVORS),clean-image-$(f)) ## Remove all built VM images
	@rm -f images/cloud-init.yaml

clean: clean-docker-builder clean-docker-linter clean-docker-publisher clean-images ## Remove all build artifacts, images, and Docker containers
	@rm -rf build/ dist/ $(COVERAGE_DIR)
