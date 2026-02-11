#!/usr/bin/env bash
# commands/up.sh — mps up [name] [path]
#
# Ensure a sandbox is running. Creates it if it does not exist, starts it
# if stopped, or reports that it is already running.
#
# Usage:
#   mps up [name] [path]
#   mps up --cpus 8 --memory 8G myproject ~/code/proj
#
# Accepts all the same flags as 'mps create'. When the instance does not
# exist, they are passed through to cmd_create. When the instance is
# already created, resource flags are ignored (use 'mps create' to
# reconfigure).

cmd_up() {
    local arg_name=""
    local arg_path=""
    local arg_no_mount=false
    local -a original_args=("$@")
    local -a arg_extra_mounts=()

    # ---- Parse arguments (lightweight — just enough to resolve name/path) ----
    # We keep the original args intact so we can pass them through to cmd_create.
    local -a positionals=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --image|--cpus|--memory|--mem|--disk|--cloud-init|--profile|--mount|--port)
                # Flags with values — skip the value too
                if [[ "$1" == "--mount" ]]; then
                    arg_extra_mounts+=("${2:?--mount requires a value}")
                fi
                shift 2
                ;;
            --no-mount)
                arg_no_mount=true
                shift
                ;;
            --help|-h)
                _up_usage
                return 0
                ;;
            -*)
                # Unknown flags will be caught by cmd_create if we delegate
                shift
                ;;
            *)
                positionals+=("$1")
                shift
                ;;
        esac
    done

    # Extract name and path from positionals
    arg_name="${positionals[0]:-}"
    arg_path="${positionals[1]:-}"

    # ---- Resolve instance name ----
    local name
    name="$(mps_resolve_name "$arg_name")"
    mps_validate_name "$name"

    local instance_name
    instance_name="$(mps_instance_name "$name")"
    mps_log_debug "Resolved instance name: ${instance_name}"

    # ---- Check current state ----
    local state
    state="$(mp_instance_state "$instance_name")"
    mps_log_debug "Instance state: ${state}"

    case "$state" in
        nonexistent)
            mps_log_info "Instance '${instance_name}' does not exist. Creating..."
            # Delegate to cmd_create with all original arguments
            # shellcheck source=create.sh
            source "${MPS_ROOT}/commands/create.sh"
            cmd_create "${original_args[@]}"
            ;;

        Stopped)
            mps_log_info "Instance '${instance_name}' is stopped. Starting..."
            mp_start "$instance_name"

            # Re-establish mounts if needed
            _up_restore_mounts "$instance_name" "$arg_path" "$arg_no_mount"

            # Show IP
            _up_show_info "$name" "$instance_name"
            ;;

        Running)
            mps_log_info "Instance '${instance_name}' is already running."
            _up_show_info "$name" "$instance_name"
            ;;

        Suspended)
            mps_log_info "Instance '${instance_name}' is suspended. Starting..."
            mp_start "$instance_name"

            _up_restore_mounts "$instance_name" "$arg_path" "$arg_no_mount"

            _up_show_info "$name" "$instance_name"
            ;;

        *)
            mps_die "Instance '${instance_name}' is in unexpected state: ${state}"
            ;;
    esac
}

# Restore mounts after starting a stopped/suspended instance.
# Multipass native mounts persist across stop/start, but this handles
# cases where mounts were added or the instance was created with --no-mount
# and the user now wants mounts.
_up_restore_mounts() {
    local instance_name="$1"
    local arg_path="$2"
    local arg_no_mount="$3"

    if [[ "$arg_no_mount" == "true" ]]; then
        return 0
    fi

    # Resolve the primary mount
    mps_resolve_mount "$arg_path"

    if [[ -n "${MPS_MOUNT_SOURCE:-}" && -n "${MPS_MOUNT_TARGET:-}" ]]; then
        # Check if mount already exists by inspecting instance info
        local mount_info
        mount_info="$(mp_info "$instance_name" 2>/dev/null | jq -r ".info[\"${instance_name}\"].mounts // empty" 2>/dev/null)" || true

        if [[ -n "$mount_info" ]] && echo "$mount_info" | jq -e ".[\"${MPS_MOUNT_TARGET}\"]" &>/dev/null; then
            mps_log_debug "Mount at '${MPS_MOUNT_TARGET}' already present."
        else
            mps_log_info "Mounting project directory..."
            mp_mount "$MPS_MOUNT_SOURCE" "$instance_name" "$MPS_MOUNT_TARGET" || \
                mps_log_warn "Could not mount '${MPS_MOUNT_SOURCE}'. You can mount manually with: mps mount ${instance_name}"
        fi
    fi
}

# Print connection info after an instance is up.
_up_show_info() {
    local name="$1"
    local instance_name="$2"

    local ip=""
    ip="$(mp_ipv4 "$instance_name" 2>/dev/null)" || true

    echo ""
    printf "  %-14s %s\n" "Instance:" "$instance_name"
    if [[ -n "$ip" ]]; then
        printf "  %-14s %s\n" "IP:" "$ip"
    fi
    echo ""
    mps_log_info "Connect with: mps shell ${name}"
}

_up_usage() {
    cat <<EOF
${_color_bold}mps up${_color_reset} — Create (if needed) and start a sandbox

${_color_bold}Usage:${_color_reset}
    mps up [name] [path] [flags]

${_color_bold}Arguments:${_color_reset}
    name        Sandbox name (default: from .mps.env or 'default')
    path        Host directory to mount (default: current directory)

${_color_bold}Flags:${_color_reset}
    --image <image>         Ubuntu image (only used on create)
    --cpus <n>              CPU cores (only used on create)
    --memory <size>         Memory (only used on create)
    --disk <size>           Disk (only used on create)
    --cloud-init <name>     Cloud-init template (only used on create)
    --profile <name>        Resource profile (only used on create)
    --mount <src:dst>       Additional mount point (can be repeated)
    --port <host:guest>     Port forwarding rule (only used on create)
    --no-mount              Do not auto-mount the project directory
    --help, -h              Show this help

${_color_bold}Behavior:${_color_reset}
    If the instance does not exist, 'mps up' delegates to 'mps create'
    with all provided flags. If the instance is stopped, it starts it
    and re-establishes mounts. If already running, it prints the current
    status.

${_color_bold}Examples:${_color_reset}
    mps up                      Start or create default sandbox
    mps up myproject            Start or create 'myproject'
    mps up --profile heavy dev  Create 'dev' with heavy profile if new
    mps up dev ~/code/proj      Mount specific directory

EOF
}
