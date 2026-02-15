#!/usr/bin/env bash
# shellcheck disable=SC2154  # color vars defined in lib/common.sh
# commands/image.sh — mps image [list|pull|import]

_image_usage() {
    cat <<EOF
${_color_bold}Usage:${_color_reset} mps image <subcommand> [options]

${_color_bold}Subcommands:${_color_reset}
    list                     List locally cached images
    pull <name>[:<version>]  Download an image (default: latest version)
    import <file> [options]  Import a local QCOW2 image into cache

${_color_bold}Options:${_color_reset}
    --remote           (list) Also show remote images from registry
    --help, -h         Show this help message

${_color_bold}Import Options:${_color_reset}
    --name <name>      Image name (default: auto-detect from filename)
    --tag <version>    Version tag (default: local)
    --arch <arch>      Architecture (default: auto-detect from filename or host)

${_color_bold}Examples:${_color_reset}
    mps image list
    mps image list --remote
    mps image pull base
    mps image pull base:1.0.0
    mps image import images/artifacts/mps-base-amd64.qcow2.img
    mps image import myimage.qcow2 --name base --tag 1.0.0
EOF
}

cmd_image() {
    local subcmd=""
    local -a args=()

    if [[ $# -eq 0 ]]; then
        _image_usage
        exit 1
    fi

    subcmd="$1"
    shift
    args=("$@")

    case "$subcmd" in
        list)   _image_list "${args[@]}" ;;
        pull)   _image_pull "${args[@]}" ;;
        import) _image_import "${args[@]}" ;;
        --help|-h) _image_usage ;;
        *)
            mps_log_error "Unknown image subcommand: '$subcmd'"
            _image_usage
            exit 1
            ;;
    esac
}

# ---------- image list ----------

