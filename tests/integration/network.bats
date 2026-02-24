#!/usr/bin/env bats
# Integration tests for lib/common.sh network functions:
#   _mps_remote_is_fresh, _mps_remote_fetch, _mps_download_file,
#   _mps_fetch_manifest, _mps_check_image_staleness, _mps_warn_image_staleness,
#   _mps_check_instance_staleness, _mps_warn_instance_staleness,
#   _mps_check_cli_update, _mps_cli_update_warn
#
# Uses a Python3 HTTP server (tests/stubs/http_server.py) serving fixture files
# on localhost. Both aria2c and curl download paths are exercised.

load ../test_helper

# ================================================================
# Helpers
# ================================================================

# Create a local image .meta.json in the cache hierarchy
# Usage: _create_local_meta <name> <ver> <arch> <sha256>
_create_local_meta() {
    local name="$1" ver="$2" arch="$3" sha256="$4"
    local dir="${HOME}/.mps/cache/images/${name}/${ver}"
    mkdir -p "$dir"
    printf '{"sha256": "%s"}\n' "$sha256" > "${dir}/${arch}.meta.json"
}

# Create instance metadata JSON
# Usage: _create_instance_meta <short_name> <img_name> <ver> <arch> <sha256> [source]
_create_instance_meta() {
    local short_name="$1" img_name="$2" ver="$3" arch="$4" sha256="$5"
    local source="${6:-cache}"
    local dir="${HOME}/.mps/instances"
    mkdir -p "$dir"
    cat > "${dir}/${short_name}.json" <<EOF
{
    "name": "${short_name}",
    "image": {
        "name": "${img_name}",
        "version": "${ver}",
        "arch": "${arch}",
        "sha256": "${sha256}",
        "source": "${source}"
    }
}
EOF
}

# ================================================================
# Setup / Teardown
# ================================================================

setup() {
    setup_home_override

    # Start the HTTP server
    HTTP_READY="${TEST_TEMP_DIR}/http_ready"
    HTTP_FIXTURES="${MPS_ROOT}/tests/fixtures/http"

    python3 "${MPS_ROOT}/tests/stubs/http_server.py" \
        "$HTTP_FIXTURES" "$HTTP_READY" &
    HTTP_PID=$!

    # Wait for server readiness (poll for port file, 100ms intervals, 2s timeout)
    local elapsed=0
    while [[ ! -s "$HTTP_READY" ]]; do
        if [[ $elapsed -ge 20 ]]; then
            echo "HTTP server failed to start within 2s" >&2
            kill "$HTTP_PID" 2>/dev/null || true
            return 1
        fi
        sleep 0.1
        elapsed=$((elapsed + 1))
    done

    HTTP_PORT="$(cat "$HTTP_READY")"
    export MPS_IMAGE_BASE_URL="http://127.0.0.1:${HTTP_PORT}"
    export MPS_VERSION="0.4.1"
}

teardown() {
    kill "$HTTP_PID" 2>/dev/null || true
    wait "$HTTP_PID" 2>/dev/null || true
    teardown_home_override
}

# ================================================================
# Group A: HTTP Primitives
# ================================================================

# ----------------------------------------------------------------
# _mps_remote_is_fresh
# ----------------------------------------------------------------

@test "_mps_remote_is_fresh: returns 0 (304) when reference file mtime >= fixture" {
    # Create a reference file with current timestamp (>= fixture mtime)
    local ref="${TEST_TEMP_DIR}/ref_file"
    echo "cached" > "$ref"
    # Touch to future date to ensure 304
    touch -t 203001010000 "$ref"
    run _mps_remote_is_fresh "${MPS_IMAGE_BASE_URL}/testfile.txt" "$ref"
    [[ "$status" -eq 0 ]]
}

@test "_mps_remote_is_fresh: returns 1 (200) when reference file mtime in distant past" {
    local ref="${TEST_TEMP_DIR}/ref_file"
    echo "cached" > "$ref"
    touch -t 200001010000 "$ref"
    run _mps_remote_is_fresh "${MPS_IMAGE_BASE_URL}/testfile.txt" "$ref"
    [[ "$status" -ne 0 ]]
}

