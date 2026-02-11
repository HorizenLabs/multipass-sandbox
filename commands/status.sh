#!/usr/bin/env bash
# commands/status.sh — mps status [name]
#
# Show detailed status of a sandbox including resources, image,
# mounts, and Docker availability.
#
# Usage:
#   mps status [name]
#   mps status --json myproject
#
# Flags:
#   --json              Output raw JSON from multipass info
#   --help, -h          Show this help

cmd_status() {
    local arg_name=""
    local arg_json=false

    # ---- Parse arguments ----
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                arg_json=true
                shift
                ;;
            --help|-h)
                _status_usage
                return 0
                ;;
            -*)
                mps_die "Unknown flag: $1 (see 'mps status --help')"
                ;;
            *)
                if [[ -z "$arg_name" ]]; then
                    arg_name="$1"
                else
                    mps_die "Unexpected argument: $1 (see 'mps status --help')"
                fi
                shift
                ;;
        esac
    done

    # ---- Resolve instance name ----
    local name
    name="$(mps_resolve_name "$arg_name")"
    mps_validate_name "$name"

    local instance_name
    instance_name="$(mps_instance_name "$name")"
    mps_log_debug "Resolved instance name: ${instance_name}"

    # ---- Check instance exists ----
    if ! mp_instance_exists "$instance_name"; then
        mps_die "Instance '${instance_name}' does not exist. Create it with: mps up ${name}"
    fi

    # ---- Fetch info ----
    local raw
    raw="$(mp_info "$instance_name")"

    # ---- JSON output mode ----
    if [[ "$arg_json" == "true" ]]; then
        echo "$raw"
        return 0
    fi

    # ---- Parse fields ----
    local info_base=".info[\"${instance_name}\"]"

    local state
    state="$(echo "$raw" | jq -r "${info_base}.state // \"Unknown\"")"

    local ipv4
    ipv4="$(echo "$raw" | jq -r "${info_base}.ipv4[0] // empty")"

    local cpus
    cpus="$(echo "$raw" | jq -r "${info_base}.cpus // empty")"

    local memory_used
    memory_used="$(echo "$raw" | jq -r "${info_base}.memory.used // empty")"

    local memory_total
    memory_total="$(echo "$raw" | jq -r "${info_base}.memory.total // empty")"

    local disk_used
    disk_used="$(echo "$raw" | jq -r "${info_base}.disk.used // empty")"

    local disk_total
    disk_total="$(echo "$raw" | jq -r "${info_base}.disk.total // empty")"

    local image
    image="$(echo "$raw" | jq -r "${info_base}.image_release // empty")"

    local image_hash
    image_hash="$(echo "$raw" | jq -r "${info_base}.image_hash // empty")"

    # ---- Format state with color ----
    local state_display
    case "$state" in
        Running)
            state_display="${_color_green}${state}${_color_reset}"
            ;;
        Stopped)
            state_display="${_color_red}${state}${_color_reset}"
            ;;
        *)
            state_display="${_color_yellow}${state}${_color_reset}"
            ;;
    esac

    # ---- Format human-readable sizes ----
    local memory_display=""
    if [[ -n "$memory_used" && -n "$memory_total" ]]; then
        memory_display="$(_status_human_bytes "$memory_used") / $(_status_human_bytes "$memory_total")"
    fi

    local disk_display=""
    if [[ -n "$disk_used" && -n "$disk_total" ]]; then
        disk_display="$(_status_human_bytes "$disk_used") / $(_status_human_bytes "$disk_total")"
    fi

    # ---- Display ----
    echo ""
    printf "  ${_color_bold}%-16s${_color_reset} %s\n" "Name:" "$name"
    printf "  ${_color_bold}%-16s${_color_reset} %b\n" "State:" "$state_display"

    if [[ -n "$ipv4" ]]; then
        printf "  ${_color_bold}%-16s${_color_reset} %s\n" "IPv4:" "$ipv4"
    fi

    echo ""

    if [[ -n "$cpus" ]]; then
        printf "  ${_color_bold}%-16s${_color_reset} %s\n" "CPUs:" "$cpus"
    fi

    if [[ -n "$memory_display" ]]; then
        printf "  ${_color_bold}%-16s${_color_reset} %s\n" "Memory:" "$memory_display"
    fi

    if [[ -n "$disk_display" ]]; then
        printf "  ${_color_bold}%-16s${_color_reset} %s\n" "Disk:" "$disk_display"
    fi

    echo ""

    if [[ -n "$image" ]]; then
        local image_info="$image"
        if [[ -n "$image_hash" ]]; then
            image_info="${image} (${image_hash:0:12})"
        fi
        printf "  ${_color_bold}%-16s${_color_reset} %s\n" "Image:" "$image_info"
    fi

    # ---- Mounts ----
    local mounts
    mounts="$(echo "$raw" | jq -r "${info_base}.mounts // empty")"

    if [[ -n "$mounts" && "$mounts" != "null" && "$mounts" != "{}" ]]; then
        printf "  ${_color_bold}%-16s${_color_reset}" "Mounts:"
        local first=true
        echo "$mounts" | jq -r 'to_entries[] | "\(.value.source_path) => \(.key)"' | \
        while IFS= read -r mount_line; do
            if [[ "$first" == "true" ]]; then
                printf " %s\n" "$mount_line"
                first=false
            else
                printf "  %-16s %s\n" "" "$mount_line"
            fi
        done
    fi

    # ---- Docker status (only if running) ----
    if [[ "$state" == "Running" ]]; then
        local docker_version
        docker_version="$(mp_docker_status "$instance_name" 2>/dev/null)" || true

        echo ""
        if [[ -n "$docker_version" && "$docker_version" != "not running" ]]; then
            printf "  ${_color_bold}%-16s${_color_reset} %s (%s)\n" "Docker:" "${_color_green}running${_color_reset}" "$docker_version"
        else
            printf "  ${_color_bold}%-16s${_color_reset} %b\n" "Docker:" "${_color_yellow}not available${_color_reset}"
        fi
    fi

    echo ""
}

