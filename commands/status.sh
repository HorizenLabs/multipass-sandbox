#!/usr/bin/env bash
# shellcheck disable=SC2154  # color vars defined in lib/common.sh
# commands/status.sh — mps status [--name <name>]
#
# Show detailed status of a sandbox including resources, image,
# mounts, and Docker availability.
#
# Usage:
#   mps status [--name <name>]
#   mps status --json --name myproject
#
# Flags:
#   --name, -n <name>   Sandbox name (default: auto-resolved from CWD)
#   --json              Output raw JSON from multipass info
#   --help, -h          Show this help

cmd_status() {
    local arg_name=""
    local arg_json=false

    # ---- Parse arguments ----
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name|-n)
                arg_name="${2:?--name requires a value}"
                shift 2
                ;;
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
                mps_die "Unexpected argument: $1 (see 'mps status --help')"
                ;;
        esac
    done

    # ---- Resolve instance name ----
    local instance_name
    instance_name="$(mps_resolve_instance_name "$arg_name")"

    # ---- Check instance exists ----
    mps_require_exists "$instance_name"

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
    printf "  ${_color_bold}%-16s${_color_reset} %s\n" "Name:" "$(mps_short_name "$instance_name")"
    printf "  ${_color_bold}%-16s${_color_reset} %b\n" "State:" "$state_display"

    if [[ -n "$ipv4" ]]; then
        printf "  ${_color_bold}%-16s${_color_reset} %s\n" "IPv4:" "$ipv4"
    fi

    echo ""

    if [[ -n "$cpus" ]]; then
        printf "  ${_color_bold}%-16s${_color_reset} %s\n" "vCPUs:" "$cpus"
    fi

    if [[ -n "$memory_display" ]]; then
        printf "  ${_color_bold}%-16s${_color_reset} %s\n" "Memory:" "$memory_display"
    fi

    if [[ -n "$disk_display" ]]; then
        printf "  ${_color_bold}%-16s${_color_reset} %s\n" "Disk:" "$disk_display"
    fi

    echo ""

    # ---- Short name (used by staleness + mounts) ----
    local short_name
    short_name="$(mps_short_name "$instance_name")"

    if [[ -n "$image" ]]; then
        local image_info="$image"
        if [[ -n "$image_hash" ]]; then
            image_info="${image} (${image_hash:0:12})"
        fi
        printf "  ${_color_bold}%-16s${_color_reset} %s\n" "Image:" "$image_info"
    fi

    # ---- Image Status ----
    local instance_staleness=""
    instance_staleness="$(_mps_check_instance_staleness "$short_name" 2>/dev/null)" || true
    case "$instance_staleness" in
        up-to-date)
            printf "  ${_color_bold}%-16s${_color_reset} %b\n" "Image Status:" "${_color_green}up-to-date${_color_reset}"
            ;;
        stale:manifest)
            printf "  ${_color_bold}%-16s${_color_reset} %b\n" "Image Status:" "${_color_yellow}stale (rebuild available, not yet pulled)${_color_reset}"
            ;;
        stale)
            printf "  ${_color_bold}%-16s${_color_reset} %b\n" "Image Status:" "${_color_yellow}stale (rebuild available)${_color_reset}"
            ;;
        update:manifest:*)
            local new_ver="${instance_staleness#update:manifest:}"
            printf "  ${_color_bold}%-16s${_color_reset} %b\n" "Image Status:" "${_color_yellow}update available (${new_ver}, not yet pulled)${_color_reset}"
            ;;
        update:*)
            local new_ver="${instance_staleness#update:}"
            printf "  ${_color_bold}%-16s${_color_reset} %b\n" "Image Status:" "${_color_yellow}update available (${new_ver})${_color_reset}"
            ;;
    esac

    # ---- Mounts ----
    local mounts
    mounts="$(echo "$raw" | jq -r "${info_base}.mounts // empty")"

    if [[ -n "$mounts" && "$mounts" != "null" && "$mounts" != "{}" ]]; then
        local workdir=""
        local meta_file
        meta_file="$(mps_instance_meta "$short_name")"
        if [[ -f "$meta_file" ]]; then
            workdir="$(_mps_read_meta_json "$meta_file" '.workdir')"
        fi

        local persistent_mounts=""
        local -a config_targets=()
        if [[ "$state" == "Running" ]]; then
            persistent_mounts="$(_mps_resolve_project_mounts "$short_name")"
            if [[ -n "$persistent_mounts" ]]; then
                local pmount
                for pmount in $persistent_mounts; do
                    local ptgt="${pmount#*:}"
                    if [[ "$ptgt" != "$workdir" ]]; then
                        config_targets+=("$ptgt")
                    fi
                done
            fi
        fi

        printf "  ${_color_bold}%-16s${_color_reset}" "Mounts:"
        local first=true
        local guest_path
        while IFS= read -r guest_path; do
            [[ -z "$guest_path" ]] && continue
            local source_path
            source_path="$(echo "$mounts" | jq -r ".[\"${guest_path}\"].source_path // empty" 2>/dev/null)"
            local mount_line="${source_path} => ${guest_path}"

            # Derive origin annotation for running instances
            if [[ "$state" == "Running" ]]; then
                local origin="adhoc"
                if [[ -n "$workdir" && "$guest_path" == "$workdir" ]]; then
                    origin="auto"
                else
                    local ctgt
                    for ctgt in ${config_targets[@]+"${config_targets[@]}"}; do
                        if [[ "$guest_path" == "$ctgt" ]]; then
                            origin="config"
                            break
                        fi
                    done
                fi
                mount_line="${mount_line} (${origin})"
            fi

            if [[ "$first" == "true" ]]; then
                printf " %s\n" "$mount_line"
                first=false
            else
                printf "  %-16s %s\n" "" "$mount_line"
            fi
        done < <(echo "$mounts" | jq -r 'keys[]' 2>/dev/null)
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
        gib="$(awk -v b="$bytes" 'BEGIN { printf "%.1f", b / 1073741824 }')"
        echo "${gib}GiB"
    elif [[ "$bytes" -ge 1048576 ]]; then
        # MiB
        local mib
        mib="$(awk -v b="$bytes" 'BEGIN { printf "%.1f", b / 1048576 }')"
        echo "${mib}MiB"
    elif [[ "$bytes" -ge 1024 ]]; then
        # KiB
        local kib
        kib="$(awk -v b="$bytes" 'BEGIN { printf "%.1f", b / 1024 }')"
        echo "${kib}KiB"
    else
        echo "${bytes}B"
    fi
}

_complete_status() {
    case "${1:-}" in
        flags)       echo "--name -n --json --help -h" ;;
        flag-values) case "${2:-}" in --name|-n) echo "__instances__" ;; esac ;;
    esac
}

_status_usage() {
    cat <<EOF
${_color_bold}mps status${_color_reset} — Show detailed sandbox status

${_color_bold}Usage:${_color_reset}
    mps status [flags]

${_color_bold}Flags:${_color_reset}
    --name, -n <name>   Sandbox name (default: auto-resolved from CWD)
    --json              Output raw JSON
    --help, -h          Show this help

${_color_bold}Examples:${_color_reset}
    mps status                      Show status of sandbox for current directory
    mps status --name dev           Show status of 'dev' sandbox
    mps status --json --name dev    Output raw JSON for scripting

EOF
}
