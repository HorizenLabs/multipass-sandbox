#!/usr/bin/env bash
# shellcheck disable=SC2154  # color vars defined in lib/common.sh
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
    local arg_cloud_init=""
    local -a original_args=("$@")

    # ---- Parse arguments (lightweight — just enough to resolve name/path) ----
    # We keep the original args intact so we can pass them through to cmd_create.
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name|-n)
                arg_name="${2:?--name requires a value}"
                shift 2
                ;;
            --cloud-init)
                arg_cloud_init="$2"
                shift 2
                ;;
            --image|--profile|--cpus|--memory|--mem|--disk|--mount|--port|--transfer)
                # Flags with values — skip the value too
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
                # Positional: path to mount
                if [[ -z "$arg_path" ]]; then
                    arg_path="$1"
                fi
                shift
                ;;
        esac
    done

    # ---- Resolve mount first (needed for auto-naming) ----
    if [[ "$arg_no_mount" == "true" ]]; then
        export MPS_NO_AUTOMOUNT=true
    fi
    mps_resolve_mount "$arg_path"

    # ---- Resolve instance name ----
    local effective_template="${arg_cloud_init:-${MPS_CLOUD_INIT:-${MPS_DEFAULT_CLOUD_INIT:-default}}}"

    local instance_name
    instance_name="$(mps_resolve_name "$arg_name" "${MPS_MOUNT_SOURCE:-}" "$effective_template")"
    mps_log_debug "Resolved instance name: ${instance_name}"

    # ---- Check current state ----
    local short_name
    short_name="$(mps_short_name "$instance_name")"
    local state
    state="$(mp_instance_state "$instance_name")"
    mps_log_debug "Instance state: ${state}"

    case "$state" in
        nonexistent)
            mps_log_info "Instance '${short_name}' does not exist. Creating..."
            # Delegate to cmd_create with all original arguments
            # shellcheck source=create.sh
            source "${MPS_ROOT}/commands/create.sh"
            cmd_create ${original_args[@]+"${original_args[@]}"}
            ;;

        Stopped)
            mps_log_info "Instance '${short_name}' is stopped. Starting..."
            mp_start "$instance_name"

            # Re-establish mounts if needed
            _up_restore_mounts "$instance_name" "$arg_path" "$arg_no_mount"

            # Re-establish port forwards (kill stale, then auto-forward)
            mps_reset_port_forwards "$instance_name" "$short_name" --auto-forward

            # Staleness checks (image + instance)
            _up_staleness_checks "$short_name"

            _up_show_info "$instance_name"
            ;;

        Running)
            mps_log_info "Instance '${short_name}' is already running."

            # Staleness checks (image + instance)
            _up_staleness_checks "$short_name"

            _up_show_info "$instance_name"
            ;;

        Suspended)
            mps_log_info "Instance '${short_name}' is suspended. Starting..."
            mp_start "$instance_name"

            _up_restore_mounts "$instance_name" "$arg_path" "$arg_no_mount"

            # Re-establish port forwards (kill stale, then auto-forward)
            mps_reset_port_forwards "$instance_name" "$short_name" --auto-forward

            # Staleness checks (image + instance)
            _up_staleness_checks "$short_name"

            _up_show_info "$instance_name"
            ;;

        *)
            mps_die "Instance '${short_name}' is in unexpected state: ${state}"
            ;;
    esac
}

# Run image + instance staleness checks for existing instances.
# Image staleness: checks if a newer image exists remotely (bug fix — was missing).
# Instance staleness: checks if the local cached image has changed since creation.
_up_staleness_checks() {
    local short_name="$1"
    local meta_file
    meta_file="$(mps_instance_meta "$short_name")"
    [[ -f "$meta_file" ]] || return 0

    # Image staleness (remote check) — construct file:// URL from instance metadata
    local img_name img_version img_arch
    img_name="$(_mps_read_meta_json "$meta_file" '.image.name')"
    img_version="$(_mps_read_meta_json "$meta_file" '.image.version')"
    img_arch="$(_mps_read_meta_json "$meta_file" '.image.arch')"
    if [[ -n "$img_name" && -n "$img_version" && -n "$img_arch" ]]; then
        local img_path
        img_path="$(mps_cache_dir)/images/${img_name}/${img_version}/${img_arch}.img"
        if [[ -f "$img_path" ]]; then
            _mps_warn_image_staleness "file://${img_path}"
        fi
    fi

    # Instance staleness (local check — skip manifest warnings since image staleness above covers them)
    _mps_warn_instance_staleness "$short_name" --skip-manifest
}

