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
#   MPS_B2_BUCKET_PREFIX  — Path prefix in bucket (default: mps)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load defaults
# shellcheck source=../config/defaults.env
source "${MPS_ROOT}/config/defaults.env"

VERSION="${1:?Usage: update-manifest.sh <version> [flavor ...]}"
shift

BUCKET="${MPS_B2_BUCKET:-mps-images}"
PREFIX="${MPS_B2_BUCKET_PREFIX:-mps}"
MANIFEST_FILE="${SCRIPT_DIR}/manifest.json"
ARCHS="amd64 arm64"

# Validate SemVer format
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Version must be SemVer format (e.g., 1.0.0). Got: $VERSION"
    exit 1
fi

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

if b2 file download "b2://${BUCKET}/${PREFIX}/manifest.json" "$REMOTE_MANIFEST" 2>/dev/null; then
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

    META_DISK_SIZE=""
    META_MIN_PROFILE=""
    META_MIN_DISK=""
    META_MIN_MEMORY=""
    META_MIN_CPUS=""
    if [[ -f "$LAYER_FILE" ]] && command -v yq &>/dev/null; then
        META_DISK_SIZE="$(yq '.x-mps.disk_size // ""' "$LAYER_FILE")"
        META_MIN_PROFILE="$(yq '.x-mps.min_profile // ""' "$LAYER_FILE")"
        META_MIN_DISK="$(yq '.x-mps.min_disk // ""' "$LAYER_FILE")"
        META_MIN_MEMORY="$(yq '.x-mps.min_memory // ""' "$LAYER_FILE")"
        META_MIN_CPUS="$(yq '.x-mps.min_cpus // ""' "$LAYER_FILE")"
    fi

    for arch in $ARCHS; do
        B2_SHA_PATH="${PREFIX}/${flavor}/${VERSION}/${arch}.img.sha256"
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

        # Get build_date from the image file's B2 upload timestamp
        B2_IMG_PATH="${PREFIX}/${flavor}/${VERSION}/${arch}.img"
        UPLOAD_TS="$(b2 file info "b2://${BUCKET}/${B2_IMG_PATH}" | jq -r '.uploadTimestamp')"
        if [[ -z "$UPLOAD_TS" || "$UPLOAD_TS" == "null" ]]; then
            echo "  WARN: Could not get upload timestamp, using current time"
            BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        else
            # Convert millis-since-epoch to ISO 8601
            BUILD_DATE="$(date -u -d "@$((UPLOAD_TS / 1000))" +%Y-%m-%dT%H:%M:%SZ)"
        fi
        echo "  Date:   ${BUILD_DATE}"

        # Merge into manifest (in-place via temp file swap)
        RELATIVE_URL="${flavor}/${VERSION}/${arch}.img"
        TMP_MANIFEST="$(mktemp)"

        jq \
            --arg name "$flavor" \
            --arg ver "$VERSION" \
            --arg arch "$arch" \
            --arg url "$RELATIVE_URL" \
            --arg sha "$SHA256" \
            --arg build_date "$BUILD_DATE" \
            --arg disk_size "$META_DISK_SIZE" \
            --arg min_profile "$META_MIN_PROFILE" \
            --arg min_disk "$META_MIN_DISK" \
            --arg min_memory "$META_MIN_MEMORY" \
            --arg min_cpus "$META_MIN_CPUS" \
            '
            # Ensure image entry exists
            .images[$name] //= {"description": "", "versions": {}, "latest": null} |
            # Inject x-mps metadata (overwrite if present)
            (if $disk_size != "" then .images[$name].disk_size = $disk_size else . end) |
            (if $min_profile != "" then .images[$name].min_profile = $min_profile else . end) |
            (if $min_disk != "" then .images[$name].min_disk = $min_disk else . end) |
            (if $min_memory != "" then .images[$name].min_memory = $min_memory else . end) |
            (if $min_cpus != "" then .images[$name].min_cpus = ($min_cpus | tonumber) else . end) |
            # Ensure version entry exists
            .images[$name].versions[$ver] //= {} |
            # Set arch-specific data
            .images[$name].versions[$ver][$arch] = {
                "url": $url,
                "sha256": $sha,
                "build_date": $build_date
            } |
            # Update latest pointer
            .images[$name].latest = $ver
            ' "$REMOTE_MANIFEST" > "$TMP_MANIFEST"

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
echo "Uploading manifest to b2://${BUCKET}/${PREFIX}/manifest.json..."
b2 file upload --no-progress "${BUCKET}" "$REMOTE_MANIFEST" "${PREFIX}/manifest.json"

echo ""
echo "=== Manifest updated successfully ==="
echo "  Version:  ${VERSION}"
echo "  Updated:  ${UPDATED} entries"
echo "  Skipped:  ${SKIPPED} entries (missing sidecars)"
echo "  Manifest: b2://${BUCKET}/${PREFIX}/manifest.json"
