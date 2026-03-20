#!/usr/bin/env bash
set -euo pipefail
_ts() { echo "[$(date '+%H:%M:%S')] $*"; }

# MPS Image: Smart-contract-dev layer install script
# Installs: Solana CLI + Anchor (amd64), Foundry, Hardhat, Solhint
#
# Environment variables (set by Packer):
#   FLAVOR          — image flavor (base, protocol-dev, etc.)
#   ANCHOR_VERSION  — anchor-cli release tag (e.g., v0.32.1)

# Self-select: only run for flavors that include smart-contract-dev tools
case "${FLAVOR:-}" in
    smart-contract-dev|smart-contract-audit) ;;
    *) _ts "=== install-smart-contract-dev.sh: skipping (flavor: ${FLAVOR:-base}) ==="; exit 0 ;;
esac

_ts "=== install-smart-contract-dev.sh (flavor: ${FLAVOR}) ==="

# ---------- Solana CLI + Anchor (amd64 only — no arm64 binaries) ----------
if [ "$(dpkg --print-architecture)" = "amd64" ]; then
    if ! sudo -u ubuntu bash -c 'export HOME=/home/ubuntu; [ -d "$HOME/.local/share/solana" ]'; then
        _ts "--- Installing Solana CLI + Anchor ---"
        sudo -u ubuntu bash -c '
            set -euo pipefail
            export HOME=/home/ubuntu
            source "$HOME/.cargo/env"
            # Solana CLI
            sh -c "$(curl -fsSL https://release.anza.xyz/stable/install)"
            echo "export PATH=\"\$HOME/.local/share/solana/install/active_release/bin:\$PATH\"" >> "$HOME/.bashrc"
            # Anchor CLI via crates.io (avm is broken in non-interactive
            # builds: RC version URL derivation 404s, binary conflicts,
            # interactive prompts on failure; --git has refspec issues)
            cargo install anchor-cli --version "'"${ANCHOR_VERSION#v}"'" --force
        '
    fi
else
    _ts "Skipping Solana CLI + Anchor (amd64-only)"
fi

# ---------- Foundry (forge, cast, anvil, chisel) ----------
if ! sudo -u ubuntu bash -c 'export HOME=/home/ubuntu; [ -f "$HOME/.foundry/bin/forge" ]'; then
    _ts "--- Installing Foundry ---"
    sudo -u ubuntu bash -c '
        set -euo pipefail
        export HOME=/home/ubuntu
        curl -fsSL https://foundry.paradigm.xyz | bash
        source "$HOME/.bashrc"
        "$HOME/.foundry/bin/foundryup"
    '
fi

# ---------- Hardhat (via bun) ----------
if ! sudo -u ubuntu bash -c 'export HOME=/home/ubuntu; export PATH="$HOME/.bun/bin:$PATH"; command -v hardhat &>/dev/null'; then
    _ts "--- Installing Hardhat ---"
    sudo -u ubuntu bash -c '
        set -euo pipefail
        export HOME=/home/ubuntu
        export PATH="$HOME/.bun/bin:$PATH"
        bun install -g hardhat
    '
fi

# ---------- Solhint linter (via bun) ----------
if ! sudo -u ubuntu bash -c 'export HOME=/home/ubuntu; export PATH="$HOME/.bun/bin:$PATH"; command -v solhint &>/dev/null'; then
    _ts "--- Installing Solhint ---"
    sudo -u ubuntu bash -c '
        set -euo pipefail
        export HOME=/home/ubuntu
        export PATH="$HOME/.bun/bin:$PATH"
        bun install -g solhint
    '
fi

_ts "=== install-smart-contract-dev.sh complete ==="
