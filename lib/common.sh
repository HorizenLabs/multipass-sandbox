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

_mps_has_aria2c() {
    command -v aria2c &>/dev/null
}

_mps_download_file() {
    local url="$1"
    local dest="$2"

    if _mps_has_aria2c; then
        aria2c -x 8 -s 8 \
            --file-allocation=none \
            --allow-overwrite=true \
            --console-log-level=warn \
            --summary-interval=0 \
            -d "$(dirname "$dest")" \
            -o "$(basename "$dest")" \
            "$url" >&2
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
    if [[ -f "${HOME}/mps/config" ]]; then
        mps_log_debug "Loading user config from ~/mps/config"
        _mps_load_env_file "${HOME}/mps/config"
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

    # 5. Compute auto-scaled vCPU/memory from profile fractions (if not already set)
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

# Convert a size string to raw bytes (integer).  All units are base-2.
# Accepts (case insensitive): 4G, 4GB, 4GiB, 512M, 512MB, 512MiB,
# 1024K, 1024KB, 1024KiB, 1073741824B, or bare number (= bytes).
_mps_size_to_bytes() {
    local raw="$1"
    local size
    size="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
    local num="${size%%[a-z]*}"
    local unit="${size#"$num"}"
    if [[ -z "$num" || ! "$num" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "0"
        return 1
    fi
    case "$unit" in
        gib|gb|g)  awk -v n="$num" 'BEGIN { printf "%.0f", n * 1073741824 }' ;;
        mib|mb|m)  awk -v n="$num" 'BEGIN { printf "%.0f", n * 1048576 }' ;;
        kib|kb|k)  awk -v n="$num" 'BEGIN { printf "%.0f", n * 1024 }' ;;
        b|"")      awk -v n="$num" 'BEGIN { printf "%.0f", n }' ;;
        *)         echo "0"; return 1 ;;
    esac
}

# Parse a size string into megabytes (integer).  See _mps_size_to_bytes for formats.
_mps_parse_size_mb() {
    local bytes
    bytes="$(_mps_size_to_bytes "$1")" || { echo "0"; return 1; }
    awk -v b="$bytes" 'BEGIN { printf "%d", b / 1048576 }'
}

# Detect host hardware and compute MPS_CPUS/MPS_MEMORY from profile fractions.
# Only sets values that are not already set (explicit overrides always win).
_mps_compute_resources() {
    # Skip if both are already explicitly set
    if [[ -n "${MPS_CPUS:-}" && -n "${MPS_MEMORY:-}" ]]; then
        return 0
    fi

    # Detect host vCPUs
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

    # Compute vCPUs from fraction/min if not already set
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
            mps_log_debug "Auto-scaled vCPUs: ${computed_cpus} (host=${host_cpus}, fraction=${frac_num}/${frac_den}, min=${cpu_min:-none})"
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

# Generate the auto-name: mps-<folder>-<template>
# Profile is a resource sizing knob, not an identity component — excluded from
# the name so that changing the profile doesn't orphan an existing instance.
# Truncates the folder portion and appends a short hash if too long.
mps_auto_name() {
    local mount_source="${1:-}"
    local raw_template="${2:-${MPS_CLOUD_INIT:-${MPS_DEFAULT_CLOUD_INIT:-default}}}"
    local prefix="${MPS_INSTANCE_PREFIX:-mps}"

    # Strip path and extension from template name (e.g., ".mps/cloud-init.yaml" → "cloud-init")
    local template
    template="$(basename "$raw_template")"
    template="${template%.yaml}"
    template="${template%.yml}"

    if [[ -z "$mount_source" ]]; then
        mps_die "Cannot auto-name: no mount path. Use --name to specify a name, or provide a mount path."
    fi

    local folder
    folder="$(basename "$mount_source")"

    # Sanitize folder name: lowercase, replace non-alphanumeric with dash, collapse dashes
    folder="$(echo "$folder" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//')"

    # Build the full name
    local suffix="${template}"
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
        mps_auto_name "$mount_source" "$template"
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
            "${MPS_CLOUD_INIT:-${MPS_DEFAULT_CLOUD_INIT:-default}}")"
    fi
    mps_log_debug "Resolved instance name: ${instance_name}"
    echo "$instance_name"
}

# ---------- State Directory ----------

mps_state_dir() {
    local dir="${HOME}/mps/instances"
    mkdir -p "$dir"
    echo "$dir"
}

mps_cache_dir() {
    local dir="${HOME}/mps/cache"
    mkdir -p "$dir"
    echo "$dir"
}

# ---------- Instance State Guards ----------

mps_require_exists() {
    local instance_name="$1"
    local _display
    _display="$(mps_short_name "$instance_name")"
    local suffix="${2:-Create it with: mps up --name ${_display}}"
    if ! mp_instance_exists "$instance_name"; then
        mps_die "Instance '${_display}' does not exist. ${suffix}"
    fi
}

mps_require_running() {
    local instance_name="$1"
    local _display
    _display="$(mps_short_name "$instance_name")"
    local state
    state="$(mp_instance_state "$instance_name")"
    if [[ "$state" == "nonexistent" ]]; then
        mps_die "Instance '${_display}' does not exist. Create it with: mps up --name ${_display}"
    fi
    if [[ "$state" != "Running" ]]; then
        mps_die "Instance '${_display}' is not running (state: ${state}). Start it with: mps up --name ${_display}"
    fi
}