@test "_mps_remote_is_fresh: returns 1 when reference file does not exist" {
    run _mps_remote_is_fresh "${MPS_IMAGE_BASE_URL}/testfile.txt" "${TEST_TEMP_DIR}/nonexistent"
    [[ "$status" -ne 0 ]]
}

@test "_mps_remote_is_fresh: returns 1 when server unreachable" {
    local ref="${TEST_TEMP_DIR}/ref_file"
    echo "cached" > "$ref"
    run _mps_remote_is_fresh "http://127.0.0.1:1/testfile.txt" "$ref"
    [[ "$status" -ne 0 ]]
}

# ----------------------------------------------------------------
# _mps_remote_fetch
# ----------------------------------------------------------------

@test "_mps_remote_fetch: first fetch downloads file and outputs content" {
    local cache="${TEST_TEMP_DIR}/cache/testfile.txt"
    run _mps_remote_fetch "${MPS_IMAGE_BASE_URL}/testfile.txt" "$cache"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Hello from the test HTTP server fixture."* ]]
    [[ -f "$cache" ]]
}

@test "_mps_remote_fetch: cached fetch with 304 returns cached content unchanged" {
    local cache="${TEST_TEMP_DIR}/cache/testfile.txt"
    # First fetch
    _mps_remote_fetch "${MPS_IMAGE_BASE_URL}/testfile.txt" "$cache" >/dev/null
    # Touch cache to future to ensure 304
    touch -t 203001010000 "$cache"
    run _mps_remote_fetch "${MPS_IMAGE_BASE_URL}/testfile.txt" "$cache"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Hello from the test HTTP server fixture."* ]]
}

@test "_mps_remote_fetch: cache update on 200 overwrites cache file" {
    local cache="${TEST_TEMP_DIR}/cache/testfile.txt"
    mkdir -p "$(dirname "$cache")"
    echo "old content" > "$cache"
    # Touch to distant past to force 200
    touch -t 200001010000 "$cache"
    run _mps_remote_fetch "${MPS_IMAGE_BASE_URL}/testfile.txt" "$cache"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Hello from the test HTTP server fixture."* ]]
    # Verify the on-disk cache was updated
    local on_disk
    on_disk="$(cat "$cache")"
    [[ "$on_disk" == *"Hello from the test HTTP server fixture."* ]]
}

@test "_mps_remote_fetch: network failure with existing cache returns cached content" {
    local cache="${TEST_TEMP_DIR}/cache/testfile.txt"
    mkdir -p "$(dirname "$cache")"
    echo "cached fallback" > "$cache"
    run _mps_remote_fetch "http://127.0.0.1:1/testfile.txt" "$cache"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"cached fallback"* ]]
}

@test "_mps_remote_fetch: network failure without cache returns 1" {
    local cache="${TEST_TEMP_DIR}/cache/nonexistent.txt"
    run _mps_remote_fetch "http://127.0.0.1:1/testfile.txt" "$cache"
    [[ "$status" -ne 0 ]]
}

@test "_mps_remote_fetch: creates parent directories for cache file" {
    local cache="${TEST_TEMP_DIR}/deep/nested/dir/file.txt"
    run _mps_remote_fetch "${MPS_IMAGE_BASE_URL}/testfile.txt" "$cache"
    [[ "$status" -eq 0 ]]
    [[ -d "${TEST_TEMP_DIR}/deep/nested/dir" ]]
    [[ -f "$cache" ]]
}

# ----------------------------------------------------------------
# _mps_download_file (aria2c path)
# ----------------------------------------------------------------

@test "_mps_download_file (aria2c): downloads file to correct destination" {
    if ! command -v aria2c &>/dev/null; then
        skip "aria2c not available"
    fi
    local dest="${TEST_TEMP_DIR}/downloads/testfile.txt"
    mkdir -p "$(dirname "$dest")"
    run _mps_download_file "${MPS_IMAGE_BASE_URL}/testfile.txt" "$dest"
    [[ "$status" -eq 0 ]]
    [[ -f "$dest" ]]
    local content
    content="$(cat "$dest")"
    [[ "$content" == *"Hello from the test HTTP server fixture."* ]]
}

