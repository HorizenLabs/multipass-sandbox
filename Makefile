# Multi Pass Sandbox (mps) — Makefile
# All build, test, and lint commands run inside Docker containers
# for reproducibility between local dev and CI/CD.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# ---------- Docker builder config ----------
BUILDER_IMAGE  := mps-builder
BUILDER_TAG    := latest
LINTER_IMAGE   := mps-linter
LINTER_TAG     := latest
HOST_UID       := $(shell id -u)
HOST_GID       := $(shell id -g)
WORKDIR        := /workdir

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
BASH_SCRIPTS := $(shell find bin/ lib/ commands/ images/ -name '*.sh' -o -name 'mps' 2>/dev/null | grep -v '.ps1') install.sh
PS_SCRIPTS   := $(shell find . -name '*.ps1' 2>/dev/null)
YAML_FILES   := $(shell find templates/ images/layers/ -name '*.yaml' 2>/dev/null)
HCL_FILES    := $(shell find images/ -name '*.pkr.hcl' 2>/dev/null)
DOCKERFILES  := Dockerfile.builder Dockerfile.linter

BUILDER_STAMP := .stamp-builder
BUILDER_DEPS  := Dockerfile.builder docker/entrypoint.sh

LINTER_STAMP := .stamp-linter
LINTER_DEPS  := Dockerfile.linter docker/entrypoint.sh

