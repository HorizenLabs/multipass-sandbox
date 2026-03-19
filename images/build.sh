#!/usr/bin/env bash
set -euo pipefail

# Build an MPS image flavor using Packer
# Merges cloud-init layers with yq, then runs Packer.
#
# Usage:
#   bash build.sh [--base-image <path>] <flavor>
#   bash build.sh base
#   bash build.sh --base-image artifacts/mps-base-amd64.qcow2.img protocol-dev
#   bash build.sh smart-contract-audit
#
# When --base-image is provided (chained build), only the delta layer for
# the flavor is applied on top of the parent QCOW2 image. Without it,
# all cumulative layers are merged from scratch (original behavior).
#
# Flavors (from-scratch — each includes all preceding layers):
#   base                  — base
#   protocol-dev          — base + protocol-dev
#   smart-contract-dev    — base + protocol-dev + smart-contract-dev
#   smart-contract-audit  — base + protocol-dev + smart-contract-dev + smart-contract-audit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------- Argument parsing ----------
BASE_IMAGE=""
FLAVOR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-image)
            BASE_IMAGE="${2:?ERROR: --base-image requires a path argument}"
            shift 2
            ;;
        -*)
            echo "ERROR: Unknown option: $1"
            echo "Usage: build.sh [--base-image <path>] <flavor>"
            exit 1
            ;;
        *)
            if [[ -n "$FLAVOR" ]]; then
                echo "ERROR: Multiple flavors specified: '$FLAVOR' and '$1'"
                exit 1
            fi
            FLAVOR="$1"
            shift
            ;;
    esac
done

if [[ -z "$FLAVOR" ]]; then
    echo "ERROR: No flavor specified."
    echo "Usage: build.sh [--base-image <path>] <flavor>"
    echo "Valid flavors: base, protocol-dev, smart-contract-dev, smart-contract-audit"
    exit 1
fi

# Validate --base-image not used with base flavor
if [[ -n "$BASE_IMAGE" && "$FLAVOR" == "base" ]]; then
    echo "ERROR: --base-image cannot be used with 'base' flavor (it has no parent)."
    exit 1
fi

# Validate base image file exists and convert to absolute path
if [[ -n "$BASE_IMAGE" ]]; then
    if [[ ! -f "$BASE_IMAGE" ]]; then
        echo "ERROR: Base image not found: $BASE_IMAGE"
        exit 1
    fi
    BASE_IMAGE="$(cd "$(dirname "$BASE_IMAGE")" && pwd)/$(basename "$BASE_IMAGE")"
fi

# ---------- Map flavor to layer files ----------
if [[ -n "$BASE_IMAGE" ]]; then
    # Chained build: only the delta layer for this flavor
    echo "Chained build: using parent image $(basename "$BASE_IMAGE")"
    case "$FLAVOR" in
        protocol-dev)
            LAYERS=("layers/protocol-dev.yaml")
            ;;
        smart-contract-dev)
            LAYERS=("layers/smart-contract-dev.yaml")
            ;;
        smart-contract-audit)
            LAYERS=("layers/smart-contract-audit.yaml")
            ;;
        *)
            echo "ERROR: Unknown flavor: $FLAVOR"
            echo "Valid flavors: base, protocol-dev, smart-contract-dev, smart-contract-audit"
            exit 1
            ;;
    esac
else
    # From-scratch build: all cumulative layers
    case "$FLAVOR" in
        base)
            LAYERS=("layers/base.yaml")
            ;;
        protocol-dev)
            LAYERS=("layers/base.yaml" "layers/protocol-dev.yaml")
            ;;
        smart-contract-dev)
            LAYERS=("layers/base.yaml" "layers/protocol-dev.yaml" "layers/smart-contract-dev.yaml")
            ;;
        smart-contract-audit)
            LAYERS=("layers/base.yaml" "layers/protocol-dev.yaml" "layers/smart-contract-dev.yaml" "layers/smart-contract-audit.yaml")
            ;;
        *)
            echo "ERROR: Unknown flavor: $FLAVOR"
            echo "Valid flavors: base, protocol-dev, smart-contract-dev, smart-contract-audit"
            exit 1
            ;;
    esac
fi

echo "=== Building MPS Image: ${FLAVOR} ==="
echo "Layers: ${LAYERS[*]}"

# ---------- Check dependencies ----------
if ! command -v packer &>/dev/null; then
    echo "ERROR: 'packer' is required but not installed."
    exit 1
fi

if ! command -v yq &>/dev/null; then
    echo "ERROR: 'yq' is required but not installed."
    exit 1
fi

# Verify git submodule (private Claude Code marketplace)
if [[ ! -f "$MPS_ROOT/vendor/hl-claude-marketplace/.claude-plugin/marketplace.json" ]]; then
    echo "ERROR: Git submodule 'vendor/hl-claude-marketplace' is not initialized."
    echo "Run: git submodule update --init"
    exit 1
fi

cd "$SCRIPT_DIR"

# ---------- Resolve tool versions from GitHub releases ----------
# Authenticated if GITHUB_TOKEN available (CI: 5000 req/hr), unauthenticated
# with pinned fallback for local builds (60 req/hr shared IP).
_resolve_gh_latest() {
    local repo="$1" fallback="$2"
    local version=""
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        version=$(curl -fsSL -H "Authorization: token ${GITHUB_TOKEN}" \
            "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
            | jq -r '.tag_name // empty') || true
    else
        version=$(curl -fsSL \
            "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
            | jq -r '.tag_name // empty') || true
    fi
    if [[ -z "$version" ]]; then
        echo "  WARN: Failed to resolve ${repo} latest, using fallback: ${fallback}" >&2
        version="$fallback"
    fi
    echo "$version"
}

