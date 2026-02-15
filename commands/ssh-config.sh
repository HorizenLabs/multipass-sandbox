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
    local instance_name short_name
    instance_name="$(mps_resolve_instance_name "$arg_name")"
    short_name="$(mps_short_name "$instance_name")"

    # ---- Check instance exists and is running ----
    mps_require_running "$instance_name"

    # ---- Resolve key, inject into VM, get private key path ----
    local ssh_key
    ssh_key="$(mps_ensure_ssh_key "$instance_name" "$short_name" "$arg_ssh_key")"

    # ---- Get IP ----
    local ssh_ip
    ssh_ip="$(mp_ipv4 "$instance_name")"
    if [[ -z "$ssh_ip" ]]; then
        mps_die "Could not determine IP address for '${instance_name}'"
    fi

    # ---- Build config block ----
    local ssh_user="ubuntu"
    local config_block
    config_block="$(cat <<EOF
Host ${instance_name}
    HostName ${ssh_ip}
    User ${ssh_user}
    IdentityFile ${ssh_key}
    StrictHostKeyChecking no
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
    2. Ensure ~/.ssh/config has: Include config.d/*
    3. In VS Code, use Remote-SSH to connect to 'mps-dev'

${_color_bold}Port Forwarding:${_color_reset}
    Run ssh-config before using port forwarding:
    1. mps ssh-config --name dev
    2. mps port forward dev 3000:3000

EOF
}
