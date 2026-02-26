#!/usr/bin/env bash
# shellcheck disable=SC2154  # color vars defined in lib/common.sh
# commands/mount.sh — mps mount [add|remove|list]
#
# Manage mounts on a running sandbox instance.
#
# Usage:
#   mps mount add <src:dst> [--name <name>]
#   mps mount remove <guest_path> [--name <name>]
#   mps mount list [--name <name>]

cmd_mount() {
    local subcmd=""
    local -a args=()

    if [[ $# -eq 0 ]]; then
        _mount_usage
        exit 1
    fi

    subcmd="$1"
    shift
    args=("$@")

    case "$subcmd" in
        add)    _mount_add ${args[@]+"${args[@]}"} ;;
        remove) _mount_remove ${args[@]+"${args[@]}"} ;;
        list)   _mount_list ${args[@]+"${args[@]}"} ;;
        --help|-h) _mount_usage ;;
        *)
            mps_log_error "Unknown mount subcommand: '$subcmd'"
            _mount_usage
            exit 1
            ;;
    esac
}

# ---------- mount add ----------

_mount_add() {
    local name=""
    local mount_spec=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name|-n) name="${2:?--name requires a value}"; shift 2 ;;
            --help|-h) _mount_usage; exit 0 ;;
            -*)        mps_die "Unknown option: $1 (see 'mps mount --help')" ;;
            *)
                if [[ -z "$mount_spec" ]]; then
                    mount_spec="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$mount_spec" ]]; then
        mps_die "Usage: mps mount add <source>:<target> [--name <name>]"
    fi

    # Parse src:dst
    local mount_src="${mount_spec%%:*}"
    local mount_dst="${mount_spec#*:}"

    if [[ -z "$mount_src" || -z "$mount_dst" || "$mount_src" == "$mount_spec" ]]; then
        mps_die "Invalid mount format: '${mount_spec}'. Expected <source>:<target>"
    fi

    # Resolve relative source to absolute
    if [[ "$mount_src" != /* ]]; then
        mount_src="$(cd "$mount_src" 2>/dev/null && pwd)" || mps_die "Mount source does not exist: ${mount_src}"
    fi

    # Validate mount source
    mps_validate_mount_source "$mount_src"

    # Resolve instance
    local instance_name
    instance_name="$(mps_resolve_instance_name "$name")"
    mps_require_running "$instance_name"

    # Check if mount already exists
    local mount_info=""
    mount_info="$(mp_get_mounts "$instance_name")"

    if [[ -n "$mount_info" ]] && echo "$mount_info" | jq -e ".[\"${mount_dst}\"]" &>/dev/null; then
        mps_log_info "Mount at '${mount_dst}' is already present."
        return 0
    fi

    mp_mount "$mount_src" "$instance_name" "$mount_dst"
    mps_log_info "Mounted ${mount_src} -> ${mount_dst} (session-only, removed on 'mps down')"
    mps_log_info "For persistent mounts, add MPS_MOUNTS to .mps.env"
}

# ---------- mount remove ----------

_mount_remove() {
    local name=""
    local guest_path=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name|-n) name="${2:?--name requires a value}"; shift 2 ;;
            --help|-h) _mount_usage; exit 0 ;;
            -*)        mps_die "Unknown option: $1 (see 'mps mount --help')" ;;
            *)
                if [[ -z "$guest_path" ]]; then
                    guest_path="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$guest_path" ]]; then
        mps_die "Usage: mps mount remove <guest_path> [--name <name>]"
    fi

    # Resolve instance
    local instance_name
    instance_name="$(mps_resolve_instance_name "$name")"
    mps_require_running "$instance_name"

    # Verify mount exists
    local mount_info=""
    mount_info="$(mp_get_mounts "$instance_name")"

    if [[ -z "$mount_info" ]] || ! echo "$mount_info" | jq -e ".[\"${guest_path}\"]" &>/dev/null; then
        mps_die "No mount found at guest path '${guest_path}'"
    fi

    mp_umount "$instance_name" "$guest_path"

    # Warn if this is a persistent mount
    local short_name
    short_name="$(mps_short_name "$instance_name")"
    local persistent_mounts
    persistent_mounts="$(_mps_resolve_project_mounts "$short_name")"

    if [[ -n "$persistent_mounts" ]]; then
        local pmount
        for pmount in $persistent_mounts; do
            local ptgt="${pmount#*:}"
            if [[ "$guest_path" == "$ptgt" ]]; then
                mps_log_warn "This mount is persistent and will return on next 'mps up'."
                mps_log_warn "To remove permanently, edit MPS_MOUNTS in .mps.env or remove the auto-mount with --no-mount."
                break
            fi
        done
    fi

    mps_log_info "Unmounted '${guest_path}'"
}

# ---------- mount list ----------

_mount_list() {
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name|-n) name="${2:?--name requires a value}"; shift 2 ;;
            --help|-h) _mount_usage; exit 0 ;;
            -*)        mps_die "Unknown option: $1 (see 'mps mount --help')" ;;
            *)         mps_die "Unexpected argument: $1 (see 'mps mount --help')" ;;
        esac
    done

    # Resolve instance (exists is enough — multipass reports mounts for stopped instances)
    local instance_name
    instance_name="$(mps_resolve_instance_name "$name")"
    mps_require_exists "$instance_name"

    # Get current mounts from Multipass
    local mount_info=""
    mount_info="$(mp_get_mounts "$instance_name")"

    if [[ -z "$mount_info" ]]; then
        echo "No mounts."
        return 0
    fi

    # Resolve persistent mounts for origin derivation
    local short_name
    short_name="$(mps_short_name "$instance_name")"

    local meta_file
    meta_file="$(mps_instance_meta "$short_name")"
    local workdir=""
    if [[ -f "$meta_file" ]]; then
        workdir="$(_mps_read_meta_json "$meta_file" '.workdir')"
    fi

    local persistent_mounts
    persistent_mounts="$(_mps_resolve_project_mounts "$short_name")"

    # Build lookup of config mount targets (excluding auto-mount / workdir)
    local -a config_targets=()
    if [[ -n "$persistent_mounts" ]]; then
        local pmount
        for pmount in $persistent_mounts; do
            local ptgt="${pmount#*:}"
            # Skip workdir — that's "auto", not "config"
            if [[ "$ptgt" != "$workdir" ]]; then
                config_targets+=("$ptgt")
            fi
        done
    fi

    # Display table
    printf "${_color_bold}%-40s %-40s %s${_color_reset}\n" "SOURCE" "TARGET" "ORIGIN"

    local guest_path
    while IFS= read -r guest_path; do
        [[ -z "$guest_path" ]] && continue
        local source_path
        source_path="$(echo "$mount_info" | jq -r ".[\"${guest_path}\"].source_path // empty" 2>/dev/null)"

        # Derive origin
        local origin="adhoc"
        if [[ -n "$workdir" && "$guest_path" == "$workdir" ]]; then
            origin="auto"
        else
            local ctgt
            for ctgt in ${config_targets[@]+"${config_targets[@]}"}; do
                if [[ "$guest_path" == "$ctgt" ]]; then
                    origin="config"
                    break
                fi
            done
        fi

        printf "%-40s %-40s %s\n" "$source_path" "$guest_path" "$origin"
    done < <(echo "$mount_info" | jq -r 'keys[]' 2>/dev/null)
}

# ---------- usage ----------

_complete_mount() {
    case "${1:-}" in
        subcmds) echo "add remove list" ;;
        flags)
            case "${2:-}" in
                add)    echo "--name -n --help -h" ;;
                remove) echo "--name -n --help -h" ;;
                list)   echo "--name -n --help -h" ;;
                *)      echo "--help -h" ;;
            esac ;;
        flag-values)
            case "${2:-}" in
                --name|-n) echo "__instances__" ;;
            esac ;;
    esac
}

_mount_usage() {
    cat <<EOF
${_color_bold}mps mount${_color_reset} — Manage sandbox mounts

${_color_bold}Usage:${_color_reset}
    mps mount <subcommand> [options]

${_color_bold}Subcommands:${_color_reset}
    add <source>:<target>       Mount a host directory into the sandbox
    remove <guest_path>         Unmount a directory from the sandbox
    list                        List current mounts with origin

${_color_bold}Options:${_color_reset}
    --name, -n <name>           Sandbox name (default: auto-resolved from CWD)
    --help, -h                  Show this help

${_color_bold}Mount Origins:${_color_reset}
    auto    CWD auto-mount (set at create time)
    config  From MPS_MOUNTS in .mps.env or ~/mps/config
    adhoc   Added at runtime via 'mps mount add' (removed on 'mps down')

${_color_bold}Persistence:${_color_reset}
    Mounts added with 'mps mount add' are session-only — they are removed
    on 'mps down' and not restored on 'mps up'.

    For persistent mounts, add MPS_MOUNTS to .mps.env:
        MPS_MOUNTS="/host/path:/guest/path /other/src:/other/dst"

${_color_bold}Restrictions:${_color_reset}
    Mount sources must be within your home directory (\$HOME).
    On Linux with Multipass snap, hidden directories under \$HOME (e.g.
    ~/.ssh) are blocked by snap confinement. MPS detects this and refuses
    the operation. Move files to a non-hidden path instead.

${_color_bold}Examples:${_color_reset}
    mps mount add ~/data:/home/ubuntu/data
    mps mount add ~/configs:/opt/configs --name dev
    mps mount remove /home/ubuntu/data
    mps mount list
    mps mount list --name dev

EOF
}
