#!/usr/bin/env bash
set -euo pipefail

# Install/verify Rust toolchain for blockchain image
# This runs as ubuntu user during Packer build (after cloud-init already installed Rust)

echo "=== Verifying Rust installation ==="

export HOME="/home/ubuntu"
source "$HOME/.cargo/env"

rustc --version
cargo --version
rustup --version

# Ensure common targets are available
rustup target add wasm32-unknown-unknown

echo "=== Rust verification complete ==="
