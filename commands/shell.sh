#!/usr/bin/env bash
# commands/shell.sh — mps shell [name]
#
# Open an interactive shell inside a running sandbox. Optionally set the
# working directory inside the VM.
#
# Usage:
#   mps shell [name]
#   mps shell --workdir /home/ubuntu/project myproject
#
# Flags:
#   --workdir <path>    Working directory inside the VM
#   --help, -h          Show this help

cmd_shell() {
    local arg_name=""
    local arg_workdir=""

    # ---- Parse arguments ----
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --workdir|-w)
                arg_workdir="${2:?--workdir requires a value}"
                shift 2
                ;;
            --help|-h)
                _shell_usage
                return 0
                ;;
            -*)
                mps_die "Unknown flag: $1 (see 'mps shell --help')"
                ;;
            *)
                if [[ -z "$arg_name" ]]; then
                    arg_name="$1"
                else
                    mps_die "Unexpected argument: $1 (see 'mps shell --help')"
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

    # ---- Check instance is running ----
    local state
    state="$(mp_instance_state "$instance_name")"

    if [[ "$state" == "nonexistent" ]]; then
        mps_die "Instance '${instance_name}' does not exist. Create it with: mps up ${name}"
    fi

    if [[ "$state" != "Running" ]]; then
        mps_die "Instance '${instance_name}' is not running (state: ${state}). Start it with: mps up ${name}"
    fi

    # ---- Determine working directory ----
    local workdir="$arg_workdir"

    if [[ -z "$workdir" ]]; then
        # Try to load mount target from instance metadata
        local meta_file
        meta_file="$(mps_instance_meta "$name")"
        if [[ -f "$meta_file" ]]; then
            local mount_target=""
            # shellcheck disable=SC1090
            mount_target="$(source "$meta_file" && echo "${MPS_MOUNT_TARGET:-}")"
            if [[ -n "$mount_target" ]]; then
                workdir="$mount_target"
                mps_log_debug "Using mount target as workdir: ${workdir}"
            fi
        fi
    fi

    # ---- Open shell ----
    mps_log_debug "Opening shell in '${instance_name}' (workdir: ${workdir:-<default>})"
    mp_shell "$instance_name" "$workdir"
}

_shell_usage() {
    cat <<EOF
${_color_bold}mps shell${_color_reset} — Open an interactive shell in a sandbox

${_color_bold}Usage:${_color_reset}
    mps shell [name] [flags]

${_color_bold}Arguments:${_color_reset}
    name        Sandbox name (default: from .mps.env or 'default')

${_color_bold}Flags:${_color_reset}
    --workdir, -w <path>    Working directory inside the VM
                            (default: mount target from instance metadata)
    --help, -h              Show this help

${_color_bold}Examples:${_color_reset}
    mps shell                       Shell into default sandbox at mount dir
    mps shell dev                   Shell into 'dev' sandbox
    mps shell --workdir /tmp dev    Shell into 'dev' at /tmp

EOF
}
