#!/usr/bin/env bash
# commands/ssh-config.sh — mps ssh-config [name]
#
# Generate an SSH config block for a running sandbox, suitable for
# VS Code Remote-SSH and other SSH clients.
#
# Usage:
#   mps ssh-config [name]
#   mps ssh-config --append myproject
#   mps ssh-config --print --append myproject
#
# Flags:
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
                if [[ -z "$arg_name" ]]; then
                    arg_name="$1"
                else
                    mps_die "Unexpected argument: $1 (see 'mps ssh-config --help')"
                fi
                shift
                ;;
        esac
    done

    # Default to --print if neither flag specified
    if [[ "$arg_print" == "false" && "$arg_append" == "false" ]]; then
        arg_print=true
    fi

    # ---- Resolve instance name ----
    local name
    name="$(mps_resolve_name "$arg_name")"
    mps_validate_name "$name"

    local instance_name
    instance_name="$(mps_instance_name "$name")"
    mps_log_debug "Resolved instance name: ${instance_name}"

    # ---- Check instance exists and is running ----
    local state
    state="$(mp_instance_state "$instance_name")"

    if [[ "$state" == "nonexistent" ]]; then
        mps_die "Instance '${instance_name}' does not exist. Create it with: mps up ${name}"
    fi

    if [[ "$state" != "Running" ]]; then
        mps_die "Instance '${instance_name}' is not running (state: ${state}). Start it with: mps up ${name}"
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
    mps ssh-config [name] [flags]

${_color_bold}Arguments:${_color_reset}
    name        Sandbox name (default: from .mps.env or 'default')

${_color_bold}Flags:${_color_reset}
    --print             Print SSH config to stdout (default)
    --append            Write config to ~/.ssh/config.d/mps-<name>
    --help, -h          Show this help

Both --print and --append can be used together.

${_color_bold}Examples:${_color_reset}
    mps ssh-config dev              Print SSH config for 'dev'
    mps ssh-config --append dev     Write to ~/.ssh/config.d/mps-dev
    mps ssh-config --print --append dev   Print and write config

${_color_bold}VS Code Integration:${_color_reset}
    1. Run: mps ssh-config --append dev
    2. Ensure ~/.ssh/config has: Include config.d/*
    3. In VS Code, use Remote-SSH to connect to 'mps-dev'

EOF
}