@test "_mps_download_file (aria2c): overwrites existing file" {
    if ! command -v aria2c &>/dev/null; then
        skip "aria2c not available"
    fi
    local dest="${TEST_TEMP_DIR}/downloads/testfile.txt"
    mkdir -p "$(dirname "$dest")"
    echo "old data" > "$dest"
    run _mps_download_file "${MPS_IMAGE_BASE_URL}/testfile.txt" "$dest"
    [[ "$status" -eq 0 ]]
    local content
    content="$(cat "$dest")"
    [[ "$content" == *"Hello from the test HTTP server fixture."* ]]
}

@test "_mps_download_file (aria2c): returns non-zero on 404" {
    if ! command -v aria2c &>/dev/null; then
        skip "aria2c not available"
    fi
    local dest="${TEST_TEMP_DIR}/downloads/missing.txt"
    mkdir -p "$(dirname "$dest")"
    run _mps_download_file "${MPS_IMAGE_BASE_URL}/nonexistent_file.xyz" "$dest"
    [[ "$status" -ne 0 ]]
}

# ----------------------------------------------------------------
# _mps_download_file (curl fallback path)
# ----------------------------------------------------------------

@test "_mps_download_file (curl): downloads file when aria2c hidden from PATH" {
    # Hide aria2c by restricting PATH
    local saved_path="$PATH"
    local aria2c_dir=""
    if command -v aria2c &>/dev/null; then
        aria2c_dir="$(dirname "$(command -v aria2c)")"
    fi
    # Build a PATH that excludes the aria2c directory
    local new_path=""
    local IFS=':'
    for p in $saved_path; do
        if [[ "$p" != "$aria2c_dir" ]]; then
            new_path="${new_path:+${new_path}:}${p}"
        fi
    done
    unset IFS

    local dest="${TEST_TEMP_DIR}/downloads_curl/testfile.txt"
    mkdir -p "$(dirname "$dest")"
    PATH="$new_path" run _mps_download_file "${MPS_IMAGE_BASE_URL}/testfile.txt" "$dest"
    [[ "$status" -eq 0 ]]
    [[ -f "$dest" ]]
    local content
    content="$(cat "$dest")"
    [[ "$content" == *"Hello from the test HTTP server fixture."* ]]
}

@test "_mps_download_file (curl): overwrites existing file" {
    local saved_path="$PATH"
    local aria2c_dir=""
    if command -v aria2c &>/dev/null; then
        aria2c_dir="$(dirname "$(command -v aria2c)")"
    fi
    local new_path=""
    local IFS=':'
    for p in $saved_path; do
        if [[ "$p" != "$aria2c_dir" ]]; then
            new_path="${new_path:+${new_path}:}${p}"
        fi
    done
    unset IFS

    local dest="${TEST_TEMP_DIR}/downloads_curl/overwrite.txt"
    mkdir -p "$(dirname "$dest")"
    echo "old data" > "$dest"
    PATH="$new_path" run _mps_download_file "${MPS_IMAGE_BASE_URL}/testfile.txt" "$dest"
    [[ "$status" -eq 0 ]]
    local content
    content="$(cat "$dest")"
    [[ "$content" == *"Hello from the test HTTP server fixture."* ]]
}

@test "_mps_download_file (curl): returns non-zero on 404" {
    local saved_path="$PATH"
    local aria2c_dir=""
    if command -v aria2c &>/dev/null; then
        aria2c_dir="$(dirname "$(command -v aria2c)")"
    fi
    local new_path=""
    local IFS=':'
    for p in $saved_path; do
        if [[ "$p" != "$aria2c_dir" ]]; then
            new_path="${new_path:+${new_path}:}${p}"
        fi
    done
    unset IFS

    local dest="${TEST_TEMP_DIR}/downloads_curl/missing.txt"
    mkdir -p "$(dirname "$dest")"
    PATH="$new_path" run _mps_download_file "${MPS_IMAGE_BASE_URL}/nonexistent_file.xyz" "$dest"
    [[ "$status" -ne 0 ]]
}

# ----------------------------------------------------------------
# _mps_download_file: aria2c -d/-o flag correctness
# ----------------------------------------------------------------

