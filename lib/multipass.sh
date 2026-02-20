#!/usr/bin/env bash
# lib/multipass.sh — Multipass CLI wrappers for Multi Pass Sandbox (mps)
#
# All functions use --format json and parse with jq.
# Only operates on instances with the configured prefix (default: mps-).

# ---------- Lifecycle ----------

mp_launch() {
    local instance_name="$1"
    local image="${2:-${MPS_DEFAULT_IMAGE:-base}}"
    local cpus="${3:-${MPS_CPUS:-${MPS_DEFAULT_CPUS:-2}}}"
    local memory="${4:-${MPS_MEMORY:-${MPS_DEFAULT_MEMORY:-2G}}}"
    local disk="${5:-${MPS_DISK:-${MPS_DEFAULT_DISK:-20G}}}"
    local cloud_init="${6:-}"
    shift 6 || true
    # Remaining args are extra flags (--mount, etc.)
    local -a extra_args=("$@")

    local -a cmd=(multipass launch "$image"
        --name "$instance_name"
        --cpus "$cpus"
        --memory "$memory"
        --disk "$disk"
        --timeout 600
    )

    if [[ -n "$cloud_init" ]]; then
        cmd+=(--cloud-init "$cloud_init")
    fi

    cmd+=(${extra_args[@]+"${extra_args[@]}"})

    mps_log_info "Launching instance '$instance_name' (image=$image, cpus=$cpus, mem=$memory, disk=$disk)..."
    mps_log_debug "Running: ${cmd[*]}"

    if ! ${cmd[@]+"${cmd[@]}"}; then
        mps_die "Failed to launch instance '$instance_name'"
    fi

    mps_log_info "Instance '$instance_name' launched successfully."
}

mp_start() {
    local instance_name="$1"
    mps_log_info "Starting instance '$instance_name'..."
    if ! multipass start "$instance_name"; then
        mps_die "Failed to start instance '$instance_name'"
    fi
    mps_log_info "Instance '$instance_name' started."
}

mp_stop() {
    local instance_name="$1"
    local force="${2:-false}"

    local -a cmd=(multipass stop "$instance_name")
    if [[ "$force" == "true" ]]; then
        cmd+=(--force)
    fi

    mps_log_info "Stopping instance '$instance_name'..."
    if ! ${cmd[@]+"${cmd[@]}"}; then
        mps_die "Failed to stop instance '$instance_name'"
    fi
    mps_log_info "Instance '$instance_name' stopped."
}

mp_delete() {
    local instance_name="$1"
    local purge="${2:-true}"

    local -a cmd=(multipass delete "$instance_name")
    if [[ "$purge" == "true" ]]; then
        cmd+=(--purge)
    fi

    mps_log_info "Deleting instance '$instance_name'..."
    if ! ${cmd[@]+"${cmd[@]}"}; then
        mps_die "Failed to delete instance '$instance_name'"
    fi
    mps_log_info "Instance '$instance_name' deleted."
}

# ---------- Execution ----------

mp_exec() {
    local instance_name="$1"
    local workdir="${2:-}"
    shift 2 || shift $#
    local -a user_cmd=("$@")

    local -a cmd=(multipass exec "$instance_name")
    if [[ -n "$workdir" ]]; then
        cmd+=(--working-directory "$workdir")
    fi
    cmd+=(--)
    cmd+=(${user_cmd[@]+"${user_cmd[@]}"})

    mps_log_debug "Running: ${cmd[*]}"
    ${cmd[@]+"${cmd[@]}"}
}

mp_shell() {
    local instance_name="$1"
    local workdir="${2:-}"

    if [[ -n "$workdir" ]]; then
        # multipass shell doesn't support --working-directory,
        # so we exec into bash with a cd.
        # Use printf '%q' to safely escape special characters in the path.
        local escaped_workdir
        escaped_workdir="$(printf '%q' "$workdir")"
        multipass exec "$instance_name" -- bash -c "cd ${escaped_workdir} && exec bash -l"
    else
        multipass shell "$instance_name"
    fi
}

