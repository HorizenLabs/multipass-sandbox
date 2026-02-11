#!/usr/bin/env bash
# commands/image.sh — mps image [list|pull]

_image_usage() {
    cat <<EOF
${_color_bold}Usage:${_color_reset} mps image <subcommand> [options]

${_color_bold}Subcommands:${_color_reset}
    list               List locally cached images
    pull <name:tag>    Download an image from the registry

${_color_bold}Options:${_color_reset}
    --remote           (list) Also show remote images from registry
    --help, -h         Show this help message

${_color_bold}Examples:${_color_reset}
    mps image list
    mps image list --remote
    mps image pull base:latest
    mps image pull blockchain:latest
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
        printf "  ${_color_bold}%-20s %-10s %-10s %s${_color_reset}\n" "NAME" "TAG" "ARCH" "SIZE"
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
                    printf "  %-20s %-10s %-10s %s\n" "$image_name" "$tag" "$arch" "$size"
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

        printf "  ${_color_bold}%-20s %-10s %s${_color_reset}\n" "NAME" "TAG" "DESCRIPTION"
        echo "$manifest" | jq -r '
            .images | to_entries[] | .key as $name |
            .value | to_entries[] |
            "\($name)\t\(.key)\t\(.value.description // "—")"
        ' | while IFS=$'\t' read -r name tag desc; do
            printf "  %-20s %-10s %s\n" "$name" "$tag" "$desc"
        done
    fi
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
        mps_die "Usage: mps image pull <name:tag>"
    fi

    # Parse name:tag
    local image_name="${image_spec%%:*}"
    local image_tag="${image_spec#*:}"
    if [[ "$image_tag" == "$image_name" ]]; then
        image_tag="latest"
    fi

    local base_url="${MPS_IMAGE_BASE_URL:-}"
    if [[ -z "$base_url" ]]; then
        mps_die "MPS_IMAGE_BASE_URL not configured"
    fi

    # Detect architecture
    local arch
    arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
    esac

    mps_log_info "Fetching manifest..."
    local manifest
    manifest="$(curl -fsSL "${base_url}/manifest.json" 2>/dev/null)" || {
        mps_die "Failed to fetch manifest from ${base_url}/manifest.json"
    }

    # Extract image info
    local image_url expected_sha256
    image_url="$(echo "$manifest" | jq -r ".images[\"${image_name}\"][\"${image_tag}\"][\"${arch}\"].url // empty")"
    expected_sha256="$(echo "$manifest" | jq -r ".images[\"${image_name}\"][\"${image_tag}\"][\"${arch}\"].sha256 // empty")"

    if [[ -z "$image_url" ]]; then
        mps_die "Image '${image_name}:${image_tag}' not found for architecture '${arch}'"
    fi

    # Full URL (relative to base)
    local full_url="${base_url}/${image_url}"
    local cache_dir
    cache_dir="$(mps_cache_dir)/images/${image_name}/${image_tag}"
    mkdir -p "$cache_dir"
    local dest_file="${cache_dir}/${arch}.img"

    mps_log_info "Downloading ${image_name}:${image_tag} (${arch})..."
    if ! curl --progress-bar -fSL "$full_url" -o "$dest_file"; then
        rm -f "$dest_file"
        mps_die "Failed to download image from ${full_url}"
    fi

    # Verify checksum
    if [[ -n "$expected_sha256" ]]; then
        mps_log_info "Verifying checksum..."
        local actual_sha256
        actual_sha256="$(sha256sum "$dest_file" | cut -d' ' -f1)"
        if [[ "$actual_sha256" != "$expected_sha256" ]]; then
            rm -f "$dest_file"
            mps_die "Checksum mismatch! Expected: ${expected_sha256}, Got: ${actual_sha256}"
        fi
        mps_log_info "Checksum verified."
    fi

    mps_log_info "Image cached to ${dest_file}"
}
