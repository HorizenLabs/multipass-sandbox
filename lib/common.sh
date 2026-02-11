#!/usr/bin/env bash
# lib/common.sh — Shared functions for Multi Pass Sandbox (mps)

# ---------- Colors & Logging ----------

_color_reset=$'\033[0m'
_color_red=$'\033[0;31m'
_color_green=$'\033[0;32m'
_color_yellow=$'\033[0;33m'
_color_blue=$'\033[0;34m'
_color_bold=$'\033[1m'

mps_log_info() {
    printf "%s[mps]%s %s\n" "$_color_green" "$_color_reset" "$*" >&2
}

mps_log_warn() {
    printf "%s[mps WARN]%s %s\n" "$_color_yellow" "$_color_reset" "$*" >&2
}

mps_log_error() {
    printf "%s[mps ERROR]%s %s\n" "$_color_red" "$_color_reset" "$*" >&2
}

mps_log_debug() {
    if [[ "${MPS_DEBUG:-false}" == "true" ]]; then
        printf "%s[mps DEBUG]%s %s\n" "$_color_blue" "$_color_reset" "$*" >&2
    fi
}

mps_die() {
    mps_log_error "$@"
    exit 1
}

# ---------- Dependency Checks ----------

mps_require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        case "$cmd" in
            multipass)
                mps_die "'multipass' is not installed. Install from https://multipass.run/"
                ;;
            jq)
                mps_die "'jq' is not installed. Install with: sudo apt install jq  (Linux) / brew install jq  (macOS)"
                ;;
            *)
                mps_die "'$cmd' is not installed."
                ;;
        esac
    fi
}

mps_check_deps() {
    mps_require_cmd multipass
    mps_require_cmd jq
}

# ---------- Configuration ----------

mps_load_config() {
    # 1. Ship defaults
    if [[ -f "${MPS_ROOT}/config/defaults.env" ]]; then
        mps_log_debug "Loading defaults from ${MPS_ROOT}/config/defaults.env"
        # shellcheck disable=SC1091
        source "${MPS_ROOT}/config/defaults.env"
    fi

    # 2. User global overrides
    if [[ -f "${HOME}/.mps/config" ]]; then
        mps_log_debug "Loading user config from ~/.mps/config"
        # shellcheck disable=SC1091
        source "${HOME}/.mps/config"
    fi

    # 3. Per-project overrides
    if [[ -f "${MPS_PROJECT_DIR:-.}/.mps.env" ]]; then
        mps_log_debug "Loading project config from .mps.env"
        # shellcheck disable=SC1091
        source "${MPS_PROJECT_DIR:-.}/.mps.env"
    fi

    # 4. Apply profile if set (profile values are defaults, explicit CLI/env wins)
    local profile="${MPS_PROFILE:-${MPS_DEFAULT_PROFILE:-standard}}"
    if [[ -f "${MPS_ROOT}/templates/profiles/${profile}.env" ]]; then
        mps_log_debug "Loading profile: ${profile}"
        _mps_apply_profile "${MPS_ROOT}/templates/profiles/${profile}.env"
    fi
}

_mps_apply_profile() {
    local profile_file="$1"
    local key val
    while IFS='=' read -r key val; do
        # Skip comments and blank lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        key=$(echo "$key" | xargs)
        val=$(echo "$val" | xargs)
        # Only apply profile value if not already overridden by project/user config
        local current_var="MPS_${key#MPS_PROFILE_}"
        if [[ -z "${!current_var:-}" ]]; then
            export "$current_var=$val"
        fi
    done < "$profile_file"
}

# ---------- Name Resolution ----------

mps_resolve_name() {
    local name="${1:-}"

    # Explicit name on command line
    if [[ -n "$name" ]]; then
        echo "$name"
        return
    fi

    # From project config
    if [[ -n "${MPS_NAME:-}" ]]; then
        echo "$MPS_NAME"
        return
    fi

    # Default
    echo "default"
}

mps_instance_name() {
    local name="$1"
    local prefix="${MPS_INSTANCE_PREFIX:-mps}"
    echo "${prefix}-${name}"
}

# Strip the mps- prefix to get the short name
mps_short_name() {
    local full_name="$1"
    local prefix="${MPS_INSTANCE_PREFIX:-mps}"
    echo "${full_name#${prefix}-}"
}

# ---------- State Directory ----------

mps_state_dir() {
    local dir="${HOME}/.mps/instances"
    mkdir -p "$dir"
    echo "$dir"
}

mps_cache_dir() {
    local dir="${HOME}/.mps/cache"
    mkdir -p "$dir"
    echo "$dir"
}

mps_instance_meta() {
    local name="$1"
    echo "$(mps_state_dir)/${name}.env"
}

mps_save_instance_meta() {
    local name="$1"
    local meta_file
    meta_file="$(mps_instance_meta "$name")"
    cat > "$meta_file" <<EOF
MPS_INSTANCE_NAME=${name}
MPS_INSTANCE_FULL=$(mps_instance_name "$name")
MPS_CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MPS_CPUS=${MPS_CPUS:-${MPS_DEFAULT_CPUS:-4}}
MPS_MEMORY=${MPS_MEMORY:-${MPS_DEFAULT_MEMORY:-4G}}
MPS_DISK=${MPS_DISK:-${MPS_DEFAULT_DISK:-50G}}
MPS_CLOUD_INIT=${MPS_CLOUD_INIT:-${MPS_DEFAULT_CLOUD_INIT:-base}}
MPS_MOUNT_SOURCE=${MPS_MOUNT_SOURCE:-}
MPS_MOUNT_TARGET=${MPS_MOUNT_TARGET:-}
EOF
    mps_log_debug "Saved instance metadata to $meta_file"
}

