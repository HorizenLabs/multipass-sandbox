#!/usr/bin/env bash
# shellcheck disable=SC2154  # color vars defined in lib/common.sh
# commands/exec.sh — mps exec [--name <name>] [--workdir <path>] -- <command...>
#
# Execute a command inside a running sandbox. Everything after '--' is
# passed as the command. The working directory is automatically set to
# the mount target from instance metadata, or can be overridden with
# --workdir.
#
# Usage:
#   mps exec [--name <name>] -- <command...>
#   mps exec --workdir /tmp --name dev -- docker ps
#   mps exec -- ls -la
#
# Flags:
#   --name, -n <name>       Sandbox name (default: auto-resolved from CWD)
#   --workdir, -w <path>    Working directory inside the VM
#   --help, -h              Show this help

cmd_exec() {
    local arg_name=""
    local arg_workdir=""
    local -a user_cmd=()

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
            --)
                shift
                user_cmd=("$@")
                break
                ;;
            --help|-h)
                _exec_usage
                return 0
                ;;
            -*)
                mps_die "Unknown flag: $1 (see 'mps exec --help')"
                ;;
            *)
                mps_die "Unexpected argument: $1 (use '--' before the command, see 'mps exec --help')"
                ;;
        esac
    done

    # ---- Validate command ----
    if [[ ${#user_cmd[@]} -eq 0 ]]; then
        mps_die "No command specified. Usage: mps exec [--name <name>] -- <command...>"
    fi

    # ---- Resolve instance name ----
    local instance_name
    instance_name="$(mps_resolve_instance_name "$arg_name")"

    # ---- Check instance is running ----
    mps_require_running "$instance_name"

    # ---- Instance staleness check ----
    local short_name
    short_name="$(mps_short_name "$instance_name")"
    _mps_warn_instance_staleness "$short_name"

    # ---- Ensure port forwards are alive ----
    mps_auto_forward_ports "$instance_name" "$short_name" "Re-established"

    # ---- Determine working directory ----
    local workdir
    workdir="$(mps_resolve_workdir "$instance_name" "$arg_workdir")"

    # ---- Execute command ----
    mps_log_debug "Executing in '${instance_name}' (workdir: ${workdir:-<default>}): ${user_cmd[*]}"
    mp_exec "$instance_name" "$workdir" ${user_cmd[@]+"${user_cmd[@]}"}
}

_exec_usage() {
    cat <<EOF
${_color_bold}mps exec${_color_reset} — Execute a command in a sandbox

${_color_bold}Usage:${_color_reset}
    mps exec [flags] -- <command...>

${_color_bold}Arguments:${_color_reset}
    command     Command to execute (everything after --)

${_color_bold}Flags:${_color_reset}
    --name, -n <name>       Sandbox name (default: auto-resolved from CWD)
    --workdir, -w <path>    Working directory inside the VM
                            (default: mount target from instance metadata)
    --help, -h              Show this help

${_color_bold}Examples:${_color_reset}
    mps exec -- ls -la                      Run 'ls -la' in sandbox for current directory
    mps exec --name dev -- docker ps        Run 'docker ps' in 'dev' sandbox
    mps exec -w /tmp -- bash -c "echo hi"   Run a shell command at /tmp
    mps exec --name myproject -- make build    Run make in 'myproject'

EOF
}
