#!/usr/bin/env bash
# shellcheck disable=SC2154  # color vars defined in lib/common.sh
# commands/create.sh — mps create [name] [path]
#
# Create a new sandbox VM. Launches a Multipass instance with the given
# configuration, mounts the project directory, and waits for cloud-init.
#
# Usage:
#   mps create [name] [path]
#   mps create --image base --cpus 8 --memory 8G myproject ~/code/proj
#
# Flags:
#   --image <image>         Image name (default: base; accepts mps names or Ubuntu versions)
#   --cpus <n>              vCPUs (default: from config/profile)
#   --memory <size>         Memory with unit (default: from config/profile)
#   --disk <size>           Disk with unit (default: from config/profile)
#   --cloud-init <name>     Cloud-init template name or path
#   --profile <name>        Resource profile (micro, lite, standard, heavy)
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
    local -a arg_transfers=()

    # ---- Parse arguments ----
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name|-n)
                arg_name="${2:?--name requires a value}"
                shift 2
                ;;
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
            --transfer)
                arg_transfers+=("${2:?--transfer requires a value}")
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
                # Positional argument: path to mount
                if [[ -z "$arg_path" ]]; then
                    arg_path="$1"
                else
                    mps_die "Unexpected argument: $1 (see 'mps create --help')"
                fi
                shift
                ;;
        esac
    done

    # ---- Apply profile if specified on CLI (before resolving defaults) ----
    local effective_profile="${arg_profile:-${MPS_PROFILE:-${MPS_DEFAULT_PROFILE:-lite}}}"
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

    # ---- Resolve mount (before name, since auto-name depends on mount path) ----
    if [[ "$arg_no_mount" == "true" ]]; then
        export MPS_NO_AUTOMOUNT=true
    fi
    mps_resolve_mount "$arg_path"

    # ---- Resolve cloud-init template name (for auto-naming) ----
    local effective_template="${arg_cloud_init:-${MPS_CLOUD_INIT:-${MPS_DEFAULT_CLOUD_INIT:-default}}}"

    # ---- Resolve instance name ----
    # Auto-name: mps-<folder>-<template>
    # Override: --name flag or MPS_NAME config
    local instance_name
    instance_name="$(mps_resolve_name "$arg_name" "${MPS_MOUNT_SOURCE:-}" "$effective_template")"
    mps_log_debug "Resolved instance name: ${instance_name}"

    # ---- Check instance does not already exist ----
    if mp_instance_exists "$instance_name"; then
        local short
        short="$(mps_short_name "$instance_name")"
        mps_die "Instance '${short}' already exists. Use 'mps up' to start it, or 'mps destroy --name ${short}' first."
    fi

    # ---- Resolve cloud-init ----
    local cloud_init_path=""
    cloud_init_path="$(mps_resolve_cloud_init "${arg_cloud_init:-}")"
    mps_log_debug "Cloud-init template: ${cloud_init_path}"

    # ---- Resolve resource values: CLI flags > config/profile > defaults ----
    local image_spec="${arg_image:-${MPS_IMAGE:-${MPS_DEFAULT_IMAGE:-base}}}"
    local image
    image="$(mps_resolve_image "$image_spec")"
    local cpus="${arg_cpus:-${MPS_CPUS:-${MPS_DEFAULT_CPUS:-2}}}"
    local memory="${arg_memory:-${MPS_MEMORY:-${MPS_DEFAULT_MEMORY:-2G}}}"
    local disk="${arg_disk:-${MPS_DISK:-${MPS_DEFAULT_DISK:-20G}}}"

    mps_validate_resources "$cpus" "$memory" "$disk"
    mps_check_image_requirements "$image" "$cpus" "$memory" "$disk"

    # Export so mps_save_instance_meta picks them up
    export MPS_CPUS="$cpus"
    export MPS_MEMORY="$memory"
    export MPS_DISK="$disk"
    export MPS_CLOUD_INIT="${arg_cloud_init:-${MPS_CLOUD_INIT:-${MPS_DEFAULT_CLOUD_INIT:-default}}}"

    # ---- Build extra arguments for mp_launch ----
    local -a extra_args=()

    # Primary mount (passed as --mount to multipass launch)
    if [[ -n "${MPS_MOUNT_SOURCE:-}" && -n "${MPS_MOUNT_TARGET:-}" ]]; then
        # Rule 2 check only for auto-mount (CWD is virtually always under $HOME)
        if [[ "${MPS_MOUNT_SOURCE}" == "${HOME:-}" ]]; then
            mps_log_warn "Mounting your entire home directory exposes dotfiles (.ssh, .gnupg, etc.) inside the VM."
            mps_log_warn "Consider mounting a project subdirectory instead, or use --no-mount."
        fi
        extra_args+=(--mount "${MPS_MOUNT_SOURCE}:${MPS_MOUNT_TARGET}")
        mps_log_debug "Primary mount: ${MPS_MOUNT_SOURCE} -> ${MPS_MOUNT_TARGET}"
    fi

    # Extra mounts from --mount flags
    local extra_mount
    for extra_mount in ${arg_extra_mounts[@]+"${arg_extra_mounts[@]}"}; do
        local mount_src="${extra_mount%%:*}"
        local mount_dst="${extra_mount#*:}"
        # Resolve relative source paths
        if [[ "$mount_src" != /* ]]; then
            mount_src="$(cd "$mount_src" 2>/dev/null && pwd)" || mps_die "Mount source does not exist: ${mount_src}"
        fi
        mps_validate_mount_source "$mount_src"
        extra_args+=(--mount "${mount_src}:${mount_dst}")
        mps_log_debug "Extra mount: ${mount_src} -> ${mount_dst}"
    done

    # Extra mounts from MPS_MOUNTS config
    local config_mounts
    config_mounts="$(mps_parse_extra_mounts)"
    if [[ -n "$config_mounts" ]]; then
        local cfg_mount
        for cfg_mount in $config_mounts; do
            local cfg_src="${cfg_mount%%:*}"
            mps_validate_mount_source "$cfg_src"
            extra_args+=(--mount "$cfg_mount")
            mps_log_debug "Config mount: ${cfg_mount}"
        done
    fi

    # ---- Launch ----
    mp_launch "$instance_name" "$image" "$cpus" "$memory" "$disk" "$cloud_init_path" ${extra_args[@]+"${extra_args[@]}"}

    # ---- Wait for cloud-init ----
    mp_wait_cloud_init "$instance_name"

    # ---- Build metadata JSON sub-objects ----
    local short_name
    short_name="$(mps_short_name "$instance_name")"

    # Image provenance
    local image_json="null"
    if [[ "$image" == file://* ]]; then
        local img_path="${image#file://}"
        local img_arch img_version img_name img_sha256="" img_source="pulled"
        img_arch="$(basename "$img_path" .img)"
        img_version="$(basename "$(dirname "$img_path")")"
        img_name="$(basename "$(dirname "$(dirname "$img_path")")")"
        # Read sha256 from .meta.json sidecar
        local img_meta_file="${img_path%.img}.meta.json"
        if [[ -f "$img_meta_file" ]]; then
            img_sha256="$(jq -r '.sha256 // empty' "$img_meta_file")"
            # Detect imported vs pulled: imported images lack build_date
            local build_date=""
            build_date="$(jq -r '.build_date // empty' "$img_meta_file")"
            if [[ -z "$build_date" ]]; then
                img_source="imported"
            fi
        fi
        image_json="$(jq -n \
            --arg name "$img_name" \
            --arg version "$img_version" \
            --arg arch "$img_arch" \
            --arg sha256 "$img_sha256" \
            --arg source "$img_source" \
            '{name: $name, version: $version, arch: $arch, sha256: (if $sha256 == "" then null else $sha256 end), source: $source}')"
    elif ! _mps_is_mps_image "$image_spec"; then
        # Stock Ubuntu passthrough
        image_json="$(jq -n --arg name "$image_spec" \
            '{name: $name, version: null, arch: null, sha256: null, source: "stock"}')"
    fi

    # Workdir for metadata (the auto-mount target path)
    local workdir="${MPS_MOUNT_TARGET:-}"

    # Port forwards array
    local pf_json="[]"
    local port_rule
    for port_rule in ${arg_ports[@]+"${arg_ports[@]}"}; do
        pf_json="$(echo "$pf_json" | jq --arg p "$port_rule" '. + [$p]')"
    done

    # Transfers array
    local tf_json="[]"
    local tf_spec
    for tf_spec in ${arg_transfers[@]+"${arg_transfers[@]}"}; do
        tf_json="$(echo "$tf_json" | jq --arg t "$tf_spec" '. + [$t]')"
    done

    mps_save_instance_meta "$short_name" "$image_json" "$workdir" "$pf_json" "$tf_json"

    # ---- Auto-forward ports (from MPS_PORTS config + --port flags) ----
    mps_auto_forward_ports "$instance_name" "$short_name"

    # ---- Transfer files if --transfer was specified ----
    local transfer_count=0
    if [[ ${#arg_transfers[@]} -gt 0 ]]; then
        local transfer_spec
        for transfer_spec in ${arg_transfers[@]+"${arg_transfers[@]}"}; do
            # Format: <host-path>:<guest-path> (split on first colon)
            local host_src="${transfer_spec%%:*}"
            local guest_dst="${transfer_spec#*:}"

            if [[ -z "$host_src" || -z "$guest_dst" || "$host_src" == "$transfer_spec" ]]; then
                mps_die "Invalid --transfer format: '${transfer_spec}' (expected <host-path>:<guest-path>)"
            fi

            # Resolve relative host paths to absolute
            if [[ "$host_src" != /* ]]; then
                host_src="${MPS_PROJECT_DIR:-$(pwd)}/${host_src}"
            fi

            if [[ ! -e "$host_src" ]]; then
                mps_die "Transfer source not found: ${host_src}"
            fi
            if [[ ! -f "$host_src" && ! -d "$host_src" ]]; then
                mps_die "Transfer source is not a file or directory: ${host_src}"
            fi

            mps_log_info "Transferring '${host_src}' -> '${short_name}:${guest_dst}'..."
            mp_transfer -r -p "$host_src" "${instance_name}:${guest_dst}"
            transfer_count=$((transfer_count + 1))
        done
    fi

    # ---- Print summary ----
    local ip=""
    ip="$(mp_ipv4 "$instance_name" 2>/dev/null)" || true

    mps_log_info "Sandbox '${short_name}' is ready."
    echo ""
    printf "  %-14s %s\n" "Instance:" "$short_name"
    printf "  %-14s %s\n" "Image:" "$image_spec"
    printf "  %-14s %s\n" "Profile:" "$effective_profile"
    printf "  %-14s %s\n" "vCPUs:" "$cpus"
    printf "  %-14s %s\n" "Memory:" "$memory"
    printf "  %-14s %s\n" "Disk:" "$disk"
    if [[ -n "${MPS_MOUNT_SOURCE:-}" ]]; then
        printf "  %-14s %s -> %s\n" "Mount:" "$MPS_MOUNT_SOURCE" "$MPS_MOUNT_TARGET"
    fi
    local port_fwd_count
    port_fwd_count="$(mps_port_forward_count "$short_name")"
    if [[ $port_fwd_count -gt 0 ]]; then
        printf "  %-14s %s\n" "Ports:" "${port_fwd_count} forwarded"
    fi
    if [[ $transfer_count -gt 0 ]]; then
        printf "  %-14s %s\n" "Transferred:" "${transfer_count} path(s)"
    fi
    if [[ -n "$ip" ]]; then
        printf "  %-14s %s\n" "IP:" "$ip"
    fi
    echo ""
    mps_log_info "Connect with: mps shell --name ${short_name}"
}

_complete_create() {
    case "${1:-}" in
        flags) echo "--name -n --image --cpus --memory --mem --disk --cloud-init --profile --mount --port --transfer --no-mount --help -h" ;;
        flag-values)
            case "${2:-}" in
                --name|-n)    echo "__instances__" ;;
                --profile)    echo "__profiles__" ;;
                --image)      echo "__images__" ;;
                --cloud-init) echo "__cloud_init__" ;;
            esac ;;
    esac
}

_create_usage() {
    cat <<EOF
${_color_bold}mps create${_color_reset} — Create a new sandbox

${_color_bold}Usage:${_color_reset}
    mps create [path] [flags]

${_color_bold}Arguments:${_color_reset}
    path        Host directory to mount (default: current directory)

${_color_bold}Naming:${_color_reset}
    Auto-generated: mps-<folder>-<template>
    Override with --name or MPS_NAME in .mps.env

${_color_bold}Flags:${_color_reset}
    --name <name>           Override auto-generated instance name
    --image <image>         Image: mps name (base, base:1.0.0) or Ubuntu version (24.04)
    --cpus <n>              vCPUs (default: auto-scaled from profile)
    --memory <size>         Memory, e.g. 4G, 8G (default: auto-scaled from profile)
    --disk <size>           Disk, e.g. 20G, 50G (default: ${MPS_DEFAULT_DISK:-20G})
    --cloud-init <name>     Cloud-init template (default: ${MPS_DEFAULT_CLOUD_INIT:-default})
    --profile <name>        Resource profile: micro, lite, standard, heavy
    --mount <src:dst>       Additional mount point (can be repeated)
    --port <host:guest>     Port forwarding rule (can be repeated)
    --transfer <src:dst>    Transfer file or directory from host to guest after creation (can be repeated)
    --no-mount              Do not auto-mount (requires --name)
    --help, -h              Show this help

${_color_bold}Examples:${_color_reset}
    mps create                              Auto-name from CWD, mount CWD
    mps create ~/code/proj                  Auto-name from 'proj', mount that dir
    mps create --name mydev                 Explicit name, mount CWD
    mps create --profile heavy --cpus 8 --memory 16G
    mps create --no-mount --name scratch    No mount, explicit name

EOF
}
