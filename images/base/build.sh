#!/usr/bin/env bash
set -euo pipefail

# Build the base MPS image using Packer
# Requires: packer, qemu (or virtualbox)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MPS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== Building MPS Base Image ==="

# Check dependencies
if ! command -v packer &>/dev/null; then
    echo "ERROR: 'packer' is required but not installed."
    exit 1
fi

cd "$SCRIPT_DIR"

# Initialize packer plugins
packer init packer.pkr.hcl

# Build
packer build \
    -var "mps_root=${MPS_ROOT}" \
    packer.pkr.hcl

echo "=== Base image build complete ==="
