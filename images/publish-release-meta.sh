#!/usr/bin/env bash
set -euo pipefail

# images/publish-release-meta.sh — Publish mps-release.json to Backblaze B2
#
# Generates a small JSON metadata file that clients fetch to check for CLI updates,
# then uploads it to B2 at the bucket root (alongside manifest.json).
#
# Usage:
#   ./images/publish-release-meta.sh <version> <commit_sha>
#
# The tag is derived as mps/v<version> (convention).
# commit_sha is the dereferenced commit (git rev-parse <tag>^0), resolved by
# the caller (Makefile / CI) since git is not available in the publisher container.
#
# Requires: b2 CLI, jq, curl
#
# Environment:
#   B2_APPLICATION_KEY_ID — B2 application key ID (required)
#   B2_APPLICATION_KEY    — B2 application key (required)
#   MPS_B2_BUCKET         — B2 bucket name (default: mpsandbox)
#   CF_ZONE_ID            — Cloudflare zone ID (optional, for cache purge)
#   CF_API_TOKEN          — Cloudflare API token (optional, for cache purge)

# shellcheck source=lib/publish-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/publish-common.sh"
publish_init

VERSION="${1:?Usage: publish-release-meta.sh <version> <commit_sha>}"
COMMIT_SHA="${2:?Usage: publish-release-meta.sh <version> <commit_sha>}"

_validate_semver "$VERSION"

TAG="mps/v${VERSION}"

echo "=== Publishing mps-release.json ==="
echo "  Version:    ${VERSION}"
echo "  Tag:        ${TAG}"
echo "  Commit SHA: ${COMMIT_SHA}"

# Generate mps-release.json
RELEASE_JSON="$(mktemp)"
trap 'rm -f "$RELEASE_JSON"' EXIT

jq -n \
    --arg version "$VERSION" \
    --arg tag "$TAG" \
    --arg commit_sha "$COMMIT_SHA" \
    '{version: $version, tag: $tag, commit_sha: $commit_sha}' \
    > "$RELEASE_JSON"

echo ""
echo "Generated mps-release.json:"
cat "$RELEASE_JSON"
echo ""

# Upload to B2
echo "Uploading to b2://${BUCKET}/mps-release.json..."
b2 file upload --no-progress \
    --content-type application/json \
    "$BUCKET" "$RELEASE_JSON" mps-release.json
echo "Upload complete."

# Clean up old file versions
echo "Cleaning up old file versions..."
_b2_cleanup_old_versions "mps-release.json"

# Purge CF cache
CDN_BASE="${MPS_IMAGE_BASE_URL:-}"
if [[ -n "$CDN_BASE" ]]; then
    echo "Purging CF cache..."
    _cf_purge_urls "${CDN_BASE}/mps-release.json"
fi

echo ""
echo "=== mps-release.json published successfully ==="