@test "_mps_download_file (aria2c): lands in correct directory with correct basename" {
    if ! command -v aria2c &>/dev/null; then
        skip "aria2c not available"
    fi
    # Use a nested destination to verify -d and -o splitting
    local dest="${TEST_TEMP_DIR}/deep/sub/dir/result.txt"
    mkdir -p "$(dirname "$dest")"
    run _mps_download_file "${MPS_IMAGE_BASE_URL}/testfile.txt" "$dest"
    [[ "$status" -eq 0 ]]
    [[ -f "$dest" ]]
    # Verify no extra files leaked into parent dirs
    local count
    count="$(find "${TEST_TEMP_DIR}/deep/sub/dir" -type f | wc -l)"
    [[ "$count" -eq 1 ]]
}

# ================================================================
# Group B: Manifest & Staleness
# ================================================================

# ----------------------------------------------------------------
# _mps_fetch_manifest
# ----------------------------------------------------------------

@test "_mps_fetch_manifest: returns manifest JSON when MPS_IMAGE_BASE_URL set" {
    run _mps_fetch_manifest
    [[ "$status" -eq 0 ]]
    # Verify it's valid JSON with expected structure
    echo "$output" | jq -e '.schema_version == 2'
    echo "$output" | jq -e '.images.base.latest == "1.1.0"'
}

@test "_mps_fetch_manifest: returns 1 when MPS_IMAGE_BASE_URL empty" {
    MPS_IMAGE_BASE_URL="" run _mps_fetch_manifest
    [[ "$status" -ne 0 ]]
}

@test "_mps_fetch_manifest: caches to ~/.mps/cache/manifest.json" {
    _mps_fetch_manifest >/dev/null
    [[ -f "${HOME}/.mps/cache/manifest.json" ]]
    local cached
    cached="$(cat "${HOME}/.mps/cache/manifest.json")"
    echo "$cached" | jq -e '.schema_version == 2'
}

@test "_mps_fetch_manifest: returns cached content on network failure" {
    # First fetch to populate cache
    _mps_fetch_manifest >/dev/null
    # Now break the URL
    MPS_IMAGE_BASE_URL="http://127.0.0.1:1"
    run _mps_fetch_manifest
    [[ "$status" -eq 0 ]]
    echo "$output" | jq -e '.schema_version == 2'
}

# ----------------------------------------------------------------
# _mps_check_image_staleness
# ----------------------------------------------------------------

@test "_mps_check_image_staleness: up-to-date when local SHA matches remote sidecar" {
    local arch
    arch="$(mps_detect_arch)"
    _create_local_meta "base" "1.0.0" "$arch" \
        "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"
    # Touch meta to distant past so HEAD returns 200 (not 304)
    touch -t 200001010000 "${HOME}/.mps/cache/images/base/1.0.0/${arch}.meta.json"
    # Use a manifest where latest==1.0.0 so version-update check doesn't fire
    local manifest='{"schema_version":2,"images":{"base":{"latest":"1.0.0","versions":{"1.0.0":{"'"$arch"'":{"sha256":"aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"}}}}}}'
    run _mps_check_image_staleness "$manifest" "base" "1.0.0" "$arch"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "up-to-date" ]]
}

@test "_mps_check_image_staleness: stale when local SHA differs from remote" {
    local arch
    arch="$(mps_detect_arch)"
    _create_local_meta "base" "1.0.0" "$arch" \
        "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    touch -t 200001010000 "${HOME}/.mps/cache/images/base/1.0.0/${arch}.meta.json"
    # Use a manifest where latest==1.0.0 so version-update check doesn't fire
    local manifest='{"schema_version":2,"images":{"base":{"latest":"1.0.0","versions":{"1.0.0":{"'"$arch"'":{"sha256":"aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"}}}}}}'
    run _mps_check_image_staleness "$manifest" "base" "1.0.0" "$arch"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "stale" ]]
}

