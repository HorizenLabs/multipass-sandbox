#!/usr/bin/env bash
# commands/ssh-config.sh — mps ssh-config [--name <name>]
#
# Generate an SSH config block for a running sandbox, suitable for
# VS Code Remote-SSH and other SSH clients.
#
# Usage:
#   mps ssh-config [--name <name>]
#   mps ssh-config --append --name myproject
#   mps ssh-config --print --append --name myproject
#
# Flags:
#   --name, -n <name>   Sandbox name (default: auto-resolved from CWD)
#   --print             Print SSH config to stdout (default)
#   --append            Write config to ~/.ssh/config.d/mps-<name>
#   --help, -h          Show this help

cmd_ssh_config() {
    local arg_name=""
    local arg_print=false
    local arg_append=false

    # ---- Parse arguments ----
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name|-n)
                arg_name="${2:?--name requires a value}"
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
    if [[ -n "$arg_name" ]]; then
        instance_name="$(mps_instance_name "$arg_name")"
    else
        instance_name="$(mps_resolve_name "" "$(pwd)" "${MPS_CLOUD_INIT:-${MPS_DEFAULT_CLOUD_INIT:-base}}" "${MPS_PROFILE:-${MPS_DEFAULT_PROFILE:-standard}}")"
    fi
    mps_log_debug "Resolved instance name: ${instance_name}"

    # ---- Check instance exists and is running ----
    local state
    state="$(mp_instance_state "$instance_name")"

    if [[ "$state" == "nonexistent" ]]; then
        mps_die "Instance '${instance_name}' does not exist. Create it with: mps up --name $(mps_short_name "$instance_name")"
    fi

    if [[ "$state" != "Running" ]]; then
        mps_die "Instance '${instance_name}' is not running (state: ${state}). Start it with: mps up --name $(mps_short_name "$instance_name")"
    fi

    # ---- Get SSH info ----
    local ssh_ip="" ssh_key="" ssh_user=""
    local ssh_line
    while IFS='=' read -r key val; do
        case "$key" in
            IP)       ssh_ip="$val" ;;
            SSH_KEY)  ssh_key="$val" ;;
            USER)     ssh_user="$val" ;;
        esac
    done < <(mp_ssh_info "$instance_name")

    if [[ -z "$ssh_ip" ]]; then
        mps_die "Could not determine IP address for '${instance_name}'"
    fi

    # ---- Build config block ----
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
${_color_bold}mps ssh-config${_color_reset} — Generate SSH config for a sandbox

${_color_bold}Usage:${_color_reset}
    mps ssh-config [flags]

${_color_bold}Flags:${_color_reset}
    --name, -n <name>   Sandbox name (default: auto-resolved from CWD)
    --print             Print SSH config to stdout (default)
    --append            Write config to ~/.ssh/config.d/mps-<name>
    --help, -h          Show this help

Both --print and --append can be used together.

${_color_bold}Examples:${_color_reset}
    mps ssh-config                              Print SSH config for current directory
    mps ssh-config --name dev                   Print SSH config for 'dev'
    mps ssh-config --append --name dev          Write to ~/.ssh/config.d/mps-dev
    mps ssh-config --print --append --name dev  Print and write config

${_color_bold}VS Code Integration:${_color_reset}
    1. Run: mps ssh-config --append --name dev
    2. Ensure ~/.ssh/config has: Include config.d/*
    3. In VS Code, use Remote-SSH to connect to 'mps-dev'

EOF
}
