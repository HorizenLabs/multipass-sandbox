#!/usr/bin/env bash
# .github/scripts/ci-setup-submodule.sh — Configure SSH deploy key, init and verify submodule
#
# Expects DEPLOY_KEY environment variable with the SSH private key.
# Configures SSH, rewrites the HTTPS submodule URL to SSH, initializes
# the submodule, and verifies it was checked out correctly.
#
# Usage (in CI):
#   DEPLOY_KEY="${{ secrets.SUBMODULE_DEPLOY_KEY }}" bash .github/scripts/ci-setup-submodule.sh

set -euo pipefail

if [[ -z "${DEPLOY_KEY:-}" ]]; then
    echo "::error::DEPLOY_KEY environment variable is required"
    exit 1
fi

# ---- SSH key configuration ----
mkdir -p ~/.ssh
echo "$DEPLOY_KEY" > ~/.ssh/submodule_key
chmod 600 ~/.ssh/submodule_key
ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null

cat >> ~/.ssh/config <<'SSH'
Host github-submodule
  HostName github.com
  IdentityFile ~/.ssh/submodule_key
  IdentitiesOnly yes
SSH

# Relative submodule URL resolves to HTTPS — rewrite to SSH with deploy key
git config --global url."git@github-submodule:HorizenLabs/hl-claude-marketplace".insteadOf \
    "https://github.com/HorizenLabs/hl-claude-marketplace"

# ---- Init submodule ----
git submodule update --init --recursive

# ---- Verify ----
if [[ ! -f vendor/hl-claude-marketplace/.git ]] && [[ ! -d vendor/hl-claude-marketplace/.git ]]; then
    echo "::error::Submodule vendor/hl-claude-marketplace not initialized"
    exit 1
fi

echo "Submodule vendor/hl-claude-marketplace initialized successfully"
