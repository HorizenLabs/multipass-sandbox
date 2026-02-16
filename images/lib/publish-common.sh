#!/usr/bin/env bash
# images/lib/publish-common.sh — Shared helpers for publish, update-manifest, and generate-index scripts
#
# Source this file from calling scripts:
#   source "${SCRIPT_DIR}/lib/publish-common.sh"
#
# Provides:
#   publish_init          — Set SCRIPT_DIR, MPS_ROOT, BUCKET from caller context
#   _validate_semver      — Validate SemVer format
#   _b2_cleanup_old_versions — Delete old B2 file versions (keep newest)
#   _read_xmps_metadata   — Read x-mps metadata from a layer YAML
#   _b2_merge_manifest_entry — Merge an arch entry into the manifest via jq
#   _format_size          — Human-readable file size formatting

# ---------- publish_init ----------
# Sets SCRIPT_DIR (caller's directory), MPS_ROOT, sources config/defaults.env, sets BUCKET.
# Must be called before any other function in this file.
publish_init() {
    # BASH_SOURCE[0] = this file (publish-common.sh)
    # BASH_SOURCE[1] = the file that called publish_init (e.g., publish.sh)
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    MPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

    # shellcheck source=../../config/defaults.env
    source "${MPS_ROOT}/config/defaults.env"

    BUCKET="${MPS_B2_BUCKET:-mpsandbox}"
    # shellcheck disable=SC2034  # Used by callers
    MANIFEST_FILE="${SCRIPT_DIR}/manifest.json"
}

# ---------- _validate_semver ----------
# Validates that a string is a valid SemVer version (x.y.z).
# Args: $1 = version string
# Returns: 0 on success, exits with error on failure
_validate_semver() {
    local version="$1"
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "ERROR: Version must be SemVer format (e.g., 1.0.0). Got: $version"
        exit 1
    fi
}

# ---------- _b2_cleanup_old_versions ----------
# Deletes all but the latest (newest) version of a specific file in B2.
# B2 retains all file versions; old versions still consume storage.
# Args: $1 = file path in bucket (without b2:// prefix)
_b2_cleanup_old_versions() {
    local file_path="$1"

    # List all versions in the parent directory (b2 ls --versions: newest first)
    local parent_dir
    parent_dir="$(dirname "$file_path")"

    local versions
    versions="$(b2 ls --json --versions "b2://${BUCKET}/${parent_dir}/" 2>/dev/null)" || return 0

    # Filter to upload actions matching the exact file path, skip newest, collect old IDs
    # b2 ls --json returns an array; .[] unwraps it into individual objects
    local old_ids
    old_ids="$(echo "$versions" \
        | jq -r --arg fp "$file_path" \
            '.[] | select(.action == "upload" and .fileName == $fp) | .fileId' \
        | tail -n +2)"

    if [[ -z "$old_ids" ]]; then
        echo "  No old versions found."
        return 0
    fi

    local count=0
    while IFS= read -r file_id; do
        [[ -n "$file_id" ]] || continue
        echo "  Deleting old version: ${file_id}"
        b2 rm "b2id://${file_id}" || true
        count=$((count + 1))
    done <<< "$old_ids"
    echo "  Removed ${count} old version(s)."
}

# ---------- _read_xmps_metadata ----------
# Reads x-mps metadata from a layer YAML file.
# Sets: META_DISK_SIZE, META_MIN_PROFILE, META_MIN_DISK, META_MIN_MEMORY, META_MIN_CPUS
# Args: $1 = layer YAML file path
_read_xmps_metadata() {
    local layer_file="$1"

    # shellcheck disable=SC2034  # All META_* vars used by callers
    META_DISK_SIZE=""
    # shellcheck disable=SC2034
    META_MIN_PROFILE=""
    # shellcheck disable=SC2034
    META_MIN_DISK=""
    # shellcheck disable=SC2034
    META_MIN_MEMORY=""
    # shellcheck disable=SC2034
    META_MIN_CPUS=""
    if [[ -f "$layer_file" ]] && command -v yq &>/dev/null; then
        # shellcheck disable=SC2034
        META_DISK_SIZE="$(yq '.x-mps.disk_size // ""' "$layer_file")"
        # shellcheck disable=SC2034
        META_MIN_PROFILE="$(yq '.x-mps.min_profile // ""' "$layer_file")"
        # shellcheck disable=SC2034
        META_MIN_DISK="$(yq '.x-mps.min_disk // ""' "$layer_file")"
        # shellcheck disable=SC2034
        META_MIN_MEMORY="$(yq '.x-mps.min_memory // ""' "$layer_file")"
        # shellcheck disable=SC2034
        META_MIN_CPUS="$(yq '.x-mps.min_cpus // ""' "$layer_file")"
    fi
}

