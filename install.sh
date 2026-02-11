#!/usr/bin/env bash
set -euo pipefail

# Multi Pass Sandbox (mps) — Installer
# Symlinks bin/mps to a location on PATH and creates ~/.mps/ directory structure.

_color_reset="\033[0m"
_color_red="\033[0;31m"
_color_green="\033[0;32m"
_color_yellow="\033[0;33m"
_color_bold="\033[1m"

info()  { printf "${_color_green}[mps installer]${_color_reset} %s\n" "$*"; }
warn()  { printf "${_color_yellow}[mps installer]${_color_reset} %s\n" "$*"; }
error() { printf "${_color_red}[mps installer]${_color_reset} %s\n" "$*"; }

MPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${MPS_INSTALL_DIR:-/usr/local/bin}"

# ---------- Preflight Checks ----------

check_dependency() {
    local cmd="$1"
    local install_hint="$2"
    if command -v "$cmd" &>/dev/null; then
        info "  ✓ $cmd found: $(command -v "$cmd")"
        return 0
    else
        warn "  ✗ $cmd not found. Install with: $install_hint"
        return 1
    fi
}

info "Checking dependencies..."

missing=0
check_dependency "multipass" "https://multipass.run/ (snap install multipass / brew install multipass)" || missing=1
check_dependency "jq" "sudo apt install jq / brew install jq" || missing=1

if [[ "$missing" -eq 1 ]]; then
    warn ""
    warn "Some dependencies are missing. mps will check for them at runtime."
    warn "Install them before using mps."
fi

# ---------- Create Directory Structure ----------

info "Creating ~/.mps/ directory structure..."
mkdir -p "${HOME}/.mps/instances"
mkdir -p "${HOME}/.mps/cache/images"
mkdir -p "${HOME}/.ssh/config.d"

# ---------- Install ----------

info "Installing mps to ${INSTALL_DIR}/mps..."

# Ensure bin/mps is executable
chmod +x "${MPS_ROOT}/bin/mps"

# Symlink
if [[ -L "${INSTALL_DIR}/mps" ]]; then
    info "Removing existing symlink..."
    rm -f "${INSTALL_DIR}/mps"
fi

if [[ -f "${INSTALL_DIR}/mps" ]]; then
    error "${INSTALL_DIR}/mps already exists and is not a symlink."
    error "Remove it manually or set MPS_INSTALL_DIR to a different location."
    exit 1
fi

if ln -sf "${MPS_ROOT}/bin/mps" "${INSTALL_DIR}/mps" 2>/dev/null; then
    info "Symlinked: ${INSTALL_DIR}/mps → ${MPS_ROOT}/bin/mps"
else
    warn "Cannot write to ${INSTALL_DIR}. Trying with sudo..."
    sudo ln -sf "${MPS_ROOT}/bin/mps" "${INSTALL_DIR}/mps"
    info "Symlinked (sudo): ${INSTALL_DIR}/mps → ${MPS_ROOT}/bin/mps"
fi

# ---------- Verify ----------

if command -v mps &>/dev/null; then
    info ""
    info "Installation complete! mps is available at: $(command -v mps)"
    mps --version
else
    warn ""
    warn "mps was installed to ${INSTALL_DIR}/mps but is not on your PATH."
    warn "Add this to your shell profile:"
    warn "  export PATH=\"${INSTALL_DIR}:\$PATH\""
fi

echo ""
info "Quick start:"
info "  mps up                  # Create and start a sandbox"
info "  mps shell               # Open shell in sandbox"
info "  mps list                # List sandboxes"
info "  mps --help              # Full usage"
