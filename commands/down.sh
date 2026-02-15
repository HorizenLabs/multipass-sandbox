#!/usr/bin/env bash
# shellcheck disable=SC2154  # color vars defined in lib/common.sh
# commands/down.sh — mps down [--name <name>]
#
# Stop a running sandbox. If already stopped, prints a message and returns.
#
# Usage:
#   mps down [--name <name>]
#   mps down --force --name myproject
#
# Flags:
#   --name, -n <name>   Sandbox name (default: auto-resolved from CWD)
#   --force             Force-stop the instance (immediate shutdown)
#   --help, -h          Show this help

cmd_down() {
    local arg_name=""
    local arg_force=false

    # ---- Parse arguments ----
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name|-n)
                arg_name="${2:?--name requires a value}"
                shift 2
                ;;
            --force|-f)
                arg_force=true
                shift
                ;;
            --help|-h)
                _down_usage
                return 0
                ;;
            -*)
                mps_die "Unknown flag: $1 (see 'mps down --help')"
                ;;
            *)
                mps_die "Unexpected argument: $1 (see 'mps down --help')"
                ;;
        esac
    done

    # ---- Resolve instance name ----
    local instance_name
    instance_name="$(mps_resolve_instance_name "$arg_name")"

    # ---- Check instance exists ----
    mps_require_exists "$instance_name" "Nothing to stop."

    # ---- Check current state ----
    local state
    state="$(mp_instance_state "$instance_name")"
    mps_log_debug "Instance state: ${state}"

    if [[ "$state" == "Stopped" ]]; then
        mps_log_info "Instance '${instance_name}' is already stopped."
        return 0
    fi

    if [[ "$state" != "Running" && "$state" != "Suspended" ]]; then
        mps_die "Instance '${instance_name}' is in unexpected state: ${state}"
    fi

    # ---- Kill port forwards ----
    local short_name
    short_name="$(mps_short_name "$instance_name")"
    mps_reset_port_forwards "$instance_name" "$short_name"

    # ---- Stop ----
    mp_stop "$instance_name" "$arg_force"

    mps_log_info "Sandbox '${short_name}' stopped."
}

_down_usage() {
    cat <<EOF
${_color_bold}mps down${_color_reset} — Stop a running sandbox

${_color_bold}Usage:${_color_reset}
    mps down [flags]

${_color_bold}Flags:${_color_reset}
    --name, -n <name>   Sandbox name (default: auto-resolved from CWD)
    --force, -f         Force-stop the instance (immediate shutdown)
    --help, -h          Show this help

${_color_bold}Examples:${_color_reset}
    mps down                        Stop the sandbox for the current directory
    mps down --name myproject       Stop 'myproject' sandbox
    mps down --force --name dev     Force-stop 'dev' sandbox immediately

EOF
}
