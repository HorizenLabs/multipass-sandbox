#!/usr/bin/env bash
# commands/down.sh — mps down [name]
#
# Stop a running sandbox. If already stopped, prints a message and returns.
#
# Usage:
#   mps down [name]
#   mps down --force myproject
#
# Flags:
#   --force             Force-stop the instance (immediate shutdown)
#   --help, -h          Show this help

cmd_down() {
    local arg_name=""
    local arg_force=false

    # ---- Parse arguments ----
    while [[ $# -gt 0 ]]; do
        case "$1" in
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
                if [[ -z "$arg_name" ]]; then
                    arg_name="$1"
                else
                    mps_die "Unexpected argument: $1 (see 'mps down --help')"
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
        mps_die "Instance '${instance_name}' does not exist. Nothing to stop."
    fi

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

    # ---- Stop ----
    mp_stop "$instance_name" "$arg_force"

    mps_log_info "Sandbox '${name}' stopped."
}

_down_usage() {
    cat <<EOF
${_color_bold}mps down${_color_reset} — Stop a running sandbox

${_color_bold}Usage:${_color_reset}
    mps down [name] [flags]

${_color_bold}Arguments:${_color_reset}
    name        Sandbox name (default: from .mps.env or 'default')

${_color_bold}Flags:${_color_reset}
    --force, -f         Force-stop the instance (immediate shutdown)
    --help, -h          Show this help

${_color_bold}Examples:${_color_reset}
    mps down                Stop the default sandbox gracefully
    mps down myproject      Stop 'myproject' sandbox
    mps down --force dev    Force-stop 'dev' sandbox immediately

EOF
}
