#!/usr/bin/env bash
# shellcheck disable=SC2154  # color vars defined in lib/common.sh
# commands/shell.sh — mps shell [--name <name>]
#
# Open an interactive shell inside a running sandbox. Optionally set the
# working directory inside the VM.
#
# Usage:
#   mps shell [--name <name>]
#   mps shell --workdir /home/ubuntu/project --name myproject
#
# Flags:
#   --name, -n <name>   Sandbox name (default: auto-resolved from CWD)
#   --workdir <path>    Working directory inside the VM
#   --help, -h          Show this help

cmd_shell() {
    local arg_name=""
    local arg_workdir=""

    # ---- Parse arguments ----
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name|-n)
                arg_name="${2:?--name requires a value}"
                shift 2
                ;;
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
                mps_die "Unexpected argument: $1 (see 'mps shell --help')"
                ;;
        esac
    done

    # ---- Resolve instance name ----
    local instance_name
    instance_name="$(mps_resolve_instance_name "$arg_name")"

    # ---- Check instance is running ----
    mps_require_running "$instance_name"

    # ---- Ensure port forwards are alive ----
    local short_name
    short_name="$(mps_short_name "$instance_name")"
    mps_auto_forward_ports "$instance_name" "$short_name" "Re-established"

    # ---- Determine working directory ----
    local workdir
    workdir="$(mps_resolve_workdir "$instance_name" "$arg_workdir")"

    # ---- Open shell ----
    mps_log_debug "Opening shell in '${instance_name}' (workdir: ${workdir:-<default>})"
    mp_shell "$instance_name" "$workdir"
}

_shell_usage() {
    cat <<EOF
${_color_bold}mps shell${_color_reset} — Open an interactive shell in a sandbox

${_color_bold}Usage:${_color_reset}
    mps shell [flags]

${_color_bold}Flags:${_color_reset}
    --name, -n <name>       Sandbox name (default: auto-resolved from CWD)
    --workdir, -w <path>    Working directory inside the VM
                            (default: mount target from instance metadata)
    --help, -h              Show this help

${_color_bold}Examples:${_color_reset}
    mps shell                               Shell into sandbox for current directory
    mps shell --name dev                    Shell into 'dev' sandbox
    mps shell --workdir /tmp --name dev     Shell into 'dev' at /tmp

EOF
}