# Convert bytes to human-readable format (e.g., 1073741824 -> 1.0G)
_status_human_bytes() {
    local bytes="$1"

    # Handle non-numeric or empty input
    if [[ -z "$bytes" || ! "$bytes" =~ ^[0-9]+$ ]]; then
        echo "$bytes"
        return
    fi

    if [[ "$bytes" -ge 1073741824 ]]; then
        # GiB
        local gib
        gib="$(awk "BEGIN { printf \"%.1f\", ${bytes} / 1073741824 }")"
        echo "${gib}GiB"
    elif [[ "$bytes" -ge 1048576 ]]; then
        # MiB
        local mib
        mib="$(awk "BEGIN { printf \"%.1f\", ${bytes} / 1048576 }")"
        echo "${mib}MiB"
    elif [[ "$bytes" -ge 1024 ]]; then
        # KiB
        local kib
        kib="$(awk "BEGIN { printf \"%.1f\", ${bytes} / 1024 }")"
        echo "${kib}KiB"
    else
        echo "${bytes}B"
    fi
}

_status_usage() {
    cat <<EOF
${_color_bold}mps status${_color_reset} — Show detailed sandbox status

${_color_bold}Usage:${_color_reset}
    mps status [name] [flags]

${_color_bold}Arguments:${_color_reset}
    name        Sandbox name (default: from .mps.env or 'default')

${_color_bold}Flags:${_color_reset}
    --json              Output raw JSON
    --help, -h          Show this help

${_color_bold}Examples:${_color_reset}
    mps status              Show status of default sandbox
    mps status dev          Show status of 'dev' sandbox
    mps status --json dev   Output raw JSON for scripting

EOF
}