# Validate instance is running, warn about staleness, and re-establish port
# forwards.  Echoes short_name to stdout; all logging goes to stderr.
mps_prepare_running_instance() {
    local instance_name="$1"
    mps_require_running "$instance_name"
    local short_name
    short_name="$(mps_short_name "$instance_name")"
    _mps_warn_instance_staleness "$short_name"
    mps_auto_forward_ports "$instance_name" "$short_name" "Re-established"
    echo "$short_name"
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
        local workdir=""
        workdir="$(_mps_read_meta_json "$meta_file" '.workdir')"
        if [[ -n "$workdir" ]]; then
            mps_log_debug "Using workdir from metadata: ${workdir}"
            echo "$workdir"
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

    # Download to .part file — atomic rename after verification prevents
    # interrupted downloads from leaving corrupt .img files in the cache.
    # A .part.sha256 sidecar records the expected hash so that aria2c can
    # resume a previous partial download when the server image hasn't changed.
    local cache_dir
    cache_dir="$(mps_cache_dir)/images/${image_name}/${image_version}"
    mkdir -p "$cache_dir"
    local dest_file="${cache_dir}/${arch}.img"
    local part_file="${dest_file}.part"
    local part_sha_file="${part_file}.sha256"

    # Decide whether a leftover .part file can be resumed or must be discarded.
    if [[ -f "$part_file" ]]; then
        local stored_sha256=""
        if [[ -f "$part_sha_file" ]]; then
            stored_sha256="$(cat "$part_sha_file")"
        fi
        if [[ -z "$expected_sha256" ]] || [[ "$stored_sha256" != "$expected_sha256" ]]; then
            # Server image changed or no checksum — discard partial download
            rm -f "$part_file" "${part_file}.aria2" "$part_sha_file"
        fi
    fi

    # Record expected SHA256 so a future interrupted retry can resume safely
    if [[ -n "$expected_sha256" ]]; then
        echo "$expected_sha256" > "$part_sha_file"
    fi

    mps_log_info "Downloading ${image_name}:${image_version} (${arch})..."
    if ! _mps_download_file "$full_url" "$part_file"; then
        # Leave .part + .part.sha256 intact so aria2c can resume next time.
        mps_log_error "Failed to download image from ${full_url}"
        return 1
    fi

    # Verify checksum
    if [[ -n "$expected_sha256" ]]; then
        mps_log_info "Verifying checksum..."
        local actual_sha256
        actual_sha256="$(_mps_sha256 "$part_file" | cut -d' ' -f1)"
        if [[ "$actual_sha256" != "$expected_sha256" ]]; then
            rm -f "$part_file" "${part_file}.aria2" "$part_sha_file"
            mps_log_error "Checksum mismatch! Expected: ${expected_sha256}, Got: ${actual_sha256}"
            return 1
        fi
        mps_log_info "Checksum verified."
    fi

    # Atomic rename — only now does the .img file appear in the cache
    mv -f "$part_file" "$dest_file"
    rm -f "$part_sha_file" "${part_file}.aria2"

    # Save remote .meta.json verbatim — enables HEAD -z staleness checks.
    # File mtime (set to "now" by this write) is the reference for subsequent checks.
    echo "$meta_json" > "${cache_dir}/${arch}.meta.json"

    # Post-pull integrity check: verify written file against .meta.json SHA256.
    # Catches disk corruption or partial writes that the in-flight check may miss.
    local meta_sha256=""
    meta_sha256="$(echo "$meta_json" | jq -r '.sha256 // empty')"
    if [[ -n "$meta_sha256" && ${#meta_sha256} -eq 64 ]]; then
        local ondisk_sha256
        ondisk_sha256="$(_mps_sha256 "$dest_file" | cut -d' ' -f1)"
        if [[ "$ondisk_sha256" != "$meta_sha256" ]]; then
            rm -f "$dest_file" "${cache_dir}/${arch}.meta.json"
            mps_log_error "Post-pull integrity check failed (expected: ${meta_sha256}, got: ${ondisk_sha256})"
            return 1
        fi
    fi

    mps_log_info "Image '${image_name}:${image_version}' cached successfully."
    return 0
}

# Resolve an image spec to a file:// URL (if cached) or pass through unchanged.
# Input: "base", "base:1.0.0", "base:local", "base:latest", "24.04"
# Output: "file:///home/.../mps/cache/images/base/1.0.0/amd64.img" or "24.04"
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

    # If the image name directory doesn't exist or contains no .img files, try auto-pull
    local _has_images=false
    if [[ -d "$image_dir" ]]; then
        local _vdir _img
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

# ---------- Remote Fetch Primitives ----------

# HEAD check: has a remote URL been modified since a local reference file?
# Uses If-Modified-Since via curl -z against local file mtime.
# Returns 0 if NOT modified (304 — fresh), 1 if modified or unavailable.
_mps_remote_is_fresh() {
    local url="$1" reference_file="$2"
    [[ -f "$reference_file" ]] || return 1

    local http_code
    http_code="$(curl -s --head --connect-timeout 1 --max-time 3 \
        -z "$reference_file" -o /dev/null -w '%{http_code}' \
        "$url" 2>/dev/null)" || return 1

    [[ "$http_code" == "304" ]]
}

# Conditional GET: fetch a remote URL with If-Modified-Since caching.
# If cache_file exists and remote unchanged (304): outputs cached content.
# If cache_file exists and remote updated (200): updates file, outputs new content.
# If no cache_file: full download (returns 1 if unavailable).
# Outputs content to stdout.
_mps_remote_fetch() {
    local url="$1" cache_file="$2"

    if [[ -f "$cache_file" ]]; then
        curl --connect-timeout 1 --max-time 3 -fsSL \
            -z "$cache_file" -o "$cache_file" \
            "$url" 2>/dev/null || true
    else
        mkdir -p "$(dirname "$cache_file")"
        curl --connect-timeout 1 --max-time 3 -fsSL \
            -o "$cache_file" "$url" 2>/dev/null || return 1
    fi

    [[ -f "$cache_file" ]] || return 1
    cat "$cache_file"
}

# ---------- Image Staleness Detection ----------

# Fetch remote manifest.json to stdout. Thin wrapper around _mps_remote_fetch.
# Caches locally at ~/mps/cache/manifest.json with conditional GET.
# Returns 1 only if no manifest is available (neither remote nor cached).
_mps_fetch_manifest() {
    local base_url="${MPS_IMAGE_BASE_URL:-}"
    [[ -z "$base_url" ]] && return 1
    _mps_remote_fetch "${base_url}/manifest.json" "$(mps_cache_dir)/manifest.json"
}

# Read cached manifest.json from disk (no network). Returns manifest on stdout.
# Returns 1 if no cached manifest exists.
_mps_read_cached_manifest() {
    local cache_file
    cache_file="$(mps_cache_dir)/manifest.json"
    [[ -f "$cache_file" ]] || return 1
    cat "$cache_file"
}

# Compare local .meta.json SHA256 vs remote .meta.json sidecar (HEAD + body fallback).
# Prints one of: up-to-date, stale, update:<ver>, unknown.
_mps_check_image_staleness() {
    local manifest="$1" name="$2" version="$3" arch="$4"

    # Skip non-SemVer tags (e.g. "local")
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "unknown"
        return
    fi

    # Get local SHA256 from .meta.json
    local local_sha256
    local_sha256="$(mps_image_meta "$name" "$version" "$arch" "sha256")"
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

    # Rebuild detection via remote .meta.json sidecar
    # (uploaded atomically with image — always current, unlike manifest during CI fan-in)
    local base_url="${MPS_IMAGE_BASE_URL:-}"
    local meta_url="${base_url}/${name}/${version}/${arch}.img.meta.json"
    local local_meta
    local_meta="$(mps_cache_dir)/images/${name}/${version}/${arch}.meta.json"

    # Fast path: HEAD check — 304 means remote .meta.json unchanged since pull
    if [[ -n "$base_url" ]] && _mps_remote_is_fresh "$meta_url" "$local_meta"; then
        echo "up-to-date"
        return
    fi

    # HEAD said modified or unavailable — confirm with SHA256 comparison.
    # Fetch body to memory only (must NOT overwrite local .meta.json — it records
    # our pulled image's hash; overwriting would corrupt staleness state).
    local remote_sha256=""
    if [[ -n "$base_url" ]]; then
        local remote_meta
        remote_meta="$(curl --connect-timeout 1 --max-time 3 -fsSL \
            "$meta_url" 2>/dev/null)" || true
        if [[ -n "$remote_meta" ]]; then
            remote_sha256="$(echo "$remote_meta" | jq -r '.sha256 // empty')"
        fi
    fi

    # Fallback: manifest SHA256 (may lag behind during CI fan-in window)
    if [[ -z "$remote_sha256" ]]; then
        remote_sha256="$(echo "$manifest" | jq -r \
            ".images[\"${name}\"].versions[\"${version}\"][\"${arch}\"].sha256 // empty")"
    fi

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
    # Format: file:///home/.../mps/cache/images/<name>/<version>/<arch>.img
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

# ---------- Instance Staleness Detection ----------

# Check if an instance is stale vs its locally cached image.
# Compares instance metadata SHA256 against cached image .meta.json.
# Returns (stdout): up-to-date, stale, update:<new_ver>, unknown
_mps_check_instance_staleness() {
    local short_name="$1"
    local meta_file
    meta_file="$(mps_instance_meta "$short_name")"
    [[ -f "$meta_file" ]] || { echo "unknown"; return 0; }

    local img_name img_version img_arch img_sha256 img_source
    img_name="$(_mps_read_meta_json "$meta_file" '.image.name')"
    img_version="$(_mps_read_meta_json "$meta_file" '.image.version')"
    img_arch="$(_mps_read_meta_json "$meta_file" '.image.arch')"
    img_sha256="$(_mps_read_meta_json "$meta_file" '.image.sha256')"
    img_source="$(_mps_read_meta_json "$meta_file" '.image.source')"

    # Can't compare stock images or missing sha256
    if [[ "$img_source" == "stock" || -z "$img_sha256" ]]; then
        echo "unknown"
        return 0
    fi

    # Need name/version/arch to locate cached image
    if [[ -z "$img_name" || -z "$img_version" || -z "$img_arch" ]]; then
        echo "unknown"
        return 0
    fi

    # Check for newer SemVer version in local cache (only for SemVer tags)
    # This runs before the cache_meta check — detecting a newer local version
    # doesn't require the old version's metadata to still exist in cache.
    local has_update=""
    if [[ "$img_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local image_dir
        image_dir="$(mps_cache_dir)/images/${img_name}"
        if [[ -d "$image_dir" ]]; then
            local best_version=""
            best_version="$(_mps_resolve_latest_version "$image_dir" "$img_arch")"
            if [[ -n "$best_version" && "$best_version" != "local" ]] && _mps_semver_gt "$best_version" "$img_version"; then
                has_update="$best_version"
            fi
        fi
    fi

    if [[ -n "$has_update" ]]; then
        echo "update:${has_update}"
        return 0
    fi

    # SHA256 rebuild detection: compare instance SHA against cached image metadata.
    # Only possible when the exact version is still in cache.
    local cache_meta
    cache_meta="$(mps_cache_dir)/images/${img_name}/${img_version}/${img_arch}.meta.json"
    if [[ -f "$cache_meta" ]]; then
        local cached_sha256=""
        cached_sha256="$(_mps_read_meta_json "$cache_meta" '.sha256')"
        if [[ -n "$cached_sha256" && "$img_sha256" != "$cached_sha256" ]]; then
            echo "stale"
            return 0
        fi
    fi

    # ---- Manifest-based enhancement (no network) ----
    local manifest=""
    manifest="$(_mps_read_cached_manifest)" || true

    if [[ -n "$manifest" ]]; then
        # Newer version in manifest?
        if [[ "$img_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            local manifest_latest=""
            manifest_latest="$(echo "$manifest" | jq -r ".images[\"${img_name}\"].latest // empty")"
            if [[ -n "$manifest_latest" && "$manifest_latest" != "$img_version" ]] \
                && _mps_semver_gt "$manifest_latest" "$img_version"; then
                echo "update:manifest:${manifest_latest}"
                return 0
            fi
        fi

        # Rebuild detection via manifest SHA256
        local manifest_sha256=""
        manifest_sha256="$(echo "$manifest" | jq -r \
            ".images[\"${img_name}\"].versions[\"${img_version}\"][\"${img_arch}\"].sha256 // empty")"
        if [[ -n "$manifest_sha256" && "$img_sha256" != "$manifest_sha256" ]]; then
            echo "stale:manifest"
            return 0
        fi
    fi

    # If old version was removed and no manifest data available, we can't determine status
    if [[ ! -f "$cache_meta" ]]; then
        echo "unknown"
        return 0
    fi

    echo "up-to-date"
    return 0
}

# High-level wrapper: check instance staleness and emit warnings.
# Respects MPS_IMAGE_CHECK_UPDATES opt-out. Silent on up-to-date/unknown/failure.
_mps_warn_instance_staleness() {
    local short_name="$1"
    local skip_manifest="${2:-}"

    # Opt-out check
    [[ "${MPS_IMAGE_CHECK_UPDATES:-true}" == "true" ]] || return 0

    local status=""
    status="$(_mps_check_instance_staleness "$short_name")" || return 0

    # Suppress manifest-sourced warnings when caller already handles image staleness
    if [[ "$skip_manifest" == "--skip-manifest" ]]; then
        case "$status" in
            stale:manifest|update:manifest:*) return 0 ;;
        esac
    fi

    local meta_file
    meta_file="$(mps_instance_meta "$short_name")"
    local img_name img_version
    img_name="$(_mps_read_meta_json "$meta_file" '.image.name')"
    img_version="$(_mps_read_meta_json "$meta_file" '.image.version')"

    case "$status" in
        stale:manifest)
            mps_log_warn "Sandbox '${short_name}' was created from an older build of ${img_name}:${img_version}. Update with: mps image pull ${img_name}:${img_version} && mps destroy --name ${short_name} && mps up --name ${short_name}"
            ;;
        stale)
            mps_log_warn "Sandbox '${short_name}' was created from an older build of ${img_name}:${img_version}. Recreate with: mps destroy --name ${short_name} && mps up --name ${short_name}"
            ;;
        update:manifest:*)
            local new_ver="${status#update:manifest:}"
            mps_log_warn "Sandbox '${short_name}' uses ${img_name}:${img_version} but ${new_ver} is available. Update with: mps image pull ${img_name} && mps destroy --name ${short_name} && mps up --name ${short_name}"
            ;;
        update:*)
            local new_ver="${status#update:}"
            mps_log_warn "Sandbox '${short_name}' uses ${img_name}:${img_version} but ${new_ver} is available locally. Recreate with: mps destroy --name ${short_name} && mps up --name ${short_name}"
            ;;
    esac
    return 0
}

# ---------- CLI Version Update Check ----------

# Warn if a newer mps release is available on the CDN.
# Fetches mps-release.json (at most once per 24h), compares version + commit SHA.
# Silent on failure/offline — never blocks.
_mps_check_cli_update() {
    # Opt-out check
    [[ "${MPS_CHECK_UPDATES:-true}" == "true" ]] || return 0

    # Need a valid SemVer local version to compare
    [[ "${MPS_VERSION:-unknown}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0

    local base_url="${MPS_IMAGE_BASE_URL:-}"
    [[ -n "$base_url" ]] || return 0

    local cache_file
    cache_file="$(mps_cache_dir)/mps-release.json"

    # TTL gate: skip fetch if cache file is less than 24h old
    if [[ -f "$cache_file" ]]; then
        # find returns the file if older than 1440 min; empty = still fresh
        local stale=""
        stale="$(find "$cache_file" -mmin +1440 2>/dev/null)" || true
        if [[ -z "$stale" ]]; then
            # Cache is fresh — still parse and warn
            _mps_cli_update_warn "$cache_file"
            return 0
        fi
    fi

    # Fetch (creates/updates cache file)
    _mps_remote_fetch "${base_url}/mps-release.json" "$cache_file" >/dev/null 2>&1 || return 0

    _mps_cli_update_warn "$cache_file"
    return 0
}

# Parse cached mps-release.json and emit update warnings.
_mps_cli_update_warn() {
    local cache_file="$1"
    [[ -f "$cache_file" ]] || return 0

    local remote_version=""
    remote_version="$(jq -r '.version // empty' "$cache_file" 2>/dev/null)" || return 0
    [[ -n "$remote_version" ]] || return 0

    # Remote version is newer → suggest update
    if _mps_semver_gt "$remote_version" "$MPS_VERSION"; then
        printf "%smps: update available (%s → %s) — to update: cd %s && git pull%s\n" \
            "$_color_yellow" "$MPS_VERSION" "$remote_version" "$MPS_ROOT" "$_color_reset" >&2
        return 0
    fi

    # Versions equal — check if tag has been force-pushed (commit_sha mismatch)
    [[ "$remote_version" == "$MPS_VERSION" ]] || return 0

    local remote_sha=""
    remote_sha="$(jq -r '.commit_sha // empty' "$cache_file" 2>/dev/null)" || return 0
    if [[ -z "$remote_sha" || ${#remote_sha} -lt 7 ]]; then
        return 0
    fi

    # Ancestry check: is the remote commit_sha an ancestor of our HEAD?
    # Fails gracefully on shallow clone, missing objects, or non-git install.
    if git -C "$MPS_ROOT" merge-base --is-ancestor "$remote_sha" HEAD 2>/dev/null; then
        return 0
    fi

    # merge-base failed — either the object is missing locally (user hasn't
    # pulled the release commit yet) or it exists but isn't an ancestor of HEAD.
    # Both mean the user is behind; only suppress for non-git installs.
    if ! git -C "$MPS_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        return 0
    fi

    local remote_tag=""
    remote_tag="$(jq -r '.tag // empty' "$cache_file" 2>/dev/null)" || true
    printf "%smps: %s has been updated — to update: cd %s && git pull%s\n" \
        "$_color_yellow" "${remote_tag:-v${MPS_VERSION}}" "$MPS_ROOT" "$_color_reset" >&2
    return 0
}

# ---------- Metadata Helpers ----------

# Read a value from a JSON file using a jq expression.
# Returns empty string on missing file, missing key, or jq error.
_mps_read_meta_json() {
    local file="$1" jq_expr="$2"
    [[ -f "$file" ]] || return 0
    jq -r "$jq_expr // empty" "$file" 2>/dev/null || true
}

# Atomic write of a JSON string to a file (temp + mv + chmod 600).
_mps_write_json() {
    local file="$1" json_string="$2"
    local tmp_file="${file}.tmp.$$"
    printf '%s\n' "$json_string" > "$tmp_file"
    chmod 600 "$tmp_file"
    mv -f "$tmp_file" "$file"
}

mps_instance_meta() {
    local name="$1"
    echo "$(mps_state_dir)/${name}.json"
}

# Read a key from an image's .meta.json sidecar file.
# Usage: mps_image_meta <name> <tag> <arch> <key>
# Returns empty string if not found.
mps_image_meta() {
    local name="$1" tag="$2" arch="$3" key="$4"
    local meta_file
    meta_file="$(mps_cache_dir)/images/${name}/${tag}/${arch}.meta.json"
    [[ -f "$meta_file" ]] || return 0
    jq -r ".${key} // empty" "$meta_file"
}

mps_save_instance_meta() {
    local name="$1"
    local image_json="${2:-null}"
    local workdir="${3:-}"
    local port_forwards_json="${4:-[]}"
    local transfers_json="${5:-[]}"
    local meta_file
    meta_file="$(mps_instance_meta "$name")"
    local full_name
    full_name="$(mps_instance_name "$name")"
    local json
    json="$(jq -n \
        --arg name "$name" \
        --arg full_name "$full_name" \
        --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg cpus "${MPS_CPUS:-${MPS_DEFAULT_CPUS:-2}}" \
        --arg memory "${MPS_MEMORY:-${MPS_DEFAULT_MEMORY:-2G}}" \
        --arg disk "${MPS_DISK:-${MPS_DEFAULT_DISK:-20G}}" \
        --arg cloud_init "${MPS_CLOUD_INIT:-${MPS_DEFAULT_CLOUD_INIT:-default}}" \
        --argjson image "$image_json" \
        --arg workdir "$workdir" \
        --argjson port_forwards "$port_forwards_json" \
        --argjson transfers "$transfers_json" \
        '{
            name: $name,
            full_name: $full_name,
            created: $created,
            cpus: ($cpus | tonumber),
            memory: $memory,
            disk: $disk,
            cloud_init: $cloud_init,
            image: $image,
            workdir: (if $workdir == "" then null else $workdir end),
            ssh: null,
            port_forwards: $port_forwards,
            transfers: $transfers
        }')"
    _mps_write_json "$meta_file" "$json"
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
        # Resolve to physical absolute path (symlinks resolved via pwd -P / readlink)
        if [[ "$provided_path" = /* ]]; then
            (cd "$provided_path" 2>/dev/null && pwd -P) || mps_die "Path does not exist: $provided_path"
        else
            (cd "$provided_path" 2>/dev/null && pwd -P) || mps_die "Path does not exist: $provided_path"
        fi
    else
        pwd -P
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

# ---------- Snap Confinement Helpers ----------

# Detect active Multipass snap confinement.
# Returns 0 (true) if: snap is installed, multipass is a snap, and AppArmor is enabled.
# Short-circuits on macOS (no snap), WSL2 (AppArmor disabled), Docker (no snap).
_mps_snap_confined() {
    command -v snap >/dev/null 2>&1 \
        && snap list multipass >/dev/null 2>&1 \
        && [[ -f /sys/module/apparmor/parameters/enabled ]] \
        && [[ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" == "Y" ]]
}

# Check if a path is inside a hidden ($HOME/.*) directory and bail if snap confined.
# Usage: _mps_check_snap_path <path> <operation>
# Dies with a clear message if the path is under a $HOME dot-directory.
# No-op when snap confinement is not active.
_mps_check_snap_path() {
    local path="$1" operation="$2"
    _mps_snap_confined || return 0
    local rel="${path#${HOME}/}"
    [[ "$rel" != "$path" && -n "$rel" ]] || return 0
    local top="${rel%%/*}"
    case "$top" in
        .*) mps_die "${operation} path '${path}' is inside a hidden directory (~/${top}). Multipass snap confinement blocks access to dot-directories under \$HOME. Move to a non-hidden path." ;;
    esac
}

# Validate mount source path against security rules.
# Called after resolving to absolute path.
# Returns 0 on success, dies on hard block, warns on soft issues.
mps_validate_mount_source() {
    local source_path="$1"
    local home_dir="${HOME:-}"

    # Rule 1: Block mounts outside $HOME
    if [[ -n "$home_dir" ]]; then
        case "$source_path" in
            "${home_dir}"|"${home_dir}"/*)
                # Inside $HOME — OK
                ;;
            *)
                mps_die "Mount source must be within your home directory (${home_dir})."
                ;;
        esac
    fi

    # Rule 2: Warn on mounting $HOME directly
    if [[ "$source_path" == "$home_dir" ]]; then
        mps_log_warn "Mounting your entire home directory exposes dotfiles (.ssh, .gnupg, etc.) inside the VM."
        mps_log_warn "Consider mounting a project subdirectory instead, or use --no-mount."
    fi

    # Rule 3: Block snap-confined hidden paths under $HOME
    _mps_check_snap_path "$source_path" "Mount"
}

# Resolve the set of persistent mounts for an instance.
# Reads workdir from metadata and MPS_MOUNTS from the full config cascade:
# current env (already loaded) -> project .mps.env -> ~/mps/config -> defaults.env.
# Outputs space-separated "source:target" pairs to stdout.
# Usage: _mps_resolve_project_mounts <short_name>
_mps_resolve_project_mounts() {
    local short_name="$1"
    local -a persistent=()

    # Read workdir from metadata
    local meta_file
    meta_file="$(mps_instance_meta "$short_name")"
    local workdir=""
    if [[ -f "$meta_file" ]]; then
        workdir="$(_mps_read_meta_json "$meta_file" '.workdir')"
    fi

    # Auto-mount: workdir maps to itself (identity on Linux/macOS)
    if [[ -n "$workdir" ]]; then
        persistent+=("${workdir}:${workdir}")
    fi

    # Config mounts: try MPS_MOUNTS from current cascade first
    local config_mounts="${MPS_MOUNTS:-}"

    # If MPS_MOUNTS not set in current env and workdir is known,
    # grep it from the project's .mps.env and global config (don't source)
    if [[ -z "$config_mounts" && -n "$workdir" ]]; then
        local project_env="${workdir}/.mps.env"
        if [[ -f "$project_env" ]]; then
            config_mounts="$(grep -E '^MPS_MOUNTS=' "$project_env" 2>/dev/null | head -1 | sed 's/^MPS_MOUNTS=//' | sed 's/^["'"'"']//; s/["'"'"']$//')" || true
        fi
    fi
    if [[ -z "$config_mounts" ]]; then
        local global_config="${HOME}/mps/config"
        if [[ -f "$global_config" ]]; then
            config_mounts="$(grep -E '^MPS_MOUNTS=' "$global_config" 2>/dev/null | head -1 | sed 's/^MPS_MOUNTS=//' | sed 's/^["'"'"']//; s/["'"'"']$//')" || true
        fi
    fi
    if [[ -z "$config_mounts" ]]; then
        local defaults_env="${MPS_ROOT}/config/defaults.env"
        if [[ -f "$defaults_env" ]]; then
            config_mounts="$(grep -E '^MPS_MOUNTS=' "$defaults_env" 2>/dev/null | head -1 | sed 's/^MPS_MOUNTS=//' | sed 's/^["'"'"']//; s/["'"'"']$//')" || true
        fi
    fi

    # Parse config mounts
    if [[ -n "$config_mounts" ]]; then
        local mount
        for mount in $config_mounts; do
            local src="${mount%%:*}"
            local dst="${mount#*:}"
            if [[ "$src" != /* && -n "$workdir" ]]; then
                src="$(cd "${workdir}/$src" 2>/dev/null && pwd)" || continue
            fi
            persistent+=("${src}:${dst}")
        done
    fi

    echo "${persistent[*]}"
}

# ---------- Cloud-init Resolution ----------

mps_resolve_cloud_init() {
    local template="${1:-${MPS_CLOUD_INIT:-${MPS_DEFAULT_CLOUD_INIT:-default}}}"

    # If it's an absolute path or relative path to a file, use it directly
    if [[ -f "$template" ]]; then
        echo "$template"
        return
    fi

    # Look in the project templates directory
    local template_path="${MPS_ROOT}/templates/cloud-init/${template}.yaml"
    if [[ -f "$template_path" ]]; then
        echo "$template_path"
        return
    fi

    # Look in personal templates directory
    local user_path="${HOME}/mps/cloud-init/${template}.yaml"
    if [[ -f "$user_path" ]]; then
        echo "$user_path"
        return
    fi

    mps_die "Cloud-init template not found: $template (searched ${template_path} and ${user_path})"
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
    local meta_file="${img_path%.img}.meta.json"
    [[ -f "$meta_file" ]] || return 0

    local warned=false

    # Check vCPUs
    local min_cpus=""
    min_cpus="$(jq -r '.min_cpus // empty' "$meta_file")"
    if [[ -n "$min_cpus" && "$cpus" =~ ^[0-9]+$ && "$min_cpus" =~ ^[0-9]+$ ]]; then
        if [[ "$cpus" -lt "$min_cpus" ]]; then
            mps_log_warn "vCPUs ($cpus) below image minimum ($min_cpus)"
            warned=true
        fi
    fi

    # Check memory
    local min_memory=""
    min_memory="$(jq -r '.min_memory // empty' "$meta_file")"
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
    min_disk="$(jq -r '.min_disk // empty' "$meta_file")"
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
        min_profile="$(jq -r '.min_profile // empty' "$meta_file")"
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
        mps_die "Invalid vCPU count: $cpus (must be a positive integer)"
    fi
    if [[ -n "$cpus" && "$cpus" =~ ^[0-9]+$ && "$cpus" -lt 1 ]]; then
        mps_die "vCPU count must be at least 1 (got $cpus)"
    fi

    if [[ -n "$memory" && ! "$memory" =~ ^[0-9]+([Gg]([Ii]?[Bb])?|[Mm]([Ii]?[Bb])?|[Kk]([Ii]?[Bb])?|[Bb])?$ ]]; then
        mps_die "Invalid memory: $memory (e.g., 4G, 512M)"
    fi
    if [[ -n "$memory" && "$memory" =~ ^[0-9]+([Gg]([Ii]?[Bb])?|[Mm]([Ii]?[Bb])?|[Kk]([Ii]?[Bb])?|[Bb])?$ ]]; then
        local mem_mb
        mem_mb="$(_mps_parse_size_mb "$memory")"
        if [[ "$mem_mb" -lt 512 ]]; then
            mps_die "Memory must be at least 512M (got $memory)"
        fi
    fi

    if [[ -n "$disk" && ! "$disk" =~ ^[0-9]+([Gg]([Ii]?[Bb])?|[Mm]([Ii]?[Bb])?|[Kk]([Ii]?[Bb])?|[Bb])?$ ]]; then
        mps_die "Invalid disk: $disk (e.g., 50G, 100G)"
    fi
    if [[ -n "$disk" && "$disk" =~ ^[0-9]+([Gg]([Ii]?[Bb])?|[Mm]([Ii]?[Bb])?|[Kk]([Ii]?[Bb])?|[Bb])?$ ]]; then
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

# ---------- Port Forwarding Helpers ----------

# Return the path to the .ports tracking file for an instance
mps_ports_file() {
    local short_name="$1"
    echo "$(mps_state_dir)/${short_name}.ports.json"
}

# Return the control socket path for a given instance + host port.
# Sockets live in ~/mps/sockets/, separate from instance metadata.
mps_port_socket() {
    local short_name="$1" host_port="$2"
    local dir="${HOME}/mps/sockets"
    mkdir -p "$dir"
    echo "${dir}/${short_name}-${host_port}.sock"
}

# Return the number of active port forwards for an instance (echoes "0" if none).
mps_port_forward_count() {
    local short_name="$1"
    local pf_file
    pf_file="$(mps_ports_file "$short_name")"
    if [[ -f "$pf_file" ]]; then
        jq 'length' "$pf_file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Gather port specs from MPS_PORTS config and instance metadata.
# Deduplicates by host_port (first occurrence wins).
# Outputs newline-separated host:guest pairs.
mps_collect_port_specs() {
    local short_name="$1"
    local seen=" "
    local -a specs=()

    # Source 1: MPS_PORTS config (space-separated host:guest pairs)
    local port_spec
    if [[ -n "${MPS_PORTS:-}" ]]; then
        for port_spec in $MPS_PORTS; do
            local hp="${port_spec%%:*}"
            case "$seen" in *" $hp "*) ;; *)
                seen="$seen$hp "
                specs+=("$port_spec")
            ;; esac
        done
    fi

    # Source 2: port_forwards array in instance metadata JSON
    local meta_file
    meta_file="$(mps_instance_meta "$short_name")"
    if [[ -f "$meta_file" ]]; then
        local pf_entry=""
        while IFS= read -r pf_entry; do
            [[ -z "$pf_entry" ]] && continue
            local hp="${pf_entry%%:*}"
            case "$seen" in *" $hp "*) ;; *)
                seen="$seen$hp "
                specs+=("$pf_entry")
            ;; esac
        done < <(_mps_read_meta_json "$meta_file" '.port_forwards[]')
    fi

    local s
    for s in ${specs[@]+"${specs[@]}"}; do
        echo "$s"
    done
}

# Forward a single port via SSH tunnel using a control socket.
# Args: instance_name short_name port_spec [--privileged]
# Returns: 0 = tunnel newly established
#          2 = already active (dedup skip)
#          1 = error (warns but never dies)
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
        mps_log_warn "Cannot determine IP for '${short_name}' — skipping port ${port_spec}"
        return 1
    fi

    # Get SSH credentials (requires prior mps ssh-config setup)
    local ssh_key="" ssh_user="ubuntu"
    local meta_file
    meta_file="$(mps_instance_meta "$short_name")"
    if [[ -f "$meta_file" ]]; then
        local injected=""
        injected="$(_mps_read_meta_json "$meta_file" '.ssh.injected')"
        if [[ "$injected" == "true" ]]; then
            ssh_key="$(_mps_read_meta_json "$meta_file" '.ssh.key')"
        fi
    fi
    if [[ -z "$ssh_key" || ! -f "$ssh_key" ]]; then
        mps_log_warn "SSH not configured for '${short_name}' — skipping port ${port_spec}. Run: mps ssh-config --name ${short_name}"
        return 1
    fi

    # Check for existing active tunnel via control socket
    local socket_path
    socket_path="$(mps_port_socket "$short_name" "$host_port")"
    if [[ -e "$socket_path" ]]; then
        local _check_ok=false
        if [[ "$_use_sudo" == "true" ]]; then
            # Use sudo -n to avoid password prompts; if cache expired, treat as not forwarded
            sudo -n ssh -O check -S "$socket_path" dummy 2>/dev/null && _check_ok=true
        else
            ssh -O check -S "$socket_path" dummy 2>/dev/null && _check_ok=true
        fi
        if [[ "$_check_ok" == "true" ]]; then
            mps_log_debug "Port ${host_port} already forwarded (socket ${socket_path}) — skipping"
            return 2
        fi
        # Stale socket — remove it before re-establishing
        rm -f "$socket_path"
    fi

    # Build SSH tunnel command with control socket
    local -a ssh_cmd=(ssh -M -S "$socket_path" -N -f
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
        if ! sudo ${ssh_cmd[@]+"${ssh_cmd[@]}"}; then
            mps_log_warn "Failed to forward privileged port ${host_port}:${guest_port} (sudo may have been denied)"
            return 1
        fi
    elif ! ${ssh_cmd[@]+"${ssh_cmd[@]}"}; then
        mps_log_warn "Failed to forward port ${host_port}:${guest_port}"
        return 1
    fi

    # Verify tunnel is up via control socket
    local _verify_ok=false
    if [[ "$_use_sudo" == "true" ]]; then
        sudo ssh -O check -S "$socket_path" dummy 2>/dev/null && _verify_ok=true
    else
        ssh -O check -S "$socket_path" dummy 2>/dev/null && _verify_ok=true
    fi

    if [[ "$_verify_ok" == "true" ]]; then
        # Record in .ports.json (socket path instead of PID)
        local ports_file
        ports_file="$(mps_ports_file "$short_name")"
        local current_json="{}"
        [[ -f "$ports_file" ]] && current_json="$(cat "$ports_file")"
        local updated
        updated="$(echo "$current_json" | jq \
            --arg hp "$host_port" \
            --argjson gp "$guest_port" \
            --arg sock "$socket_path" \
            --argjson sudo "$_use_sudo" \
            '.[$hp] = {"guest_port": $gp, "socket": $sock, "sudo": $sudo}')"
        _mps_write_json "$ports_file" "$updated"
        mps_log_debug "Port forward active (socket ${socket_path}): localhost:${host_port} → ${instance_name}:${guest_port}"
    else
        mps_log_warn "Port forward started but control socket check failed for ${port_spec}"
    fi
    return 0
}

# Auto-forward all ports gathered from config and metadata.
mps_auto_forward_ports() {
    local instance_name="$1"
    local short_name="$2"
    local verb="${3:-Forwarded}"
    local count=0

    local specs
    specs="$(mps_collect_port_specs "$short_name")"
    if [[ -z "$specs" ]]; then
        return 0
    fi

    local spec rc
    while IFS= read -r spec; do
        [[ -z "$spec" ]] && continue
        rc=0
        mps_forward_port "$instance_name" "$short_name" "$spec" || rc=$?
        # Only count newly established tunnels (0); ignore already-active (2) and errors (1)
        [[ $rc -eq 0 ]] && count=$((count + 1))
    done <<< "$specs"

    if [[ $count -gt 0 ]]; then
        mps_log_info "${verb} ${count} port forward(s)."
    fi
}

# Kill all tracked port forwards for an instance via control sockets.
# Returns silently if no .ports file exists.
mps_kill_port_forwards() {
    local short_name="$1"
    local ports_file
    ports_file="$(mps_ports_file "$short_name")"

    if [[ ! -f "$ports_file" ]]; then
        return 0
    fi

    local killed=0
    local entry
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local sock="" use_sudo=false
        sock="$(echo "$entry" | jq -r '.socket')"
        local sudo_val=""
        sudo_val="$(echo "$entry" | jq -r '.sudo')"
        [[ "$sudo_val" == "true" ]] && use_sudo=true
        if [[ -z "$sock" || "$sock" == "null" ]]; then
            continue
        fi
        # Gracefully shut down the SSH master via control socket
        if [[ "$use_sudo" == "true" ]]; then
            sudo ssh -n -O exit -S "$sock" dummy 2>/dev/null || true
        else
            ssh -n -O exit -S "$sock" dummy 2>/dev/null || true
        fi
        rm -f "$sock"
        killed=$((killed + 1))
    done < <(jq -c '.[]' "$ports_file" 2>/dev/null)

    if [[ $killed -gt 0 ]]; then
        mps_log_debug "Killed ${killed} port forward(s) for '${short_name}'"
    fi
}

# Clean up any remaining control socket files for an instance.
mps_cleanup_port_sockets() {
    local short_name="$1"
    local sock
    for sock in "${HOME}/mps/sockets/${short_name}-"*.sock; do
        if [[ -e "$sock" ]]; then rm -f "$sock"; fi
    done
}

# Reset port forwards: kill existing tunnels, clear tracking file, optionally auto-forward.
mps_reset_port_forwards() {
    local instance_name="$1"
    local short_name="$2"
    local auto_forward="${3:-}"
    mps_kill_port_forwards "$short_name"
    local ports_file
    ports_file="$(mps_ports_file "$short_name")"
    rm -f "$ports_file"
    mps_cleanup_port_sockets "$short_name"
    if [[ "$auto_forward" == "--auto-forward" ]]; then
        mps_auto_forward_ports "$instance_name" "$short_name"
    fi
}