# ---------- Info & Listing ----------

mp_info() {
    local instance_name="$1"
    local raw
    raw="$(multipass info "$instance_name" --format json 2>/dev/null)" || {
        mps_die "Failed to get info for instance '$instance_name'. Is it running?"
    }
    echo "$raw"
}

mp_info_field() {
    local instance_name="$1"
    local field="$2"
    mp_info "$instance_name" | jq -r ".info[\"$instance_name\"].$field // empty"
}

mp_state() {
    local instance_name="$1"
    mp_info_field "$instance_name" "state"
}

mp_ipv4() {
    local instance_name="$1"
    mp_info_field "$instance_name" "ipv4[0]"
}

mp_list() {
    local prefix="${MPS_INSTANCE_PREFIX:-mps}"
    local raw
    raw="$(multipass list --format json 2>/dev/null)" || {
        mps_die "Failed to list instances."
    }
    echo "$raw" | jq -r ".list[] | select(.name | startswith(\"${prefix}-\"))"
}

mp_list_all() {
    local prefix="${MPS_INSTANCE_PREFIX:-mps}"
    multipass list --format json 2>/dev/null | jq -r "[.list[] | select(.name | startswith(\"${prefix}-\"))]"
}

mp_instance_exists() {
    local instance_name="$1"
    multipass info "$instance_name" --format json &>/dev/null
}

mp_instance_state() {
    local instance_name="$1"
    if ! mp_instance_exists "$instance_name"; then
        echo "nonexistent"
        return
    fi
    mp_state "$instance_name"
}

# ---------- Mounts ----------

mp_mount() {
    local source="$1"
    local instance_name="$2"
    local target="$3"

    mps_log_info "Mounting '$source' → '${instance_name}:${target}'..."
    if ! multipass mount "$source" "${instance_name}:${target}"; then
        mps_log_warn "Failed to mount '$source' to '${instance_name}:${target}'"
        return 1
    fi
}

mp_umount() {
    local instance_name="$1"
    local target="$2"

    mps_log_info "Unmounting '${instance_name}:${target}'..."
    multipass umount "${instance_name}:${target}" 2>/dev/null || true
}

# ---------- File Transfer ----------

mp_transfer() {
    if [[ $# -lt 2 ]]; then
        mps_die "mp_transfer requires at least 2 arguments (source(s) and destination)"
    fi
    mps_log_debug "Transferring: $*"
    if ! multipass transfer "$@"; then
        mps_die "File transfer failed"
    fi
}

# ---------- SSH ----------

mp_ssh_info() {
    local instance_name="$1"
    local ip
    ip="$(mp_ipv4 "$instance_name")"

    if [[ -z "$ip" ]]; then
        mps_die "Cannot determine IP for instance '$instance_name'"
    fi

    # Read SSH key from instance metadata (set by mps ssh-config)
    local short_name
    short_name="$(mps_short_name "$instance_name")"
    local ssh_key=""
    local meta_file
    meta_file="$(mps_instance_meta "$short_name")"
    if [[ -f "$meta_file" ]]; then
        ssh_key="$(_mps_read_meta_key "$meta_file" "MPS_SSH_KEY")"
    fi

    echo "IP=$ip"
    echo "SSH_KEY=$ssh_key"
    echo "USER=ubuntu"
}

# ---------- Cloud-init Wait ----------

mp_wait_cloud_init() {
    local instance_name="$1"
    local timeout="${2:-600}"

    mps_log_info "Waiting for cloud-init to complete (timeout: ${timeout}s)..."
    if ! multipass exec "$instance_name" -- cloud-init status --wait 2>/dev/null; then
        mps_log_warn "cloud-init may not have completed cleanly on '$instance_name'"
    fi
    mps_log_info "Cloud-init finished on '$instance_name'."
}

# ---------- Docker Health Check ----------

mp_docker_status() {
    local instance_name="$1"
    if multipass exec "$instance_name" -- docker info --format '{{.ServerVersion}}' 2>/dev/null; then
        return 0
    else
        echo "not running"
        return 1
    fi
}
