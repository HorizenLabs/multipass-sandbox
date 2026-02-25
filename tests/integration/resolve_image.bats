#!/usr/bin/env bats
# Integration tests for mps_resolve_image (lib/common.sh:610-702).
#
# Exercises the full resolve→pull→cache flow with NO stubs on _mps_pull_image,
# _mps_fetch_manifest, or _mps_download_file. Uses a Python3 HTTP server
# serving dynamically built fixtures with real SHA256 checksums.

load ../test_helper

# ================================================================
# Helpers
# ================================================================

# Build a self-contained fixture tree with .img files, .meta.json sidecars,
# and manifest.json, all with real SHA256 values that match.
# Creates files under $FIXTURE_DIR (served by HTTP) for the given image.
#
# Usage: _build_resolve_fixtures
# Populates: base/1.0.0/amd64.img, base/1.0.0/arm64.img,
#             base/1.1.0/amd64.img, base/1.1.0/arm64.img
_build_resolve_fixtures() {
    FIXTURE_DIR="${TEST_TEMP_DIR}/http_root"
    mkdir -p "${FIXTURE_DIR}/base/1.0.0" "${FIXTURE_DIR}/base/1.1.0"

    # Create deterministic .img files and matching .meta.json sidecars
    local ver arch content file sha
    for ver in 1.0.0 1.1.0; do
        for arch in amd64 arm64; do
            content="base-${ver}-${arch}-image-content"
            file="${FIXTURE_DIR}/base/${ver}/${arch}.img"
            printf '%s' "$content" > "$file"
            sha="$(_mps_sha256 "$file" | cut -d' ' -f1)"
            printf '{"sha256":"%s","build_date":"2026-01-15T10:00:00Z"}\n' "$sha" \
                > "${file}.meta.json"
        done
    done

    # Helper: read SHA from already-written sidecar
    _sha() { jq -r '.sha256' "${FIXTURE_DIR}/base/$1/$2.img.meta.json"; }

    # Generate manifest.json with latest=1.1.0
    # shellcheck disable=SC2016
    jq -n \
        --arg s100a "$(_sha 1.0.0 amd64)" \
        --arg s100r "$(_sha 1.0.0 arm64)" \
        --arg s110a "$(_sha 1.1.0 amd64)" \
        --arg s110r "$(_sha 1.1.0 arm64)" \
        '{
            schema_version: 2,
            images: {
                base: {
                    latest: "1.1.0",
                    versions: {
                        "1.0.0": { amd64: { sha256: $s100a }, arm64: { sha256: $s100r } },
                        "1.1.0": { amd64: { sha256: $s110a }, arm64: { sha256: $s110r } }
                    }
                }
            }
        }' > "${FIXTURE_DIR}/manifest.json"
}

# Start the HTTP server pointing at $FIXTURE_DIR
_start_http_server() {
    HTTP_READY="${TEST_TEMP_DIR}/http_ready"
    python3 "${MPS_ROOT}/tests/stubs/http_server.py" \
        "$FIXTURE_DIR" "$HTTP_READY" &
    HTTP_PID=$!

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
}

# Pre-populate the cache with an image (no HTTP needed)
# Usage: _cache_image <name> <version> <arch>
_cache_image() {
    local name="$1" ver="$2" arch="$3"
    local cache="${HOME}/mps/cache/images/${name}/${ver}"
    mkdir -p "$cache"
    local content="${name}-${ver}-${arch}-image-content"
    printf '%s' "$content" > "${cache}/${arch}.img"
    local sha
    sha="$(_mps_sha256 "${cache}/${arch}.img" | cut -d' ' -f1)"
    printf '{"sha256":"%s","build_date":"2026-01-15T10:00:00Z"}\n' "$sha" \
        > "${cache}/${arch}.meta.json"
}

# ================================================================
# Setup / Teardown
# ================================================================

setup() {
    setup_home_override
    mkdir -p "$HOME/mps/cache/images"

    # Stub arch detection to amd64 for determinism
    mps_detect_arch() { echo "amd64"; }
    export -f mps_detect_arch

    # Disable staleness checks by default (Group F enables it)
    export MPS_IMAGE_CHECK_UPDATES=false
}

teardown() {
    if [[ -n "${HTTP_PID:-}" ]]; then
        kill "$HTTP_PID" 2>/dev/null || true
        wait "$HTTP_PID" 2>/dev/null || true
    fi
    teardown_home_override
}

# ================================================================
# Group A: Cache Hit (4 tests)
# ================================================================

@test "resolve_image: explicit version returns file:// URL from cache" {
    _cache_image base 1.0.0 amd64
    run mps_resolve_image "base:1.0.0"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "file://${HOME}/mps/cache/images/base/1.0.0/amd64.img" ]]
}

@test "resolve_image: latest resolves to highest cached SemVer" {
    _cache_image base 1.0.0 amd64
    _cache_image base 1.1.0 amd64
    run mps_resolve_image "base"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"/base/1.1.0/amd64.img" ]]
}

