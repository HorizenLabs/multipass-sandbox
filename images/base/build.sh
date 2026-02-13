#!/usr/bin/env bash
set -euo pipefail

# Build the base MPS image using Packer
# Builds both amd64 and arm64 by default, or a single arch if TARGET_ARCH is set.
# Requires: packer, qemu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MPS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== Building MPS Base Image ==="

# Check dependencies
if ! command -v packer &>/dev/null; then
    echo "ERROR: 'packer' is required but not installed."
    exit 1
fi

cd "$SCRIPT_DIR"

# Determine which architectures to build
if [[ -n "${TARGET_ARCH:-}" ]]; then
    ARCHITECTURES=("$TARGET_ARCH")
else
    ARCHITECTURES=("amd64" "arm64")
fi

# Initialize packer plugins (once, shared across arch builds)
packer init packer.pkr.hcl

# Use a native filesystem path for Packer output to avoid rename failures
# on Docker-mounted volumes (WSL2/Windows 9p mounts don't support cross-device rename)
OUTPUT_DIR="${SCRIPT_DIR}/output-base"
mkdir -p "$OUTPUT_DIR"

for arch in "${ARCHITECTURES[@]}"; do
    echo ""
    echo "=== Building for ${arch} ==="

    # Set TARGET_ARCH for arch-config.sh
    export TARGET_ARCH="$arch"

    # Source arch configuration (sets PACKER_ARCH_VARS)
    # shellcheck source=../arch-config.sh
    source "$MPS_ROOT/images/arch-config.sh"

    PACKER_OUTPUT_DIR="/tmp/packer-output-base-${arch}"
    rm -rf "${PACKER_OUTPUT_DIR:?err_unset}"

    packer build \
        -var "mps_root=${MPS_ROOT}" \
        -var "output_dir=${PACKER_OUTPUT_DIR}" \
        -var "vm_name=mps-base-${arch}.qcow2.img" \
        "${PACKER_ARCH_VARS[@]}" \
        packer.pkr.hcl

    # Compact QCOW2 for optimal on-disk size
    if command -v qemu-img &>/dev/null; then
        echo "Compacting image..."
        qemu-img convert -O qcow2 \
            "${PACKER_OUTPUT_DIR}/mps-base-${arch}.qcow2.img" \
            "${PACKER_OUTPUT_DIR}/mps-base-${arch}.compact.qcow2.img"
        mv "${PACKER_OUTPUT_DIR}/mps-base-${arch}.compact.qcow2.img" \
            "${PACKER_OUTPUT_DIR}/mps-base-${arch}.qcow2.img"
    fi

    # Copy arch-specific artifacts to output
    cp -a "${PACKER_OUTPUT_DIR}/mps-base-${arch}.qcow2.img" "$OUTPUT_DIR/"
    if [[ -f "${PACKER_OUTPUT_DIR}/mps-base-${arch}.qcow2.img.sha256" ]]; then
        cp -a "${PACKER_OUTPUT_DIR}/mps-base-${arch}.qcow2.img.sha256" "$OUTPUT_DIR/"
    fi
    rm -rf "${PACKER_OUTPUT_DIR:?err_unset}"

    echo "=== ${arch} build complete ==="
done

echo ""
echo "=== All builds complete ==="
echo "Artifacts in: ${OUTPUT_DIR}/"
ls -lh "$OUTPUT_DIR/"
