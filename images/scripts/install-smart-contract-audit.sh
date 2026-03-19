#!/usr/bin/env bash
set -euo pipefail
_ts() { echo "[$(date '+%H:%M:%S')] $*"; }

# MPS Image: Smart-contract-audit layer install script
# Installs: cosign, Slither, Mythril (amd64), Halmos (amd64), Aderyn, Echidna, Medusa
#
# Environment variables (set by Packer):
#   FLAVOR          — image flavor (base, protocol-dev, etc.)
#   COSIGN_VERSION  — cosign release tag (e.g., v2.5.0)
#   ECHIDNA_VERSION — echidna release tag (e.g., v2.3.1)

# Self-select: only run for smart-contract-audit
case "${FLAVOR:-}" in
    smart-contract-audit) ;;
    *) _ts "=== install-smart-contract-audit.sh: skipping (flavor: ${FLAVOR:-base}) ==="; exit 0 ;;
esac

_ts "=== install-smart-contract-audit.sh (flavor: ${FLAVOR}) ==="

# ---------- cosign (SHA256-verified, sigstore verification tool) ----------
if ! command -v cosign &>/dev/null; then
    _ts "--- Installing cosign ${COSIGN_VERSION} ---"
    ARCH=$(dpkg --print-architecture)
    COSIGN_FILE="cosign-linux-${ARCH}"
    curl -fsSL "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/${COSIGN_FILE}" -o /tmp/"${COSIGN_FILE}"
    curl -fsSL "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign_checksums.txt" -o /tmp/cosign_checksums.txt
    grep -w "${COSIGN_FILE}" /tmp/cosign_checksums.txt | sed "s|${COSIGN_FILE}|/tmp/${COSIGN_FILE}|" | sha256sum -c -
    install -m 755 /tmp/"${COSIGN_FILE}" /usr/local/bin/cosign
    rm /tmp/"${COSIGN_FILE}" /tmp/cosign_checksums.txt
fi

# ---------- Solidity security: static analysis (via uv) ----------
if ! sudo -u ubuntu bash -c 'export HOME=/home/ubuntu; export PATH="$HOME/.local/bin:$PATH"; command -v slither &>/dev/null'; then
    _ts "--- Installing Slither + solc-select ---"
    sudo -u ubuntu bash -c '
        set -euo pipefail
        export HOME=/home/ubuntu
        export PATH="$HOME/.local/bin:$PATH"
        uv tool install slither-analyzer
        uv tool install solc-select
    '
fi

# ---------- Mythril + Halmos (amd64 only — z3-solver has no arm64 wheel) ----------
if [ "$(dpkg --print-architecture)" = "amd64" ]; then
    if ! sudo -u ubuntu bash -c 'export HOME=/home/ubuntu; export PATH="$HOME/.local/bin:$PATH"; command -v myth &>/dev/null'; then
        _ts "--- Installing Mythril + Halmos ---"
        sudo -u ubuntu bash -c '
            set -euo pipefail
            export HOME=/home/ubuntu
            export PATH="$HOME/.local/bin:$PATH"
            uv tool install mythril
            uv tool install halmos
        '
    fi
else
    _ts "Skipping Mythril + Halmos (amd64-only, z3-solver requires source build on arm64)"
fi

# ---------- Solidity security: Aderyn (Cyfrin installer) ----------
if ! sudo -u ubuntu bash -c 'export HOME=/home/ubuntu; command -v aderyn &>/dev/null || [ -f "$HOME/.aderyn/bin/aderyn" ]'; then
    _ts "--- Installing Aderyn ---"
    sudo -u ubuntu bash -c '
        set -euo pipefail
        export HOME=/home/ubuntu
        curl --proto "=https" --tlsv1.2 -LsSf https://github.com/cyfrin/aderyn/releases/latest/download/aderyn-installer.sh | bash
    '
fi

# ---------- Solidity security: Echidna fuzzer (sigstore-verified) ----------
if ! command -v echidna &>/dev/null; then
    _ts "--- Installing Echidna ${ECHIDNA_VERSION} ---"
    ARCH=$(uname -m)
    EC_FILE="echidna-${ECHIDNA_VERSION#v}-${ARCH}-linux.tar.gz"
    curl -fsSL "https://github.com/crytic/echidna/releases/download/${ECHIDNA_VERSION}/${EC_FILE}" -o /tmp/"${EC_FILE}"
    curl -fsSL "https://github.com/crytic/echidna/releases/download/${ECHIDNA_VERSION}/${EC_FILE}.sigstore.json" -o /tmp/"${EC_FILE}.sigstore.json"
    cosign verify-blob \
        --bundle /tmp/"${EC_FILE}.sigstore.json" \
        --certificate-oidc-issuer https://token.actions.githubusercontent.com \
        --certificate-identity-regexp '^https://github\.com/crytic/echidna/.+' \
        /tmp/"${EC_FILE}"
    tar -xzf /tmp/"${EC_FILE}" -C /usr/local/bin
    chmod +x /usr/local/bin/echidna
    rm /tmp/"${EC_FILE}" /tmp/"${EC_FILE}.sigstore.json"
fi

# ---------- Solidity security: Medusa fuzzer (via go install) ----------
if ! sudo -u ubuntu bash -c 'export HOME=/home/ubuntu; export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"; command -v medusa &>/dev/null'; then
    _ts "--- Installing Medusa ---"
    sudo -u ubuntu bash -c '
        set -euo pipefail
        export HOME=/home/ubuntu
        export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"
        export GOPATH="$HOME/go"
        go install github.com/crytic/medusa@latest
    '
fi

_ts "=== install-smart-contract-audit.sh complete ==="