# ---------- Path Handling ----------

mps_detect_os() {
    case "$(uname -s)" in
        Linux*)  echo "linux" ;;
        Darwin*) echo "macos" ;;
        MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
        *)       echo "unknown" ;;
    esac
}

# Convert host path to guest mount path
# Linux/macOS: identity (same path)
# Windows: C:\Users\foo → /c/Users/foo
mps_host_to_guest_path() {
    local host_path="$1"
    local os
    os="$(mps_detect_os)"

    case "$os" in
        windows)
            # Convert backslashes to forward slashes
            local converted="${host_path//\\//}"
            # Convert drive letter: C:/foo → /c/foo
            if [[ "$converted" =~ ^([A-Za-z]):/(.*) ]]; then
                local drive="${BASH_REMATCH[1],,}"  # lowercase
                local rest="${BASH_REMATCH[2]}"
                echo "/${drive}/${rest}"
            else
                echo "$converted"
            fi
            ;;
        *)
            echo "$host_path"
            ;;
    esac
}

# Resolve mount source path: use provided path or CWD
# Returns absolute host path
mps_resolve_mount_source() {
    local provided_path="${1:-}"

    if [[ -n "$provided_path" ]]; then
        # Resolve relative paths to absolute
        if [[ "$provided_path" = /* ]]; then
            echo "$provided_path"
        else
            echo "$(cd "$provided_path" 2>/dev/null && pwd)" || mps_die "Path does not exist: $provided_path"
        fi
    else
        pwd
    fi
}

# Resolve full mount spec: source:target
# Sets MPS_MOUNT_SOURCE and MPS_MOUNT_TARGET
mps_resolve_mount() {
    local provided_path="${1:-}"
    local no_automount="${MPS_NO_AUTOMOUNT:-false}"

    if [[ "$no_automount" == "true" && -z "$provided_path" ]]; then
        MPS_MOUNT_SOURCE=""
        MPS_MOUNT_TARGET=""
        return
    fi

    MPS_MOUNT_SOURCE="$(mps_resolve_mount_source "$provided_path")"
    MPS_MOUNT_TARGET="$(mps_host_to_guest_path "$MPS_MOUNT_SOURCE")"

    export MPS_MOUNT_SOURCE MPS_MOUNT_TARGET
}

# Parse additional mounts from MPS_MOUNTS config (space-separated src:dst pairs)
mps_parse_extra_mounts() {
    local mounts="${MPS_MOUNTS:-}"
    local -a result=()

    if [[ -z "$mounts" ]]; then
        echo ""
        return
    fi

    local mount
    for mount in $mounts; do
        local src="${mount%%:*}"
        local dst="${mount#*:}"
        # Resolve relative source paths
        if [[ "$src" != /* ]]; then
            src="$(cd "${MPS_PROJECT_DIR:-.}/$src" 2>/dev/null && pwd)" || continue
        fi
        result+=("${src}:${dst}")
    done

    echo "${result[*]}"
}

# ---------- Cloud-init Resolution ----------

mps_resolve_cloud_init() {
    local template="${1:-${MPS_CLOUD_INIT:-${MPS_DEFAULT_CLOUD_INIT:-base}}}"

    # If it's an absolute path or relative path to a file, use it directly
    if [[ -f "$template" ]]; then
        echo "$template"
        return
    fi

    # Look in the templates directory
    local template_path="${MPS_ROOT}/templates/cloud-init/${template}.yaml"
    if [[ -f "$template_path" ]]; then
        echo "$template_path"
        return
    fi

    mps_die "Cloud-init template not found: $template (searched ${template_path})"
}

# ---------- Validation ----------

mps_validate_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        mps_die "Invalid instance name: '$name'. Names must start with alphanumeric and contain only [a-zA-Z0-9._-]"
    fi
}

mps_validate_resources() {
    local cpus="${1:-}"
    local memory="${2:-}"
    local disk="${3:-}"

    if [[ -n "$cpus" && ! "$cpus" =~ ^[0-9]+$ ]]; then
        mps_die "Invalid CPU count: $cpus (must be a positive integer)"
    fi

    if [[ -n "$memory" && ! "$memory" =~ ^[0-9]+[GgMm]?$ ]]; then
        mps_die "Invalid memory: $memory (e.g., 4G, 512M)"
    fi

    if [[ -n "$disk" && ! "$disk" =~ ^[0-9]+[GgMm]?$ ]]; then
        mps_die "Invalid disk: $disk (e.g., 50G, 100G)"
    fi
}

# ---------- Prompt ----------

mps_confirm() {
    local prompt="${1:-Are you sure?}"
    local response
    printf "%s [y/N] " "$prompt" >&2
    read -r response
    [[ "$response" =~ ^[Yy]([Ee][Ss])?$ ]]
}
