#!/usr/bin/env bash
set -euo pipefail

# Build the blockchain MPS image using Packer
# Requires: packer, qemu (or virtualbox)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MPS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== Building MPS Blockchain Image ==="

for cmd in packer; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' is required but not installed."
        exit 1
    fi
done

cd "$SCRIPT_DIR"

packer init packer.pkr.hcl

packer build \
    -var "mps_root=${MPS_ROOT}" \
    packer.pkr.hcl

echo "=== Blockchain image build complete ==="