@test "_mps_check_image_staleness: update when manifest latest is newer version" {
    local arch
    arch="$(mps_detect_arch)"
    _create_local_meta "base" "1.0.0" "$arch" \
        "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"
    local manifest
    manifest="$(cat "${MPS_ROOT}/tests/fixtures/http/manifest.json")"
    # Manifest has latest=1.1.0, we're on 1.0.0
    run _mps_check_image_staleness "$manifest" "base" "1.0.0" "$arch"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "update:1.1.0" ]]
}

@test "_mps_check_image_staleness: up-to-date via 304 fast path (recent mtime)" {
    local arch
    arch="$(mps_detect_arch)"
    # Use 1.1.0 so manifest latest == version (no update path)
    _create_local_meta "base" "1.1.0" "$arch" \
        "cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333"
    # Touch meta to future → HEAD gets 304
    touch -t 203001010000 "${HOME}/.mps/cache/images/base/1.1.0/${arch}.meta.json"
    local manifest
    manifest='{"schema_version":2,"images":{"base":{"latest":"1.1.0","versions":{"1.1.0":{"'"$arch"'":{"sha256":"cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333"}}}}}}'
    run _mps_check_image_staleness "$manifest" "base" "1.1.0" "$arch"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "up-to-date" ]]
}

@test "_mps_check_image_staleness: unknown for non-SemVer version" {
    local manifest
    manifest="$(cat "${MPS_ROOT}/tests/fixtures/http/manifest.json")"
    run _mps_check_image_staleness "$manifest" "base" "local" "amd64"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "unknown" ]]
}

@test "_mps_check_image_staleness: unknown when no local .meta.json exists" {
    local manifest
    manifest="$(cat "${MPS_ROOT}/tests/fixtures/http/manifest.json")"
    run _mps_check_image_staleness "$manifest" "base" "1.0.0" "amd64"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "unknown" ]]
}

@test "_mps_check_image_staleness: falls back to manifest SHA when sidecar fetch fails" {
    local arch
    arch="$(mps_detect_arch)"
    # Set up matching local SHA with manifest SHA
    _create_local_meta "base" "1.1.0" "$arch" \
        "cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333"
    touch -t 200001010000 "${HOME}/.mps/cache/images/base/1.1.0/${arch}.meta.json"
    local manifest
    manifest='{"schema_version":2,"images":{"base":{"latest":"1.1.0","versions":{"1.1.0":{"'"$arch"'":{"sha256":"cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333"}}}}}}'
    # Point at unreachable server so sidecar fetch fails
    MPS_IMAGE_BASE_URL="http://127.0.0.1:1"
    run _mps_check_image_staleness "$manifest" "base" "1.1.0" "$arch"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "up-to-date" ]]
}

# ----------------------------------------------------------------
# _mps_warn_image_staleness
# ----------------------------------------------------------------

@test "_mps_warn_image_staleness: emits rebuild warning for stale image" {
    local arch
    arch="$(mps_detect_arch)"
    _create_local_meta "base" "1.1.0" "$arch" \
        "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    touch -t 200001010000 "${HOME}/.mps/cache/images/base/1.1.0/${arch}.meta.json"
    local img_path="${HOME}/.mps/cache/images/base/1.1.0/${arch}.img"
    mkdir -p "$(dirname "$img_path")"
    touch "$img_path"
    run _mps_warn_image_staleness "file://${img_path}"
    [[ "$output" == *"has been rebuilt"* ]]
}

@test "_mps_warn_image_staleness: emits update warning with new version" {
    local arch
    arch="$(mps_detect_arch)"
    _create_local_meta "base" "1.0.0" "$arch" \
        "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"
    local img_path="${HOME}/.mps/cache/images/base/1.0.0/${arch}.img"
    mkdir -p "$(dirname "$img_path")"
    touch "$img_path"
    run _mps_warn_image_staleness "file://${img_path}"
    [[ "$output" == *"is outdated"* ]]
    [[ "$output" == *"1.1.0"* ]]
}

