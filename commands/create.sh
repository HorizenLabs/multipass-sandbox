#!/usr/bin/env bash
# commands/create.sh — mps create [name] [path]
#
# Create a new sandbox VM. Launches a Multipass instance with the given
# configuration, mounts the project directory, and waits for cloud-init.
#
# Usage:
#   mps create [name] [path]
#   mps create --image 24.04 --cpus 8 --memory 8G myproject ~/code/proj
#
# Flags:
#   --image <image>         Ubuntu image (default: from config, e.g. 22.04)
#   --cpus <n>              CPU cores (default: from config/profile)
#   --memory <size>         Memory with unit (default: from config/profile)
#   --disk <size>           Disk with unit (default: from config/profile)
#   --cloud-init <name>     Cloud-init template name or path
#   --profile <name>        Resource profile (lite, standard, heavy)
#   --mount <src:dst>       Extra mount (repeatable)
#   --port <host:guest>     Port forward rule (stored in metadata, repeatable)
#   --no-mount              Skip automatic CWD mount

cmd_create() {
    local arg_name=""
    local arg_path=""
    local arg_image=""
    local arg_cpus=""
    local arg_memory=""
    local arg_disk=""
    local arg_cloud_init=""
    local arg_profile=""
    local arg_no_mount=false
    local -a arg_extra_mounts=()
    local -a arg_ports=()

    # ---- Parse arguments ----
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --image)
                arg_image="${2:?--image requires a value}"
                shift 2
                ;;
            --cpus)
                arg_cpus="${2:?--cpus requires a value}"
                shift 2
                ;;
            --memory|--mem)
                arg_memory="${2:?--memory requires a value}"
                shift 2
                ;;
            --disk)
                arg_disk="${2:?--disk requires a value}"
                shift 2
                ;;
            --cloud-init)
                arg_cloud_init="${2:?--cloud-init requires a value}"
                shift 2
                ;;
            --profile)
                arg_profile="${2:?--profile requires a value}"
                shift 2
                ;;
            --mount)
                arg_extra_mounts+=("${2:?--mount requires a value}")
                shift 2
                ;;
            --port)
                arg_ports+=("${2:?--port requires a value}")
                shift 2
                ;;
            --no-mount)
                arg_no_mount=true
                shift
                ;;
            --help|-h)
                _create_usage
                return 0
                ;;
            -*)
                mps_die "Unknown flag: $1 (see 'mps create --help')"
                ;;
            *)
                # Positional arguments: first is name, second is path
                if [[ -z "$arg_name" ]]; then
                    arg_name="$1"
                elif [[ -z "$arg_path" ]]; then
                    arg_path="$1"
                else
                    mps_die "Unexpected argument: $1 (see 'mps create --help')"
                fi
                shift
                ;;
        esac
    done

    # ---- Apply profile if specified on CLI (before resolving defaults) ----
    if [[ -n "$arg_profile" ]]; then
        export MPS_PROFILE="$arg_profile"
        local profile_file="${MPS_ROOT}/templates/profiles/${arg_profile}.env"
        if [[ -f "$profile_file" ]]; then
            mps_log_debug "Applying CLI profile: ${arg_profile}"
            _mps_apply_profile "$profile_file"
        else
            mps_die "Unknown profile: '${arg_profile}' (not found at ${profile_file})"
        fi
    fi

    # ---- Resolve instance name ----
    local name
    name="$(mps_resolve_name "$arg_name")"
    mps_validate_name "$name"

    local instance_name
    instance_name="$(mps_instance_name "$name")"
    mps_log_debug "Resolved instance name: ${instance_name}"

    # ---- Check instance does not already exist ----
    if mp_instance_exists "$instance_name"; then
        mps_die "Instance '${instance_name}' already exists. Use 'mps up' to start it, or 'mps destroy ${name}' first."
    fi

    # ---- Resolve mount ----
    if [[ "$arg_no_mount" == "true" ]]; then
        MPS_NO_AUTOMOUNT=true
    fi
    mps_resolve_mount "$arg_path"

    # ---- Resolve cloud-init ----
    local cloud_init_path=""
    cloud_init_path="$(mps_resolve_cloud_init "${arg_cloud_init:-}")"
    mps_log_debug "Cloud-init template: ${cloud_init_path}"

    # ---- Resolve resource values: CLI flags > config/profile > defaults ----
    local image="${arg_image:-${MPS_IMAGE:-${MPS_DEFAULT_IMAGE:-22.04}}}"
    local cpus="${arg_cpus:-${MPS_CPUS:-${MPS_DEFAULT_CPUS:-4}}}"
    local memory="${arg_memory:-${MPS_MEMORY:-${MPS_DEFAULT_MEMORY:-4G}}}"
    local disk="${arg_disk:-${MPS_DISK:-${MPS_DEFAULT_DISK:-50G}}}"

    mps_validate_resources "$cpus" "$memory" "$disk"

    # Export so mps_save_instance_meta picks them up
    export MPS_CPUS="$cpus"
    export MPS_MEMORY="$memory"
    export MPS_DISK="$disk"
    export MPS_CLOUD_INIT="${arg_cloud_init:-${MPS_CLOUD_INIT:-${MPS_DEFAULT_CLOUD_INIT:-base}}}"

    # ---- Build extra arguments for mp_launch ----
    local -a extra_args=()

    # Primary mount (passed as --mount to multipass launch)
    if [[ -n "${MPS_MOUNT_SOURCE:-}" && -n "${MPS_MOUNT_TARGET:-}" ]]; then
        extra_args+=(--mount "${MPS_MOUNT_SOURCE}:${MPS_MOUNT_TARGET}")
        mps_log_debug "Primary mount: ${MPS_MOUNT_SOURCE} -> ${MPS_MOUNT_TARGET}"
    fi

    # Extra mounts from --mount flags
    local extra_mount
    for extra_mount in "${arg_extra_mounts[@]}"; do
        local mount_src="${extra_mount%%:*}"
        local mount_dst="${extra_mount#*:}"
        # Resolve relative source paths
        if [[ "$mount_src" != /* ]]; then
            mount_src="$(cd "$mount_src" 2>/dev/null && pwd)" || mps_die "Mount source does not exist: ${mount_src}"
        fi
        extra_args+=(--mount "${mount_src}:${mount_dst}")
        mps_log_debug "Extra mount: ${mount_src} -> ${mount_dst}"
    done

    # Extra mounts from MPS_MOUNTS config
    local config_mounts
    config_mounts="$(mps_parse_extra_mounts)"
    if [[ -n "$config_mounts" ]]; then
        local cfg_mount
        for cfg_mount in $config_mounts; do
            extra_args+=(--mount "$cfg_mount")
            mps_log_debug "Config mount: ${cfg_mount}"
        done
    fi

    # ---- Launch ----
    mp_launch "$instance_name" "$image" "$cpus" "$memory" "$disk" "$cloud_init_path" "${extra_args[@]}"

    # ---- Wait for cloud-init ----
    mp_wait_cloud_init "$instance_name"

    # ---- Save instance metadata ----
    mps_save_instance_meta "$name"

    # ---- Store port forwarding rules in metadata (for use by 'mps port' later) ----
    if [[ ${#arg_ports[@]} -gt 0 ]]; then
        local meta_file
        meta_file="$(mps_instance_meta "$name")"
        local port_rule
        for port_rule in "${arg_ports[@]}"; do
            echo "MPS_PORT_FORWARD+=${port_rule}" >> "$meta_file"
        done
        mps_log_debug "Stored ${#arg_ports[@]} port forwarding rule(s)"
    fi

    # ---- Print summary ----
    local ip=""
    ip="$(mp_ipv4 "$instance_name" 2>/dev/null)" || true

    mps_log_info "Sandbox '${name}' is ready."
    echo ""
    printf "  %-14s %s\n" "Instance:" "$instance_name"
    printf "  %-14s %s\n" "Image:" "$image"
    printf "  %-14s %s\n" "CPUs:" "$cpus"
    printf "  %-14s %s\n" "Memory:" "$memory"
    printf "  %-14s %s\n" "Disk:" "$disk"
    if [[ -n "${MPS_MOUNT_SOURCE:-}" ]]; then
        printf "  %-14s %s -> %s\n" "Mount:" "$MPS_MOUNT_SOURCE" "$MPS_MOUNT_TARGET"
    fi
    if [[ -n "$ip" ]]; then
        printf "  %-14s %s\n" "IP:" "$ip"
    fi
    echo ""
    mps_log_info "Connect with: mps shell ${name}"
}

_create_usage() {
    cat <<EOF
${_color_bold}mps create${_color_reset} — Create a new sandbox

${_color_bold}Usage:${_color_reset}
    mps create [name] [path] [flags]

${_color_bold}Arguments:${_color_reset}
    name        Sandbox name (default: from .mps.env or 'default')
    path        Host directory to mount (default: current directory)

${_color_bold}Flags:${_color_reset}
    --image <image>         Ubuntu image, e.g. 22.04, 24.04 (default: ${MPS_DEFAULT_IMAGE:-22.04})
    --cpus <n>              CPU cores (default: ${MPS_DEFAULT_CPUS:-4})
    --memory <size>         Memory, e.g. 4G, 8G (default: ${MPS_DEFAULT_MEMORY:-4G})
    --disk <size>           Disk, e.g. 50G, 100G (default: ${MPS_DEFAULT_DISK:-50G})
    --cloud-init <name>     Cloud-init template (default: ${MPS_DEFAULT_CLOUD_INIT:-base})
    --profile <name>        Resource profile: lite, standard, heavy
    --mount <src:dst>       Additional mount point (can be repeated)
    --port <host:guest>     Port forwarding rule (can be repeated)
    --no-mount              Do not auto-mount the project directory
    --help, -h              Show this help

${_color_bold}Examples:${_color_reset}
    mps create                              Use defaults, mount CWD
    mps create myproject                    Named sandbox, mount CWD
    mps create myproject ~/code/proj        Named sandbox, mount specific dir
    mps create --profile heavy --image 24.04 dev
    mps create --cloud-init blockchain --mount /data:/data dev

EOF
}