echo "Resolving tool versions..."
YQ_VERSION=$(_resolve_gh_latest "mikefarah/yq" "v4.52.4")
SHELLCHECK_VERSION=$(_resolve_gh_latest "koalaman/shellcheck" "v0.11.0")
HADOLINT_VERSION=$(_resolve_gh_latest "hadolint/hadolint" "v2.14.0")
echo "  yq: ${YQ_VERSION}, shellcheck: ${SHELLCHECK_VERSION}, hadolint: ${HADOLINT_VERSION}"

# Audit-layer tools (only resolve when needed)
COSIGN_VERSION=""
ECHIDNA_VERSION=""
case "$FLAVOR" in
    smart-contract-audit)
        COSIGN_VERSION=$(_resolve_gh_latest "sigstore/cosign" "v2.5.0")
        ECHIDNA_VERSION=$(_resolve_gh_latest "crytic/echidna" "v2.3.1")
        echo "  cosign: ${COSIGN_VERSION}, echidna: ${ECHIDNA_VERSION}"
        ;;
esac

# ---------- Merge layers with yq ----------
echo "Merging cloud-init layers..."
yq eval-all '. as $item ireduce ({}; . *+ $item)' "${LAYERS[@]}" > cloud-init.yaml
echo "Merged cloud-init.yaml generated ($(wc -l < cloud-init.yaml) lines)"

# ---------- Extract disk size from merged cloud-init (x-mps metadata) ----------
if [[ -z "${PACKER_DISK_SIZE:-}" ]]; then
    PACKER_DISK_SIZE="$(yq '.x-mps.disk_size // "15G"' cloud-init.yaml)"
fi
echo "Disk size: ${PACKER_DISK_SIZE}"

# ---------- Build extra Packer variables for chained builds ----------
PACKER_EXTRA_VARS=()
if [[ -n "$BASE_IMAGE" ]]; then
    PACKER_EXTRA_VARS+=(
        -var "iso_url=${BASE_IMAGE}"
        -var "iso_checksum=file:${BASE_IMAGE}.sha256"
    )
fi

# Pass flavor and resolved tool versions to Packer provisioners
PACKER_EXTRA_VARS+=(
    -var "flavor=${FLAVOR}"
    -var "yq_version=${YQ_VERSION}"
    -var "shellcheck_version=${SHELLCHECK_VERSION}"
    -var "hadolint_version=${HADOLINT_VERSION}"
    -var "cosign_version=${COSIGN_VERSION}"
    -var "echidna_version=${ECHIDNA_VERSION}"
)

# ---------- Determine architectures ----------
if [[ -n "${TARGET_ARCH:-}" ]]; then
    ARCHITECTURES=("$TARGET_ARCH")
else
    ARCHITECTURES=("amd64" "arm64")
fi

# Initialize packer plugins (once, shared across arch builds)
packer init packer.pkr.hcl

# Ensure artifacts directory exists
mkdir -p artifacts

for arch in "${ARCHITECTURES[@]}"; do
    echo ""
    echo "=== Building ${FLAVOR} for ${arch} ==="

    # Set TARGET_ARCH for arch-config.sh
    export TARGET_ARCH="$arch"

    # Source arch configuration (sets PACKER_ARCH_VARS)
    # shellcheck source=arch-config.sh
    source "$MPS_ROOT/images/arch-config.sh"

    PACKER_OUTPUT_DIR="${MPS_ROOT}/build/packer-output-${FLAVOR}-${arch}"
    mkdir -p "${MPS_ROOT}/build"
    rm -rf "${PACKER_OUTPUT_DIR:?err_unset}"

    VM_NAME="mps-${FLAVOR}-${arch}.qcow2.img"

    PACKER_LOG=1 packer build \
        -var "mps_root=${MPS_ROOT}" \
        -var "image_name=${FLAVOR}" \
        -var "output_dir=${PACKER_OUTPUT_DIR}" \
        -var "vm_name=${VM_NAME}" \
        -var "disk_size=${PACKER_DISK_SIZE}" \
        "${PACKER_ARCH_VARS[@]}" \
        "${PACKER_EXTRA_VARS[@]}" \
        packer.pkr.hcl

    # Copy arch-specific artifacts to output
    cp -a "${PACKER_OUTPUT_DIR}/${VM_NAME}" "artifacts/"
    cp -a "${PACKER_OUTPUT_DIR}/${VM_NAME}.sha256" "artifacts/"
    # Packer checksums all output files; on arm64 this includes efivars.fd.
    # Keep only the .img entry so downstream consumers get a single hash.
    grep '\.img$' "artifacts/${VM_NAME}.sha256" > "artifacts/${VM_NAME}.sha256.tmp" \
        && mv "artifacts/${VM_NAME}.sha256.tmp" "artifacts/${VM_NAME}.sha256"
    rm -rf "${PACKER_OUTPUT_DIR:?err_unset}"

    echo "=== ${FLAVOR} ${arch} build complete ==="
done

# Clean up generated cloud-init.yaml
rm -f cloud-init.yaml

echo ""
echo "=== All ${FLAVOR} builds complete ==="
echo "Artifacts in: ${SCRIPT_DIR}/artifacts/"
ls -lh artifacts/mps-"${FLAVOR}"-*.qcow2.img* 2>/dev/null || true