# ---------- _b2_merge_manifest_entry ----------
# Merges a single arch entry into the manifest JSON using jq.
# Args: $1  = input manifest file
#       $2  = output manifest file
#       $3  = image name (flavor)
#       $4  = version
#       $5  = architecture
#       $6  = relative URL
#       $7  = sha256 hash
#       $8  = build date (ISO 8601)
#       $9  = file size in bytes (empty string if unknown)
#       $10 = disk_size metadata (empty string if not set)
#       $11 = min_profile metadata (empty string if not set)
#       $12 = min_disk metadata (empty string if not set)
#       $13 = min_memory metadata (empty string if not set)
#       $14 = min_cpus metadata (empty string if not set)
_b2_merge_manifest_entry() {
    local manifest_in="$1"
    local manifest_out="$2"
    local name="$3"
    local ver="$4"
    local arch="$5"
    local url="$6"
    local sha="$7"
    local build_date="$8"
    local file_size="${9}"
    local disk_size="${10}"
    local min_profile="${11}"
    local min_disk="${12}"
    local min_memory="${13}"
    local min_cpus="${14}"

    jq \
        --arg name "$name" \
        --arg ver "$ver" \
        --arg arch "$arch" \
        --arg url "$url" \
        --arg sha "$sha" \
        --arg build_date "$build_date" \
        --arg file_size "$file_size" \
        --arg disk_size "$disk_size" \
        --arg min_profile "$min_profile" \
        --arg min_disk "$min_disk" \
        --arg min_memory "$min_memory" \
        --arg min_cpus "$min_cpus" \
        '
        # Ensure image entry exists
        .images[$name] //= {"description": "", "versions": {}, "latest": null} |
        # Inject x-mps metadata (overwrite if present)
        (if $disk_size != "" then .images[$name].disk_size = $disk_size else . end) |
        (if $min_profile != "" then .images[$name].min_profile = $min_profile else . end) |
        (if $min_disk != "" then .images[$name].min_disk = $min_disk else . end) |
        (if $min_memory != "" then .images[$name].min_memory = $min_memory else . end) |
        (if $min_cpus != "" then .images[$name].min_cpus = ($min_cpus | tonumber) else . end) |
        # Ensure version entry exists
        .images[$name].versions[$ver] //= {} |
        # Set arch-specific data (include file_size if available)
        .images[$name].versions[$ver][$arch] = (
            {
                "url": $url,
                "sha256": $sha,
                "build_date": $build_date
            } + if $file_size != "" then {"file_size": ($file_size | tonumber)} else {} end
        ) |
        # Update latest pointer
        .images[$name].latest = $ver
        ' "$manifest_in" > "$manifest_out"
}

# ---------- _format_size ----------
# Formats a file size in bytes to a human-readable string (B, KiB, MiB, GiB).
# Args: $1 = size in bytes (empty or non-numeric returns "-")
_format_size() {
    local bytes="$1"
    if [[ -z "$bytes" || "$bytes" == "null" ]]; then
        echo "-"
        return
    fi
    awk -v b="$bytes" 'BEGIN {
        if (b+0 != b) { print "-"; exit }
        if (b < 1024) { printf "%d B\n", b }
        else if (b < 1048576) { printf "%.1f KiB\n", b/1024 }
        else if (b < 1073741824) { printf "%.1f MiB\n", b/1048576 }
        else { printf "%.2f GiB\n", b/1073741824 }
    }'
}