# Image build dependencies — shared across all flavors
IMAGE_LAYERS      := $(wildcard images/layers/*.yaml)
IMAGE_SHARED_DEPS := images/packer.pkr.hcl images/packer-user-data.pkrtpl.hcl images/build.sh $(IMAGE_LAYERS)

# Image flavors
FLAVORS := base protocol-dev smart-contract-dev smart-contract-audit

.PHONY: all help builder linter install test lint lint-bash lint-powershell lint-dockerfile lint-makefile lint-yaml lint-hcl \
	image-base image-base-amd64 image-base-arm64 \
	image-protocol-dev image-protocol-dev-amd64 image-protocol-dev-arm64 \
	image-smart-contract-dev image-smart-contract-dev-amd64 image-smart-contract-dev-arm64 \
	image-smart-contract-audit image-smart-contract-audit-amd64 image-smart-contract-audit-arm64 \
	import-base import-protocol-dev import-smart-contract-dev import-smart-contract-audit \
	publish-base publish-protocol-dev publish-smart-contract-dev publish-smart-contract-audit \
	clean clean-builder clean-linter clean-images \
	clean-image-base clean-image-protocol-dev clean-image-smart-contract-dev clean-image-smart-contract-audit

# ---------- All ----------
all: lint ## Run all linters (alias)

# ---------- Help ----------
help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-34s\033[0m %s\n", $$1, $$2}'

# ---------- Builder image ----------
builder: $(BUILDER_STAMP) ## Build the mps-builder Docker image

$(BUILDER_STAMP): $(BUILDER_DEPS)
	docker build --progress plain -f Dockerfile.builder -t $(BUILDER_IMAGE):$(BUILDER_TAG) .
	@touch $@

# ---------- Linter image ----------
linter: $(LINTER_STAMP) ## Build the mps-linter Docker image

$(LINTER_STAMP): $(LINTER_DEPS)
	docker build --progress plain -f Dockerfile.linter -t $(LINTER_IMAGE):$(LINTER_TAG) .
	@touch $@

# ---------- Install (runs on host) ----------
install: ## Install mps (symlink to PATH, runs on host)
	@chmod +x bin/mps install.sh
	@./install.sh

# ---------- Test ----------
test: $(LINTER_STAMP) ## Run BATS tests inside linter container
	$(DOCKER_RUN) bats tests/

# ---------- Lint (all) ----------
lint: lint-bash lint-powershell lint-dockerfile lint-makefile lint-yaml lint-hcl ## Run all linters

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

# ---------- Image builds ----------
# Each flavor builds both archs in parallel via sub-make

image-base: ## Build base VM image (both archs in parallel)
	+$(MAKE) image-base-amd64 image-base-arm64 -j2

image-protocol-dev: ## Build protocol-dev VM image (both archs in parallel)
	+$(MAKE) image-protocol-dev-amd64 image-protocol-dev-arm64 -j2

image-smart-contract-dev: ## Build smart-contract-dev VM image (both archs in parallel)
	+$(MAKE) image-smart-contract-dev-amd64 image-smart-contract-dev-arm64 -j2

image-smart-contract-audit: ## Build smart-contract-audit VM image (both archs in parallel)
	+$(MAKE) image-smart-contract-audit-amd64 image-smart-contract-audit-arm64 -j2

# Per-flavor, per-arch stamp targets
# base
image-base-amd64: .stamp-image-base-amd64 ## Build base VM image (amd64)

.stamp-image-base-amd64: $(BUILDER_STAMP) $(IMAGE_SHARED_DEPS)
	$(call docker_run_image,amd64) bash -c 'cd images && bash build.sh base'
	@touch $@

image-base-arm64: .stamp-image-base-arm64 ## Build base VM image (arm64)

.stamp-image-base-arm64: $(BUILDER_STAMP) $(IMAGE_SHARED_DEPS)
	$(call docker_run_image,arm64) bash -c 'cd images && bash build.sh base'
	@touch $@

# protocol-dev
image-protocol-dev-amd64: .stamp-image-protocol-dev-amd64 ## Build protocol-dev VM image (amd64)

.stamp-image-protocol-dev-amd64: $(BUILDER_STAMP) $(IMAGE_SHARED_DEPS)
	$(call docker_run_image,amd64) bash -c 'cd images && bash build.sh protocol-dev'
	@touch $@

image-protocol-dev-arm64: .stamp-image-protocol-dev-arm64 ## Build protocol-dev VM image (arm64)

.stamp-image-protocol-dev-arm64: $(BUILDER_STAMP) $(IMAGE_SHARED_DEPS)
	$(call docker_run_image,arm64) bash -c 'cd images && bash build.sh protocol-dev'
	@touch $@

# smart-contract-dev
image-smart-contract-dev-amd64: .stamp-image-smart-contract-dev-amd64 ## Build smart-contract-dev VM image (amd64)

.stamp-image-smart-contract-dev-amd64: $(BUILDER_STAMP) $(IMAGE_SHARED_DEPS)
	$(call docker_run_image,amd64) bash -c 'cd images && bash build.sh smart-contract-dev'
	@touch $@

image-smart-contract-dev-arm64: .stamp-image-smart-contract-dev-arm64 ## Build smart-contract-dev VM image (arm64)

.stamp-image-smart-contract-dev-arm64: $(BUILDER_STAMP) $(IMAGE_SHARED_DEPS)
	$(call docker_run_image,arm64) bash -c 'cd images && bash build.sh smart-contract-dev'
	@touch $@

# smart-contract-audit
image-smart-contract-audit-amd64: .stamp-image-smart-contract-audit-amd64 ## Build smart-contract-audit VM image (amd64)

.stamp-image-smart-contract-audit-amd64: $(BUILDER_STAMP) $(IMAGE_SHARED_DEPS)
	$(call docker_run_image,amd64) bash -c 'cd images && bash build.sh smart-contract-audit'
	@touch $@

image-smart-contract-audit-arm64: .stamp-image-smart-contract-audit-arm64 ## Build smart-contract-audit VM image (arm64)

.stamp-image-smart-contract-audit-arm64: $(BUILDER_STAMP) $(IMAGE_SHARED_DEPS)
	$(call docker_run_image,arm64) bash -c 'cd images && bash build.sh smart-contract-audit'
	@touch $@

# ---------- Image import (local) ----------
import-base: image-base ## Import host-arch base image into mps cache
	@arch=$$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/'); \
	./bin/mps image import images/artifacts/mps-base-$$arch.qcow2.img --name base --tag local

import-protocol-dev: image-protocol-dev ## Import host-arch protocol-dev image into mps cache
	@arch=$$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/'); \
	./bin/mps image import images/artifacts/mps-protocol-dev-$$arch.qcow2.img --name protocol-dev --tag local

import-smart-contract-dev: image-smart-contract-dev ## Import host-arch smart-contract-dev image into mps cache
	@arch=$$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/'); \
	./bin/mps image import images/artifacts/mps-smart-contract-dev-$$arch.qcow2.img --name smart-contract-dev --tag local

import-smart-contract-audit: image-smart-contract-audit ## Import host-arch smart-contract-audit image into mps cache
	@arch=$$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/'); \
	./bin/mps image import images/artifacts/mps-smart-contract-audit-$$arch.qcow2.img --name smart-contract-audit --tag local

# ---------- Image publishing (Backblaze B2) ----------
# Usage: make publish-base VERSION=1.0.0
publish-base: ## Publish base image to Backblaze B2 (requires VERSION=x.y.z)
	@test -n "$(VERSION)" || (echo "ERROR: VERSION is required (e.g., make publish-base VERSION=1.0.0)"; exit 1)
	$(DOCKER_RUN) bash -c '\
		for arch in amd64 arm64; do \
			echo "Publishing $$arch..."; \
			TARGET_ARCH=$$arch bash images/publish.sh base $(VERSION) images/artifacts/mps-base-$$arch.qcow2.img; \
		done'

publish-protocol-dev: ## Publish protocol-dev image to B2 (requires VERSION=x.y.z)
	@test -n "$(VERSION)" || (echo "ERROR: VERSION is required"; exit 1)
	$(DOCKER_RUN) bash -c '\
		for arch in amd64 arm64; do \
			echo "Publishing $$arch..."; \
			TARGET_ARCH=$$arch bash images/publish.sh protocol-dev $(VERSION) images/artifacts/mps-protocol-dev-$$arch.qcow2.img; \
		done'

publish-smart-contract-dev: ## Publish smart-contract-dev image to B2 (requires VERSION=x.y.z)
	@test -n "$(VERSION)" || (echo "ERROR: VERSION is required"; exit 1)
	$(DOCKER_RUN) bash -c '\
		for arch in amd64 arm64; do \
			echo "Publishing $$arch..."; \
			TARGET_ARCH=$$arch bash images/publish.sh smart-contract-dev $(VERSION) images/artifacts/mps-smart-contract-dev-$$arch.qcow2.img; \
		done'

publish-smart-contract-audit: ## Publish smart-contract-audit image to B2 (requires VERSION=x.y.z)
	@test -n "$(VERSION)" || (echo "ERROR: VERSION is required"; exit 1)
	$(DOCKER_RUN) bash -c '\
		for arch in amd64 arm64; do \
			echo "Publishing $$arch..."; \
			TARGET_ARCH=$$arch bash images/publish.sh smart-contract-audit $(VERSION) images/artifacts/mps-smart-contract-audit-$$arch.qcow2.img; \
		done'

# ---------- Clean ----------
clean-builder: ## Remove mps-builder Docker image
	@echo "Removing $(BUILDER_IMAGE):$(BUILDER_TAG) image..."
	@docker rmi $(BUILDER_IMAGE):$(BUILDER_TAG) 2>/dev/null || true
	@rm -f $(BUILDER_STAMP)

clean-linter: ## Remove mps-linter Docker image
	@echo "Removing $(LINTER_IMAGE):$(LINTER_TAG) image..."
	@docker rmi $(LINTER_IMAGE):$(LINTER_TAG) 2>/dev/null || true
	@rm -f $(LINTER_STAMP)

clean-image-base: ## Remove base image artifacts
	@echo "Removing base image artifacts..."
	@rm -f images/artifacts/mps-base-*
	@rm -f .stamp-image-base-*

clean-image-protocol-dev: ## Remove protocol-dev image artifacts
	@echo "Removing protocol-dev image artifacts..."
	@rm -f images/artifacts/mps-protocol-dev-*
	@rm -f .stamp-image-protocol-dev-*

clean-image-smart-contract-dev: ## Remove smart-contract-dev image artifacts
	@echo "Removing smart-contract-dev image artifacts..."
	@rm -f images/artifacts/mps-smart-contract-dev-*
	@rm -f .stamp-image-smart-contract-dev-*

clean-image-smart-contract-audit: ## Remove smart-contract-audit image artifacts
	@echo "Removing smart-contract-audit image artifacts..."
	@rm -f images/artifacts/mps-smart-contract-audit-*
	@rm -f .stamp-image-smart-contract-audit-*

clean-images: clean-image-base clean-image-protocol-dev clean-image-smart-contract-dev clean-image-smart-contract-audit ## Remove all built VM images
	@rm -f images/cloud-init.yaml

clean: clean-builder clean-linter clean-images ## Remove all build artifacts, images, and Docker containers
	@rm -rf build/ dist/
