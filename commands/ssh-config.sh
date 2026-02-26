#!/usr/bin/env bash
# shellcheck disable=SC2154  # color vars defined in lib/common.sh
# commands/ssh-config.sh — mps ssh-config [--name <name>]
#
# Resolve user's SSH key, inject it into the VM, and generate an SSH config
# block for VS Code Remote-SSH and other SSH clients.
#
# Usage:
#   mps ssh-config [--name <name>]
#   mps ssh-config --append --name myproject
#   mps ssh-config --ssh-key ~/.ssh/id_ed25519 --name myproject
#
# Flags:
#   --name, -n <name>       Sandbox name (default: auto-resolved from CWD)
#   --ssh-key <path>        Path to SSH key (public or private)
#   --print                 Print SSH config to stdout (default)
#   --append                Write config to ~/.ssh/config.d/mps-<name>
#   --help, -h              Show this help

# ---------- SSH Key Helpers ----------
# These functions are exclusive to ssh-config; kept here to reduce lib/common.sh size.

# Resolve SSH public key path.
# Priority: explicit path > MPS_SSH_KEY config > ~/.ssh/ auto-detect
# If given a private key path (no .pub), appends .pub.
_ssh_config_resolve_pubkey() {
    local explicit_path="${1:-${MPS_SSH_KEY:-}}"

    if [[ -n "$explicit_path" ]]; then
        # If user gave a private key path, derive the pubkey path
        if [[ "$explicit_path" != *.pub ]]; then
            explicit_path="${explicit_path}.pub"
        fi
        if [[ -f "$explicit_path" ]]; then
            echo "$explicit_path"
            return
        fi
        mps_die "SSH public key not found: ${explicit_path}"
    fi

    # Auto-detect from ~/.ssh/
    local key_name
    for key_name in id_ed25519.pub id_ecdsa.pub id_rsa.pub; do
        if [[ -f "${HOME}/.ssh/${key_name}" ]]; then
            echo "${HOME}/.ssh/${key_name}"
            return
        fi
    done

    mps_die "No SSH key found. Provide one with --ssh-key <path>, set MPS_SSH_KEY in config, or generate a key with: ssh-keygen -t ed25519"
}

# Inject SSH public key into a running instance.
# Checks instance metadata to avoid re-injection.
# Writes MPS_SSH_KEY and MPS_SSH_INJECTED=true to metadata.
_ssh_config_inject_key() {
    local instance_name="$1"
    local short_name="$2"
    local pubkey_path="$3"
    local privkey_path="$4"

    # Check if already injected
    local meta_file
    meta_file="$(mps_instance_meta "$short_name")"
    if [[ -f "$meta_file" ]]; then
        local injected=""
        injected="$(_mps_read_meta_json "$meta_file" '.ssh.injected')"
        if [[ "$injected" == "true" ]]; then
            mps_log_debug "SSH key already injected for '${short_name}'"
            return 0
        fi
    fi

    mps_log_info "Injecting SSH key into '${short_name}'..."

    # Transfer public key file into the instance, then append to authorized_keys.
    # Using multipass transfer avoids shell-interpolation risks with inline echo.
    # Create temp file inside VM with mktemp (unpredictable name).
    local tmp_dest
    tmp_dest="$(multipass exec "$instance_name" -- mktemp /tmp/mps_pubkey_XXXXXXXX.pub)"

    # Stage pubkey in a snap-accessible location: snap confinement blocks
    # multipass from reading hidden directories like ~/.ssh/.
    local _state_dir _tmp_pubkey
    _state_dir="$(mps_state_dir)"
    _tmp_pubkey="$(mktemp "${_state_dir}/tmp_pubkey_XXXXXXXX")"
    cp "$pubkey_path" "$_tmp_pubkey"
    chmod 600 "$_tmp_pubkey"

    local _transfer_ok=true
    if ! multipass transfer "$_tmp_pubkey" "${instance_name}:${tmp_dest}"; then
        _transfer_ok=false
    fi
    rm -f "${_tmp_pubkey:?}"

    if [[ "$_transfer_ok" != "true" ]]; then
        mps_die "Failed to transfer SSH public key to '${short_name}'"
    fi
    if ! multipass exec "$instance_name" -- bash -c \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat '${tmp_dest}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && rm -f '${tmp_dest}'"; then
        mps_die "Failed to inject SSH key into '${short_name}'"
    fi

    # Record in instance metadata via jq read-modify-write
    if [[ -f "$meta_file" ]]; then
        local updated
        updated="$(jq --arg k "$privkey_path" '.ssh = {"key": $k, "injected": true}' "$meta_file")"
        _mps_write_json "$meta_file" "$updated"
    fi

    mps_log_info "SSH key injected."
}

# Orchestrator: resolve key, inject if needed, return private key path.
_ssh_config_ensure_key() {
    local instance_name="$1"
    local short_name="$2"
    local ssh_key_arg="${3:-}"

    local pubkey_path privkey_path
    pubkey_path="$(_ssh_config_resolve_pubkey "$ssh_key_arg")" || exit 1
    privkey_path="${pubkey_path%.pub}"

    if [[ ! -f "$privkey_path" ]]; then
        mps_die "SSH private key not found: ${privkey_path} (derived from ${pubkey_path})"
    fi

    _ssh_config_inject_key "$instance_name" "$short_name" "$pubkey_path" "$privkey_path"

    echo "$privkey_path"
}

