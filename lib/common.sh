#!/usr/bin/env bash
# lib/common.sh — Shared functions for Multi Pass Sandbox (mps)

# ---------- Portable Hashing Helpers ----------
# macOS has shasum/md5, Linux has sha256sum/md5sum

_mps_sha256() {
    if command -v sha256sum &>/dev/null; then
        sha256sum "$@"
    else
        shasum -a 256 "$@"
    fi
}

# shellcheck disable=SC2120  # called with args from image.sh, without from common.sh (stdin)
_mps_md5() {
    if command -v md5sum &>/dev/null; then
        md5sum "$@"
    else
        md5 -r "$@"
    fi
}

# ---------- Download Helper ----------
# Uses aria2c for multi-connection downloads when available, falls back to curl

_mps_download_file() {
    local url="$1"
    local dest="$2"

    if command -v aria2c &>/dev/null; then
        aria2c -x 8 -s 8 \
            --file-allocation=none \
            --console-log-level=warn \
            --summary-interval=0 \
            -d "$(dirname "$dest")" \
            -o "$(basename "$dest")" \
            "$url"
    else
        curl --progress-bar -fSL "$url" -o "$dest"
    fi
}

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

    # 2. User global overrides (safe line-by-line parsing, no sourcing)
    if [[ -f "${HOME}/.mps/config" ]]; then
        mps_log_debug "Loading user config from ~/.mps/config"
        _mps_load_env_file "${HOME}/.mps/config"
    fi

    # 3. Per-project overrides (safe line-by-line parsing, no sourcing)
    if [[ -f "${MPS_PROJECT_DIR:-.}/.mps.env" ]]; then
        mps_log_debug "Loading project config from .mps.env"
        _mps_load_env_file "${MPS_PROJECT_DIR:-.}/.mps.env"
    fi

    # 4. Apply profile if set (profile values are defaults, explicit CLI/env wins)
    local profile="${MPS_PROFILE:-${MPS_DEFAULT_PROFILE:-lite}}"
    if [[ -f "${MPS_ROOT}/templates/profiles/${profile}.env" ]]; then
        mps_log_debug "Loading profile: ${profile}"
        _mps_apply_profile "${MPS_ROOT}/templates/profiles/${profile}.env"
    fi

    # 5. Compute auto-scaled CPU/memory from profile fractions (if not already set)
    _mps_compute_resources

    # 6. Validate security-sensitive config values
    if [[ -n "${MPS_IMAGE_BASE_URL:-}" && ! "$MPS_IMAGE_BASE_URL" =~ ^https:// ]]; then
        mps_die "MPS_IMAGE_BASE_URL must use https:// (got '${MPS_IMAGE_BASE_URL}')"
    fi
}

_mps_apply_profile() {
    local profile_file="$1"
    local key val
    while IFS='=' read -r key val; do
        # Skip comments and blank lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        key="$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        val="$(echo "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        # Only apply profile value if not already overridden by project/user config
        local current_var="MPS_${key#MPS_PROFILE_}"
        if [[ -z "${!current_var:-}" ]]; then
            export "$current_var=$val"
        fi
    done < "$profile_file"
}

# Safe env file parser: reads KEY=VALUE lines without sourcing.
# Only accepts MPS_* variables, strips comments/blanks/quotes.
_mps_load_env_file() {
    local env_file="$1"
    local key val
    while IFS='=' read -r key val; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        key="$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        val="$(echo "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        # Strip optional quotes from value
        val="${val#\"}" ; val="${val%\"}"
        val="${val#\'}" ; val="${val%\'}"
        # Only accept MPS_* variables
        if [[ "$key" == MPS_* ]]; then
            export "$key=$val"
        else
            mps_log_warn "Ignoring non-MPS variable in ${env_file}: ${key}"
        fi
    done < "$env_file"
}

# ---------- Auto-Scaling Resources ----------

# Parse a size string like "4G", "512M", "1g" into megabytes (integer).
_mps_parse_size_mb() {
    local size="$1"
    local num unit
    num="${size%%[GgMm]*}"
    unit="${size##*[0-9.]}"
    if [[ ! "$num" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "0"
        return 1
    fi
    case "$unit" in
        G|g) awk -v n="$num" 'BEGIN { printf "%d", n * 1024 }' ;;
        M|m) awk -v n="$num" 'BEGIN { printf "%d", n }' ;;
        *)   awk -v n="$num" 'BEGIN { printf "%d", n }' ;;
    esac
}

# Detect host hardware and compute MPS_CPUS/MPS_MEMORY from profile fractions.
# Only sets values that are not already set (explicit overrides always win).
_mps_compute_resources() {
    # Skip if both are already explicitly set
    if [[ -n "${MPS_CPUS:-}" && -n "${MPS_MEMORY:-}" ]]; then
        return 0
    fi

    # Detect host CPUs
    local host_cpus
    if command -v nproc &>/dev/null; then
        host_cpus="$(nproc)"
    elif command -v sysctl &>/dev/null && sysctl -n hw.ncpu &>/dev/null 2>&1; then
        host_cpus="$(sysctl -n hw.ncpu)"
    else
        host_cpus=4
    fi

    # Detect host memory (in MB)
    local host_memory_mb
    if [[ -f /proc/meminfo ]]; then
        local mem_kb
        mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
        host_memory_mb=$(( mem_kb / 1024 ))
    elif command -v sysctl &>/dev/null && sysctl -n hw.memsize &>/dev/null 2>&1; then
        local mem_bytes
        mem_bytes="$(sysctl -n hw.memsize)"
        host_memory_mb=$(( mem_bytes / 1024 / 1024 ))
    else
        host_memory_mb=4096
    fi

    # Compute CPUs from fraction/min if not already set
    if [[ -z "${MPS_CPUS:-}" ]]; then
        local frac_num="${MPS_CPUS_FRACTION_NUM:-}"
        local frac_den="${MPS_CPUS_FRACTION_DEN:-}"
        local cpu_min="${MPS_CPUS_MIN:-}"

        if [[ -n "$frac_num" && -n "$frac_den" && "$frac_den" -gt 0 ]]; then
            local computed_cpus=$(( host_cpus * frac_num / frac_den ))
            if [[ -n "$cpu_min" && "$computed_cpus" -lt "$cpu_min" ]]; then
                computed_cpus="$cpu_min"
            fi
            if [[ "$computed_cpus" -lt 1 ]]; then
                computed_cpus=1
            fi
            export MPS_CPUS="$computed_cpus"
            mps_log_debug "Auto-scaled CPUs: ${computed_cpus} (host=${host_cpus}, fraction=${frac_num}/${frac_den}, min=${cpu_min:-none})"
        fi
    fi

    # Compute memory from fraction/min/cap if not already set
    if [[ -z "${MPS_MEMORY:-}" ]]; then
        local mem_frac_num="${MPS_MEMORY_FRACTION_NUM:-}"
        local mem_frac_den="${MPS_MEMORY_FRACTION_DEN:-}"
        local mem_min="${MPS_MEMORY_MIN:-}"
        local mem_cap="${MPS_MEMORY_CAP:-}"

        if [[ -n "$mem_frac_num" && -n "$mem_frac_den" && "$mem_frac_den" -gt 0 ]]; then
            local computed_mem_mb=$(( host_memory_mb * mem_frac_num / mem_frac_den ))

            # Apply minimum
            if [[ -n "$mem_min" ]]; then
                local min_mb
                min_mb="$(_mps_parse_size_mb "$mem_min")"
                if [[ "$computed_mem_mb" -lt "$min_mb" ]]; then
                    computed_mem_mb="$min_mb"
                fi
            fi

            # Apply cap
            if [[ -n "$mem_cap" ]]; then
                local cap_mb
                cap_mb="$(_mps_parse_size_mb "$mem_cap")"
                if [[ "$computed_mem_mb" -gt "$cap_mb" ]]; then
                    computed_mem_mb="$cap_mb"
                fi
            fi

            # Format as G or M
            if [[ $(( computed_mem_mb % 1024 )) -eq 0 && "$computed_mem_mb" -ge 1024 ]]; then
                export MPS_MEMORY="$(( computed_mem_mb / 1024 ))G"
            else
                export MPS_MEMORY="${computed_mem_mb}M"
            fi
            mps_log_debug "Auto-scaled memory: ${MPS_MEMORY} (host=${host_memory_mb}MB, fraction=${mem_frac_num}/${mem_frac_den}, min=${mem_min:-none}, cap=${mem_cap:-none})"
        fi
    fi
}

# ---------- Name Resolution ----------

# Maximum length for Multipass instance names
MPS_MAX_INSTANCE_NAME_LEN=40

# Generate the auto-name: mps-<folder>-<template>-<profile>
# Truncates the folder portion and appends a short hash if too long.
mps_auto_name() {
    local mount_source="${1:-}"
    local template="${2:-${MPS_CLOUD_INIT:-${MPS_DEFAULT_CLOUD_INIT:-default}}}"
    local profile="${3:-${MPS_PROFILE:-${MPS_DEFAULT_PROFILE:-lite}}}"
    local prefix="${MPS_INSTANCE_PREFIX:-mps}"

    if [[ -z "$mount_source" ]]; then
        mps_die "Cannot auto-name: no mount path. Use --name to specify a name, or provide a mount path."
    fi

    local folder
    folder="$(basename "$mount_source")"

    # Sanitize folder name: lowercase, replace non-alphanumeric with dash, collapse dashes
    folder="$(echo "$folder" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//')"

    # Build the full name
    local suffix="${template}-${profile}"
    local full_name="${prefix}-${folder}-${suffix}"

    # Truncate if too long
    if [[ ${#full_name} -gt $MPS_MAX_INSTANCE_NAME_LEN ]]; then
        # Compute a short hash of the original folder name for uniqueness
        local hash
        hash="$(echo -n "$folder" | _mps_md5 | cut -c1-4)"
        # Calculate how much space we have for the folder portion
        # Format: <prefix>-<folder>-<hash>-<suffix>
        local overhead=$(( ${#prefix} + 1 + ${#hash} + 1 + ${#suffix} + 1 ))
        local max_folder=$(( MPS_MAX_INSTANCE_NAME_LEN - overhead ))
        if [[ $max_folder -lt 1 ]]; then
            max_folder=1
        fi
        local truncated_folder="${folder:0:$max_folder}"
        # Remove trailing dash from truncation
        truncated_folder="${truncated_folder%-}"
        full_name="${prefix}-${truncated_folder}-${hash}-${suffix}"
    fi

    # Ensure name starts with a letter (Multipass requirement)
    if [[ ! "$full_name" =~ ^[a-zA-Z] ]]; then
        full_name="m${full_name}"
    fi

    echo "$full_name"
}

# Resolve the instance name.
# Priority: --name flag > MPS_NAME config > auto-name from mount path
mps_resolve_name() {
    local explicit_name="${1:-}"
    local mount_source="${2:-}"
    local template="${3:-}"
    local profile="${4:-}"

    # 1. Explicit --name flag
    if [[ -n "$explicit_name" ]]; then
        mps_validate_name "$explicit_name"
        mps_instance_name "$explicit_name"
        return
    fi

    # 2. From project config MPS_NAME
    if [[ -n "${MPS_NAME:-}" ]]; then
        mps_validate_name "$MPS_NAME"
        mps_instance_name "$MPS_NAME"
        return
    fi

    # 3. Auto-name from mount path
    if [[ -n "$mount_source" ]]; then
        mps_auto_name "$mount_source" "$template" "$profile"
        return
    fi

    # 4. No name can be derived
    mps_die "Cannot determine instance name. Use --name to specify one, or provide a mount path."
}

mps_instance_name() {
    local name="$1"
    local prefix="${MPS_INSTANCE_PREFIX:-mps}"
    # Don't double-prefix
    if [[ "$name" == "${prefix}-"* ]]; then
        echo "$name"
    else
        echo "${prefix}-${name}"
    fi
}

# Strip the mps- prefix to get the short name
mps_short_name() {
    local full_name="$1"
    local prefix="${MPS_INSTANCE_PREFIX:-mps}"
    echo "${full_name#${prefix}-}"
}

# Convenience wrapper: resolve instance name from an optional --name arg.
# If arg is given, apply prefix; otherwise auto-derive from CWD + defaults.
mps_resolve_instance_name() {
    local arg_name="${1:-}"
    local instance_name
    if [[ -n "$arg_name" ]]; then
        mps_validate_name "$arg_name"
        instance_name="$(mps_instance_name "$arg_name")"
    else
        instance_name="$(mps_resolve_name "" "$(pwd)" \
            "${MPS_CLOUD_INIT:-${MPS_DEFAULT_CLOUD_INIT:-default}}" \
            "${MPS_PROFILE:-${MPS_DEFAULT_PROFILE:-lite}}")"
    fi
    mps_log_debug "Resolved instance name: ${instance_name}"
    echo "$instance_name"
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

# ---------- Instance State Guards ----------

mps_require_exists() {
    local instance_name="$1"
    local suffix="${2:-Create it with: mps up --name $(mps_short_name "$instance_name")}"
    if ! mp_instance_exists "$instance_name"; then
        mps_die "Instance '${instance_name}' does not exist. ${suffix}"
    fi
}

mps_require_running() {
    local instance_name="$1"
    local state
    state="$(mp_instance_state "$instance_name")"
    if [[ "$state" == "nonexistent" ]]; then
        mps_die "Instance '${instance_name}' does not exist. Create it with: mps up --name $(mps_short_name "$instance_name")"
    fi
    if [[ "$state" != "Running" ]]; then
        mps_die "Instance '${instance_name}' is not running (state: ${state}). Start it with: mps up --name $(mps_short_name "$instance_name")"
    fi
}

# ---------- Workdir Resolution ----------

mps_resolve_workdir() {
    local instance_name="$1"
    local explicit_workdir="${2:-}"
    if [[ -n "$explicit_workdir" ]]; then
        echo "$explicit_workdir"
        return
    fi
    local meta_file
    meta_file="$(mps_instance_meta "$(mps_short_name "$instance_name")")"
    if [[ -f "$meta_file" ]]; then
        local mount_target=""
        mount_target="$(_mps_read_meta_key "$meta_file" "MPS_MOUNT_TARGET")"
        if [[ -n "$mount_target" ]]; then
            mps_log_debug "Using mount target as workdir: ${mount_target}"
            echo "$mount_target"
            return
        fi
    fi
    echo ""
}

# ---------- Architecture Detection ----------

mps_detect_arch() {
    local arch
    arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        arm64)   echo "arm64" ;;
        *)       echo "$arch" ;;
    esac
}

# ---------- Image Resolution ----------

# Check if an image name looks like an mps image (not a Multipass/Ubuntu version).
# Ubuntu versions start with a digit (e.g. "24.04", "22.04").
# mps image names are words (e.g. "base", "protocol-dev").
_mps_is_mps_image() {
    local name="$1"
    [[ ! "$name" =~ ^[0-9] ]]
}

# Pull an image from the remote registry into the local cache.
# Usage: _mps_pull_image <name> [<version>]
# Returns 0 on success, 1 on failure. Logs progress/errors via mps_log_*.
# Called by both auto-pull (mps_resolve_image) and interactive (mps image pull).
_mps_pull_image() {
    local image_name="$1"
    local image_version="${2:-latest}"

    local base_url="${MPS_IMAGE_BASE_URL:-}"
    if [[ -z "$base_url" ]]; then
        mps_log_error "MPS_IMAGE_BASE_URL not configured"
        return 1
    fi

    local arch
    arch="$(mps_detect_arch)"

    mps_log_info "Pulling image '${image_name}:${image_version}'..."

    # Fetch manifest
    local manifest
    manifest="$(curl -fsSL "${base_url}/manifest.json" 2>/dev/null)" || {
        mps_log_error "Failed to fetch manifest from ${base_url}/manifest.json"
        return 1
    }

    # Resolve "latest" to actual version number
    if [[ "$image_version" == "latest" ]]; then
        image_version="$(echo "$manifest" | jq -r ".images[\"${image_name}\"].latest // empty")"
        if [[ -z "$image_version" ]]; then
            mps_log_error "No 'latest' version found for image '${image_name}'"
            return 1
        fi
        mps_log_info "Resolved 'latest' to version ${image_version}"
    fi

    # Construct deterministic URL (no url field in manifest v2)
    local relative_path="${image_name}/${image_version}/${arch}.img"
    local full_url="${base_url}/${relative_path}"

    # Fetch .meta.json sidecar (authoritative SHA256 source)
    local meta_json_url="${full_url}.meta.json"
    local meta_json expected_sha256
    meta_json="$(curl --connect-timeout 5 --max-time 10 -fsSL "$meta_json_url" 2>/dev/null)" || {
        mps_log_error "Image '${image_name}:${image_version}' not found for arch '${arch}'"
        return 1
    }
    expected_sha256="$(echo "$meta_json" | jq -r '.sha256 // empty')"

    # Download
    local cache_dir
    cache_dir="$(mps_cache_dir)/images/${image_name}/${image_version}"
    mkdir -p "$cache_dir"
    local dest_file="${cache_dir}/${arch}.img"

    mps_log_info "Downloading ${image_name}:${image_version} (${arch})..."
    if ! _mps_download_file "$full_url" "$dest_file"; then
        rm -f "$dest_file"
        mps_log_error "Failed to download image from ${full_url}"
        return 1
    fi

    # Verify checksum
    if [[ -n "$expected_sha256" ]]; then
        mps_log_info "Verifying checksum..."
        local actual_sha256
        actual_sha256="$(_mps_sha256 "$dest_file" | cut -d' ' -f1)"
        if [[ "$actual_sha256" != "$expected_sha256" ]]; then
            rm -f "$dest_file"
            mps_log_error "Checksum mismatch! Expected: ${expected_sha256}, Got: ${actual_sha256}"
            return 1
        fi
        mps_log_info "Checksum verified."
    fi

    # Write .meta sidecar with image metadata from .meta.json
    # Strip newlines from jq output to prevent value injection
    local meta_file="${cache_dir}/${arch}.meta"
    local _desc _disk_size _min_profile _min_disk _min_memory _min_cpus
    _desc="$(echo "$meta_json" | jq -r '.description // empty' | tr -d '\n')"
    _disk_size="$(echo "$meta_json" | jq -r '.disk_size // empty' | tr -d '\n')"
    _min_profile="$(echo "$meta_json" | jq -r '.min_profile // empty' | tr -d '\n')"
    _min_disk="$(echo "$meta_json" | jq -r '.min_disk // empty' | tr -d '\n')"
    _min_memory="$(echo "$meta_json" | jq -r '.min_memory // empty' | tr -d '\n')"
    _min_cpus="$(echo "$meta_json" | jq -r '.min_cpus // empty' | tr -d '\n')"
    cat > "$meta_file" <<EOF
SOURCE=pulled
PULLED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SHA256=${expected_sha256}
DESCRIPTION=${_desc}
IMAGE_DISK_SIZE=${_disk_size}
MIN_PROFILE=${_min_profile}
MIN_DISK=${_min_disk}
MIN_MEMORY=${_min_memory}
MIN_CPUS=${_min_cpus}
EOF

    mps_log_info "Image '${image_name}:${image_version}' cached successfully."
    return 0
}

# Resolve an image spec to a file:// URL (if cached) or pass through unchanged.
# Input: "base", "base:1.0.0", "base:local", "base:latest", "24.04"
# Output: "file:///home/.../.mps/cache/images/base/1.0.0/amd64.img" or "24.04"
mps_resolve_image() {
    local image_spec="$1"
    local name="${image_spec%%:*}"
    local tag="${image_spec#*:}"
    if [[ "$tag" == "$name" ]]; then
        tag="latest"
    fi

    local cache_dir
    cache_dir="$(mps_cache_dir)/images"
    local image_dir="${cache_dir}/${name}"

    # If the image name directory doesn't exist or is empty, try auto-pull for mps images
    local _has_images=false
    if [[ -d "$image_dir" ]]; then
        # Check if any .img files exist in any version subdirectory
        for _vdir in "$image_dir"/*/; do
            [[ -d "$_vdir" ]] || continue
            for _img in "$_vdir"*.img; do
                if [[ -f "$_img" ]]; then
                    _has_images=true
                    break 2
                fi
            done
        done
    fi
    if [[ "$_has_images" == "false" ]]; then
        if _mps_is_mps_image "$name" && [[ -n "${MPS_IMAGE_BASE_URL:-}" ]]; then
            mps_log_info "Image '${name}' not found locally. Pulling..."
            if _mps_pull_image "$name" "$tag" && [[ -d "$image_dir" ]]; then
                : # Pull succeeded — fall through to normal resolution below
            else
                mps_die "Could not pull image '${name}'. Pull manually with 'mps image pull ${name}' or use '--image 24.04' for stock Ubuntu."
            fi
        elif _mps_is_mps_image "$name"; then
            mps_die "Image '${name}' not found locally and MPS_IMAGE_BASE_URL not configured. Pull or import the image first, or use '--image 24.04' for stock Ubuntu."
        else
            echo "$image_spec"
            return
        fi
    fi

    local arch
    arch="$(mps_detect_arch)"

    # Resolve "latest" to best available version
    if [[ "$tag" == "latest" ]]; then
        tag="$(_mps_resolve_latest_version "$image_dir" "$arch")"
        if [[ -z "$tag" ]]; then
            # Name dir exists but no matching arch — list what's available
            local available=""
            for tag_dir in "$image_dir"/*/; do
                [[ -d "$tag_dir" ]] || continue
                for img_file in "$tag_dir"/*.img; do
                    [[ -f "$img_file" ]] || continue
                    local a
                    a="$(basename "$img_file" .img)"
                    available="${available:+${available}, }$(basename "$tag_dir")/${a}"
                done
            done
            if [[ -n "$available" ]]; then
                mps_die "Image '${name}' found but no ${arch} build. Available: ${available}"
            fi
            # No images at all in the dir — fall through
            echo "$image_spec"
            return
        fi
    fi

    local img_file="${image_dir}/${tag}/${arch}.img"
    if [[ -f "$img_file" ]]; then
        # Verify cached image integrity against .meta sidecar SHA256
        local meta_file="${image_dir}/${tag}/${arch}.meta"
        if [[ -f "$meta_file" ]]; then
            local expected_sha256=""
            expected_sha256="$(grep '^SHA256=' "$meta_file" | head -1 | cut -d= -f2-)"
            if [[ -n "$expected_sha256" && ${#expected_sha256} -eq 64 ]]; then
                local actual_sha256
                actual_sha256="$(_mps_sha256 "$img_file" | cut -d' ' -f1)"
                if [[ "$actual_sha256" != "$expected_sha256" ]]; then
                    mps_log_warn "Cached image '${name}:${tag}' is corrupted (checksum mismatch). Re-pulling..."
                    rm -f "$img_file"
                    if _mps_is_mps_image "$name" && [[ -n "${MPS_IMAGE_BASE_URL:-}" ]]; then
                        _mps_pull_image "$name" "$tag" || mps_die "Failed to re-pull corrupted image '${name}:${tag}'"
                    else
                        mps_die "Cached image corrupted and cannot auto-pull. Remove with 'mps image remove ${name}:${tag}' and pull again."
                    fi
                fi
            fi
        fi
        local abs_path
        abs_path="$(cd "$(dirname "$img_file")" && pwd)/$(basename "$img_file")"
        _mps_warn_image_staleness "file://${abs_path}"
        echo "file://${abs_path}"
        return
    fi

    # Tag dir exists but wrong arch
    if [[ -d "${image_dir}/${tag}" ]]; then
        local available=""
        for f in "${image_dir}/${tag}"/*.img; do
            [[ -f "$f" ]] || continue
            available="${available:+${available}, }$(basename "$f" .img)"
        done
        if [[ -n "$available" ]]; then
            mps_die "Image '${name}:${tag}' found but not for ${arch}. Available arch(es): ${available}"
        fi
    fi

    # No match — pass through to Multipass
    echo "$image_spec"
}

# Scan version subdirs, return highest SemVer that has a matching arch file.
# Falls back to "local" if no SemVer versions exist.
_mps_resolve_latest_version() {
    local image_dir="$1"
    local arch="$2"
    local best=""

    for tag_dir in "$image_dir"/*/; do
        [[ -d "$tag_dir" ]] || continue
        local tag
        tag="$(basename "$tag_dir")"
        [[ -f "${tag_dir}/${arch}.img" ]] || continue

        # Skip non-SemVer tags for comparison (handle "local" separately)
        if [[ "$tag" == "local" ]]; then
            continue
        fi
        if [[ ! "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            continue
        fi

        if [[ -z "$best" ]] || _mps_semver_gt "$tag" "$best"; then
            best="$tag"
        fi
    done

    # If we found a SemVer version, use it
    if [[ -n "$best" ]]; then
        echo "$best"
        return
    fi

    # Fall back to "local" if it has the right arch
    if [[ -f "${image_dir}/local/${arch}.img" ]]; then
        echo "local"
        return
    fi

    # Nothing matched
    echo ""
}

# Compare two SemVer strings (a > b). Returns 0 if a > b, 1 otherwise.
_mps_semver_gt() {
    local a="$1" b="$2"
    local a_major a_minor a_patch b_major b_minor b_patch

    IFS='.' read -r a_major a_minor a_patch <<< "$a"
    IFS='.' read -r b_major b_minor b_patch <<< "$b"

    if (( a_major > b_major )); then return 0; fi
    if (( a_major < b_major )); then return 1; fi
    if (( a_minor > b_minor )); then return 0; fi
    if (( a_minor < b_minor )); then return 1; fi
    if (( a_patch > b_patch )); then return 0; fi
    return 1
}

# ---------- Image Staleness Detection ----------

# Fetch remote manifest.json to stdout. Caches locally at ~/.mps/cache/manifest.json.
# Uses conditional GET (If-Modified-Since via curl -z) to avoid re-downloading
# when the remote hasn't changed. Falls back to cached copy when offline.
# Returns 1 only if no manifest is available (neither remote nor cached).
_mps_fetch_manifest() {
    local base_url="${MPS_IMAGE_BASE_URL:-}"
    [[ -z "$base_url" ]] && return 1

    local cache_file
    cache_file="$(mps_cache_dir)/manifest.json"
    local manifest_url="${base_url}/manifest.json"

    if [[ -f "$cache_file" ]]; then
        # Conditional GET: -z sends If-Modified-Since, server returns 304 if unchanged
        curl --connect-timeout 1 --max-time 3 -fsSL \
            -z "$cache_file" -o "$cache_file" \
            "$manifest_url" 2>/dev/null || true
    else
        # No cache — full download (fail if offline)
        curl --connect-timeout 1 --max-time 3 -fsSL \
            -o "$cache_file" "$manifest_url" 2>/dev/null || return 1
    fi

    [[ -f "$cache_file" ]] || return 1
    cat "$cache_file"
}

# Compare local .meta SHA256 vs remote manifest.
# Prints one of: up-to-date, stale, update:<ver>, unknown.
_mps_check_image_staleness() {
    local manifest="$1" name="$2" version="$3" arch="$4"

    # Skip non-SemVer tags (e.g. "local")
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "unknown"
        return
    fi

    # Get local SHA256 from .meta
    local local_sha256
    local_sha256="$(mps_image_meta "$name" "$version" "$arch" "SHA256")"
    if [[ -z "$local_sha256" ]]; then
        echo "unknown"
        return
    fi

    # Check if there's a newer version available
    local latest_version
    latest_version="$(echo "$manifest" | jq -r ".images[\"${name}\"].latest // empty")"
    if [[ -n "$latest_version" && "$latest_version" != "$version" ]] && _mps_semver_gt "$latest_version" "$version"; then
        echo "update:${latest_version}"
        return
    fi

    # Compare SHA256 for same version (rebuild detection)
    local remote_sha256
    remote_sha256="$(echo "$manifest" | jq -r ".images[\"${name}\"].versions[\"${version}\"][\"${arch}\"].sha256 // empty")"
    if [[ -n "$remote_sha256" ]]; then
        if [[ "$local_sha256" == "$remote_sha256" ]]; then
            echo "up-to-date"
        else
            echo "stale"
        fi
    else
        echo "unknown"
    fi
}

# High-level wrapper: parse file:// URL, check staleness, emit warnings.
# Called from mps_resolve_image(). Respects MPS_IMAGE_CHECK_UPDATES opt-out.
# Silent on failure/offline — never blocks.
_mps_warn_image_staleness() {
    local file_url="$1"

    # Opt-out check
    [[ "${MPS_IMAGE_CHECK_UPDATES:-true}" == "true" ]] || return 0

    # Parse name/version/arch from cache path
    # Format: file:///home/.../.mps/cache/images/<name>/<version>/<arch>.img
    local img_path="${file_url#file://}"
    local arch
    arch="$(basename "$img_path" .img)"
    local version
    version="$(basename "$(dirname "$img_path")")"
    local name
    name="$(basename "$(dirname "$(dirname "$img_path")")")"

    # Skip non-SemVer (e.g. "local")
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0

    # Fetch manifest (silent on failure)
    local manifest
    manifest="$(_mps_fetch_manifest)" || return 0

    local status
    status="$(_mps_check_image_staleness "$manifest" "$name" "$version" "$arch")"

    case "$status" in
        stale)
            mps_log_warn "Image '${name}:${version}' has been rebuilt with OS updates. Run 'mps image pull ${name}:${version}' to update."
            ;;
        update:*)
            local new_ver="${status#update:}"
            mps_log_warn "Image '${name}:${version}' is outdated. Version ${new_ver} is available. Run 'mps image pull ${name}' to update."
            ;;
    esac
    return 0
}

# ---------- Metadata Helpers ----------

_mps_read_meta_key() {
    local file="$1" key="$2"
    if [[ -f "$file" ]]; then
        grep "^${key}=" "$file" 2>/dev/null | cut -d= -f2 || true
    fi
}

mps_instance_meta() {
    local name="$1"
    echo "$(mps_state_dir)/${name}.env"
}

# Read a key from an image's .meta sidecar file.
# Usage: mps_image_meta <name> <tag> <arch> <key>
# Returns empty string if not found.
mps_image_meta() {
    local name="$1" tag="$2" arch="$3" key="$4"
    local meta_file
    meta_file="$(mps_cache_dir)/images/${name}/${tag}/${arch}.meta"
    _mps_read_meta_key "$meta_file" "$key"
}

mps_save_instance_meta() {
    local name="$1"
    local meta_file
    meta_file="$(mps_instance_meta "$name")"
    cat > "$meta_file" <<EOF
MPS_INSTANCE_NAME=${name}
MPS_INSTANCE_FULL=$(mps_instance_name "$name")
MPS_CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MPS_CPUS=${MPS_CPUS:-${MPS_DEFAULT_CPUS:-2}}
MPS_MEMORY=${MPS_MEMORY:-${MPS_DEFAULT_MEMORY:-2G}}
MPS_DISK=${MPS_DISK:-${MPS_DEFAULT_DISK:-20G}}
MPS_CLOUD_INIT=${MPS_CLOUD_INIT:-${MPS_DEFAULT_CLOUD_INIT:-default}}
MPS_MOUNT_SOURCE=${MPS_MOUNT_SOURCE:-}
MPS_MOUNT_TARGET=${MPS_MOUNT_TARGET:-}
EOF
    chmod 600 "$meta_file"
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
                local drive
                drive="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
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
    local template="${1:-${MPS_CLOUD_INIT:-${MPS_DEFAULT_CLOUD_INIT:-default}}}"

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

# Check resolved resources against image .meta minimum requirements.
# Emits warnings but never blocks (always returns 0).
mps_check_image_requirements() {
    local image_url="$1"
    local cpus="$2"
    local memory="$3"
    local disk="$4"

    # Only check for mps cached images (file:// URLs)
    [[ "$image_url" == file://* ]] || return 0

    # Derive meta file path from image file path
    local img_path="${image_url#file://}"
    local meta_file="${img_path%.img}.meta"
    [[ -f "$meta_file" ]] || return 0

    local warned=false

    # Check CPUs
    local min_cpus=""
    min_cpus="$(_mps_read_meta_key "$meta_file" "MIN_CPUS")"
    if [[ -n "$min_cpus" && "$cpus" =~ ^[0-9]+$ && "$min_cpus" =~ ^[0-9]+$ ]]; then
        if [[ "$cpus" -lt "$min_cpus" ]]; then
            mps_log_warn "CPUs ($cpus) below image minimum ($min_cpus)"
            warned=true
        fi
    fi

    # Check memory
    local min_memory=""
    min_memory="$(_mps_read_meta_key "$meta_file" "MIN_MEMORY")"
    if [[ -n "$min_memory" && -n "$memory" ]]; then
        local mem_mb min_mem_mb
        mem_mb="$(_mps_parse_size_mb "$memory")"
        min_mem_mb="$(_mps_parse_size_mb "$min_memory")"
        if [[ "$mem_mb" -lt "$min_mem_mb" ]]; then
            mps_log_warn "Memory ($memory) below image minimum ($min_memory)"
            warned=true
        fi
    fi

    # Check disk
    local min_disk=""
    min_disk="$(_mps_read_meta_key "$meta_file" "MIN_DISK")"
    if [[ -n "$min_disk" && -n "$disk" ]]; then
        local disk_mb min_disk_mb
        disk_mb="$(_mps_parse_size_mb "$disk")"
        min_disk_mb="$(_mps_parse_size_mb "$min_disk")"
        if [[ "$disk_mb" -lt "$min_disk_mb" ]]; then
            mps_log_warn "Disk ($disk) below image minimum ($min_disk)"
            warned=true
        fi
    fi

    # Suggest recommended profile if any warnings
    if [[ "$warned" == "true" ]]; then
        local min_profile=""
        min_profile="$(_mps_read_meta_key "$meta_file" "MIN_PROFILE")"
        if [[ -n "$min_profile" ]]; then
            mps_log_warn "Recommended minimum profile: $min_profile"
        fi
    fi

    return 0
}

mps_validate_resources() {
    local cpus="${1:-}"
    local memory="${2:-}"
    local disk="${3:-}"

    if [[ -n "$cpus" && ! "$cpus" =~ ^[0-9]+$ ]]; then
        mps_die "Invalid CPU count: $cpus (must be a positive integer)"
    fi
    if [[ -n "$cpus" && "$cpus" =~ ^[0-9]+$ && "$cpus" -lt 1 ]]; then
        mps_die "CPU count must be at least 1 (got $cpus)"
    fi

    if [[ -n "$memory" && ! "$memory" =~ ^[0-9]+[GgMm]?$ ]]; then
        mps_die "Invalid memory: $memory (e.g., 4G, 512M)"
    fi
    if [[ -n "$memory" && "$memory" =~ ^[0-9]+[GgMm]?$ ]]; then
        local mem_mb
        mem_mb="$(_mps_parse_size_mb "$memory")"
        if [[ "$mem_mb" -lt 512 ]]; then
            mps_die "Memory must be at least 512M (got $memory)"
        fi
    fi

    if [[ -n "$disk" && ! "$disk" =~ ^[0-9]+[GgMm]?$ ]]; then
        mps_die "Invalid disk: $disk (e.g., 50G, 100G)"
    fi
    if [[ -n "$disk" && "$disk" =~ ^[0-9]+[GgMm]?$ ]]; then
        local disk_mb
        disk_mb="$(_mps_parse_size_mb "$disk")"
        if [[ "$disk_mb" -lt 1024 ]]; then
            mps_die "Disk must be at least 1G (got $disk)"
        fi
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

# ---------- SSH Key Helpers ----------

# Resolve SSH public key path.
# Priority: explicit path > MPS_SSH_KEY config > ~/.ssh/ auto-detect
# If given a private key path (no .pub), appends .pub.
mps_resolve_ssh_pubkey() {
    local explicit_path="${1:-${MPS_SSH_KEY:-}}"

    if [[ -n "$explicit_path" ]]; then
        # If user gave a private key path, derive the pubkey path
        if [[ "$explicit_path" != *.pub ]]; then
            explicit_path="${explicit_path}.pub"
        fi
        if [[ -f "$explicit_path" ]]; then
            echo "$explicit_path"
            return
        fi
        mps_die "SSH public key not found: ${explicit_path}"
    fi

    # Auto-detect from ~/.ssh/
    local key_name
    for key_name in id_ed25519.pub id_ecdsa.pub id_rsa.pub; do
        if [[ -f "${HOME}/.ssh/${key_name}" ]]; then
            echo "${HOME}/.ssh/${key_name}"
            return
        fi
    done

    mps_die "No SSH key found. Provide one with --ssh-key <path>, set MPS_SSH_KEY in config, or generate a key with: ssh-keygen -t ed25519"
}

# Derive SSH private key path from public key path (strip .pub).
# Verifies the private key file exists.
mps_resolve_ssh_privkey() {
    local explicit_path="${1:-}"
    local pubkey_path
    pubkey_path="$(mps_resolve_ssh_pubkey "$explicit_path")"

    local privkey_path="${pubkey_path%.pub}"
    if [[ ! -f "$privkey_path" ]]; then
        mps_die "SSH private key not found: ${privkey_path} (derived from ${pubkey_path})"
    fi
    echo "$privkey_path"
}

# Inject SSH public key into a running instance.
# Checks instance metadata to avoid re-injection.
# Writes MPS_SSH_KEY and MPS_SSH_INJECTED=true to metadata.
mps_inject_ssh_key() {
    local instance_name="$1"
    local short_name="$2"
    local pubkey_path="$3"
    local privkey_path="$4"

    # Check if already injected
    local meta_file
    meta_file="$(mps_instance_meta "$short_name")"
    if [[ -f "$meta_file" ]]; then
        local injected=""
        injected="$(_mps_read_meta_key "$meta_file" "MPS_SSH_INJECTED")"
        if [[ "$injected" == "true" ]]; then
            mps_log_debug "SSH key already injected for '${short_name}'"
            return 0
        fi
    fi

    mps_log_info "Injecting SSH key into '${short_name}'..."

    # Transfer public key file into the instance, then append to authorized_keys.
    # Using multipass transfer avoids shell-interpolation risks with inline echo.
    # Create temp file inside VM with mktemp (unpredictable name).
    local tmp_dest
    tmp_dest="$(multipass exec "$instance_name" -- mktemp /tmp/mps_pubkey_XXXXXXXX.pub)"
    if ! multipass transfer "$pubkey_path" "${instance_name}:${tmp_dest}"; then
        mps_die "Failed to transfer SSH public key to '${instance_name}'"
    fi
    if ! multipass exec "$instance_name" -- bash -c \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat '${tmp_dest}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && rm -f '${tmp_dest}'"; then
        mps_die "Failed to inject SSH key into '${instance_name}'"
    fi

    # Record in instance metadata
    if [[ -f "$meta_file" ]]; then
        # Append to existing metadata
        printf "MPS_SSH_KEY=%s\nMPS_SSH_INJECTED=true\n" "$privkey_path" >> "$meta_file"
    else
        # Create metadata file with SSH info
        printf "MPS_SSH_KEY=%s\nMPS_SSH_INJECTED=true\n" "$privkey_path" > "$meta_file"
    fi
    chmod 600 "$meta_file"

    mps_log_info "SSH key injected."
}

# Orchestrator: resolve key, inject if needed, return private key path.
# Used by ssh-config only.
mps_ensure_ssh_key() {
    local instance_name="$1"
    local short_name="$2"
    local ssh_key_arg="${3:-}"

    local pubkey_path privkey_path
    pubkey_path="$(mps_resolve_ssh_pubkey "$ssh_key_arg")"
    privkey_path="${pubkey_path%.pub}"

    if [[ ! -f "$privkey_path" ]]; then
        mps_die "SSH private key not found: ${privkey_path} (derived from ${pubkey_path})"
    fi

    mps_inject_ssh_key "$instance_name" "$short_name" "$pubkey_path" "$privkey_path"

    echo "$privkey_path"
}

# Check that SSH has been configured for an instance (via mps ssh-config).
# Returns private key path from metadata.
# If not configured, errors with instructions.
mps_require_ssh_key() {
    local instance_name="$1"
    local short_name="$2"

    local meta_file
    meta_file="$(mps_instance_meta "$short_name")"

    if [[ -f "$meta_file" ]]; then
        local injected=""
        injected="$(_mps_read_meta_key "$meta_file" "MPS_SSH_INJECTED")"
        if [[ "$injected" == "true" ]]; then
            local ssh_key=""
            ssh_key="$(_mps_read_meta_key "$meta_file" "MPS_SSH_KEY")"
            if [[ -n "$ssh_key" && -f "$ssh_key" ]]; then
                echo "$ssh_key"
                return 0
            fi
        fi
    fi

    mps_die "SSH not configured for '${short_name}'. Run: mps ssh-config --name ${short_name}"
}

# ---------- Port Forwarding Helpers ----------

# Verify a PID belongs to an ssh process before signaling it.
_mps_is_ssh_pid() {
    local pid="$1" use_sudo="$2"
    local pname
    if [[ "$use_sudo" == "true" ]]; then
        pname="$(sudo ps -o comm= -p "$pid" 2>/dev/null)" || return 1
    else
        pname="$(ps -o comm= -p "$pid" 2>/dev/null)" || return 1
    fi
    [[ "$pname" == "ssh" ]]
}

# Return the path to the .ports tracking file for an instance
mps_ports_file() {
    local short_name="$1"
    echo "$(mps_state_dir)/${short_name}.ports"
}

# Gather port specs from MPS_PORTS config and instance metadata.
# Deduplicates by host_port (first occurrence wins).
# Outputs newline-separated host:guest pairs.
mps_collect_port_specs() {
    local short_name="$1"
    local seen_ports=""
    local -a specs=()

    # Source 1: MPS_PORTS config (space-separated host:guest pairs)
    local port_spec
    if [[ -n "${MPS_PORTS:-}" ]]; then
        for port_spec in $MPS_PORTS; do
            local hp="${port_spec%%:*}"
            case " $seen_ports " in
                *" $hp "*) ;;  # already seen, skip
                *)
                    seen_ports="${seen_ports} ${hp}"
                    specs+=("$port_spec")
                    ;;
            esac
        done
    fi

    # Source 2: MPS_PORT_FORWARD+ entries in instance metadata
    local meta_file
    meta_file="$(mps_instance_meta "$short_name")"
    if [[ -f "$meta_file" ]]; then
        while IFS='=' read -r key val; do
            if [[ "$key" == "MPS_PORT_FORWARD+" ]]; then
                local hp="${val%%:*}"
                case " $seen_ports " in
                    *" $hp "*) ;;  # already seen, skip
                    *)
                        seen_ports="${seen_ports} ${hp}"
                        specs+=("$val")
                        ;;
                esac
            fi
        done < "$meta_file"
    fi

    local s
    for s in ${specs[@]+"${specs[@]}"}; do
        echo "$s"
    done
}

# Forward a single port via SSH tunnel.
# Args: instance_name short_name port_spec [--privileged]
# Returns 0 on success, 1 on failure (warns but never dies).
mps_forward_port() {
    local instance_name="$1"
    local short_name="$2"
    local port_spec="$3"
    local privileged="${4:-}"

    # Parse and validate
    local host_port="${port_spec%%:*}"
    local guest_port="${port_spec#*:}"

    if [[ -z "$host_port" || -z "$guest_port" ]]; then
        mps_log_warn "Invalid port spec: '${port_spec}' — skipping"
        return 1
    fi
    if [[ ! "$host_port" =~ ^[0-9]+$ ]] || [[ ! "$guest_port" =~ ^[0-9]+$ ]]; then
        mps_log_warn "Ports must be numbers (got '${port_spec}') — skipping"
        return 1
    fi
    if [[ "$host_port" -lt 1 || "$host_port" -gt 65535 ]] || \
       [[ "$guest_port" -lt 1 || "$guest_port" -gt 65535 ]]; then
        mps_log_warn "Ports must be 1-65535 (got '${port_spec}') — skipping"
        return 1
    fi

    # Privileged port check (< 1024 requires root)
    local _use_sudo=false
    if [[ "$host_port" -lt 1024 ]] && [[ "$(id -u)" -ne 0 ]]; then
        if [[ "$privileged" != "--privileged" ]]; then
            mps_log_warn "Host port ${host_port} is a privileged port (< 1024) and requires elevated privileges. Re-run with --privileged: mps port forward --privileged ${short_name} ${port_spec}"
            return 1
        fi
        _use_sudo=true
    fi

    # Get instance IP
    local ip
    ip="$(mp_ipv4 "$instance_name")" || true
    if [[ -z "$ip" ]]; then
        mps_log_warn "Cannot determine IP for '${instance_name}' — skipping port ${port_spec}"
        return 1
    fi

    # Get SSH credentials (requires prior mps ssh-config setup)
    local ssh_key="" ssh_user="ubuntu"
    local meta_file
    meta_file="$(mps_instance_meta "$short_name")"
    if [[ -f "$meta_file" ]]; then
        local injected=""
        injected="$(_mps_read_meta_key "$meta_file" "MPS_SSH_INJECTED")"
        if [[ "$injected" == "true" ]]; then
            ssh_key="$(_mps_read_meta_key "$meta_file" "MPS_SSH_KEY")"
        fi
    fi
    if [[ -z "$ssh_key" || ! -f "$ssh_key" ]]; then
        mps_log_warn "SSH not configured for '${short_name}' — skipping port ${port_spec}. Run: mps ssh-config --name ${short_name}"
        return 1
    fi

    # Check for existing active tunnel on same host port
    local ports_file
    ports_file="$(mps_ports_file "$short_name")"
    if [[ -f "$ports_file" ]]; then
        local _line
        while IFS= read -r _line; do
            [[ -z "$_line" ]] && continue
            local _fhp="" _fpid="" _fsudo=false
            if [[ "$_line" =~ ^([0-9]+):[0-9]+:s:([0-9]+)$ ]]; then
                _fhp="${BASH_REMATCH[1]}"; _fpid="${BASH_REMATCH[2]}"; _fsudo=true
            elif [[ "$_line" =~ ^([0-9]+):[0-9]+:([0-9]+)$ ]]; then
                _fhp="${BASH_REMATCH[1]}"; _fpid="${BASH_REMATCH[2]}"
            fi
            if [[ "$_fhp" == "$host_port" && -n "$_fpid" ]]; then
                # Verify PID is actually an SSH process before trusting it
                if ! _mps_is_ssh_pid "$_fpid" "$_fsudo"; then
                    continue
                fi
                local _alive=false
                if [[ "$_fsudo" == "true" ]]; then
                    sudo kill -0 "$_fpid" 2>/dev/null && _alive=true
                else
                    kill -0 "$_fpid" 2>/dev/null && _alive=true
                fi
                if [[ "$_alive" == "true" ]]; then
                    mps_log_debug "Port ${host_port} already forwarded (PID ${_fpid}) — skipping"
                    return 0
                fi
            fi
        done < "$ports_file"
    fi

    # Build SSH tunnel command
    local -a ssh_cmd=(ssh -N -f
        -L "${host_port}:localhost:${guest_port}"
        -o StrictHostKeyChecking=accept-new
        -o UserKnownHostsFile=/dev/null
        -o LogLevel=ERROR
    )
    if [[ -n "$ssh_key" && -f "$ssh_key" ]]; then
        ssh_cmd+=(-i "$ssh_key")
    fi
    ssh_cmd+=("${ssh_user}@${ip}")

    # Elevate with sudo for privileged ports
    if [[ "$_use_sudo" == "true" ]]; then
        if ! sudo "${ssh_cmd[@]}"; then
            mps_log_warn "Failed to forward privileged port ${host_port}:${guest_port} (sudo may have been denied)"
            return 1
        fi
    elif ! "${ssh_cmd[@]}"; then
        mps_log_warn "Failed to forward port ${host_port}:${guest_port}"
        return 1
    fi

    # Track PID (sudo-spawned ssh runs as root, needs sudo pgrep)
    local pid
    if [[ "$_use_sudo" == "true" ]]; then
        pid="$(sudo pgrep -f "ssh.*-L.*${host_port}:localhost:${guest_port}.*${ip}" | tail -1)" || true
    else
        pid="$(pgrep -f "ssh.*-L.*${host_port}:localhost:${guest_port}.*${ip}" | tail -1)" || true
    fi
    if [[ -n "$pid" ]]; then
        # Prefix with 's:' to mark sudo-owned tunnels for cleanup
        local owner_prefix=""
        [[ "$_use_sudo" == "true" ]] && owner_prefix="s:"
        echo "${host_port}:${guest_port}:${owner_prefix}${pid}" >> "$ports_file"
        chmod 600 "$ports_file"
        mps_log_debug "Port forward active (PID ${pid}): localhost:${host_port} → ${instance_name}:${guest_port}"
    else
        mps_log_warn "Port forward started but could not track PID for ${port_spec}"
    fi
    return 0
}

# Auto-forward all ports gathered from config and metadata.
mps_auto_forward_ports() {
    local instance_name="$1"
    local short_name="$2"
    local count=0

    local specs
    specs="$(mps_collect_port_specs "$short_name")"
    if [[ -z "$specs" ]]; then
        return 0
    fi

    local spec
    while IFS= read -r spec; do
        [[ -z "$spec" ]] && continue
        if mps_forward_port "$instance_name" "$short_name" "$spec"; then
            count=$((count + 1))
        fi
    done <<< "$specs"

    if [[ $count -gt 0 ]]; then
        mps_log_info "Forwarded ${count} port(s)."
    fi
}

# Kill all tracked port forwards for an instance.
# Returns silently if no .ports file exists.
mps_kill_port_forwards() {
    local short_name="$1"
    local ports_file
    ports_file="$(mps_ports_file "$short_name")"

    if [[ ! -f "$ports_file" ]]; then
        return 0
    fi

    local killed=0
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Format: host_port:guest_port:[s:]pid — 's:' prefix marks sudo-owned tunnels
        local pid="" use_sudo=false
        if [[ "$line" =~ :s:([0-9]+)$ ]]; then
            pid="${BASH_REMATCH[1]}"
            use_sudo=true
        elif [[ "$line" =~ :([0-9]+)$ ]]; then
            pid="${BASH_REMATCH[1]}"
        fi
        if [[ -z "$pid" ]]; then
            continue
        fi
        # Verify PID is actually an SSH process before killing
        if ! _mps_is_ssh_pid "$pid" "$use_sudo"; then
            continue
        fi
        if [[ "$use_sudo" == "true" ]]; then
            if sudo kill -0 "$pid" 2>/dev/null; then
                sudo kill "$pid" 2>/dev/null || true
                killed=$((killed + 1))
            fi
        elif kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            killed=$((killed + 1))
        fi
    done < "$ports_file"

    if [[ $killed -gt 0 ]]; then
        mps_log_debug "Killed ${killed} port forward(s) for '${short_name}'"
    fi
}

# Reset port forwards: kill existing tunnels, clear tracking file, optionally auto-forward.
mps_reset_port_forwards() {
    local instance_name="$1"
    local short_name="$2"
    local auto_forward="${3:-}"
    mps_kill_port_forwards "$short_name"
    local ports_file
    ports_file="$(mps_ports_file "$short_name")"
    [[ -f "$ports_file" ]] && true > "$ports_file"
    if [[ "$auto_forward" == "--auto-forward" ]]; then
        mps_auto_forward_ports "$instance_name" "$short_name"
    fi
}
