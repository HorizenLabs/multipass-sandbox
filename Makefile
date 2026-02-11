# Multi Pass Sandbox (mps) — Makefile
# All build, test, and lint commands run inside the builder Docker container
# for reproducibility between local dev and CI/CD.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# ---------- Docker builder config ----------
BUILDER_IMAGE  := mps-builder
BUILDER_TAG    := latest
HOST_UID       := $(shell id -u)
HOST_GID       := $(shell id -g)
WORKDIR        := /workdir

DOCKER_RUN := docker run --rm \
	-v "$(CURDIR):$(WORKDIR)" \
	-e HOST_UID=$(HOST_UID) \
	-e HOST_GID=$(HOST_GID) \
	$(BUILDER_IMAGE):$(BUILDER_TAG)

# ---------- File sets ----------
BASH_SCRIPTS := $(shell find bin/ lib/ commands/ images/ -name '*.sh' -o -name 'mps' 2>/dev/null | grep -v '.ps1') install.sh
PS_SCRIPTS   := $(shell find . -name '*.ps1' 2>/dev/null)
YAML_FILES   := $(shell find templates/ -name '*.yaml' 2>/dev/null)
HCL_FILES    := $(shell find images/ -name '*.pkr.hcl' 2>/dev/null)
DOCKERFILES  := Dockerfile.builder

.PHONY: help builder install test lint lint-bash lint-powershell lint-dockerfile lint-makefile lint-yaml lint-hcl image-base image-blockchain publish-base publish-blockchain clean

# ---------- Help ----------
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-24s\033[0m %s\n", $$1, $$2}'

# ---------- Builder image ----------
builder: ## Build the mps-builder Docker image
	docker build -f Dockerfile.builder -t $(BUILDER_IMAGE):$(BUILDER_TAG) .

# ---------- Install (runs on host) ----------
install: ## Install mps (symlink to PATH, runs on host)
	@chmod +x bin/mps install.sh
	@./install.sh

# ---------- Test ----------
test: ## Run BATS tests inside builder container
	$(DOCKER_RUN) bats tests/

# ---------- Lint (all) ----------
lint: lint-bash lint-powershell lint-dockerfile lint-makefile lint-yaml lint-hcl ## Run all linters

lint-bash: ## Lint Bash scripts with shellcheck
	$(DOCKER_RUN) bash -c '\
		exit_code=0; \
		for f in $(BASH_SCRIPTS); do \
			echo "shellcheck: $$f"; \
			if ! shellcheck -x -S warning "$$f"; then \
				exit_code=1; \
			fi; \
		done; \
		exit $$exit_code'

lint-powershell: ## Lint PowerShell scripts with py-psscriptanalyzer
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

lint-dockerfile: ## Lint Dockerfiles with hadolint
	$(DOCKER_RUN) bash -c '\
		exit_code=0; \
		for f in $(DOCKERFILES); do \
			echo "hadolint: $$f"; \
			if ! hadolint "$$f"; then \
				exit_code=1; \
			fi; \
		done; \
		exit $$exit_code'

lint-makefile: ## Lint Makefile with checkmake
	$(DOCKER_RUN) bash -c '\
		echo "checkmake: Makefile"; \
		checkmake Makefile || true'

lint-yaml: ## Lint YAML files with yamllint
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

lint-hcl: ## Lint HCL/Packer files with packer fmt
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
image-base: ## Build base VM image with Packer
	$(DOCKER_RUN) bash -c 'cd images/base && bash build.sh'

image-blockchain: ## Build blockchain VM image with Packer
	$(DOCKER_RUN) bash -c 'cd images/blockchain && bash build.sh'

# ---------- Image publishing (Backblaze B2) ----------
# Usage: make publish-base VERSION=1.0.0
#        make publish-blockchain VERSION=1.0.0
publish-base: ## Publish base image to Backblaze B2 (requires VERSION=x.y.z)
	@test -n "$(VERSION)" || (echo "ERROR: VERSION is required (e.g., make publish-base VERSION=1.0.0)"; exit 1)
	$(DOCKER_RUN) bash images/publish.sh base $(VERSION) images/base/output-base/mps-base.qcow2

publish-blockchain: ## Publish blockchain image to B2 (requires VERSION=x.y.z)
	@test -n "$(VERSION)" || (echo "ERROR: VERSION is required (e.g., make publish-blockchain VERSION=1.0.0)"; exit 1)
	$(DOCKER_RUN) bash images/publish.sh blockchain $(VERSION) images/blockchain/output-blockchain/mps-blockchain.qcow2

# ---------- Clean ----------
clean: ## Remove build artifacts and caches
	@echo "Cleaning..."
	@rm -rf build/ dist/
	@echo "Done."
