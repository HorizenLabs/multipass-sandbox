#!/usr/bin/env bash
# commands/destroy.sh — mps destroy [name]
#
# Permanently remove a sandbox. Deletes the Multipass instance (with purge),
# removes stored metadata, and cleans up SSH config.
#
# Usage:
#   mps destroy [name]
#   mps destroy --force myproject
#
# Flags:
#   --force             Skip confirmation prompt
#   --help, -h          Show this help

cmd_destroy() {
    local arg_name=""
    local arg_force=false

    # ---- Parse arguments ----
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f)
                arg_force=true
                shift
                ;;
            --help|-h)
                _destroy_usage
                return 0
                ;;
            -*)
                mps_die "Unknown flag: $1 (see 'mps destroy --help')"
                ;;
            *)
                if [[ -z "$arg_name" ]]; then
                    arg_name="$1"
                else
                    mps_die "Unexpected argument: $1 (see 'mps destroy --help')"
                fi
                shift
                ;;
        esac
    done

    # ---- Resolve instance name ----
    local name
    name="$(mps_resolve_name "$arg_name")"
    mps_validate_name "$name"

    local instance_name
    instance_name="$(mps_instance_name "$name")"
    mps_log_debug "Resolved instance name: ${instance_name}"

    # ---- Check instance exists ----
    if ! mp_instance_exists "$instance_name"; then
        mps_die "Instance '${instance_name}' does not exist. Nothing to destroy."
    fi

    # ---- Confirm unless --force ----
    if [[ "$arg_force" != "true" ]]; then
        if ! mps_confirm "Destroy sandbox '${name}'? This cannot be undone."; then
            mps_log_info "Aborted."
            return 0
        fi
    fi

    # ---- Delete instance (purge) ----
    mp_delete "$instance_name" "true"

    # ---- Remove metadata file ----
    local meta_file
    meta_file="$(mps_instance_meta "$name")"
    if [[ -f "$meta_file" ]]; then
        rm -f "$meta_file"
        mps_log_debug "Removed metadata: ${meta_file}"
    fi

    # ---- Remove SSH config if present ----
    local ssh_config="${HOME}/.ssh/config.d/${instance_name}"
    if [[ -f "$ssh_config" ]]; then
        rm -f "$ssh_config"
        mps_log_debug "Removed SSH config: ${ssh_config}"
    fi

    mps_log_info "Sandbox '${name}' destroyed."
}

_destroy_usage() {
    cat <<EOF
${_color_bold}mps destroy${_color_reset} — Remove a sandbox permanently

${_color_bold}Usage:${_color_reset}
    mps destroy [name] [flags]

${_color_bold}Arguments:${_color_reset}
    name        Sandbox name (default: from .mps.env or 'default')

${_color_bold}Flags:${_color_reset}
    --force, -f         Skip confirmation prompt
    --help, -h          Show this help

${_color_bold}Examples:${_color_reset}
    mps destroy dev             Destroy 'dev' (with confirmation)
    mps destroy --force dev     Destroy 'dev' without confirmation

EOF
}
