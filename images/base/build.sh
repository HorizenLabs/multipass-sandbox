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

# Verify git submodule (private Claude Code marketplace)
if [[ ! -f "$MPS_ROOT/vendor/hl-claude-marketplace/.claude-plugin/marketplace.json" ]]; then
    echo "ERROR: Git submodule 'vendor/hl-claude-marketplace' is not initialized."
    echo "Run: git submodule update --init"
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

    # Generate SHA256 checksum (must be after compaction)
    echo "Generating SHA256 checksum..."
    (cd "${PACKER_OUTPUT_DIR}" && sha256sum "mps-base-${arch}.qcow2.img" > "mps-base-${arch}.qcow2.img.sha256")

    # Copy arch-specific artifacts to output
    cp -a "${PACKER_OUTPUT_DIR}/mps-base-${arch}.qcow2.img" "$OUTPUT_DIR/"
    cp -a "${PACKER_OUTPUT_DIR}/mps-base-${arch}.qcow2.img.sha256" "$OUTPUT_DIR/"
    rm -rf "${PACKER_OUTPUT_DIR:?err_unset}"

    echo "=== ${arch} build complete ==="
done

echo ""
echo "=== All builds complete ==="
echo "Artifacts in: ${OUTPUT_DIR}/"
ls -lh "$OUTPUT_DIR/"