_image_list() {
    local show_remote=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --remote)  show_remote=true; shift ;;
            --help|-h) _image_usage; exit 0 ;;
            *)         mps_log_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    local cache_dir
    cache_dir="$(mps_cache_dir)/images"

    mps_log_info "Local images:"
    if [[ -d "$cache_dir" ]] && [[ -n "$(ls -A "$cache_dir" 2>/dev/null)" ]]; then
        printf "  ${_color_bold}%-20s %-10s %-10s %-10s %s${_color_reset}\n" "NAME" "TAG" "ARCH" "SOURCE" "SIZE"
        for image_dir in "$cache_dir"/*/; do
            [[ -d "$image_dir" ]] || continue
            local image_name
            image_name="$(basename "$image_dir")"
            for tag_dir in "$image_dir"/*/; do
                [[ -d "$tag_dir" ]] || continue
                local tag
                tag="$(basename "$tag_dir")"
                for img_file in "$tag_dir"/*.img; do
                    [[ -f "$img_file" ]] || continue
                    local arch
                    arch="$(basename "$img_file" .img)"
                    local size
                    size="$(du -sh "$img_file" 2>/dev/null | cut -f1)"
                    local source="pulled"
                    local meta_file="${img_file%.img}.meta"
                    if [[ -f "$meta_file" ]]; then
                        source="$(grep '^SOURCE=' "$meta_file" | cut -d= -f2)" || source="pulled"
                    fi
                    printf "  %-20s %-10s %-10s %-10s %s\n" "$image_name" "$tag" "$arch" "$source" "$size"
                done
            done
        done
    else
        echo "  (none)"
    fi

    if [[ "$show_remote" == "true" ]]; then
        echo ""
        mps_log_info "Remote images:"
        local base_url="${MPS_IMAGE_BASE_URL:-}"
        if [[ -z "$base_url" ]]; then
            mps_log_warn "MPS_IMAGE_BASE_URL not configured"
            return 1
        fi

        local manifest
        manifest="$(curl -fsSL "${base_url}/manifest.json" 2>/dev/null)" || {
            mps_log_error "Failed to fetch manifest from ${base_url}/manifest.json"
            return 1
        }

        printf "  ${_color_bold}%-20s %-12s %-10s %-12s %s${_color_reset}\n" "NAME" "VERSION" "LATEST" "MIN PROFILE" "DESCRIPTION"
        echo "$manifest" | jq -r '
            .images | to_entries[] | .key as $name |
            .value | .latest as $latest | .description as $desc | .min_profile as $mp |
            .versions | to_entries[] |
            "\($name)\t\(.key)\t\($latest // "—")\t\($mp // "—")\t\($desc // "—")"
        ' | while IFS=$'\t' read -r name ver latest min_prof desc; do
            local latest_marker=""
            if [[ "$ver" == "$latest" ]]; then
                latest_marker="*"
            fi
            printf "  %-20s %-12s %-10s %-12s %s\n" "$name" "$ver" "$latest_marker" "$min_prof" "$desc"
        done
    fi
}

# ---------- image import ----------

_image_import() {
    local file=""
    local name=""
    local tag="local"
    local arch=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)  name="${2:?--name requires a value}"; shift 2 ;;
            --tag)   tag="${2:?--tag requires a value}"; shift 2 ;;
            --arch)  arch="${2:?--arch requires a value}"; shift 2 ;;
            --help|-h) _image_usage; exit 0 ;;
            -*)      mps_log_error "Unknown option: $1"; exit 1 ;;
            *)       file="$1"; shift ;;
        esac
    done

    if [[ -z "$file" ]]; then
        mps_die "Usage: mps image import <file> [--name <name>] [--tag <version>] [--arch <arch>]"
    fi

    # Resolve relative paths
    if [[ "$file" != /* ]]; then
        file="${MPS_PROJECT_DIR:-$(pwd)}/${file}"
    fi

    if [[ ! -f "$file" ]]; then
        mps_die "File not found: ${file}"
    fi

    local filename
    filename="$(basename "$file")"

    # Auto-detect name from filename: mps-<name>-<arch>.qcow2 → name
    if [[ -z "$name" ]]; then
        if [[ "$filename" =~ ^mps-(.+)-(amd64|arm64)\.(qcow2\.img|qcow2|img)$ ]]; then
            name="${BASH_REMATCH[1]}"
        else
            # Strip extension and use as name
            name="${filename%.*}"
            name="${name%.*}"  # handle .qcow2 or .tar.gz double extensions
        fi
    fi

    # Auto-detect arch from filename
    if [[ -z "$arch" ]]; then
        case "$filename" in
            *-amd64*|*_amd64*|*x86_64*) arch="amd64" ;;
            *-arm64*|*_arm64*|*aarch64*) arch="arm64" ;;
            *) arch="$(mps_detect_arch)" ;;
        esac
    fi

    # Validate tag: must be "local" or SemVer
    if [[ "$tag" != "local" && ! "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        mps_die "Invalid tag: '${tag}'. Must be 'local' or SemVer (e.g., 1.0.0)"
    fi

    # Validate arch
    if [[ "$arch" != "amd64" && "$arch" != "arm64" ]]; then
        mps_die "Invalid architecture: '${arch}'. Must be 'amd64' or 'arm64'"
    fi

    local cache_dir
    cache_dir="$(mps_cache_dir)/images/${name}/${tag}"
    mkdir -p "$cache_dir"
    local dest_file="${cache_dir}/${arch}.img"

    # Verify against .sha256 sidecar if present alongside source
    local sha256_file="${file}.sha256"
    local actual_sha256
    actual_sha256="$(_mps_sha256 "$file" | cut -d' ' -f1)"

    if [[ -f "$sha256_file" ]]; then
        local expected_sha256
        expected_sha256="$(cut -d' ' -f1 < "$sha256_file")"
        if [[ "$actual_sha256" != "$expected_sha256" ]]; then
            mps_die "Checksum mismatch for '${file}'. Expected: ${expected_sha256}, Got: ${actual_sha256}"
        fi
        mps_log_info "Checksum verified against ${sha256_file}"
    fi

    # Copy file to cache
    mps_log_info "Importing '${filename}' as ${name}:${tag} (${arch})..."
    cp "$file" "$dest_file"

    # Write .meta sidecar (KEY=VALUE, never sourced — read via grep/cut only)
    local meta_file="${cache_dir}/${arch}.meta"
    cat > "$meta_file" <<EOF
SOURCE=imported
IMPORTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ORIGINAL_PATH=${file}
SHA256=${actual_sha256}
EOF

    # Append image metadata from local manifest if name matches a known flavor
    local local_manifest="${MPS_ROOT}/images/manifest.json"
    if [[ -f "$local_manifest" ]]; then
        local meta_disk_size meta_min_profile meta_min_disk meta_min_memory meta_min_cpus
        meta_disk_size="$(jq -r ".images[\"${name}\"].disk_size // empty" "$local_manifest")"
        if [[ -n "$meta_disk_size" ]]; then
            meta_min_profile="$(jq -r ".images[\"${name}\"].min_profile // empty" "$local_manifest")"
            meta_min_disk="$(jq -r ".images[\"${name}\"].min_disk // empty" "$local_manifest")"
            meta_min_memory="$(jq -r ".images[\"${name}\"].min_memory // empty" "$local_manifest")"
            meta_min_cpus="$(jq -r ".images[\"${name}\"].min_cpus // empty" "$local_manifest")"
            cat >> "$meta_file" <<EOF
IMAGE_DISK_SIZE=${meta_disk_size}
MIN_PROFILE=${meta_min_profile}
MIN_DISK=${meta_min_disk}
MIN_MEMORY=${meta_min_memory}
MIN_CPUS=${meta_min_cpus}
EOF
        fi
    fi

    local size
    size="$(du -sh "$dest_file" 2>/dev/null | cut -f1)"

    mps_log_info "Import complete."
    echo ""
    printf "  %-14s %s\n" "Name:" "$name"
    printf "  %-14s %s\n" "Tag:" "$tag"
    printf "  %-14s %s\n" "Arch:" "$arch"
    printf "  %-14s %s\n" "Size:" "$size"
    printf "  %-14s %s\n" "SHA256:" "$actual_sha256"
    printf "  %-14s %s\n" "Cached:" "$dest_file"
    echo ""
    mps_log_info "Use with: mps create --image ${name}${tag:+:${tag}}"
}

# ---------- image pull ----------

_image_pull() {
    local image_spec=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h) _image_usage; exit 0 ;;
            -*)        mps_log_error "Unknown option: $1"; exit 1 ;;
            *)         image_spec="$1"; shift ;;
        esac
    done

    if [[ -z "$image_spec" ]]; then
        mps_die "Usage: mps image pull <name>[:<version>]"
    fi

    # Parse name:version (default to "latest" which resolves via manifest)
    local image_name="${image_spec%%:*}"
    local image_version="${image_spec#*:}"
    if [[ "$image_version" == "$image_name" ]]; then
        image_version="latest"
    fi

    # Delegate to shared pull function (errors already logged on failure)
    _mps_pull_image "$image_name" "$image_version" || exit 1
}
