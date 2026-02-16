#!/usr/bin/env bash
set -euo pipefail

# images/update-manifest.sh — Update the B2 manifest after all image uploads complete
#
# Fan-in step: downloads .sha256 sidecars from B2, reads x-mps metadata from
# layer YAMLs in the repo, and performs a single manifest read-modify-write.
# Designed for CI where separate runners upload images with publish.sh --upload-only.
#
# Usage:
#   ./images/update-manifest.sh <version> [flavor ...]
#   ./images/update-manifest.sh 1.0.0                           # all flavors
#   ./images/update-manifest.sh 1.0.0 base protocol-dev         # specific flavors
#
# For each flavor, both amd64 and arm64 are checked. Missing sidecars in B2
# are skipped with a warning (e.g., when only one arch was published).
#
# Requires: b2 CLI v4, jq, yq (for x-mps metadata)
#
# Environment:
#   B2_APPLICATION_KEY_ID — B2 application key ID (required, read by b2 CLI)
#   B2_APPLICATION_KEY    — B2 application key (required, read by b2 CLI)
#   MPS_B2_BUCKET         — B2 bucket name (default: from config/defaults.env)

# shellcheck source=lib/publish-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/publish-common.sh"
publish_init

VERSION="${1:?Usage: update-manifest.sh <version> [flavor ...]}"
shift

ARCHS="amd64 arm64"

_validate_semver "$VERSION"

# Discover flavors: from args, or auto-detect from layer YAML files
if [[ $# -gt 0 ]]; then
    FLAVORS=("$@")
else
    FLAVORS=()
    for layer_file in "${SCRIPT_DIR}"/layers/*.yaml; do
        [[ -f "$layer_file" ]] || continue
        flavor="$(basename "$layer_file" .yaml)"
        FLAVORS+=("$flavor")
    done
fi

if [[ ${#FLAVORS[@]} -eq 0 ]]; then
    echo "ERROR: No flavors found. Check images/layers/*.yaml or pass flavors as arguments."
    exit 1
fi

echo "=== Updating manifest for version ${VERSION} ==="
echo "  Flavors: ${FLAVORS[*]}"
echo "  Archs:   ${ARCHS}"

# ---------- Download remote manifest (single read) ----------
echo ""
echo "Fetching remote manifest..."
REMOTE_MANIFEST="$(mktemp)"
trap 'rm -f "$REMOTE_MANIFEST"' EXIT

if b2 file download "b2://${BUCKET}/manifest.json" "$REMOTE_MANIFEST" 2>/dev/null; then
    echo "Using remote manifest from B2."
else
    echo "Remote manifest not found, using local skeleton."
    if [[ ! -f "$MANIFEST_FILE" ]]; then
        echo "ERROR: Local manifest not found at ${MANIFEST_FILE}"
        exit 1
    fi
    cp "$MANIFEST_FILE" "$REMOTE_MANIFEST"
fi

UPDATED=0
SKIPPED=0

# ---------- Merge all flavor+arch entries ----------
for flavor in "${FLAVORS[@]}"; do
    # Read x-mps metadata from the layer YAML
    LAYER_FILE="${SCRIPT_DIR}/layers/${flavor}.yaml"
    _read_xmps_metadata "$LAYER_FILE"

    for arch in $ARCHS; do
        B2_SHA_PATH="${flavor}/${VERSION}/${arch}.img.sha256"
        TMP_SHA="$(mktemp)"

        echo ""
        echo "--- ${flavor}:${VERSION} (${arch}) ---"

        # Download .sha256 sidecar from B2
        if ! b2 file download "b2://${BUCKET}/${B2_SHA_PATH}" "$TMP_SHA" 2>/dev/null; then
            echo "  SKIP: sidecar not found at b2://${BUCKET}/${B2_SHA_PATH}"
            rm -f "$TMP_SHA"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        SHA256="$(awk '{print $1}' "$TMP_SHA")"
        rm -f "$TMP_SHA"
        echo "  SHA256: ${SHA256}"

        # Get build_date and file_size from the image file's B2 metadata
        B2_IMG_PATH="${flavor}/${VERSION}/${arch}.img"
        FILE_INFO="$(b2 file info "b2://${BUCKET}/${B2_IMG_PATH}")"
        UPLOAD_TS="$(echo "$FILE_INFO" | jq -r '.uploadTimestamp')"
        FILE_SIZE="$(echo "$FILE_INFO" | jq -r '.contentLength')"

        if [[ -z "$UPLOAD_TS" || "$UPLOAD_TS" == "null" ]]; then
            echo "  WARN: Could not get upload timestamp, using current time"
            BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        else
            # Convert millis-since-epoch to ISO 8601
            BUILD_DATE="$(date -u -d "@$((UPLOAD_TS / 1000))" +%Y-%m-%dT%H:%M:%SZ)"
        fi
        echo "  Date:   ${BUILD_DATE}"

        if [[ -z "$FILE_SIZE" || "$FILE_SIZE" == "null" ]]; then
            FILE_SIZE=""
        fi

        # Merge into manifest (in-place via temp file swap)
        RELATIVE_URL="${flavor}/${VERSION}/${arch}.img"
        TMP_MANIFEST="$(mktemp)"

        _b2_merge_manifest_entry "$REMOTE_MANIFEST" "$TMP_MANIFEST" \
            "$flavor" "$VERSION" "$arch" "$RELATIVE_URL" "$SHA256" "$BUILD_DATE" \
            "$FILE_SIZE" "$META_DISK_SIZE" "$META_MIN_PROFILE" "$META_MIN_DISK" \
            "$META_MIN_MEMORY" "$META_MIN_CPUS"

        mv "$TMP_MANIFEST" "$REMOTE_MANIFEST"
        echo "  Merged into manifest."
        UPDATED=$((UPDATED + 1))
    done
done

# ---------- Upload manifest (single write) ----------
if [[ "$UPDATED" -eq 0 ]]; then
    echo ""
    echo "ERROR: No entries were merged. Check that images were uploaded first."
    exit 1
fi

echo ""
echo "Uploading manifest to b2://${BUCKET}/manifest.json..."
b2 file upload "${BUCKET}" "$REMOTE_MANIFEST" "manifest.json"

# Generate index pages
echo "Generating index pages..."
bash "${SCRIPT_DIR}/generate-index.sh" "$REMOTE_MANIFEST" "$BUCKET"

echo ""
echo "=== Manifest updated successfully ==="
echo "  Version:  ${VERSION}"
echo "  Updated:  ${UPDATED} entries"
echo "  Skipped:  ${SKIPPED} entries (missing sidecars)"
echo "  Manifest: b2://${BUCKET}/manifest.json"
