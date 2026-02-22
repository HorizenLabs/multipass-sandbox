#!/usr/bin/env bash
# shellcheck disable=SC2154  # color vars defined in lib/common.sh
# commands/transfer.sh — mps transfer [--name <name>] [--] <source...> <destination>
#
# Transfer files between host and a running sandbox. Guest paths use a
# colon prefix convention (e.g., :/home/ubuntu/file.txt). The command
# auto-resolves the instance name and prepends it to guest paths.
#
# Usage:
#   mps transfer [--name <name>] [--] <source...> <destination>
#   mps transfer ./config.json :/home/ubuntu/config.json
#   mps transfer file1.txt file2.txt :/home/ubuntu/
#   mps transfer :/home/ubuntu/output.log ./output.log
#   mps transfer --name dev ./script.sh :/tmp/script.sh
#
# Flags:
#   --name, -n <name>   Sandbox name (default: auto-resolved from CWD)
#   --help, -h          Show this help

cmd_transfer() {
    local arg_name=""
    local -a file_args=()

    # ---- Parse arguments ----
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name|-n)
                arg_name="${2:?--name requires a value}"
                shift 2
                ;;
            --help|-h)
                _transfer_usage
                return 0
                ;;
            --)
                shift
                file_args+=("$@")
                break
                ;;
            -*)
                mps_die "Unknown flag: $1 (see 'mps transfer --help')"
                ;;
            *)
                file_args+=("$1")
                shift
                ;;
        esac
    done

    # ---- Validate file arguments ----
    if [[ ${#file_args[@]} -lt 2 ]]; then
        mps_die "At least one source and one destination required (see 'mps transfer --help')"
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

    # ---- Separate sources and destination ----
    local -a sources=("${file_args[@]:0:${#file_args[@]}-1}")
    local destination="${file_args[${#file_args[@]}-1]}"

    # ---- Classify paths (: prefix = guest, else = host) ----
    local has_guest_src=false
    local has_host_src=false
    local guest_dst=false
    local src

    for src in ${sources[@]+"${sources[@]}"}; do
        if [[ "$src" == :* ]]; then
            has_guest_src=true
        else
            has_host_src=true
        fi
    done

    if [[ "$destination" == :* ]]; then
        guest_dst=true
    fi

    # ---- Validate direction ----
    if [[ "$has_guest_src" == "false" && "$guest_dst" == "false" ]]; then
        mps_die "No guest path specified. Prefix guest paths with ':' (e.g., :/home/ubuntu/file.txt)"
    fi

    if [[ "$has_guest_src" == "true" && "$guest_dst" == "true" ]]; then
        mps_die "One side must be a host path. Cannot transfer guest-to-guest."
    fi

    if [[ "$has_guest_src" == "true" && "$has_host_src" == "true" ]]; then
        mps_die "Cannot mix host and guest sources."
    fi

    if [[ "$has_guest_src" == "true" && ${#sources[@]} -gt 1 ]]; then
        mps_die "Only one guest source allowed (multipass limitation)."
    fi

    # ---- Resolve paths and build transfer args ----
    local -a resolved_args=()

    for src in ${sources[@]+"${sources[@]}"}; do
        resolved_args+=("$(_transfer_resolve_path "$src" "$instance_name")")
    done
    resolved_args+=("$(_transfer_resolve_path "$destination" "$instance_name")")

    # ---- Execute transfer ----
    local src_count=${#sources[@]}
    if [[ "$guest_dst" == "true" ]]; then
        mps_log_info "Transferring ${src_count} path(s) host -> ${short_name}..."
    else
        mps_log_info "Transferring from ${short_name} -> host..."
    fi

    mp_transfer -r -p ${resolved_args[@]+"${resolved_args[@]}"}

    mps_log_info "Transfer complete."
}

# Resolve a single path argument.
# Guest paths (: prefix) get the instance name prepended.
# Host paths are resolved to absolute paths.
_transfer_resolve_path() {
    local path="$1"
    local instance_name="$2"

    if [[ "$path" == :* ]]; then
        # Guest path: strip leading : and prepend instance name
        local guest_path="${path#:}"
        echo "${instance_name}:${guest_path}"
    else
        # Host path: resolve to absolute
        if [[ "$path" == /* ]]; then
            echo "$path"
        else
            echo "${MPS_PROJECT_DIR:-$(pwd)}/${path}"
        fi
    fi
}

_transfer_usage() {
    cat <<EOF
${_color_bold}mps transfer${_color_reset} — Transfer files between host and sandbox

${_color_bold}Usage:${_color_reset}
    mps transfer [flags] [--] <source...> <destination>

${_color_bold}Path convention:${_color_reset}
    Host paths:   Regular paths (relative or absolute)
    Guest paths:  Prefixed with ':' (e.g., :/home/ubuntu/file.txt)

${_color_bold}Flags:${_color_reset}
    --name, -n <name>   Sandbox name (default: auto-resolved from CWD)
    --help, -h          Show this help

${_color_bold}Examples:${_color_reset}
    mps transfer ./config.json :/home/ubuntu/config.json       Host -> guest
    mps transfer file1.txt file2.txt :/home/ubuntu/            Multiple host -> guest
    mps transfer :/home/ubuntu/output.log ./output.log         Guest -> host
    mps transfer --name dev ./script.sh :/tmp/script.sh        Explicit instance name

${_color_bold}Notes:${_color_reset}
    - One side must always be a host path and the other a guest path
    - Multiple sources are only supported for host -> guest transfers
    - Guest -> host transfers support only a single source (file or directory)

EOF
}