@test "_mps_warn_image_staleness: silent when up-to-date" {
    local arch
    arch="$(mps_detect_arch)"
    _create_local_meta "base" "1.1.0" "$arch" \
        "cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333"
    touch -t 203001010000 "${HOME}/.mps/cache/images/base/1.1.0/${arch}.meta.json"
    local img_path="${HOME}/.mps/cache/images/base/1.1.0/${arch}.img"
    mkdir -p "$(dirname "$img_path")"
    touch "$img_path"
    # Provide manifest where latest==1.1.0 (no version update path)
    # Pre-populate the manifest cache so _mps_fetch_manifest returns it
    mkdir -p "${HOME}/.mps/cache"
    echo '{"schema_version":2,"images":{"base":{"latest":"1.1.0","versions":{"1.1.0":{"'"$arch"'":{"sha256":"cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333"}}}}}}' \
        > "${HOME}/.mps/cache/manifest.json"
    run _mps_warn_image_staleness "file://${img_path}"
    [[ -z "$output" ]]
}

@test "_mps_warn_image_staleness: silent when MPS_IMAGE_CHECK_UPDATES=false" {
    local arch
    arch="$(mps_detect_arch)"
    _create_local_meta "base" "1.0.0" "$arch" \
        "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    local img_path="${HOME}/.mps/cache/images/base/1.0.0/${arch}.img"
    mkdir -p "$(dirname "$img_path")"
    touch "$img_path"
    MPS_IMAGE_CHECK_UPDATES=false run _mps_warn_image_staleness "file://${img_path}"
    [[ -z "$output" ]]
}

@test "_mps_warn_image_staleness: silent for non-SemVer version" {
    local arch
    arch="$(mps_detect_arch)"
    local img_path="${HOME}/.mps/cache/images/base/local/${arch}.img"
    mkdir -p "$(dirname "$img_path")"
    touch "$img_path"
    run _mps_warn_image_staleness "file://${img_path}"
    [[ -z "$output" ]]
}

# ----------------------------------------------------------------
# _mps_check_instance_staleness (no HTTP server needed)
# ----------------------------------------------------------------

@test "_mps_check_instance_staleness: up-to-date when instance SHA matches cached image" {
    local arch
    arch="$(mps_detect_arch)"
    local sha="aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"
    _create_local_meta "base" "1.0.0" "$arch" "$sha"
    _create_instance_meta "test-inst" "base" "1.0.0" "$arch" "$sha"
    run _mps_check_instance_staleness "test-inst"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "up-to-date" ]]
}

@test "_mps_check_instance_staleness: stale when instance SHA differs from cached image" {
    local arch
    arch="$(mps_detect_arch)"
    _create_local_meta "base" "1.0.0" "$arch" \
        "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"
    _create_instance_meta "test-inst" "base" "1.0.0" "$arch" \
        "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    run _mps_check_instance_staleness "test-inst"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "stale" ]]
}

@test "_mps_check_instance_staleness: update when newer version in local cache" {
    local arch
    arch="$(mps_detect_arch)"
    local sha="aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"
    _create_local_meta "base" "1.0.0" "$arch" "$sha"
    _create_instance_meta "test-inst" "base" "1.0.0" "$arch" "$sha"
    # Create a newer version in local cache
    _create_local_meta "base" "1.1.0" "$arch" \
        "cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333"
    # Also create the .img file so _mps_resolve_latest_version finds it
    touch "${HOME}/.mps/cache/images/base/1.0.0/${arch}.img"
    touch "${HOME}/.mps/cache/images/base/1.1.0/${arch}.img"
    run _mps_check_instance_staleness "test-inst"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "update:1.1.0" ]]
}

@test "_mps_check_instance_staleness: stale:manifest when cached manifest SHA differs" {
    local arch
    arch="$(mps_detect_arch)"
    local sha="aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"
    _create_local_meta "base" "1.0.0" "$arch" "$sha"
    _create_instance_meta "test-inst" "base" "1.0.0" "$arch" "$sha"
    # Create a manifest with different SHA for this version+arch
    mkdir -p "${HOME}/.mps/cache"
    cat > "${HOME}/.mps/cache/manifest.json" <<EOF
{
    "schema_version": 2,
    "images": {
        "base": {
            "latest": "1.0.0",
            "versions": {
                "1.0.0": {
                    "${arch}": { "sha256": "ffff9999ffff9999ffff9999ffff9999ffff9999ffff9999ffff9999ffff9999" }
                }
            }
        }
    }
}
EOF
    run _mps_check_instance_staleness "test-inst"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "stale:manifest" ]]
}

