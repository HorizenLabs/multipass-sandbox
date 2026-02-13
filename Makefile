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

# Architecture (default: host)
ARCH ?=
HOST_ARCH := $(shell uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

# Docker run for lint/test (uses linter image — no QEMU needed)
DOCKER_RUN := docker run --rm \
	-v "$(CURDIR):$(WORKDIR)" \
	-e HOST_UID=$(HOST_UID) \
	-e HOST_GID=$(HOST_GID) \
	$(LINTER_IMAGE):$(LINTER_TAG)

# Docker run for image builds (uses builder image, with conditional KVM)
# Always pass /dev/kvm if available — arch-config.sh decides KVM vs TCG per-arch
KVM_FLAG := $(shell [ -e /dev/kvm ] && echo "--device /dev/kvm")

DOCKER_RUN_IMAGE := docker run --rm \
	-v "$(CURDIR):$(WORKDIR)" \
	-e HOST_UID=$(HOST_UID) \
	-e HOST_GID=$(HOST_GID) \
	-e TARGET_ARCH=$(ARCH) \
	$(KVM_FLAG) \
	$(BUILDER_IMAGE):$(BUILDER_TAG)

# ---------- File sets ----------
BASH_SCRIPTS := $(shell find bin/ lib/ commands/ images/ -name '*.sh' -o -name 'mps' 2>/dev/null | grep -v '.ps1') install.sh
PS_SCRIPTS   := $(shell find . -name '*.ps1' 2>/dev/null)
YAML_FILES   := $(shell find templates/ -name '*.yaml' 2>/dev/null)
HCL_FILES    := $(shell find images/ -name '*.pkr.hcl' 2>/dev/null)
DOCKERFILES  := Dockerfile.builder Dockerfile.linter

BUILDER_STAMP := .stamp-builder
BUILDER_DEPS  := Dockerfile.builder docker/entrypoint.sh

LINTER_STAMP := .stamp-linter
LINTER_DEPS  := Dockerfile.linter docker/entrypoint.sh

.PHONY: all help builder linter install test lint lint-bash lint-powershell lint-dockerfile lint-makefile lint-yaml lint-hcl image-base import-base publish-base clean

# ---------- All ----------
all: lint ## Run all linters (alias)

# ---------- Help ----------
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-24s\033[0m %s\n", $$1, $$2}'

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
		checkmake Makefile || true'

lint-yaml: $(LINTER_STAMP) ## Lint YAML files with yamllint
	@if [ -n "$(YAML_FILES)" ]; then \
		$(DOCKER_RUN) bash -c '\
			exit_code=0; \
			for f in $(YAML_FILES); do \
				echo "yamllint: $$f"; \
				if ! yamllint -d relaxed "$$f"; then \
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
image-base: $(BUILDER_STAMP) ## Build base VM image (both archs, or ARCH=amd64|arm64)
	$(DOCKER_RUN_IMAGE) bash -c 'cd images/base && bash build.sh'

# ---------- Image import (local) ----------
import-base: image-base ## Import host-arch base image into mps cache
	@arch=$$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/'); \
	./bin/mps image import images/base/output-base/mps-base-$$arch.qcow2 --name base --tag local

# ---------- Image publishing (Backblaze B2) ----------
# Usage: make publish-base VERSION=1.0.0
publish-base: ## Publish base image to Backblaze B2 (requires VERSION=x.y.z)
	@test -n "$(VERSION)" || (echo "ERROR: VERSION is required (e.g., make publish-base VERSION=1.0.0)"; exit 1)
	$(DOCKER_RUN) bash -c '\
		for arch in amd64 arm64; do \
			echo "Publishing $$arch..."; \
			TARGET_ARCH=$$arch bash images/publish.sh base $(VERSION) images/base/output-base/mps-base-$$arch.qcow2; \
		done'

# ---------- Clean ----------
clean: ## Remove build artifacts and caches
	@echo "Cleaning..."
	@rm -rf build/ dist/ .stamp-*
	@echo "Done."
