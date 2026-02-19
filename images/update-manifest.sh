#!/usr/bin/env bash
set -euo pipefail

# images/update-manifest.sh — Update the B2 manifest after all image uploads complete
#
# Fan-in step: downloads .meta.json sidecars from B2 and performs a single
# manifest read-modify-write. Designed for CI where separate runners upload
# images with publish.sh --upload-only.
#
# Usage:
#   ./images/update-manifest.sh <version> [flavor ...]
#   ./images/update-manifest.sh 1.0.0                           # all flavors
#   ./images/update-manifest.sh 1.0.0 base protocol-dev         # specific flavors
#
# For each flavor, both amd64 and arm64 are checked. Missing .meta.json sidecars
# in B2 are skipped with a warning (e.g., when only one arch was published).
#
# Requires: b2 CLI v4, jq
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
    echo "Remote manifest not found, seeding empty v2 manifest."
    echo '{"schema_version":2,"generated_at":"","images":{}}' > "$REMOTE_MANIFEST"
fi

UPDATED=0
SKIPPED=0

# ---------- Merge all flavor+arch entries ----------
for flavor in "${FLAVORS[@]}"; do
    for arch in $ARCHS; do
        B2_META_PATH="${flavor}/${VERSION}/${arch}.img.meta.json"
        TMP_META="$(mktemp)"

        echo ""
        echo "--- ${flavor}:${VERSION} (${arch}) ---"

        # Download .meta.json sidecar from B2
        if ! b2 file download "b2://${BUCKET}/${B2_META_PATH}" "$TMP_META" 2>/dev/null; then
            echo "  SKIP: .meta.json not found at b2://${BUCKET}/${B2_META_PATH}"
            rm -f "$TMP_META"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        echo "  SHA256: $(jq -r '.sha256' "$TMP_META")"
        echo "  Date:   $(jq -r '.build_date' "$TMP_META")"

        # Merge into manifest (in-place via temp file swap)
        TMP_MANIFEST="$(mktemp)"

        _b2_merge_manifest_entry "$REMOTE_MANIFEST" "$TMP_MANIFEST" "$TMP_META"

        mv "$TMP_MANIFEST" "$REMOTE_MANIFEST"
        rm -f "$TMP_META"
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

# Stamp schema version and generation timestamp
TMP_STAMPED="$(mktemp)"
jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.schema_version = 2 | .generated_at = $ts' \
    "$REMOTE_MANIFEST" > "$TMP_STAMPED" && mv "$TMP_STAMPED" "$REMOTE_MANIFEST"

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
echo "  Skipped:  ${SKIPPED} entries (missing .meta.json sidecars)"
echo "  Manifest: b2://${BUCKET}/manifest.json"