@test "_mps_check_instance_staleness: update:manifest when cached manifest has newer latest" {
    local arch
    arch="$(mps_detect_arch)"
    local sha="aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"
    _create_local_meta "base" "1.0.0" "$arch" "$sha"
    _create_instance_meta "test-inst" "base" "1.0.0" "$arch" "$sha"
    # Create a manifest pointing to a newer latest
    mkdir -p "${HOME}/.mps/cache"
    cat > "${HOME}/.mps/cache/manifest.json" <<EOF
{
    "schema_version": 2,
    "images": {
        "base": {
            "latest": "2.0.0",
            "versions": {
                "1.0.0": {
                    "${arch}": { "sha256": "${sha}" }
                }
            }
        }
    }
}
EOF
    run _mps_check_instance_staleness "test-inst"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "update:manifest:2.0.0" ]]
}

@test "_mps_check_instance_staleness: unknown for stock image" {
    _create_instance_meta "test-stock" "base" "1.0.0" "amd64" "somehash" "stock"
    run _mps_check_instance_staleness "test-stock"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "unknown" ]]
}

@test "_mps_check_instance_staleness: unknown when no instance metadata" {
    run _mps_check_instance_staleness "nonexistent-inst"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "unknown" ]]
}

# ----------------------------------------------------------------
# _mps_warn_instance_staleness
# ----------------------------------------------------------------

@test "_mps_warn_instance_staleness: emits warning for stale instance" {
    local arch
    arch="$(mps_detect_arch)"
    _create_local_meta "base" "1.0.0" "$arch" \
        "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"
    _create_instance_meta "test-stale" "base" "1.0.0" "$arch" \
        "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    run _mps_warn_instance_staleness "test-stale"
    [[ "$output" == *"was created from an older build"* ]]
}

@test "_mps_warn_instance_staleness: emits update warning with version" {
    local arch
    arch="$(mps_detect_arch)"
    local sha="aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"
    _create_local_meta "base" "1.0.0" "$arch" "$sha"
    _create_instance_meta "test-upd" "base" "1.0.0" "$arch" "$sha"
    _create_local_meta "base" "1.1.0" "$arch" \
        "cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333"
    touch "${HOME}/.mps/cache/images/base/1.0.0/${arch}.img"
    touch "${HOME}/.mps/cache/images/base/1.1.0/${arch}.img"
    run _mps_warn_instance_staleness "test-upd"
    [[ "$output" == *"1.1.0"* ]]
    [[ "$output" == *"available locally"* ]]
}

@test "_mps_warn_instance_staleness: --skip-manifest suppresses manifest-sourced warnings" {
    local arch
    arch="$(mps_detect_arch)"
    local sha="aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"
    _create_local_meta "base" "1.0.0" "$arch" "$sha"
    _create_instance_meta "test-skip" "base" "1.0.0" "$arch" "$sha"
    mkdir -p "${HOME}/.mps/cache"
    cat > "${HOME}/.mps/cache/manifest.json" <<EOF
{
    "schema_version": 2,
    "images": {
        "base": {
            "latest": "2.0.0",
            "versions": {
                "1.0.0": {
                    "${arch}": { "sha256": "${sha}" }
                }
            }
        }
    }
}
EOF
    run _mps_warn_instance_staleness "test-skip" "--skip-manifest"
    [[ -z "$output" ]]
}

@test "_mps_warn_instance_staleness: silent when MPS_IMAGE_CHECK_UPDATES=false" {
    local arch
    arch="$(mps_detect_arch)"
    _create_local_meta "base" "1.0.0" "$arch" \
        "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"
    _create_instance_meta "test-off" "base" "1.0.0" "$arch" \
        "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    MPS_IMAGE_CHECK_UPDATES=false run _mps_warn_instance_staleness "test-off"
    [[ -z "$output" ]]
}

# ================================================================
# Group C: CLI Update Check
# ================================================================

# ----------------------------------------------------------------
# _mps_check_cli_update
# ----------------------------------------------------------------