@test "resolve_image: 'local' tag returns correct path" {
    local cache="${HOME}/mps/cache/images/base/local"
    mkdir -p "$cache"
    printf 'local-image-content' > "${cache}/amd64.img"
    run mps_resolve_image "base:local"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "file://${HOME}/mps/cache/images/base/local/amd64.img" ]]
}

@test "resolve_image: latest falls back to 'local' tag" {
    local cache="${HOME}/mps/cache/images/base/local"
    mkdir -p "$cache"
    printf 'local-image-content' > "${cache}/amd64.img"
    run mps_resolve_image "base"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"/base/local/amd64.img" ]]
}

# ================================================================
# Group B: Auto-Pull (3 tests)
# ================================================================

@test "resolve_image: cache miss auto-pulls explicit version" {
    _build_resolve_fixtures
    _start_http_server

    run mps_resolve_image "base:1.0.0"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"/base/1.0.0/amd64.img" ]]
    # Verify file was actually downloaded
    [[ -f "${HOME}/mps/cache/images/base/1.0.0/amd64.img" ]]
    # Verify .meta.json was saved
    [[ -f "${HOME}/mps/cache/images/base/1.0.0/amd64.meta.json" ]]
}

@test "resolve_image: cache miss auto-pulls latest via manifest" {
    _build_resolve_fixtures
    _start_http_server

    run mps_resolve_image "base"
    [[ "$status" -eq 0 ]]
    # manifest.json says latest=1.1.0
    [[ "$output" == *"/base/1.1.0/amd64.img" ]]
    [[ -f "${HOME}/mps/cache/images/base/1.1.0/amd64.img" ]]
}

@test "resolve_image: auto-pull uses correct arch (arm64)" {
    mps_detect_arch() { echo "arm64"; }
    export -f mps_detect_arch

    _build_resolve_fixtures
    _start_http_server

    run mps_resolve_image "base:1.0.0"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"/base/1.0.0/arm64.img" ]]
    [[ -f "${HOME}/mps/cache/images/base/1.0.0/arm64.img" ]]
}

# ================================================================
# Group C: Non-MPS Passthrough (2 tests)
# ================================================================

@test "resolve_image: Ubuntu version passes through unchanged" {
    run mps_resolve_image "24.04"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "24.04" ]]
}

@test "resolve_image: numeric spec with colon passes through" {
    run mps_resolve_image "24.04:custom"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "24.04:custom" ]]
}

# ================================================================
# Group D: Architecture Mismatch (2 tests)
# ================================================================

@test "resolve_image: explicit tag, wrong arch — dies with available arches" {
    _cache_image base 1.0.0 arm64
    # Our arch is amd64, but only arm64 is cached
    run mps_resolve_image "base:1.0.0"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"not for amd64"* ]]
    [[ "$output" == *"arm64"* ]]
}

@test "resolve_image: latest, no matching arch — dies" {
    # Create versions with only arm64
    _cache_image base 1.0.0 arm64
    _cache_image base 1.1.0 arm64
    run mps_resolve_image "base"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"no amd64 build"* ]]
}

# ================================================================
# Group E: Pull Failure (3 tests)
# ================================================================

@test "resolve_image: server unreachable — dies" {
    # Point to a port that nothing listens on
    export MPS_IMAGE_BASE_URL="http://127.0.0.1:1"
    run mps_resolve_image "base"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Could not pull image"* ]]
}

@test "resolve_image: no base URL configured — dies with config message" {
    unset MPS_IMAGE_BASE_URL
    run mps_resolve_image "base"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"MPS_IMAGE_BASE_URL not configured"* ]]
}

@test "resolve_image: SHA256 mismatch — pull fails, no file left in cache" {
    _build_resolve_fixtures
    # Corrupt the .img file after fixture generation (append extra byte)
    printf 'x' >> "${FIXTURE_DIR}/base/1.0.0/amd64.img"
    _start_http_server

    run mps_resolve_image "base:1.0.0"
    [[ "$status" -ne 0 ]]
    # Corrupted file must not remain in cache
    [[ ! -f "${HOME}/mps/cache/images/base/1.0.0/amd64.img" ]]
}

# ================================================================
# Group F: Staleness Warning (1 test)
# ================================================================

@test "resolve_image: cache hit with update available emits staleness warning" {
    export MPS_IMAGE_CHECK_UPDATES=true

    # Cache version 1.0.0
    _cache_image base 1.0.0 amd64

    # Serve manifest that says latest=1.1.0 (with matching sidecar SHA)
    _build_resolve_fixtures
    _start_http_server

    run mps_resolve_image "base:1.0.0"
    [[ "$status" -eq 0 ]]
    # Returns the cached file
    [[ "$output" == *"/base/1.0.0/amd64.img" ]]
    # Staleness warning about newer version should be in stderr (captured by run)
    [[ "$output" == *"outdated"* ]] || [[ "$output" == *"1.1.0"* ]]
}
