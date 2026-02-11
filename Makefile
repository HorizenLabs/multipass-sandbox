# Multi Pass Sandbox (mps) — Makefile

SHELL := /bin/bash
.DEFAULT_GOAL := help

MPS_ROOT := $(shell pwd)
BASH_SCRIPTS := $(shell find bin/ lib/ commands/ -name '*.sh' -o -name 'mps' | grep -v '.ps1')
INSTALL_DIR ?= /usr/local/bin

.PHONY: help install test lint lint-fix image-base image-blockchain clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

install: ## Install mps (symlink to PATH)
	@chmod +x bin/mps install.sh
	@./install.sh

test: ## Run BATS tests
	@if command -v bats &>/dev/null; then \
		bats tests/; \
	else \
		echo "BATS not installed. Install with: npm install -g bats / brew install bats-core"; \
		exit 1; \
	fi

lint: ## Run shellcheck on all bash scripts
	@echo "Running shellcheck..."
	@shellcheck_exit=0; \
	for f in $(BASH_SCRIPTS); do \
		if ! shellcheck -x -S warning "$$f"; then \
			shellcheck_exit=1; \
		fi; \
	done; \
	if [ "$$shellcheck_exit" -eq 0 ]; then \
		echo "All scripts pass shellcheck."; \
	else \
		exit 1; \
	fi

image-base: ## Build base VM image with Packer
	@echo "Building base image..."
	@cd images/base && ./build.sh

image-blockchain: ## Build blockchain VM image with Packer
	@echo "Building blockchain image..."
	@cd images/blockchain && ./build.sh

clean: ## Remove build artifacts and caches
	@echo "Cleaning..."
	@rm -rf build/ dist/
	@echo "Done."