@test "_mps_check_cli_update: warns when remote version > MPS_VERSION" {
    # MPS_VERSION=0.4.1 (from setup), remote has 1.0.0
    # Need MPS_ROOT to be a git repo for _mps_cli_update_warn
    export MPS_ROOT="${TEST_TEMP_DIR}/fakerepo"
    mkdir -p "$MPS_ROOT"
    git -C "$MPS_ROOT" init -q
    git -C "$MPS_ROOT" -c user.name=test -c user.email=test@test.com commit --allow-empty -m "init" -q
    run _mps_check_cli_update
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"update available"* ]]
    [[ "$output" == *"1.0.0"* ]]
}

@test "_mps_check_cli_update: uses cached file within 24h TTL" {
    mkdir -p "${HOME}/.mps/cache"
    cp "${MPS_ROOT}/tests/fixtures/http/mps-release-newer.json" \
        "${HOME}/.mps/cache/mps-release.json"
    # Touch to now (fresh cache)
    touch "${HOME}/.mps/cache/mps-release.json"
    export MPS_ROOT="${TEST_TEMP_DIR}/fakerepo"
    mkdir -p "$MPS_ROOT"
    git -C "$MPS_ROOT" init -q
    git -C "$MPS_ROOT" -c user.name=test -c user.email=test@test.com commit --allow-empty -m "init" -q
    run _mps_check_cli_update
    [[ "$status" -eq 0 ]]
    # Should still warn from cached data
    [[ "$output" == *"update available"* ]]
    [[ "$output" == *"2.0.0"* ]]
}

@test "_mps_check_cli_update: silent when MPS_CHECK_UPDATES=false" {
    MPS_CHECK_UPDATES=false run _mps_check_cli_update
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "_mps_check_cli_update: silent when MPS_VERSION not SemVer" {
    MPS_VERSION="dev" run _mps_check_cli_update
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "_mps_check_cli_update: silent when MPS_IMAGE_BASE_URL empty" {
    MPS_IMAGE_BASE_URL="" run _mps_check_cli_update
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

# ----------------------------------------------------------------
# _mps_cli_update_warn
# ----------------------------------------------------------------

@test "_mps_cli_update_warn: emits update available when remote > local" {
    local cache="${TEST_TEMP_DIR}/release.json"
    cp "${MPS_ROOT}/tests/fixtures/http/mps-release-newer.json" "$cache"
    export MPS_ROOT="${TEST_TEMP_DIR}/fakerepo"
    mkdir -p "$MPS_ROOT"
    git -C "$MPS_ROOT" init -q
    git -C "$MPS_ROOT" -c user.name=test -c user.email=test@test.com commit --allow-empty -m "init" -q
    run _mps_cli_update_warn "$cache"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"update available"* ]]
    [[ "$output" == *"2.0.0"* ]]
}

@test "_mps_cli_update_warn: emits has been updated when versions equal but SHA differs" {
    local cache="${TEST_TEMP_DIR}/release.json"
    # Same version as MPS_VERSION but an unknown commit SHA
    cp "${MPS_ROOT}/tests/fixtures/http/mps-release-current.json" "$cache"

    # Create a git repo where the remote commit_sha is NOT an ancestor of HEAD
    export MPS_ROOT="${TEST_TEMP_DIR}/fakerepo"
    mkdir -p "$MPS_ROOT"
    git -C "$MPS_ROOT" init -q
    git -C "$MPS_ROOT" -c user.name=test -c user.email=test@test.com commit --allow-empty -m "init" -q
    run _mps_cli_update_warn "$cache"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"has been updated"* ]]
}

@test "_mps_cli_update_warn: silent when cache file does not exist" {
    run _mps_cli_update_warn "${TEST_TEMP_DIR}/nonexistent.json"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "_mps_cli_update_warn: silent when MPS_ROOT is not a git repo" {
    local cache="${TEST_TEMP_DIR}/release.json"
    # Same version, unknown SHA — would warn if it were a git repo
    cp "${MPS_ROOT}/tests/fixtures/http/mps-release-current.json" "$cache"

    export MPS_ROOT="${TEST_TEMP_DIR}/not-a-repo"
    mkdir -p "$MPS_ROOT"
    run _mps_cli_update_warn "$cache"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}
