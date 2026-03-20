#!/usr/bin/env bash
# .github/scripts/e2e-image-drift.sh — Detect image-affecting changes since last images/v* tag
#
# Compares HEAD against the latest images/v* tag. If any image-affecting
# paths have changed, outputs "true"; otherwise "false".
#
# Requires: git with tags fetched (fetch-depth: 0, fetch-tags: true)
#
# Usage:
#   bash .github/scripts/e2e-image-drift.sh          # prints true/false to stdout
#   if bash .github/scripts/e2e-image-drift.sh | grep -q true; then ...

set -euo pipefail

# Find the latest images/v* tag (highest SemVer)
latest_tag="$(git tag -l 'images/v*' --sort=-v:refname 2>/dev/null | head -n1)"

if [[ -z "$latest_tag" ]]; then
    echo "No images/v* tag found — assuming drift" >&2
    echo "true"
    exit 0
fi

echo "Comparing HEAD against ${latest_tag}" >&2

# Get changed files between the tag and HEAD
changed="$(git diff --name-only "${latest_tag}..HEAD" 2>/dev/null)" || {
    echo "git diff failed — assuming drift" >&2
    echo "true"
    exit 0
}

if [[ -z "$changed" ]]; then
    echo "No changes since ${latest_tag}" >&2
    echo "false"
    exit 0
fi

# Check each changed file against image-affecting prefixes
drift=false
while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    case "$file" in
        images/layers/*)                  drift=true ;;
        images/scripts/*)                 drift=true ;;
        images/build.sh)                  drift=true ;;
        images/packer.pkr.hcl)            drift=true ;;
        images/packer-user-data.pkrtpl.hcl) drift=true ;;
        images/arch-config.sh)            drift=true ;;
        vendor/*)                         drift=true ;;
    esac
    if [[ "$drift" == "true" ]]; then
        echo "Image-affecting change: ${file}" >&2
        break
    fi
done <<EOF
$changed
EOF

echo "$drift"
