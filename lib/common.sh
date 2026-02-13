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

# Maximum length for Multipass instance names
MPS_MAX_INSTANCE_NAME_LEN=40

# Generate the auto-name: mps-<folder>-<template>-<profile>
# Truncates the folder portion and appends a short hash if too long.
mps_auto_name() {
    local mount_source="${1:-}"
    local template="${2:-${MPS_CLOUD_INIT:-${MPS_DEFAULT_CLOUD_INIT:-base}}}"
    local profile="${3:-${MPS_PROFILE:-${MPS_DEFAULT_PROFILE:-standard}}}"
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
        hash="$(echo -n "$folder" | md5sum | cut -c1-4)"
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
        mps_instance_name "$explicit_name"
        return
    fi

    # 2. From project config MPS_NAME
    if [[ -n "${MPS_NAME:-}" ]]; then
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

# ---------- Architecture Detection ----------

mps_detect_arch() {
    local arch
    arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    case "$arch" in
        x86_64) echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *) echo "$arch" ;;
    esac
}

# ---------- Image Resolution ----------

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

    # If the image name directory doesn't exist, pass through (e.g. "24.04")
    if [[ ! -d "$image_dir" ]]; then
        echo "$image_spec"
        return
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
        injected="$(grep '^MPS_SSH_INJECTED=' "$meta_file" 2>/dev/null | cut -d= -f2)" || true
        if [[ "$injected" == "true" ]]; then
            mps_log_debug "SSH key already injected for '${short_name}'"
            return 0
        fi
    fi

    # Read public key content
    local pubkey_content
    pubkey_content="$(cat "$pubkey_path")"

    mps_log_info "Injecting SSH key into '${short_name}'..."
    if ! multipass exec "$instance_name" -- bash -c \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '${pubkey_content}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"; then
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
        injected="$(grep '^MPS_SSH_INJECTED=' "$meta_file" 2>/dev/null | cut -d= -f2)" || true
        if [[ "$injected" == "true" ]]; then
            local ssh_key=""
            ssh_key="$(grep '^MPS_SSH_KEY=' "$meta_file" 2>/dev/null | cut -d= -f2)" || true
            if [[ -n "$ssh_key" && -f "$ssh_key" ]]; then
                echo "$ssh_key"
                return 0
            fi
        fi
    fi

    mps_die "SSH not configured for '${short_name}'. Run: mps ssh-config --name ${short_name}"
}

# ---------- Port Forwarding Helpers ----------

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
    local -A seen=()
    local -a specs=()

    # Source 1: MPS_PORTS config (space-separated host:guest pairs)
    local port_spec
    if [[ -n "${MPS_PORTS:-}" ]]; then
        for port_spec in $MPS_PORTS; do
            local hp="${port_spec%%:*}"
            if [[ -z "${seen[$hp]:-}" ]]; then
                seen[$hp]=1
                specs+=("$port_spec")
            fi
        done
    fi

    # Source 2: MPS_PORT_FORWARD+ entries in instance metadata
    local meta_file
    meta_file="$(mps_instance_meta "$short_name")"
    if [[ -f "$meta_file" ]]; then
        while IFS='=' read -r key val; do
            if [[ "$key" == "MPS_PORT_FORWARD+" ]]; then
                local hp="${val%%:*}"
                if [[ -z "${seen[$hp]:-}" ]]; then
                    seen[$hp]=1
                    specs+=("$val")
                fi
            fi
        done < "$meta_file"
    fi

    local s
    for s in "${specs[@]}"; do
        echo "$s"
    done
}

# Forward a single port via SSH tunnel.
# Returns 0 on success, 1 on failure (warns but never dies).
mps_forward_port() {
    local instance_name="$1"
    local short_name="$2"
    local port_spec="$3"

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
        injected="$(grep '^MPS_SSH_INJECTED=' "$meta_file" 2>/dev/null | cut -d= -f2)" || true
        if [[ "$injected" == "true" ]]; then
            ssh_key="$(grep '^MPS_SSH_KEY=' "$meta_file" 2>/dev/null | cut -d= -f2)" || true
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
        while IFS=: read -r fhp _ fpid; do
            if [[ "$fhp" == "$host_port" && -n "$fpid" ]] && kill -0 "$fpid" 2>/dev/null; then
                mps_log_debug "Port ${host_port} already forwarded (PID ${fpid}) — skipping"
                return 0
            fi
        done < "$ports_file"
    fi

    # Build SSH tunnel command
    local -a ssh_cmd=(ssh -N -f
        -L "${host_port}:localhost:${guest_port}"
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o LogLevel=ERROR
    )
    if [[ -n "$ssh_key" && -f "$ssh_key" ]]; then
        ssh_cmd+=(-i "$ssh_key")
    fi
    ssh_cmd+=("${ssh_user}@${ip}")

    if ! "${ssh_cmd[@]}"; then
        mps_log_warn "Failed to forward port ${host_port}:${guest_port}"
        return 1
    fi

    # Track PID
    local pid
    pid="$(pgrep -f "ssh.*-L.*${host_port}:localhost:${guest_port}.*${ip}" | tail -1)" || true
    if [[ -n "$pid" ]]; then
        echo "${host_port}:${guest_port}:${pid}" >> "$ports_file"
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
    while IFS=: read -r _hp _ pid; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            killed=$((killed + 1))
        fi
    done < "$ports_file"

    if [[ $killed -gt 0 ]]; then
        mps_log_debug "Killed ${killed} port forward(s) for '${short_name}'"
    fi
}
