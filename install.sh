#!/usr/bin/env bash

# Multi Pass Sandbox (mps) — Installer
# Symlinks bin/mps to a location on PATH and creates ~/mps/ directory structure.

_color_reset=$'\033[0m'
_color_red=$'\033[0;31m'
_color_green=$'\033[0;32m'
_color_yellow=$'\033[0;33m'
info()  { printf "${_color_green}[mps installer]${_color_reset} %s\n" "$*"; }
warn()  { printf "${_color_yellow}[mps installer]${_color_reset} %s\n" "$*"; }
error() { printf "${_color_red}[mps installer]${_color_reset} %s\n" "$*"; }

MPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- Helper Functions ----------

detect_os() {
    case "$(uname -s)" in
        Linux*)  echo "linux" ;;
        Darwin*) echo "macos" ;;
        *)       echo "unknown" ;;
    esac
}

confirm() {
    local prompt="${1:-Are you sure?}"
    local response
    printf "%s [y/N] " "$prompt" >&2
    read -r response
    [[ "$response" =~ ^[Yy]([Ee][Ss])?$ ]]
}

OS="$(detect_os)"

# Default install directory: ~/.local/bin (no sudo required)
INSTALL_DIR="${MPS_INSTALL_DIR:-${HOME}/.local/bin}"

# ---------- Preflight Checks ----------

install_dependency() {
    local cmd="$1"
    if command -v "$cmd" &>/dev/null; then
        info "  Found $cmd: $(command -v "$cmd")"
        return 0
    fi

    warn "  $cmd not found."

    case "${cmd}:${OS}" in
        multipass:linux)
            if command -v snap &>/dev/null; then
                if confirm "  Install $cmd via snap?"; then
                    sudo snap install multipass
                    return $?
                fi
            else
                warn "  snap not found. Install multipass manually:"
                warn "    https://github.com/canonical/multipass/releases"
            fi
            return 1
            ;;
        multipass:macos)
            if command -v brew &>/dev/null; then
                if confirm "  Install $cmd via Homebrew?"; then
                    brew install --cask multipass
                    return $?
                fi
            else
                warn "  Homebrew not found. Install multipass manually:"
                warn "    https://github.com/canonical/multipass/releases"
            fi
            return 1
            ;;
        jq:linux)
            if command -v apt-get &>/dev/null; then
                if confirm "  Install $cmd via apt?"; then
                    sudo apt-get install -y jq
                    return $?
                fi
            else
                warn "  apt-get not found. Install jq manually:"
                warn "    https://github.com/jqlang/jq/releases"
            fi
            return 1
            ;;
        jq:macos)
            if command -v brew &>/dev/null; then
                if confirm "  Install $cmd via Homebrew?"; then
                    brew install jq
                    return $?
                fi
            else
                warn "  Homebrew not found. Install jq manually:"
                warn "    https://github.com/jqlang/jq/releases"
            fi
            return 1
            ;;
        *)
            warn "  Cannot auto-install $cmd on this platform."
            return 1
            ;;
    esac
}

_mps_install_main() {
    info "Checking dependencies..."

    missing=0
    install_dependency "multipass" || missing=1
    install_dependency "jq" || missing=1

    if [[ "$missing" -eq 1 ]]; then
        warn ""
        warn "Some dependencies are missing. mps will check for them at runtime."
        warn "Install them before using mps."
    fi

    # ---------- Create Directory Structure ----------

    info "Creating ~/mps/ directory structure..."
    mkdir -p "${HOME}/mps/instances"
    mkdir -p "${HOME}/mps/cache/images"
    mkdir -p "${HOME}/mps/cloud-init"
    mkdir -p "${HOME}/.ssh/config.d"

    # ---------- Install ----------

    # Ensure install directory exists
    mkdir -p "${INSTALL_DIR}"

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

    # ---------- Bash Completion ----------

    COMPLETIONS_SRC="${MPS_ROOT}/completions/mps.bash"
    if [[ -f "$COMPLETIONS_SRC" ]]; then
        installed_completion=false

        if [[ "$OS" == "linux" ]]; then
            # Linux: ~/.local/share/bash-completion/completions/mps
            comp_dir="${HOME}/.local/share/bash-completion/completions"
            mkdir -p "$comp_dir"
            if [[ -L "${comp_dir}/mps" ]]; then
                rm -f "${comp_dir}/mps"
            fi
            ln -sf "$COMPLETIONS_SRC" "${comp_dir}/mps"
            info "Bash completion installed: ${comp_dir}/mps"
            installed_completion=true
        elif [[ "$OS" == "macos" ]]; then
            # macOS: use Homebrew bash-completion directory if available
            brew_prefix="$(brew --prefix 2>/dev/null || true)"
            if [[ -n "$brew_prefix" && -d "${brew_prefix}/etc/bash_completion.d" ]]; then
                comp_dir="${brew_prefix}/etc/bash_completion.d"
                if [[ -L "${comp_dir}/mps" ]]; then
                    rm -f "${comp_dir}/mps"
                fi
                ln -sf "$COMPLETIONS_SRC" "${comp_dir}/mps"
                info "Bash completion installed: ${comp_dir}/mps"
                installed_completion=true
            fi
        fi

        if [[ "$installed_completion" == "false" ]]; then
            warn "Could not auto-install bash completion."
            warn "Add this to your shell profile:"
            warn "  source ${COMPLETIONS_SRC}"
        fi

        # Hint for zsh users
        shell_basename="$(basename "${SHELL:-bash}")"
        if [[ "$shell_basename" == "zsh" ]]; then
            info ""
            info "For zsh, add to your ~/.zshrc:"
            info "  autoload -U +X bashcompinit && bashcompinit"
            info "  source ${COMPLETIONS_SRC}"
        fi
    fi

    # ---------- PATH Check ----------

    # Check if INSTALL_DIR is on PATH
    case ":${PATH}:" in
        *":${INSTALL_DIR}:"*)
            # Already on PATH, nothing to do
            ;;
        *)
            warn ""
            warn "${INSTALL_DIR} is not in your PATH."
            shell_name="$(basename "${SHELL:-bash}")"
            case "$shell_name" in
                zsh)  rc_file="${HOME}/.zshrc" ;;
                *)    rc_file="${HOME}/.bashrc" ;;
            esac
            path_line="export PATH=\"${INSTALL_DIR}:\$PATH\""
            if confirm "Add it to ~/${rc_file##*/}?"; then
                printf '\n# Added by mps installer\n%s\n' "$path_line" >> "$rc_file"
                info "Added to ${rc_file}. Restart your shell or run: source ${rc_file}"
            else
                warn "Add this to your shell profile manually:"
                warn "  $path_line"
            fi
            ;;
    esac

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
}

# Source guard: run main only when executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
    _mps_install_main
fi
