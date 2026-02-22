#!/usr/bin/env bash
# shellcheck disable=SC2154  # color vars defined in lib/common.sh
# commands/image.sh — mps image [list|pull|import|remove]

_complete_image() {
    case "${1:-}" in
        subcmds) echo "list pull import remove" ;;
        flags)
            case "${2:-}" in
                list)   echo "--remote --help -h" ;;
                pull)   echo "--force -f --help -h" ;;
                import) echo "--name --tag --arch --help -h" ;;
                remove) echo "--arch --all --force -f --help -h" ;;
                *)      echo "--help -h" ;;
            esac ;;
        flag-values)
            case "${2:-}" in
                --arch) echo "__archs__" ;;
                --name) echo "__images__" ;;
            esac ;;
    esac
}

_image_usage() {
    cat <<EOF
${_color_bold}Usage:${_color_reset} mps image <subcommand> [options]

${_color_bold}Subcommands:${_color_reset}
    list                     List locally cached images (shows update status)
    pull <name>[:<version>]  Download an image (default: latest version)
    import <file> [options]  Import a local QCOW2 image into cache
    remove <name>[:<version>] [options]  Remove cached images

${_color_bold}Options:${_color_reset}
    --remote           (list) Also show remote images from registry
    --force, -f        (pull) Re-download even if already up to date
    --help, -h         Show this help message

${_color_bold}Import Options:${_color_reset}
    --name <name>      Image name (default: auto-detect from filename)
    --tag <version>    Version tag (default: local)
    --arch <arch>      Architecture (default: auto-detect from filename or host)

${_color_bold}Remove Options:${_color_reset}
    --arch <arch>      Remove only the specified architecture (amd64 or arm64)
    --all              Remove all cached images
    --force, -f        Skip confirmation prompt

${_color_bold}Examples:${_color_reset}
    mps image list
    mps image list --remote
    mps image pull base
    mps image pull base:1.0.0
    mps image pull base --force
    mps image import images/artifacts/mps-base-amd64.qcow2.img
    mps image import myimage.qcow2 --name base --tag 1.0.0
    mps image remove base:local
    mps image remove base
    mps image remove base:1.0.0 --arch amd64
    mps image remove --all
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
        list)   _image_list ${args[@]+"${args[@]}"} ;;
        pull)   _image_pull ${args[@]+"${args[@]}"} ;;
        import) _image_import ${args[@]+"${args[@]}"} ;;
        remove) _image_remove ${args[@]+"${args[@]}"} ;;
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

    # Try to fetch manifest for staleness checks (silent on failure)
    local manifest=""
    local have_manifest=false
    if manifest="$(_mps_fetch_manifest)" && [[ -n "$manifest" ]]; then
        have_manifest=true
    fi

    mps_log_info "Local images:"
    if [[ -d "$cache_dir" ]] && [[ -n "$(ls -A "$cache_dir" 2>/dev/null)" ]]; then
        if [[ "$have_manifest" == "true" ]]; then
            printf "  ${_color_bold}%-20s %-10s %-10s %-10s %-8s %s${_color_reset}\n" "NAME" "TAG" "ARCH" "SOURCE" "SIZE" "STATUS"
        else
            printf "  ${_color_bold}%-20s %-10s %-10s %-10s %s${_color_reset}\n" "NAME" "TAG" "ARCH" "SOURCE" "SIZE"
        fi
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
                    local meta_file="${img_file%.img}.meta.json"
                    if [[ -f "$meta_file" ]]; then
                        local _bd
                        _bd="$(jq -r '.build_date // empty' "$meta_file")"
                        [[ -n "$_bd" ]] && source="pulled" || source="imported"
                    fi
                    if [[ "$have_manifest" == "true" ]]; then
                        local status_raw status_display
                        status_raw="$(_mps_check_image_staleness "$manifest" "$image_name" "$tag" "$arch")"
                        case "$status_raw" in
                            up-to-date)
                                status_display="${_color_green}up-to-date${_color_reset}" ;;
                            stale)
                                status_display="${_color_yellow}stale (rebuild)${_color_reset}" ;;
                            update:*)
                                local new_ver="${status_raw#update:}"
                                status_display="${_color_yellow}update (${new_ver})${_color_reset}" ;;
                            *)
                                status_display="--" ;;
                        esac
                        printf "  %-20s %-10s %-10s %-10s %-8s %b\n" "$image_name" "$tag" "$arch" "$source" "$size" "$status_display"
                    else
                        printf "  %-20s %-10s %-10s %-10s %s\n" "$image_name" "$tag" "$arch" "$source" "$size"
                    fi
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
        expected_sha256="$(awk '{print $1}' "$sha256_file")"
        if [[ "$actual_sha256" != "$expected_sha256" ]]; then
            mps_die "Checksum mismatch for '${file}'. Expected: ${expected_sha256}, Got: ${actual_sha256}"
        fi
        mps_log_info "Checksum verified against ${sha256_file}"
    fi

    # Copy file to cache
    mps_log_info "Importing '${filename}' as ${name}:${tag} (${arch})..."
    cp "$file" "$dest_file"

    # Build .meta.json for imported image (no build_date → inferred as imported)
    local meta_file="${cache_dir}/${arch}.meta.json"
    local meta_json='{"sha256":"'"${actual_sha256}"'"}'

    # Merge image metadata from manifest if name matches a known flavor
    local manifest
    if manifest="$(_mps_fetch_manifest 2>/dev/null)" && [[ -n "$manifest" ]]; then
        local flavor_meta
        flavor_meta="$(echo "$manifest" | jq \
            ".images[\"${name}\"] // empty | {disk_size, min_profile, min_disk, min_memory, min_cpus}")"
        if [[ -n "$flavor_meta" && "$flavor_meta" != "null" ]]; then
            meta_json="$(echo "$meta_json" | jq --argjson fm "$flavor_meta" '. + $fm')"
        fi
    fi

    echo "$meta_json" > "$meta_file"

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
    local force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f) force=true; shift ;;
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

    # Check staleness before pulling (skip on --force or offline)
    if [[ "$force" != "true" ]]; then
        local manifest
        if manifest="$(_mps_fetch_manifest)"; then
            # Resolve "latest" for staleness check
            local check_version="$image_version"
            if [[ "$check_version" == "latest" ]]; then
                check_version="$(echo "$manifest" | jq -r ".images[\"${image_name}\"].latest // empty")"
            fi

            if [[ -n "$check_version" ]]; then
                local arch
                arch="$(mps_detect_arch)"
                local status
                status="$(_mps_check_image_staleness "$manifest" "$image_name" "$check_version" "$arch")"

                case "$status" in
                    up-to-date)
                        mps_log_info "Image '${image_name}:${check_version}' is already up to date."
                        return 0
                        ;;
                    stale)
                        mps_log_info "Image '${image_name}:${check_version}' has been updated (new build). Downloading..."
                        ;;
                    update:*)
                        local new_ver="${status#update:}"
                        mps_log_info "New version available: ${image_name}:${new_ver}"
                        ;;
                esac
            fi
        fi
    fi

    # Track what version was the latest before pull (for old version cleanup)
    local arch
    arch="$(mps_detect_arch)"
    local cache_dir
    cache_dir="$(mps_cache_dir)/images"
    local image_dir="${cache_dir}/${image_name}"
    local prev_version=""
    if [[ -d "$image_dir" ]]; then
        prev_version="$(_mps_resolve_latest_version "$image_dir" "$arch")"
    fi

    # Delegate to shared pull function (errors already logged on failure)
    _mps_pull_image "$image_name" "$image_version" || exit 1

    # After successful pull, check for old versions to clean up
    local new_version
    new_version="$(_mps_resolve_latest_version "$image_dir" "$arch")"

    if [[ -n "$prev_version" && -n "$new_version" && "$prev_version" != "$new_version" ]]; then
        # Scan for older SemVer versions
        for tag_dir in "$image_dir"/*/; do
            [[ -d "$tag_dir" ]] || continue
            local tag
            tag="$(basename "$tag_dir")"
            # Skip non-SemVer, current version, and "local"
            [[ "$tag" == "local" ]] && continue
            [[ "$tag" == "$new_version" ]] && continue
            [[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
            [[ -f "${tag_dir}/${arch}.img" ]] || continue

            local old_size
            old_size="$(du -sh "${tag_dir}/${arch}.img" 2>/dev/null | cut -f1)"
            mps_log_info "Old version '${image_name}:${tag}' (${arch}, ${old_size}) is still cached."
            if mps_confirm "Remove it?"; then
                rm -f "${tag_dir}/${arch}.img" "${tag_dir}/${arch}.meta" "${tag_dir}/${arch}.meta.json"
                # Remove tag dir if empty
                if [[ -d "$tag_dir" ]] && [[ -z "$(ls -A "$tag_dir" 2>/dev/null)" ]]; then
                    rmdir "$tag_dir"
                fi
                mps_log_info "Removed ${image_name}:${tag} (${arch})."
            fi
        done
    fi
}

# ---------- image remove ----------

_image_remove_usage() {
    cat <<EOF
${_color_bold}Usage:${_color_reset} mps image remove <name>[:<version>] [options]
       mps image remove --all [--force]

${_color_bold}Description:${_color_reset}
    Remove cached images from ~/.mps/cache/images/.

${_color_bold}Options:${_color_reset}
    --arch <arch>      Remove only the specified architecture (amd64 or arm64)
    --all              Remove all cached images
    --force, -f        Skip confirmation prompt
    --help, -h         Show this help message

${_color_bold}Examples:${_color_reset}
    mps image remove base:local          Remove base:local (all architectures)
    mps image remove base                Remove all versions of 'base'
    mps image remove base:1.0.0 --arch amd64   Remove only the amd64 image
    mps image remove --all               Remove entire image cache
    mps image remove base --force        Skip confirmation
EOF
}

_image_remove() {
    local image_spec=""
    local arch=""
    local remove_all=false
    local force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --arch)  arch="${2:?--arch requires a value}"; shift 2 ;;
            --all)   remove_all=true; shift ;;
            --force|-f) force=true; shift ;;
            --help|-h) _image_remove_usage; exit 0 ;;
            -*)      mps_log_error "Unknown option: $1"; exit 1 ;;
            *)       image_spec="$1"; shift ;;
        esac
    done

    # Validate mutually exclusive options
    if [[ "$remove_all" == "true" && -n "$image_spec" ]]; then
        mps_die "--all cannot be used with an image specifier"
    fi

    if [[ "$remove_all" == "true" && -n "$arch" ]]; then
        mps_die "--arch cannot be used with --all"
    fi

    if [[ "$remove_all" == "false" && -z "$image_spec" ]]; then
        mps_die "Usage: mps image remove <name>[:<version>] or mps image remove --all"
    fi

    # Validate arch if specified
    if [[ -n "$arch" && "$arch" != "amd64" && "$arch" != "arm64" ]]; then
        mps_die "Invalid architecture: '${arch}'. Must be 'amd64' or 'arm64'"
    fi

    local cache_dir
    cache_dir="$(mps_cache_dir)/images"

    # Build list of targets to remove
    local -a targets=()

    if [[ "$remove_all" == "true" ]]; then
        if [[ ! -d "$cache_dir" ]] || [[ -z "$(ls -A "$cache_dir" 2>/dev/null)" ]]; then
            mps_log_info "No cached images to remove."
            return 0
        fi
        targets=("$cache_dir")
    else
        # Parse name:version
        local image_name="${image_spec%%:*}"
        local image_version="${image_spec#*:}"
        if [[ "$image_version" == "$image_name" ]]; then
            image_version=""
        fi

        if [[ -z "$image_version" ]]; then
            # Remove all versions of this image
            local image_dir="${cache_dir}/${image_name}"
            if [[ ! -d "$image_dir" ]]; then
                mps_die "Image not found: '${image_name}'"
            fi
            targets=("$image_dir")
        elif [[ -n "$arch" ]]; then
            # Remove specific arch files only
            local tag_dir="${cache_dir}/${image_name}/${image_version}"
            if [[ ! -d "$tag_dir" ]]; then
                mps_die "Image not found: '${image_name}:${image_version}'"
            fi
            local img_file="${tag_dir}/${arch}.img"
            local meta_file="${tag_dir}/${arch}.meta"
            local meta_json_file="${tag_dir}/${arch}.meta.json"
            if [[ ! -f "$img_file" ]]; then
                mps_die "Architecture '${arch}' not found for '${image_name}:${image_version}'"
            fi
            [[ -f "$img_file" ]] && targets+=("$img_file")
            [[ -f "$meta_file" ]] && targets+=("$meta_file")
            [[ -f "$meta_json_file" ]] && targets+=("$meta_json_file")
        else
            # Remove specific version directory
            local tag_dir="${cache_dir}/${image_name}/${image_version}"
            if [[ ! -d "$tag_dir" ]]; then
                mps_die "Image not found: '${image_name}:${image_version}'"
            fi
            targets=("$tag_dir")
        fi
    fi

    # Preview what will be removed
    local total_size
    total_size="$(du -shc ${targets[@]+"${targets[@]}"} 2>/dev/null | tail -1 | cut -f1)"

    mps_log_info "The following will be removed:"
    for t in ${targets[@]+"${targets[@]}"}; do
        local entry_size
        entry_size="$(du -sh "$t" 2>/dev/null | cut -f1)"
        echo "  ${t}  (${entry_size})"
    done
    echo ""
    mps_log_info "Total: ${total_size}"

    # Confirm unless --force
    if [[ "$force" != "true" ]]; then
        if ! mps_confirm "Proceed with removal?"; then
            mps_log_info "Aborted."
            return 0
        fi
    fi

    # Delete targets
    local removed=0
    for t in ${targets[@]+"${targets[@]}"}; do
        if [[ -d "$t" ]]; then
            rm -rf "${t:?}"
        else
            rm -f "$t"
        fi
        removed=$((removed + 1))
    done

    # Clean up empty parent directories after arch-specific removal
    if [[ -n "$arch" && -n "${image_version:-}" ]]; then
        local tag_dir="${cache_dir}/${image_name}/${image_version}"
        local image_dir="${cache_dir}/${image_name}"
        # Remove tag dir if empty
        if [[ -d "$tag_dir" ]] && [[ -z "$(ls -A "$tag_dir" 2>/dev/null)" ]]; then
            rmdir "$tag_dir"
        fi
        # Remove image dir if empty
        if [[ -d "$image_dir" ]] && [[ -z "$(ls -A "$image_dir" 2>/dev/null)" ]]; then
            rmdir "$image_dir"
        fi
    fi

    # Re-create cache dir if --all wiped it
    if [[ "$remove_all" == "true" ]]; then
        mkdir -p "$cache_dir"
    fi

    mps_log_info "Removed ${removed} item(s), freed ${total_size}."
}
