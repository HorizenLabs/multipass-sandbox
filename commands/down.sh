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
    local short_name
    short_name="$(mps_short_name "$instance_name")"
    local state
    state="$(mp_instance_state "$instance_name")"
    mps_log_debug "Instance state: ${state}"

    if [[ "$state" == "Stopped" ]]; then
        mps_log_info "Instance '${short_name}' is already stopped."
        return 0
    fi

    if [[ "$state" != "Running" && "$state" != "Suspended" ]]; then
        mps_die "Instance '${short_name}' is in unexpected state: ${state}"
    fi

    # ---- Kill port forwards ----
    mps_reset_port_forwards "$instance_name" "$short_name"

    # ---- Clean up adhoc mounts ----
    _down_cleanup_adhoc_mounts "$instance_name" "$short_name"

    # ---- Stop ----
    mp_stop "$instance_name" "$arg_force"

    mps_log_info "Sandbox '${short_name}' stopped."
}

# Remove adhoc (session-only) mounts before stopping.
# Persistent mounts = auto-mount (workdir) + MPS_MOUNTS config.
# Anything else in Multipass is adhoc and gets unmounted.
_down_cleanup_adhoc_mounts() {
    local instance_name="$1"
    local short_name="$2"

    # Get current mounts from Multipass
    local mount_info=""
    mount_info="$(mp_get_mounts "$instance_name")"

    if [[ -z "$mount_info" ]]; then
        return 0
    fi

    # Resolve persistent mounts for this instance
    local persistent_mounts
    persistent_mounts="$(_mps_resolve_project_mounts "$short_name")"

    # Build a list of persistent guest paths for matching
    local -a persistent_targets=()
    if [[ -n "$persistent_mounts" ]]; then
        local pmount
        for pmount in $persistent_mounts; do
            persistent_targets+=("${pmount#*:}")
        done
    fi

    # Iterate over current Multipass mounts and unmount adhoc ones
    local guest_path
    while IFS= read -r guest_path; do
        [[ -z "$guest_path" ]] && continue
        local is_persistent=false
        local ptgt
        for ptgt in ${persistent_targets[@]+"${persistent_targets[@]}"}; do
            if [[ "$guest_path" == "$ptgt" ]]; then
                is_persistent=true
                break
            fi
        done
        if [[ "$is_persistent" == "false" ]]; then
            mps_log_debug "Unmounting adhoc mount: ${guest_path}"
            mp_umount "$instance_name" "$guest_path"
        fi
    done < <(echo "$mount_info" | jq -r 'keys[]' 2>/dev/null)
}

_complete_down() {
    case "${1:-}" in
        flags)       echo "--name -n --force -f --help -h" ;;
        flag-values) case "${2:-}" in --name|-n) echo "__instances__" ;; esac ;;
    esac
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
