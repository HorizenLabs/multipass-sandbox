#!/usr/bin/env bash
set -euo pipefail

# MPS Image: Protocol-dev layer install script
# Installs: Go, Rust + cargo-audit
#
# Environment variables (set by Packer):
#   FLAVOR — image flavor (base, protocol-dev, etc.)

# Self-select: only run for flavors that include protocol-dev tools
case "${FLAVOR:-}" in
    protocol-dev|smart-contract-dev|smart-contract-audit) ;;
    *) echo "=== install-protocol-dev.sh: skipping (flavor: ${FLAVOR:-base}) ==="; exit 0 ;;
esac

echo "=== install-protocol-dev.sh (flavor: ${FLAVOR}) ==="

# ---------- Go (latest stable from golang.org) ----------
if ! [ -x /usr/local/go/bin/go ]; then
    echo "--- Installing Go ---"
    ARCH=$(dpkg --print-architecture)
    GO_VERSION=$(curl -fsSL "https://go.dev/dl/?mode=json" | jq -r '.[0].version')
    curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-${ARCH}.tar.gz" | tar -C /usr/local -xzf -
    # Add to system-wide profile
    printf '%s\n' \
        'export PATH=$PATH:/usr/local/go/bin' \
        'export GOPATH=$HOME/go' \
        'export PATH=$PATH:$GOPATH/bin' \
        > /etc/profile.d/golang.sh
    chmod +x /etc/profile.d/golang.sh
fi

# ---------- Rust via rustup (as ubuntu user) ----------
if ! sudo -u ubuntu bash -c 'export HOME=/home/ubuntu; [ -f "$HOME/.cargo/bin/rustc" ]'; then
    echo "--- Installing Rust + cargo-audit ---"
    sudo -u ubuntu bash -c '
        export HOME=/home/ubuntu
        curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
        source "$HOME/.cargo/env"
        cargo install cargo-audit
    '
fi

echo "=== install-protocol-dev.sh complete ==="
