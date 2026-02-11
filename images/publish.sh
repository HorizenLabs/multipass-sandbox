#!/usr/bin/env bash
set -euo pipefail

# images/publish.sh — Publish a built image to Backblaze B2 and update manifest
#
# Usage:
#   ./images/publish.sh <image-name> <version> <image-file>
#   ./images/publish.sh base 1.0.0 images/base/output-base/mps-base.qcow2
#
# Requires: b2 CLI (authenticated), jq
#
# Environment:
#   MPS_B2_BUCKET         — B2 bucket name (default: from config/defaults.env)
#   MPS_B2_BUCKET_PREFIX  — Path prefix in bucket (default: mps)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load defaults
# shellcheck source=../config/defaults.env
source "${MPS_ROOT}/config/defaults.env"

IMAGE_NAME="${1:?Usage: publish.sh <image-name> <version> <image-file>}"
VERSION="${2:?Usage: publish.sh <image-name> <version> <image-file>}"
IMAGE_FILE="${3:?Usage: publish.sh <image-name> <version> <image-file>}"

BUCKET="${MPS_B2_BUCKET:-mps-images}"
PREFIX="${MPS_B2_BUCKET_PREFIX:-mps}"
MANIFEST_FILE="${SCRIPT_DIR}/manifest.json"

# Validate SemVer format
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Version must be SemVer format (e.g., 1.0.0). Got: $VERSION"
    exit 1
fi

if [[ ! -f "$IMAGE_FILE" ]]; then
    echo "ERROR: Image file not found: $IMAGE_FILE"
    exit 1
fi

# Detect architecture
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
esac

echo "=== Publishing ${IMAGE_NAME}:${VERSION} (${ARCH}) ==="

# Compute SHA256
echo "Computing checksum..."
SHA256="$(sha256sum "$IMAGE_FILE" | cut -d' ' -f1)"
echo "SHA256: ${SHA256}"

# Upload to B2
B2_PATH="${PREFIX}/${IMAGE_NAME}/${VERSION}/${ARCH}.img"
echo "Uploading to b2://${BUCKET}/${B2_PATH}..."
b2 file upload --no-progress "${BUCKET}" "$IMAGE_FILE" "$B2_PATH"

echo "Upload complete."

# Update manifest
echo "Updating manifest..."

if [[ ! -f "$MANIFEST_FILE" ]]; then
    echo "ERROR: Manifest not found at ${MANIFEST_FILE}"
    exit 1
fi

# Add version entry and update latest pointer
RELATIVE_URL="${IMAGE_NAME}/${VERSION}/${ARCH}.img"
TMP_MANIFEST="$(mktemp)"

jq \
    --arg name "$IMAGE_NAME" \
    --arg ver "$VERSION" \
    --arg arch "$ARCH" \
    --arg url "$RELATIVE_URL" \
    --arg sha "$SHA256" \
    '
    # Ensure image entry exists
    .images[$name] //= {"description": "", "versions": {}, "latest": null} |
    # Ensure version entry exists
    .images[$name].versions[$ver] //= {} |
    # Set arch-specific data
    .images[$name].versions[$ver][$arch] = {
        "url": $url,
        "sha256": $sha
    } |
    # Update latest pointer
    .images[$name].latest = $ver
    ' "$MANIFEST_FILE" > "$TMP_MANIFEST"

mv "$TMP_MANIFEST" "$MANIFEST_FILE"
echo "Manifest updated: ${IMAGE_NAME}:${VERSION} (${ARCH})"

# Upload updated manifest to B2
echo "Uploading manifest to b2://${BUCKET}/${PREFIX}/manifest.json..."
b2 file upload --no-progress "${BUCKET}" "$MANIFEST_FILE" "${PREFIX}/manifest.json"

echo ""
echo "=== Published successfully ==="
echo "  Image:    ${IMAGE_NAME}:${VERSION} (${ARCH})"
echo "  B2 path:  b2://${BUCKET}/${B2_PATH}"
echo "  SHA256:   ${SHA256}"
echo "  Manifest: b2://${BUCKET}/${PREFIX}/manifest.json"
