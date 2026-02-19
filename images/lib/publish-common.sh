#!/usr/bin/env bash
# images/lib/publish-common.sh — Shared helpers for publish, update-manifest, and generate-index scripts
#
# Source this file from calling scripts:
#   source "${SCRIPT_DIR}/lib/publish-common.sh"
#
# Provides:
#   publish_init          — Set SCRIPT_DIR, MPS_ROOT, BUCKET from caller context
#   _validate_semver      — Validate SemVer format
#   _validate_required_vars — Check that named env vars are set
#   _b2_cleanup_old_versions — Delete old B2 file versions (keep newest)
#   _read_xmps_metadata   — Read x-mps metadata from a layer YAML
#   _generate_meta_json   — Generate .meta.json sidecar from build metadata
#   _b2_merge_manifest_entry — Merge an arch entry into the manifest via .meta.json
#   _cf_purge_urls        — Purge URLs from Cloudflare cache
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

# ---------- _validate_required_vars ----------
# Checks that all named environment variables are non-empty.
# Args: variable names to check
# Exits with error listing all missing vars.
_validate_required_vars() {
    local -a missing=()
    local var
    for var in "$@"; do
        [[ -n "${!var:-}" ]] || missing+=("$var")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing required variables: ${missing[*]}"
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
# Sets: META_DESCRIPTION, META_DISK_SIZE, META_MIN_PROFILE, META_MIN_DISK, META_MIN_MEMORY, META_MIN_CPUS
# Args: $1 = layer YAML file path
_read_xmps_metadata() {
    local layer_file="$1"

    # shellcheck disable=SC2034  # All META_* vars used by callers
    META_DESCRIPTION=""
    # shellcheck disable=SC2034
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
        META_DESCRIPTION="$(yq '.x-mps.description // ""' "$layer_file")"
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

# ---------- _generate_meta_json ----------
# Generates a .meta.json sidecar from META_* globals + per-build params.
# Args: $1 = output file, $2 = image name, $3 = version, $4 = arch,
#       $5 = sha256, $6 = build_date, $7 = file_size (optional)
# Requires: META_DESCRIPTION, META_DISK_SIZE, META_MIN_PROFILE,
#           META_MIN_DISK, META_MIN_MEMORY, META_MIN_CPUS (from _read_xmps_metadata)
_generate_meta_json() {
    local output_file="$1" name="$2" ver="$3" arch="$4"
    local sha="$5" build_date="$6" file_size="${7:-}"

    jq -n \
        --arg image "$name" \
        --arg version "$ver" \
        --arg arch "$arch" \
        --arg sha256 "$sha" \
        --arg build_date "$build_date" \
        --arg file_size "$file_size" \
        --arg description "${META_DESCRIPTION:-}" \
        --arg disk_size "${META_DISK_SIZE:-}" \
        --arg min_profile "${META_MIN_PROFILE:-}" \
        --arg min_disk "${META_MIN_DISK:-}" \
        --arg min_memory "${META_MIN_MEMORY:-}" \
        --arg min_cpus "${META_MIN_CPUS:-}" \
        '{
            image: $image, version: $version, arch: $arch,
            sha256: $sha256, build_date: $build_date,
            description: $description, disk_size: $disk_size,
            min_profile: $min_profile, min_disk: $min_disk,
            min_memory: $min_memory,
            min_cpus: (if $min_cpus != "" then ($min_cpus | tonumber) else null end)
        } + if $file_size != "" then {file_size: ($file_size | tonumber)} else {} end' \
        > "$output_file"
}

# ---------- _b2_merge_manifest_entry ----------
# Merges a single arch entry into the manifest JSON using a .meta.json sidecar.
# Args: $1 = input manifest file
#       $2 = output manifest file
#       $3 = .meta.json sidecar file
_b2_merge_manifest_entry() {
    local manifest_in="$1"
    local manifest_out="$2"
    local meta_json="$3"

    jq --slurpfile meta "$meta_json" '
        ($meta[0].image) as $name | ($meta[0].version) as $ver | ($meta[0].arch) as $arch |
        # Ensure image entry exists
        .images[$name] //= {"description": "", "versions": {}, "latest": null} |
        # Inject flavor-level metadata from sidecar
        (if $meta[0].description != "" then .images[$name].description = $meta[0].description else . end) |
        (if $meta[0].disk_size != "" then .images[$name].disk_size = $meta[0].disk_size else . end) |
        (if $meta[0].min_profile != "" then .images[$name].min_profile = $meta[0].min_profile else . end) |
        (if $meta[0].min_disk != "" then .images[$name].min_disk = $meta[0].min_disk else . end) |
        (if $meta[0].min_memory != "" then .images[$name].min_memory = $meta[0].min_memory else . end) |
        (if $meta[0].min_cpus != null then .images[$name].min_cpus = $meta[0].min_cpus else . end) |
        # Ensure version entry exists
        .images[$name].versions[$ver] //= {} |
        # Set arch-specific data (no url field in v2)
        .images[$name].versions[$ver][$arch] = (
            {sha256: $meta[0].sha256, build_date: $meta[0].build_date}
            + if $meta[0].file_size != null then {file_size: $meta[0].file_size} else {} end
        ) |
        # Update latest pointer
        .images[$name].latest = $ver
    ' "$manifest_in" > "$manifest_out"
}

# ---------- _cf_purge_urls ----------
# Purge URLs from Cloudflare cache. No-op if CF_ZONE_ID/CF_API_TOKEN not set.
# Automatically batches into chunks of 30 (CF API limit per request).
# Returns non-zero if any batch fails.
# Args: URLs to purge
_cf_purge_urls() {
    local -a urls=("$@")
    [[ ${#urls[@]} -gt 0 ]] || return 0
    if [[ -z "${CF_ZONE_ID:-}" || -z "${CF_API_TOKEN:-}" ]]; then
        echo "  CF vars not set, skipping purge."
        return 0
    fi
    local -i i=0 batch_size=30 failures=0
    while [[ $i -lt ${#urls[@]} ]]; do
        local -a batch=("${urls[@]:$i:$batch_size}")
        local files_json response
        files_json="$(printf '%s\n' "${batch[@]}" | jq -R . | jq -sc .)"
        if ! response="$(curl -sf \
            -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/purge_cache" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "{\"files\":${files_json}}")"; then
            echo "  ERROR: CF cache purge request failed (curl error, batch at offset $i)."
            failures+=1
            i+=batch_size
            continue
        fi
        if [[ "$(echo "$response" | jq -r '.success')" != "true" ]]; then
            local errors
            errors="$(echo "$response" | jq -c '.errors // []')"
            echo "  ERROR: CF cache purge rejected (batch at offset $i): $errors"
            failures+=1
        fi
        i+=batch_size
    done
    if [[ $failures -gt 0 ]]; then
        echo "  WARNING: $failures cache purge batch(es) failed."
        return 1
    fi
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
