#!/usr/bin/env bash
# tests/ci-detect-e2e.sh — Determine whether CI should run e2e and/or build a local image
#
# Called by the "changes" job in ci.yml. Writes needs_e2e and needs_image_build
# to $GITHUB_OUTPUT (or stdout if GITHUB_OUTPUT is unset, for local testing).
#
# Environment variables (set by the workflow):
#   EVENT_NAME  — "push" or "pull_request"
#   PR_NUMBER   — PR number (pull_request events only)
#   BEFORE_SHA  — previous HEAD SHA (push events only)
#   GH_TOKEN    — GitHub token for API calls (pull_request events only)
#
# Image drift detection uses tests/e2e-image-drift.sh (compares HEAD against
# the latest images/v* tag). Cloud-init detection uses the GitHub API for PRs
# or git diff for pushes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

needs_e2e=false
needs_image_build=false

# ---- Image drift detection ----
drift="$(bash "${SCRIPT_DIR}/e2e-image-drift.sh")"
if [[ "$drift" == "true" ]]; then
    needs_image_build=true
    needs_e2e=true
    echo "Image drift detected — local build required"
fi

# ---- Cloud-init template detection ----
cloud_init_changed=false

case "${EVENT_NAME:-}" in
    pull_request)
        if [[ -n "${PR_NUMBER:-}" ]]; then
            changed="$(gh api "repos/${GITHUB_REPOSITORY:-}/pulls/${PR_NUMBER}/files" \
                --paginate --jq '.[].filename' 2>/dev/null)" || changed=""
            while IFS= read -r file; do
                case "$file" in
                    templates/cloud-init/*)
                        cloud_init_changed=true
                        echo "Cloud-init change detected: ${file}"
                        break
                        ;;
                esac
            done <<EOF
$changed
EOF
        fi
        ;;
    push)
        if [[ -n "${BEFORE_SHA:-}" ]]; then
            changed="$(git diff --name-only "${BEFORE_SHA}..HEAD" 2>/dev/null)" || changed=""
            while IFS= read -r file; do
                case "$file" in
                    templates/cloud-init/*)
                        cloud_init_changed=true
                        echo "Cloud-init change detected (push): ${file}"
                        break
                        ;;
                esac
            done <<EOF
$changed
EOF
        fi
        ;;
esac

if [[ "$cloud_init_changed" == "true" ]]; then
    needs_e2e=true
fi

# ---- Write outputs ----
echo "needs_e2e=${needs_e2e}"
echo "needs_image_build=${needs_image_build}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "needs_e2e=${needs_e2e}" >> "$GITHUB_OUTPUT"
    echo "needs_image_build=${needs_image_build}" >> "$GITHUB_OUTPUT"
fi