# ---------- Command ----------

cmd_ssh_config() {
    local arg_name=""
    local arg_print=false
    local arg_append=false
    local arg_ssh_key=""

    # ---- Parse arguments ----
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name|-n)
                arg_name="${2:?--name requires a value}"
                shift 2
                ;;
            --ssh-key)
                arg_ssh_key="${2:?--ssh-key requires a value}"
                shift 2
                ;;
            --print)
                arg_print=true
                shift
                ;;
            --append)
                arg_append=true
                shift
                ;;
            --help|-h)
                _ssh_config_usage
                return 0
                ;;
            -*)
                mps_die "Unknown flag: $1 (see 'mps ssh-config --help')"
                ;;
            *)
                mps_die "Unexpected argument: $1 (see 'mps ssh-config --help')"
                ;;
        esac
    done

    # Default to --print if neither flag specified
    if [[ "$arg_print" == "false" && "$arg_append" == "false" ]]; then
        arg_print=true
    fi

    # ---- Resolve instance name ----
    local instance_name
    instance_name="$(mps_resolve_instance_name "$arg_name")"

    # ---- Prepare running instance (state check, staleness, port forwards) ----
    mps_prepare_running_instance "$instance_name" >/dev/null

    local short_name
    short_name="$(mps_short_name "$instance_name")"

    # ---- Resolve key, inject into VM, get private key path ----
    local ssh_key
    ssh_key="$(_ssh_config_ensure_key "$instance_name" "$short_name" "$arg_ssh_key")"

    # ---- Get IP ----
    local ssh_ip
    ssh_ip="$(mp_ipv4 "$instance_name")"
    if [[ -z "$ssh_ip" ]]; then
        mps_die "Could not determine IP address for '${short_name}'"
    fi

    # ---- Build config block ----
    local ssh_user="ubuntu"
    local config_block
    config_block="$(cat <<EOF
Host ${short_name}
    HostName ${ssh_ip}
    User ${ssh_user}
    IdentityFile ${ssh_key}
    StrictHostKeyChecking accept-new
    UserKnownHostsFile /dev/null
EOF
)"

    # ---- Print to stdout ----
    if [[ "$arg_print" == "true" ]]; then
        echo "$config_block"
    fi

    # ---- Append to SSH config directory ----
    if [[ "$arg_append" == "true" ]]; then
        local config_dir="${HOME}/.ssh/config.d"
        local config_file="${config_dir}/${instance_name}"

        # Create directory if needed
        if [[ ! -d "$config_dir" ]]; then
            mkdir -p "$config_dir"
            chmod 700 "$config_dir"
            mps_log_debug "Created SSH config directory: ${config_dir}"
        fi

        # Write config file
        echo "$config_block" > "$config_file"
        chmod 600 "$config_file"

        mps_log_info "SSH config written to ${config_file}"
        mps_log_info "Ensure your ~/.ssh/config includes: Include config.d/*"
    fi
}

_complete_ssh_config() {
    case "${1:-}" in
        flags)       echo "--name -n --ssh-key --print --append --help -h" ;;
        flag-values)
            case "${2:-}" in
                --name|-n)  echo "__instances__" ;;
                --ssh-key)  echo "__files__" ;;
            esac ;;
    esac
}

_ssh_config_usage() {
    cat <<EOF
${_color_bold}mps ssh-config${_color_reset} — Configure SSH access for a sandbox

${_color_bold}Usage:${_color_reset}
    mps ssh-config [flags]

${_color_bold}Flags:${_color_reset}
    --name, -n <name>       Sandbox name (default: auto-resolved from CWD)
    --ssh-key <path>        Path to SSH key (public or private; default: auto-detect)
    --print                 Print SSH config to stdout (default)
    --append                Write config to ~/.ssh/config.d/mps-<name>
    --help, -h              Show this help

Both --print and --append can be used together.

${_color_bold}SSH Key Resolution:${_color_reset}
    1. --ssh-key <path> flag (pubkey or private key path)
    2. MPS_SSH_KEY config variable
    3. Auto-detect from ~/.ssh/: id_ed25519 > id_ecdsa > id_rsa
    4. Error with instructions if none found

${_color_bold}Examples:${_color_reset}
    mps ssh-config --name dev                              Auto-detect key, inject, print config
    mps ssh-config --ssh-key ~/.ssh/id_ed25519 --name dev  Use specific key
    mps ssh-config --append --name dev                     Write to ~/.ssh/config.d/mps-dev
    mps ssh-config --print --append --name dev             Print and write config

${_color_bold}VS Code Integration:${_color_reset}
    1. Run: mps ssh-config --append --name dev
    2. Ensure ~/.ssh/config has (at the top): Include config.d/*
    3. In VS Code, use Remote-SSH to connect to 'mps-dev'

${_color_bold}Port Forwarding:${_color_reset}
    Run ssh-config before using port forwarding:
    1. mps ssh-config --name dev
    2. mps port forward dev 3000:3000

EOF
}
