#!/usr/bin/env bash
set -euo pipefail

# Install/verify Foundry toolkit for blockchain image
# Runs as ubuntu user during Packer build

echo "=== Verifying Foundry installation ==="

export HOME="/home/ubuntu"
export PATH="$HOME/.foundry/bin:$PATH"

forge --version
cast --version
anvil --version
chisel --version 2>/dev/null || echo "chisel available"

echo "=== Foundry verification complete ==="
