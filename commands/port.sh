#!/usr/bin/env bash
# shellcheck disable=SC2154  # color vars defined in lib/common.sh
# commands/port.sh — mps port [forward|list]

_port_usage() {
    cat <<EOF
${_color_bold}Usage:${_color_reset} mps port <subcommand> [options]

${_color_bold}Subcommands:${_color_reset}
    forward <name> <host>:<guest>    Forward a port from host to sandbox
    list [name]                      List active port forwards

${_color_bold}Options:${_color_reset}
    --privileged                     Allow binding to privileged ports (< 1024) via sudo
    --help, -h                       Show this help message

${_color_bold}Examples:${_color_reset}
    mps port forward dev 3000:3000
    mps port forward dev 8080:80
    mps port forward --privileged dev 80:80   # Binds privileged port via sudo
    mps port list
    mps port list dev
EOF
}

cmd_port() {
    local subcmd=""
    local -a args=()

    if [[ $# -eq 0 ]]; then
        _port_usage
        exit 1
    fi

    subcmd="$1"
    shift
    args=("$@")

    case "$subcmd" in
        forward) _port_forward ${args[@]+"${args[@]}"} ;;
        list)    _port_list ${args[@]+"${args[@]}"} ;;
        --help|-h) _port_usage ;;
        *)
            mps_log_error "Unknown port subcommand: '$subcmd'"
            _port_usage
            exit 1
            ;;
    esac
}

# ---------- port forward ----------

_port_forward() {
    local name=""
    local port_spec=""
    local privileged=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --privileged) privileged="--privileged"; shift ;;
            --help|-h) _port_usage; exit 0 ;;
            -*)        mps_log_error "Unknown option: $1"; exit 1 ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"
                elif [[ -z "$port_spec" ]]; then
                    port_spec="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$name" || -z "$port_spec" ]]; then
        mps_die "Usage: mps port forward <name> <host-port>:<guest-port>"
    fi

    # Parse port spec
    local host_port="${port_spec%%:*}"
    local guest_port="${port_spec#*:}"

    if [[ -z "$host_port" || -z "$guest_port" ]]; then
        mps_die "Invalid port spec: '$port_spec'. Expected format: <host-port>:<guest-port>"
    fi

    # Validate ports are numbers
    if [[ ! "$host_port" =~ ^[0-9]+$ ]] || [[ ! "$guest_port" =~ ^[0-9]+$ ]]; then
        mps_die "Ports must be numbers. Got: host=$host_port, guest=$guest_port"
    fi

    local instance_name
    instance_name="$(mps_resolve_instance_name "$name")"

    # Check instance is running
    local state
    state="$(mp_instance_state "$instance_name")"
    if [[ "$state" != "Running" ]]; then
        mps_die "Instance '$name' is not running (state: $state). Start it with: mps up $name"
    fi

    mps_log_info "Forwarding localhost:${host_port} → ${instance_name}:${guest_port}..."

    if ! mps_forward_port "$instance_name" "$name" "${host_port}:${guest_port}" "$privileged"; then
        mps_die "Failed to establish port forward"
    fi

    mps_log_info "Port forward active: localhost:${host_port} → ${instance_name}:${guest_port}"
}

# ---------- port list ----------

_port_list() {
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h) _port_usage; exit 0 ;;
            -*)        mps_log_error "Unknown option: $1"; exit 1 ;;
            *)         name="$1"; shift ;;
        esac
    done

    local state_dir
    state_dir="$(mps_state_dir)"

    local found=false

    printf "${_color_bold}%-20s %-12s %-12s %-8s %s${_color_reset}\n" \
        "SANDBOX" "HOST PORT" "GUEST PORT" "PID" "STATUS"

    local ports_file
    for ports_file in "$state_dir"/*.ports.json; do
        [[ -f "$ports_file" ]] || continue

        local sandbox_name
        sandbox_name="$(basename "$ports_file" .ports.json)"

        # If filtering by name, skip non-matching
        if [[ -n "$name" && "$sandbox_name" != "$name" ]]; then
            continue
        fi

        local entry
        while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            local host_port="" guest_port="" pid="" use_sudo=false
            host_port="$(echo "$entry" | jq -r '.key')"
            guest_port="$(echo "$entry" | jq -r '.value.guest_port')"
            pid="$(echo "$entry" | jq -r '.value.pid')"
            local sudo_val=""
            sudo_val="$(echo "$entry" | jq -r '.value.sudo')"
            [[ "$sudo_val" == "true" ]] && use_sudo=true
            local status
            if [[ "$use_sudo" == "true" ]]; then
                if sudo kill -0 "$pid" 2>/dev/null; then
                    status="${_color_green}active${_color_reset}"
                else
                    status="${_color_red}dead${_color_reset}"
                fi
            elif kill -0 "$pid" 2>/dev/null; then
                status="${_color_green}active${_color_reset}"
            else
                status="${_color_red}dead${_color_reset}"
            fi
            printf "%-20s %-12s %-12s %-8s %b\n" \
                "$sandbox_name" "$host_port" "$guest_port" "${pid:-—}" "$status"
            found=true
        done < <(jq -c 'to_entries[]' "$ports_file" 2>/dev/null)
    done

    if [[ "$found" == "false" ]]; then
        echo "No active port forwards."
    fi
}