# Restore all persistent mounts after starting a stopped/suspended instance.
# Persistent = CWD auto-mount + MPS_MOUNTS from config cascade.
# Multipass native mounts persist across stop/start, but adhoc mounts are
# cleaned up in mps down, so only persistent mounts survive the cycle.
_up_restore_mounts() {
    local instance_name="$1"
    local arg_path="$2"
    local arg_no_mount="$3"

    # Query Multipass for existing mounts (single call)
    local mount_info=""
    mount_info="$(mp_get_mounts "$instance_name")"

    # Auto-mount: restore CWD mount if not --no-mount
    if [[ "$arg_no_mount" != "true" ]]; then
        mps_resolve_mount "$arg_path"

        if [[ -n "${MPS_MOUNT_SOURCE:-}" && -n "${MPS_MOUNT_TARGET:-}" ]]; then
            # Rule 2: warn if mounting $HOME
            if [[ "${MPS_MOUNT_SOURCE}" == "${HOME:-}" ]]; then
                mps_log_warn "Mounting your entire home directory exposes dotfiles (.ssh, .gnupg, etc.) inside the VM."
                mps_log_warn "Consider mounting a project subdirectory instead, or use --no-mount."
            fi

            if [[ -n "$mount_info" ]] && echo "$mount_info" | jq -e ".[\"${MPS_MOUNT_TARGET}\"]" &>/dev/null; then
                mps_log_debug "Auto-mount at '${MPS_MOUNT_TARGET}' already present."
            else
                mps_log_info "Mounting project directory..."
                mp_mount "$MPS_MOUNT_SOURCE" "$instance_name" "$MPS_MOUNT_TARGET" || \
                    mps_log_warn "Could not mount '${MPS_MOUNT_SOURCE}'. You can mount manually with: mps mount add $(mps_short_name "$instance_name") ${MPS_MOUNT_SOURCE}:${MPS_MOUNT_TARGET}"
            fi
        fi
    fi

    # Config mounts: resolve via _mps_resolve_project_mounts (handles cross-dir)
    local short_name
    short_name="$(mps_short_name "$instance_name")"
    local persistent_mounts
    persistent_mounts="$(_mps_resolve_project_mounts "$short_name")"

    if [[ -n "$persistent_mounts" ]]; then
        # Read workdir to skip the auto-mount entry (already handled above)
        local meta_file
        meta_file="$(mps_instance_meta "$short_name")"
        local workdir=""
        if [[ -f "$meta_file" ]]; then
            workdir="$(_mps_read_meta_json "$meta_file" '.workdir')"
        fi

        local pmount
        for pmount in $persistent_mounts; do
            local cfg_src="${pmount%%:*}"
            local cfg_dst="${pmount#*:}"

            # Skip auto-mount (workdir) — already handled above
            if [[ -n "$workdir" && "$cfg_dst" == "$workdir" ]]; then
                continue
            fi

            mps_validate_mount_source "$cfg_src"

            if [[ -n "$mount_info" ]] && echo "$mount_info" | jq -e ".[\"${cfg_dst}\"]" &>/dev/null; then
                mps_log_debug "Config mount at '${cfg_dst}' already present."
            else
                mps_log_info "Restoring config mount: ${cfg_src} -> ${cfg_dst}"
                mp_mount "$cfg_src" "$instance_name" "$cfg_dst" || \
                    mps_log_warn "Could not mount '${cfg_src}'. Add to MPS_MOUNTS in .mps.env for persistence."
            fi
        done
    fi
}

# Print connection info after an instance is up.
_up_show_info() {
    local instance_name="$1"
    local short_name
    short_name="$(mps_short_name "$instance_name")"

    local ip=""
    ip="$(mp_ipv4 "$instance_name" 2>/dev/null)" || true

    local port_fwd_count
    port_fwd_count="$(mps_port_forward_count "$short_name")"

    echo ""
    printf "  %-14s %s\n" "Instance:" "$short_name"
    if [[ -n "$ip" ]]; then
        printf "  %-14s %s\n" "IP:" "$ip"
    fi
    if [[ $port_fwd_count -gt 0 ]]; then
        printf "  %-14s %s\n" "Ports:" "${port_fwd_count} forwarded"
    fi
    echo ""
    mps_log_info "Connect with: mps shell --name ${short_name}"
}

_up_usage() {
    cat <<EOF
${_color_bold}mps up${_color_reset} — Create (if needed) and start a sandbox

${_color_bold}Usage:${_color_reset}
    mps up [path] [flags]

${_color_bold}Arguments:${_color_reset}
    path        Host directory to mount (default: current directory)

${_color_bold}Naming:${_color_reset}
    Auto-generated: mps-<folder>-<template>
    Override with --name or MPS_NAME in .mps.env

${_color_bold}Flags:${_color_reset}
    --name <name>           Override auto-generated instance name
    --image <image>         Ubuntu image (only used on create)
    --cpus <n>              vCPUs (only used on create)
    --memory <size>         Memory (only used on create)
    --disk <size>           Disk (only used on create)
    --cloud-init <name>     Cloud-init template (only used on create)
    --profile <name>        Resource profile (only used on create)
    --mount <src:dst>       Additional mount point (can be repeated)
    --port <host:guest>     Port forwarding rule (only used on create)
    --transfer <src:dst>    Transfer file from host to guest (only used on create)
    --no-mount              Do not auto-mount (requires --name)
    --help, -h              Show this help

${_color_bold}Behavior:${_color_reset}
    If the instance does not exist, 'mps up' delegates to 'mps create'
    with all provided flags. If the instance is stopped, it starts it
    and re-establishes mounts. If already running, it prints the current
    status.

${_color_bold}Examples:${_color_reset}
    mps up                          Auto-name from CWD, mount CWD
    mps up ~/code/proj              Auto-name from 'proj', mount that dir
    mps up --name mydev             Explicit name, mount CWD
    mps up --profile heavy --cpus 8 --memory 16G

EOF
}
