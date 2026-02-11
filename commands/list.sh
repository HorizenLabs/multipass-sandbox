#!/usr/bin/env bash
# shellcheck disable=SC2154  # color vars defined in lib/common.sh
# commands/list.sh — mps list
#
# List all sandboxes managed by mps. Displays a formatted table with
# name, state, IPv4 address, and image.
#
# Usage:
#   mps list
#   mps list --json
#
# Flags:
#   --json              Output raw JSON from multipass
#   --help, -h          Show this help

cmd_list() {
    local arg_json=false

    # ---- Parse arguments ----
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                arg_json=true
                shift
                ;;
            --help|-h)
                _list_usage
                return 0
                ;;
            -*)
                mps_die "Unknown flag: $1 (see 'mps list --help')"
                ;;
            *)
                mps_die "Unexpected argument: $1 (see 'mps list --help')"
                ;;
        esac
    done

    # ---- Fetch instance list ----
    local raw
    raw="$(mp_list_all)"

    # ---- JSON output mode ----
    if [[ "$arg_json" == "true" ]]; then
        echo "$raw"
        return 0
    fi

    # ---- Check for empty list ----
    local count
    count="$(echo "$raw" | jq 'length')"

    if [[ "$count" -eq 0 ]]; then
        echo "No sandboxes found."
        return 0
    fi

    # ---- Formatted table output ----
    local prefix="${MPS_INSTANCE_PREFIX:-mps}"

    # Header
    printf "${_color_bold}%-16s %-12s %-16s %s${_color_reset}\n" \
        "NAME" "STATE" "IPV4" "IMAGE"

    # Rows
    echo "$raw" | jq -r --arg prefix "${prefix}-" \
        '.[] | [.name, .state, (.ipv4 // [""])[0], .release] | @tsv' | \
    while IFS=$'\t' read -r full_name state ipv4 image; do
        # Strip the mps- prefix for display
        local short_name="${full_name#${prefix}-}"

        # Use em dash for missing IP
        if [[ -z "$ipv4" ]]; then
            ipv4="\u2014"
        fi

        # Color the state
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

        # printf %b interprets escape sequences for colors and em dash
        printf "%-16s %-12b %-16b %s\n" \
            "$short_name" "$state_display" "$ipv4" "$image"
    done
}

_list_usage() {
    cat <<EOF
${_color_bold}mps list${_color_reset} — List all sandboxes

${_color_bold}Usage:${_color_reset}
    mps list [flags]

${_color_bold}Flags:${_color_reset}
    --json              Output raw JSON
    --help, -h          Show this help

${_color_bold}Examples:${_color_reset}
    mps list            Show formatted table of all sandboxes
    mps list --json     Output JSON for scripting

EOF
}
