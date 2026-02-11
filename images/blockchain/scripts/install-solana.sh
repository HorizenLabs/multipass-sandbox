#!/usr/bin/env bash
set -euo pipefail

# Install/verify Solana CLI for blockchain image
# Runs as ubuntu user during Packer build

echo "=== Verifying Solana installation ==="

export HOME="/home/ubuntu"
export PATH="$HOME/.local/share/solana/install/active_release/bin:$PATH"
source "$HOME/.cargo/env"

solana --version
anchor --version 2>/dev/null || echo "Anchor CLI available via avm"

echo "=== Solana verification complete ==="
