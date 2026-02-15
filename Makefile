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
BASH_SCRIPTS := $(shell find bin/ lib/ commands/ images/ -name '*.sh' -o -name 'mps' 2>/dev/null | grep -v '.ps1') install.sh uninstall.sh
PS_SCRIPTS   := $(shell find . -name '*.ps1' 2>/dev/null)
YAML_FILES   := $(shell find templates/ images/layers/ -name '*.yaml' 2>/dev/null)
HCL_FILES    := $(shell find images/ -name '*.pkr.hcl' 2>/dev/null)
DOCKERFILES  := Dockerfile.builder Dockerfile.linter

BUILDER_STAMP := .stamp-builder
BUILDER_DEPS  := Dockerfile.builder docker/entrypoint.sh

LINTER_STAMP := .stamp-linter
LINTER_DEPS  := Dockerfile.linter docker/entrypoint.sh

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

# Generated .PHONY lists
IMAGE_PHONY       := $(foreach f,$(FLAVORS),image-$(f) $(foreach a,$(ARCHS),image-$(f)-$(a)))
IMPORT_PHONY      := $(foreach f,$(FLAVORS),import-$(f))
PUBLISH_PHONY     := $(foreach f,$(FLAVORS),publish-$(f))
CLEAN_IMAGE_PHONY := $(foreach f,$(FLAVORS),clean-image-$(f) $(foreach a,$(ARCHS),clean-image-$(f)-$(a)))

.PHONY: all help build-docker-builder build-docker-linter install uninstall test clean \
	lint lint-bash lint-powershell lint-dockerfile lint-makefile lint-yaml lint-hcl \
	clean-docker-builder clean-docker-linter clean-images \
	$(IMAGE_PHONY) $(IMPORT_PHONY) $(PUBLISH_PHONY) $(CLEAN_IMAGE_PHONY)

# ---------- All ----------
all: $(foreach f,$(FLAVORS),image-$(f)) ## Build all VM image flavors

# ---------- Help ----------
help: ## Show this help
	@echo ""
	@echo "Image targets:"
	@echo "  Flavors: $(FLAVORS)"
	@echo "  Archs:   $(ARCHS)"
	@echo ""
	@echo "  make image-FLAVOR              Build both archs in parallel"
	@echo "  make image-FLAVOR-ARCH         Build one arch"
	@echo "  make import-FLAVOR             Import host-arch image into mps cache"
	@echo "  make publish-FLAVOR VERSION=x  Publish to Backblaze B2"
	@echo "  make clean-image-FLAVOR        Remove flavor artifacts (both archs)"
	@echo "  make clean-image-FLAVOR-ARCH   Remove single flavor-arch artifacts"
	@echo ""
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-34s\033[0m %s\n", $$1, $$2}'

# ---------- Docker images ----------
build-docker-builder: $(BUILDER_STAMP) ## Build the mps-builder Docker image

$(BUILDER_STAMP): $(BUILDER_DEPS)
	docker build --progress plain -f Dockerfile.builder -t $(BUILDER_IMAGE):$(BUILDER_TAG) .
	@touch $@

build-docker-linter: $(LINTER_STAMP) ## Build the mps-linter Docker image

$(LINTER_STAMP): $(LINTER_DEPS)
	docker build --progress plain -f Dockerfile.linter -t $(LINTER_IMAGE):$(LINTER_TAG) .
	@touch $@

# ---------- Install (runs on host) ----------
install: ## Install mps (symlink to PATH, runs on host)
	@chmod +x bin/mps install.sh
	@./install.sh

uninstall: ## Uninstall mps (remove symlink, cleanup artifacts, runs on host)
	@chmod +x uninstall.sh
	@./uninstall.sh

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
# Templates generate per-flavor, per-arch stamp rules, phony wrappers,
# and both-arch parallel targets.  Adding a new flavor only requires
# entries in FLAVORS, PARENT_*, and IMAGE_LAYERS_*.

# .stamp-image-<flavor>-<arch>  (the real build rule)
# $(1) = flavor, $(2) = arch
define image_stamp_rule
.stamp-image-$(1)-$(2): $$(BUILDER_STAMP) $$(IMAGE_COMMON_DEPS) $$(IMAGE_LAYERS_$(1)) \
        $(if $(PARENT_$(1)),.stamp-image-$(PARENT_$(1))-$(2))
	$$(call docker_run_image,$(2)) bash -c \
	    'cd images && bash build.sh $(if $(PARENT_$(1)),--base-image artifacts/mps-$(PARENT_$(1))-$(2).qcow2.img )$(1)'
	@touch $$@
endef
$(foreach f,$(FLAVORS),$(foreach a,$(ARCHS),$(eval $(call image_stamp_rule,$(f),$(a)))))

# image-<flavor>-<arch> → stamp dependency
define image_arch_rule
image-$(1)-$(2): .stamp-image-$(1)-$(2)
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
# Usage: make publish-<flavor> VERSION=1.0.0
define publish_rule
publish-$(1):
	@test -n "$$(VERSION)" || (echo "ERROR: VERSION is required (e.g., make publish-$(1) VERSION=1.0.0)"; exit 1)
	$$(DOCKER_RUN) bash -c '\
		for arch in amd64 arm64; do \
			echo "Publishing $$$$arch..."; \
			TARGET_ARCH=$$$$arch bash images/publish.sh $(1) $$(VERSION) \
			    images/artifacts/mps-$(1)-$$$$arch.qcow2.img; \
		done'
endef
$(foreach f,$(FLAVORS),$(eval $(call publish_rule,$(f))))

# ---------- Clean ----------
clean-docker-builder: ## Remove mps-builder Docker image
	@echo "Removing $(BUILDER_IMAGE):$(BUILDER_TAG) image..."
	@docker rmi $(BUILDER_IMAGE):$(BUILDER_TAG) 2>/dev/null || true
	@rm -f $(BUILDER_STAMP)

clean-docker-linter: ## Remove mps-linter Docker image
	@echo "Removing $(LINTER_IMAGE):$(LINTER_TAG) image..."
	@docker rmi $(LINTER_IMAGE):$(LINTER_TAG) 2>/dev/null || true
	@rm -f $(LINTER_STAMP)

# clean-image-<flavor> (both archs)
define clean_flavor_rule
clean-image-$(1):
	@echo "Removing $(1) image artifacts..."
	@rm -f images/artifacts/mps-$(1)-*
	@rm -f .stamp-image-$(1)-*
endef
$(foreach f,$(FLAVORS),$(eval $(call clean_flavor_rule,$(f))))

# clean-image-<flavor>-<arch> (single arch)
define clean_flavor_arch_rule
clean-image-$(1)-$(2):
	@echo "Removing $(1) $(2) image artifacts..."
	@rm -f images/artifacts/mps-$(1)-$(2).qcow2.img
	@rm -f images/artifacts/mps-$(1)-$(2).qcow2.img.sha256
	@rm -f .stamp-image-$(1)-$(2)
endef
$(foreach f,$(FLAVORS),$(foreach a,$(ARCHS),$(eval $(call clean_flavor_arch_rule,$(f),$(a)))))

clean-images: $(foreach f,$(FLAVORS),clean-image-$(f)) ## Remove all built VM images
	@rm -f images/cloud-init.yaml

clean: clean-docker-builder clean-docker-linter clean-images ## Remove all build artifacts, images, and Docker containers
	@rm -rf build/ dist/
