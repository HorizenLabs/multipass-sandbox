#!/usr/bin/env bash
# shellcheck disable=SC2154  # color vars defined in lib/common.sh
# commands/exec.sh — mps exec [--name <name>] -- <command...>
#
# Execute a command inside a running sandbox. Everything after '--' is
# passed as the command. The working directory is automatically set to
# the mount target from instance metadata.
#
# Usage:
#   mps exec [--name <name>] -- <command...>
#   mps exec --name dev -- docker ps
#   mps exec -- ls -la
#
# Flags:
#   --name, -n <name>   Sandbox name (default: auto-resolved from CWD)
#   --help, -h          Show this help

cmd_exec() {
    local arg_name=""
    local -a user_cmd=()

    # ---- Parse arguments ----
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name|-n)
                arg_name="${2:?--name requires a value}"
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
    if [[ -n "$arg_name" ]]; then
        instance_name="$(mps_instance_name "$arg_name")"
    else
        instance_name="$(mps_resolve_name "" "$(pwd)" "${MPS_CLOUD_INIT:-${MPS_DEFAULT_CLOUD_INIT:-base}}" "${MPS_PROFILE:-${MPS_DEFAULT_PROFILE:-standard}}")"
    fi
    mps_log_debug "Resolved instance name: ${instance_name}"

    # ---- Check instance is running ----
    local state
    state="$(mp_instance_state "$instance_name")"

    if [[ "$state" == "nonexistent" ]]; then
        mps_die "Instance '${instance_name}' does not exist. Create it with: mps up --name $(mps_short_name "$instance_name")"
    fi

    if [[ "$state" != "Running" ]]; then
        mps_die "Instance '${instance_name}' is not running (state: ${state}). Start it with: mps up --name $(mps_short_name "$instance_name")"
    fi

    # ---- Determine working directory from instance metadata ----
    local workdir=""
    local meta_file
    meta_file="$(mps_instance_meta "$(mps_short_name "$instance_name")")"
    if [[ -f "$meta_file" ]]; then
        # shellcheck disable=SC1090
        workdir="$(source "$meta_file" && echo "${MPS_MOUNT_TARGET:-}")"
        if [[ -n "$workdir" ]]; then
            mps_log_debug "Using mount target as workdir: ${workdir}"
        fi
    fi

    # ---- Execute command ----
    mps_log_debug "Executing in '${instance_name}' (workdir: ${workdir:-<default>}): ${user_cmd[*]}"
    mp_exec "$instance_name" "$workdir" "${user_cmd[@]}"
}

_exec_usage() {
    cat <<EOF
${_color_bold}mps exec${_color_reset} — Execute a command in a sandbox

${_color_bold}Usage:${_color_reset}
    mps exec [flags] -- <command...>

${_color_bold}Arguments:${_color_reset}
    command     Command to execute (everything after --)

${_color_bold}Flags:${_color_reset}
    --name, -n <name>   Sandbox name (default: auto-resolved from CWD)
    --help, -h          Show this help

${_color_bold}Examples:${_color_reset}
    mps exec -- ls -la                      Run 'ls -la' in sandbox for current directory
    mps exec --name dev -- docker ps        Run 'docker ps' in 'dev' sandbox
    mps exec --name dev -- bash -c "echo hi"   Run a shell command in 'dev'
    mps exec --name myproject -- make build    Run make in 'myproject'

EOF
}
