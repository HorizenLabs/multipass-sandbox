#!/usr/bin/env bash
set -euo pipefail

# Multi Pass Sandbox (mps) — Uninstaller
# Reverses install.sh and cleans up mps runtime artifacts.

_color_reset=$'\033[0m'
_color_red=$'\033[0;31m'
_color_green=$'\033[0;32m'
_color_yellow=$'\033[0;33m'
_color_bold=$'\033[1m'

info()  { printf "${_color_green}[mps uninstaller]${_color_reset} %s\n" "$*"; }
warn()  { printf "${_color_yellow}[mps uninstaller]${_color_reset} %s\n" "$*"; }
error() { printf "${_color_red}[mps uninstaller]${_color_reset} %s\n" "$*"; }

# ---------- Helper Functions ----------

confirm() {
    local prompt="${1:-Are you sure?}"
    local response
    printf "%s [y/N] " "$prompt" >&2
    read -r response
    [[ "$response" =~ ^[Yy]([Ee][Ss])?$ ]]
}

MPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${MPS_INSTALL_DIR:-${HOME}/.local/bin}"

# Track what was removed for the summary
removed=()

info "${_color_bold}mps uninstaller${_color_reset}"
echo ""

# ---------- 1. Remove Symlink ----------

symlink_path="${INSTALL_DIR}/mps"
if [[ -L "$symlink_path" ]]; then
    # Verify it points to our bin/mps (readlink without -f for macOS compat)
    link_target="$(readlink "$symlink_path")"
    if [[ "$link_target" == "${MPS_ROOT}/bin/mps" ]]; then
        info "Removing symlink: ${symlink_path} → ${link_target}"
        rm -f "$symlink_path"
        removed+=("Symlink: ${symlink_path}")
    else
        warn "Symlink ${symlink_path} points to ${link_target}, not ${MPS_ROOT}/bin/mps. Skipping."
    fi
elif [[ -e "$symlink_path" ]]; then
    warn "${symlink_path} exists but is not a symlink. Skipping."
else
    info "No symlink found at ${symlink_path}."
fi

# ---------- 2. VM Cleanup ----------

if command -v multipass &>/dev/null && command -v jq &>/dev/null; then
    mps_vms="$(multipass list --format json 2>/dev/null | jq -r '.list[]? | select(.name | startswith("mps-")) | "\(.name) (\(.state))"' 2>/dev/null || true)"
    if [[ -n "$mps_vms" ]]; then
        echo ""
        info "Found mps VMs:"
        while IFS= read -r vm_line; do
            info "  $vm_line"
        done <<< "$mps_vms"
        echo ""
        if confirm "Stop and delete all mps VMs (with --purge)?"; then
            vm_names="$(multipass list --format json 2>/dev/null | jq -r '.list[]? | select(.name | startswith("mps-")) | .name' 2>/dev/null || true)"
            while IFS= read -r vm_name; do
                [[ -z "$vm_name" ]] && continue
                info "  Stopping and deleting ${vm_name}..."
                multipass stop "$vm_name" 2>/dev/null || true
                multipass delete "$vm_name" --purge 2>/dev/null || true
                removed+=("VM: ${vm_name}")
            done <<< "$vm_names"
        fi
    else
        info "No mps VMs found."
    fi
else
    info "multipass or jq not available — skipping VM cleanup."
fi

# ---------- 3. SSH Configs ----------

ssh_config_dir="${HOME}/.ssh/config.d"
if [[ -d "$ssh_config_dir" ]]; then
    ssh_configs=()
    while IFS= read -r -d '' f; do
        ssh_configs+=("$f")
    done < <(find "$ssh_config_dir" -maxdepth 1 -name 'mps-*' -print0 2>/dev/null || true)
    if [[ ${#ssh_configs[@]} -gt 0 ]]; then
        for f in "${ssh_configs[@]}"; do
            rm -f "$f"
            removed+=("SSH config: ${f}")
        done
        info "Removed ${#ssh_configs[@]} SSH config file(s) from ${ssh_config_dir}."
    fi
fi

# ---------- 4. Instance Metadata ----------

instances_dir="${HOME}/.mps/instances"
if [[ -d "$instances_dir" ]]; then
    instance_files=()
    while IFS= read -r -d '' f; do
        instance_files+=("$f")
    done < <(find "$instances_dir" -maxdepth 1 \( -name '*.env' -o -name '*.ports' \) -print0 2>/dev/null || true)
    if [[ ${#instance_files[@]} -gt 0 ]]; then
        for f in "${instance_files[@]}"; do
            rm -f "$f"
            removed+=("Instance metadata: ${f##*/}")
        done
        info "Removed ${#instance_files[@]} instance metadata file(s)."
    fi
fi

# ---------- 5. Cached Images ----------

cache_dir="${HOME}/.mps/cache"
if [[ -d "$cache_dir" ]]; then
    cache_size="$(du -sh "$cache_dir" 2>/dev/null | cut -f1 || echo "unknown")"
    echo ""
    if confirm "Remove cached images (${cache_size} in ${cache_dir})?"; then
        rm -rf "$cache_dir"
        removed+=("Image cache: ${cache_dir}")
        info "Removed image cache."
    fi
fi

# ---------- 6. User Config ----------

user_config="${HOME}/.mps/config"
if [[ -f "$user_config" ]]; then
    echo ""
    if confirm "Remove user config (~/.mps/config)?"; then
        rm -f "$user_config"
        removed+=("User config: ${user_config}")
        info "Removed user config."
    fi
fi

# ---------- 7. Cleanup ~/.mps ----------

if [[ -d "${HOME}/.mps" ]]; then
    # Remove instances dir if empty
    rmdir "${HOME}/.mps/instances" 2>/dev/null || true
    # Remove top-level dir if empty
    rmdir "${HOME}/.mps" 2>/dev/null && removed+=("Directory: ~/.mps") || true
fi

# ---------- 8. Summary ----------

echo ""
if [[ ${#removed[@]} -gt 0 ]]; then
    info "${_color_bold}Removed:${_color_reset}"
    for item in "${removed[@]}"; do
        info "  - ${item}"
    done
else
    info "Nothing was removed."
fi

echo ""
info "Uninstall complete. The mps source directory remains at: ${MPS_ROOT}"
