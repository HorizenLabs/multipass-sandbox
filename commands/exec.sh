#!/usr/bin/env bash
# commands/exec.sh — mps exec [name] -- <command...>
#
# Execute a command inside a running sandbox. Everything after '--' is
# passed as the command. The working directory is automatically set to
# the mount target from instance metadata.
#
# Usage:
#   mps exec [name] -- <command...>
#   mps exec dev -- docker ps
#   mps exec -- ls -la
#
# Flags:
#   --help, -h          Show this help

cmd_exec() {
    local arg_name=""
    local -a user_cmd=()

    # ---- Parse arguments ----
    while [[ $# -gt 0 ]]; do
        case "$1" in
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
                if [[ -z "$arg_name" ]]; then
                    arg_name="$1"
                else
                    mps_die "Unexpected argument: $1 (use '--' before the command, see 'mps exec --help')"
                fi
                shift
                ;;
        esac
    done

    # ---- Validate command ----
    if [[ ${#user_cmd[@]} -eq 0 ]]; then
        mps_die "No command specified. Usage: mps exec [name] -- <command...>"
    fi

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

    # ---- Determine working directory from instance metadata ----
    local workdir=""
    local meta_file
    meta_file="$(mps_instance_meta "$name")"
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
    mps exec [name] -- <command...>

${_color_bold}Arguments:${_color_reset}
    name        Sandbox name (default: from .mps.env or 'default')
    command     Command to execute (everything after --)

${_color_bold}Flags:${_color_reset}
    --help, -h          Show this help

${_color_bold}Examples:${_color_reset}
    mps exec -- ls -la                  Run 'ls -la' in default sandbox
    mps exec dev -- docker ps           Run 'docker ps' in 'dev' sandbox
    mps exec dev -- bash -c "echo hi"   Run a shell command in 'dev'
    mps exec myproject -- make build    Run make in 'myproject'

EOF
}
