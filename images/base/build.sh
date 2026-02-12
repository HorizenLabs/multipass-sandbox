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

# Accept target architecture (default: host)
export TARGET_ARCH="${TARGET_ARCH:-}"

# Source arch configuration
# shellcheck source=../arch-config.sh
source "$MPS_ROOT/images/arch-config.sh"

# Initialize packer plugins
packer init packer.pkr.hcl

# Use a native filesystem path for Packer output to avoid rename failures
# on Docker-mounted volumes (WSL2/Windows 9p mounts don't support cross-device rename)
OUTPUT_DIR="${SCRIPT_DIR}/output-base"
PACKER_OUTPUT_DIR="/tmp/packer-output-base"
rm -rf "${PACKER_OUTPUT_DIR:?err_unset}"

# Build
packer build \
    -var "mps_root=${MPS_ROOT}" \
    -var "output_dir=${PACKER_OUTPUT_DIR}" \
    "${PACKER_ARCH_VARS[@]}" \
    packer.pkr.hcl

# Move artifacts to the expected output location
rm -rf "${OUTPUT_DIR:?err_unset}"
mkdir -p "$OUTPUT_DIR"
cp -a "$PACKER_OUTPUT_DIR"/. "$OUTPUT_DIR"/
rm -rf "${PACKER_OUTPUT_DIR:?err_unset}"

echo "=== Base image build complete ==="
