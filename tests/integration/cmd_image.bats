#!/usr/bin/env bats
# Integration tests for command orchestration: cmd_image (list/import/pull/remove).
#
# These tests use a populated cache tree in $HOME/mps/cache/images/ and let most
# functions flow through. Network functions (_mps_fetch_manifest, _mps_pull_image)
# are stubbed since they require real CDN access.

load ../test_helper

# ================================================================
# Shared setup / teardown
# ================================================================

setup() {
    setup_home_override
    mkdir -p "$HOME/mps/instances" "$HOME/mps/cache/images"
    setup_multipass_stub
    # shellcheck source=../../lib/multipass.sh
    source "${MPS_ROOT}/lib/multipass.sh"
    export TEST_TEMP_DIR

    # Populate image cache with real SHA
    local cache="${HOME}/mps/cache/images"
    local arch
    arch="$(mps_detect_arch)"
    export TEST_ARCH="$arch"
    mkdir -p "${cache}/base/1.0.0"
    dd if=/dev/urandom of="${cache}/base/1.0.0/${arch}.img" bs=1024 count=1 2>/dev/null
    local real_sha
    real_sha="$(_mps_sha256 "${cache}/base/1.0.0/${arch}.img" | cut -d' ' -f1)"
    printf '{"sha256":"%s","build_date":"2025-01-01T00:00:00Z"}\n' "$real_sha" \
        > "${cache}/base/1.0.0/${arch}.meta.json"
    mkdir -p "${cache}/base/0.9.0"
    dd if=/dev/urandom of="${cache}/base/0.9.0/${arch}.img" bs=1024 count=1 2>/dev/null
    printf '{"sha256":"oldsha256","build_date":"2024-06-01T00:00:00Z"}\n' \
        > "${cache}/base/0.9.0/${arch}.meta.json"

    setup_integration_stubs
    # Override: resolve image uses detected arch
    mps_resolve_image() { echo "file://${HOME}/mps/cache/images/base/1.0.0/${TEST_ARCH}.img"; }
    # Override: configurable manifest stub
    _STUB_MANIFEST_FAIL=false
    _mps_fetch_manifest() {
        if [[ "${_STUB_MANIFEST_FAIL}" == "true" ]]; then return 1; fi
        cat "${MPS_ROOT}/tests/fixtures/http/manifest-simple.json"
    }
    # Override: configurable staleness
    _STUB_IMAGE_STALENESS="up-to-date"
    _mps_check_image_staleness() { echo "$_STUB_IMAGE_STALENESS"; }
    # Override: pull image tracking
    _mps_pull_image() {
        echo "pull_image $*" >> "${TEST_TEMP_DIR}/pull_image.log"
        return 0
    }
    export -f mps_resolve_image _mps_fetch_manifest
    export -f _mps_check_image_staleness _mps_pull_image
    source_commands
}
teardown() { teardown_home_override; }

# ================================================================
# _image_list
# ================================================================

@test "image list: shows cached images with name, tag, arch, source, size columns" {
    run cmd_image list
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"NAME"* ]]
    [[ "$output" == *"TAG"* ]]
    [[ "$output" == *"ARCH"* ]]
    [[ "$output" == *"SOURCE"* ]]
    [[ "$output" == *"SIZE"* ]]
    [[ "$output" == *"base"* ]]
    [[ "$output" == *"1.0.0"* ]]
    [[ "$output" == *"$TEST_ARCH"* ]]
}

@test "image list: empty cache shows (none)" {
    rm -rf "${HOME}/mps/cache/images"/*
    run cmd_image list
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"(none)"* ]]
}

@test "image list: with manifest shows STATUS column" {
    run cmd_image list
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"STATUS"* ]]
}

@test "image list: without manifest omits STATUS column" {
    _STUB_MANIFEST_FAIL=true
    _mps_fetch_manifest() { return 1; }
    export -f _mps_fetch_manifest

    run cmd_image list
    [[ "$status" -eq 0 ]]
    # Should NOT have STATUS column when manifest unavailable
    # The header line should have SIZE as last column
    [[ "$output" != *"STATUS"* ]]
}

@test "image list: stale status displayed in STATUS column" {
    _mps_check_image_staleness() { echo "stale"; }
    export -f _mps_check_image_staleness
    run cmd_image list
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"stale"* ]]
}

@test "image list: update status shows new version in STATUS column" {
    _mps_check_image_staleness() { echo "update:2.0.0"; }
    export -f _mps_check_image_staleness
    run cmd_image list
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"update"* ]]
    [[ "$output" == *"2.0.0"* ]]
}

@test "image list: unknown status shows -- in STATUS column" {
    _mps_check_image_staleness() { echo "unknown"; }
    export -f _mps_check_image_staleness
    run cmd_image list
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"--"* ]]
}

@test "image list: --remote with no MPS_IMAGE_BASE_URL warns and fails" {
    unset MPS_IMAGE_BASE_URL
    run cmd_image list --remote
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"MPS_IMAGE_BASE_URL not configured"* ]]
}

@test "image list: --remote with unreachable URL fails" {
    MPS_IMAGE_BASE_URL="http://127.0.0.1:1"
    run cmd_image list --remote
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Failed to fetch manifest"* ]]
}

@test "image list: --remote renders remote image table" {
    # Use real HTTP stub — setup already sets MPS_IMAGE_BASE_URL for the test stub
    # But our manifest is a simple one without the full fields — override
    _mps_fetch_manifest() { cat "${MPS_ROOT}/tests/fixtures/http/manifest-simple.json"; }
    export -f _mps_fetch_manifest
    # We need real curl to hit manifests; use manifest-simple.json which our stub serves
    export MPS_IMAGE_BASE_URL="http://localhost:1"
    # Just test via the stub function
    run bash -c '
        source "'"${MPS_ROOT}"'/lib/common.sh"
        source "'"${MPS_ROOT}"'/lib/multipass.sh"
        for f in "'"${MPS_ROOT}"'"/commands/*.sh; do source "$f"; done
        _mps_fetch_manifest() { cat "'"${MPS_ROOT}"'/tests/fixtures/http/manifest-simple.json"; }
        # Override curl so the function uses our manifest directly
        curl() { cat "'"${MPS_ROOT}"'/tests/fixtures/http/manifest-simple.json"; }
        export -f curl _mps_fetch_manifest
        export MPS_IMAGE_BASE_URL="http://localhost"
        cmd_image list --remote
    '
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Remote images"* ]]
    [[ "$output" == *"base"* ]]
}

@test "image list: unknown option errors" {
    run cmd_image list --bogus
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown option"* ]]
}

@test "image import: unknown option errors" {
    run cmd_image import --bogus
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown option"* ]]
}

@test "image pull: unknown option errors" {
    run cmd_image pull --bogus
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown option"* ]]
}

@test "image remove: unknown option errors" {
    run cmd_image remove --bogus
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown option"* ]]
}

@test "image remove: empty cache with --all shows 'no cached images'" {
    rm -rf "${HOME}/mps/cache/images"/*
    run cmd_image remove --all --force
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"No cached images"* ]]
}

@test "image remove: nonexistent version dies with 'Image not found'" {
    run cmd_image remove base:99.0.0 --force
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Image not found"* ]]
}

@test "image remove: nonexistent arch dies with 'Architecture not found'" {
    # Use a valid arch that doesn't exist in cache (opposite of TEST_ARCH)
    local missing_arch="arm64"
    [[ "$TEST_ARCH" == "arm64" ]] && missing_arch="amd64"
    run cmd_image remove "base:1.0.0" --arch "$missing_arch" --force
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"not found"* ]]
}

@test "image remove: confirmation declined aborts" {
    mps_confirm() { return 1; }
    export -f mps_confirm
    run cmd_image remove base:0.9.0
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Aborted"* ]]
    # Image should still exist
    [[ -d "${HOME}/mps/cache/images/base/0.9.0" ]]
}

@test "image remove: rmdir cleans empty image dir after arch removal" {
    local cache="${HOME}/mps/cache/images"
    # Create a version with only one arch file
    mkdir -p "${cache}/cleanme/1.0.0"
    : > "${cache}/cleanme/1.0.0/${TEST_ARCH}.img"
    run cmd_image remove "cleanme:1.0.0" --arch "$TEST_ARCH" --force
    [[ "$status" -eq 0 ]]
    # Both tag dir and image dir should be cleaned up
    [[ ! -d "${cache}/cleanme/1.0.0" ]]
    [[ ! -d "${cache}/cleanme" ]]
}

@test "image list: distinguishes pulled vs imported" {
    local cache="${HOME}/mps/cache/images"
    # Create an imported image (no build_date in meta)
    mkdir -p "${cache}/custom/local"
    : > "${cache}/custom/local/${TEST_ARCH}.img"
    echo '{"sha256":"abc123"}' > "${cache}/custom/local/${TEST_ARCH}.meta.json"

    run cmd_image list
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"pulled"* ]]
    [[ "$output" == *"imported"* ]]
}

# ================================================================
# _image_import
# ================================================================

@test "image import: imports file to correct cache path" {
    local src="${TEST_TEMP_DIR}/test-image.qcow2"
    dd if=/dev/urandom of="$src" bs=1024 count=1 2>/dev/null

    run cmd_image import "$src" --name testimg --tag 1.0.0 --arch amd64
    [[ "$status" -eq 0 ]]
    [[ -f "${HOME}/mps/cache/images/testimg/1.0.0/amd64.img" ]]
}

@test "image import: auto-detects name from mps-<name>-<arch>.qcow2.img filename" {
    local src="${TEST_TEMP_DIR}/mps-myimage-amd64.qcow2.img"
    dd if=/dev/urandom of="$src" bs=1024 count=1 2>/dev/null

    run cmd_image import "$src"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"myimage"* ]]
    [[ -f "${HOME}/mps/cache/images/myimage/local/amd64.img" ]]
}

@test "image import: auto-detects arch from filename" {
    local src="${TEST_TEMP_DIR}/mps-testimg-arm64.qcow2.img"
    dd if=/dev/urandom of="$src" bs=1024 count=1 2>/dev/null

    run cmd_image import "$src"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"arm64"* ]]
}

@test "image import: creates .meta.json with correct SHA256" {
    local src="${TEST_TEMP_DIR}/test-image.qcow2"
    dd if=/dev/urandom of="$src" bs=1024 count=1 2>/dev/null

    # Compute expected hash BEFORE import
    local expected_sha
    expected_sha="$(_mps_sha256 "$src" | cut -d' ' -f1)"

    run cmd_image import "$src" --name testimg --tag 1.0.0 --arch amd64
    [[ "$status" -eq 0 ]]
    local meta="${HOME}/mps/cache/images/testimg/1.0.0/amd64.meta.json"
    [[ -f "$meta" ]]
    local sha
    sha="$(jq -r '.sha256' "$meta")"
    [[ "$sha" == "$expected_sha" ]]
}

@test "image import: verifies against .sha256 sidecar when present" {
    local src="${TEST_TEMP_DIR}/test-image.qcow2"
    dd if=/dev/urandom of="$src" bs=1024 count=1 2>/dev/null
    # Create matching sidecar
    _mps_sha256 "$src" | cut -d' ' -f1 > "${src}.sha256"

    run cmd_image import "$src" --name testimg --tag 1.0.0 --arch amd64
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Checksum verified"* ]]
}

@test "image import: checksum mismatch dies" {
    local src="${TEST_TEMP_DIR}/test-image.qcow2"
    dd if=/dev/urandom of="$src" bs=1024 count=1 2>/dev/null
    # Create mismatching sidecar
    echo "0000000000000000000000000000000000000000000000000000000000000000" > "${src}.sha256"

    run cmd_image import "$src" --name testimg --tag 1.0.0 --arch amd64
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Checksum mismatch"* ]]
}

@test "image import: --name, --tag, --arch overrides" {
    local src="${TEST_TEMP_DIR}/whatever.qcow2"
    dd if=/dev/urandom of="$src" bs=1024 count=1 2>/dev/null

    run cmd_image import "$src" --name custom --tag 2.0.0 --arch arm64
    [[ "$status" -eq 0 ]]
    [[ -f "${HOME}/mps/cache/images/custom/2.0.0/arm64.img" ]]
    [[ "$output" == *"custom"* ]]
    [[ "$output" == *"2.0.0"* ]]
    [[ "$output" == *"arm64"* ]]
}

@test "image import: file not found dies" {
    run cmd_image import /nonexistent/file.qcow2
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"not found"* ]] || [[ "$output" == *"File not found"* ]]
}

@test "image import: prints summary with name, tag, arch, size, sha256" {
    local src="${TEST_TEMP_DIR}/test-image.qcow2"
    dd if=/dev/urandom of="$src" bs=1024 count=1 2>/dev/null

    run cmd_image import "$src" --name testimg --tag 1.0.0 --arch amd64
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Name:"* ]]
    [[ "$output" == *"testimg"* ]]
    [[ "$output" == *"Tag:"* ]]
    [[ "$output" == *"1.0.0"* ]]
    [[ "$output" == *"Arch:"* ]]
    [[ "$output" == *"amd64"* ]]
    [[ "$output" == *"SHA256:"* ]]
    [[ "$output" == *"Cached:"* ]]
}

# ================================================================
# _image_pull
# ================================================================

@test "image pull: stale image triggers pull with correct args" {
    _mps_check_image_staleness() { echo "stale"; }
    export -f _mps_check_image_staleness

    run cmd_image pull base:1.0.0
    [[ "$status" -eq 0 ]]
    [[ -f "${TEST_TEMP_DIR}/pull_image.log" ]]
    log="$(cat "${TEST_TEMP_DIR}/pull_image.log")"
    # Verify image name and version were passed to _mps_pull_image
    [[ "$log" == *"base"* ]]
    [[ "$log" == *"1.0.0"* ]]
}

@test "image pull: up-to-date skips pull with message" {
    _mps_check_image_staleness() { echo "up-to-date"; }
    export -f _mps_check_image_staleness

    run cmd_image pull base:1.0.0
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"already up to date"* ]]
    # Should NOT have called _mps_pull_image
    [[ ! -f "${TEST_TEMP_DIR}/pull_image.log" ]]
}

@test "image pull: update available triggers pull with version message" {
    _mps_check_image_staleness() { echo "update:2.0.0"; }
    export -f _mps_check_image_staleness

    run cmd_image pull base:1.0.0
    [[ "$status" -eq 0 ]]
    [[ -f "${TEST_TEMP_DIR}/pull_image.log" ]]
    # Should mention the new version
    [[ "$output" == *"2.0.0"* ]]
}

@test "image pull: --force bypasses up-to-date and always pulls" {
    _mps_check_image_staleness() { echo "up-to-date"; }
    export -f _mps_check_image_staleness

    run cmd_image pull base:1.0.0 --force
    [[ "$status" -eq 0 ]]
    [[ -f "${TEST_TEMP_DIR}/pull_image.log" ]]
    log="$(cat "${TEST_TEMP_DIR}/pull_image.log")"
    [[ "$log" == *"base"* ]]
}

@test "image pull: manifest fetch failure still attempts pull" {
    _STUB_MANIFEST_FAIL=true
    _mps_fetch_manifest() { return 1; }
    export -f _mps_fetch_manifest

    run cmd_image pull base
    [[ "$status" -eq 0 ]]
    [[ -f "${TEST_TEMP_DIR}/pull_image.log" ]]
}

# ================================================================
# _image_remove
# ================================================================

@test "image remove: removes specific version directory" {
    [[ -d "${HOME}/mps/cache/images/base/0.9.0" ]]
    run cmd_image remove base:0.9.0 --force
    [[ "$status" -eq 0 ]]
    [[ ! -d "${HOME}/mps/cache/images/base/0.9.0" ]]
}

@test "image remove: --arch removes only specified arch files" {
    local cache="${HOME}/mps/cache/images"
    # Add a second arch file to 1.0.0
    local other_arch="arm64"
    [[ "$TEST_ARCH" == "arm64" ]] && other_arch="amd64"
    : > "${cache}/base/1.0.0/${other_arch}.img"
    echo '{"sha256":"other"}' > "${cache}/base/1.0.0/${other_arch}.meta.json"

    run cmd_image remove "base:1.0.0" --arch "$other_arch" --force
    [[ "$status" -eq 0 ]]
    # Other arch should be removed
    [[ ! -f "${cache}/base/1.0.0/${other_arch}.img" ]]
    # Original arch should still be there
    [[ -f "${cache}/base/1.0.0/${TEST_ARCH}.img" ]]
}

@test "image remove --all: removes entire cache, recreates dir" {
    run cmd_image remove --all --force
    [[ "$status" -eq 0 ]]
    # Cache dir should still exist (recreated) but be empty
    [[ -d "${HOME}/mps/cache/images" ]]
    local contents
    contents="$(ls -A "${HOME}/mps/cache/images" 2>/dev/null)"
    [[ -z "$contents" ]]
}

@test "image remove: cleans up empty parent directories after arch removal" {
    local cache="${HOME}/mps/cache/images"
    # Remove the only arch file from 0.9.0
    run cmd_image remove "base:0.9.0" --arch "$TEST_ARCH" --force
    [[ "$status" -eq 0 ]]
    # Tag dir should have been cleaned up (empty after removing the only arch)
    [[ ! -d "${cache}/base/0.9.0" ]]
}

@test "image remove --force: skips confirmation" {
    run cmd_image remove base:0.9.0 --force
    [[ "$status" -eq 0 ]]
    [[ ! -d "${HOME}/mps/cache/images/base/0.9.0" ]]
}

@test "image remove: not found dies" {
    run cmd_image remove nonexistent:1.0.0 --force
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"not found"* ]] || [[ "$output" == *"Image not found"* ]]
}

@test "image remove: removes all versions when no tag specified" {
    run cmd_image remove base --force
    [[ "$status" -eq 0 ]]
    [[ ! -d "${HOME}/mps/cache/images/base" ]]
}

@test "image remove: shows preview before removing" {
    run cmd_image remove base:0.9.0 --force
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"will be removed"* ]]
}

# ================================================================
# _image_pull: old version cleanup after successful pull
# ================================================================

@test "image pull: cleans up old version when mps_confirm accepts" {
    local cache="${HOME}/mps/cache/images"

    # Override _mps_check_image_staleness to trigger a pull (stale)
    _mps_check_image_staleness() { echo "stale"; }
    export -f _mps_check_image_staleness

    # Override _mps_pull_image to simulate downloading a new version.
    # It creates the 2.0.0 directory with an image file.
    _mps_pull_image() {
        local name="$1"
        mkdir -p "${HOME}/mps/cache/images/${name}/2.0.0"
        dd if=/dev/urandom of="${HOME}/mps/cache/images/${name}/2.0.0/${TEST_ARCH}.img" bs=1024 count=1 2>/dev/null
        printf '{"sha256":"new_sha","build_date":"2026-01-01T00:00:00Z"}\n' \
            > "${HOME}/mps/cache/images/${name}/2.0.0/${TEST_ARCH}.meta.json"
        return 0
    }
    export -f _mps_pull_image

    # Override mps_confirm to accept removal
    mps_confirm() { return 0; }
    export -f mps_confirm

    # Verify old versions exist before pull
    [[ -d "${cache}/base/1.0.0" ]]
    [[ -d "${cache}/base/0.9.0" ]]

    run cmd_image pull base:1.0.0
    [[ "$status" -eq 0 ]]

    # After pull, 2.0.0 is the new version; old SemVer versions should be cleaned up
    [[ -d "${cache}/base/2.0.0" ]]
    # Both old versions (1.0.0 and 0.9.0) should have been removed (mps_confirm returns 0)
    [[ ! -f "${cache}/base/1.0.0/${TEST_ARCH}.img" ]]
    [[ ! -f "${cache}/base/0.9.0/${TEST_ARCH}.img" ]]
}

@test "image pull: preserves old version when mps_confirm declines" {
    local cache="${HOME}/mps/cache/images"

    _mps_check_image_staleness() { echo "stale"; }
    export -f _mps_check_image_staleness

    # Override _mps_pull_image to simulate downloading a new version
    _mps_pull_image() {
        local name="$1"
        mkdir -p "${HOME}/mps/cache/images/${name}/2.0.0"
        dd if=/dev/urandom of="${HOME}/mps/cache/images/${name}/2.0.0/${TEST_ARCH}.img" bs=1024 count=1 2>/dev/null
        printf '{"sha256":"new_sha","build_date":"2026-01-01T00:00:00Z"}\n' \
            > "${HOME}/mps/cache/images/${name}/2.0.0/${TEST_ARCH}.meta.json"
        return 0
    }
    export -f _mps_pull_image

    # Override mps_confirm to DECLINE removal
    mps_confirm() { return 1; }
    export -f mps_confirm

    [[ -d "${cache}/base/0.9.0" ]]

    run cmd_image pull base:1.0.0
    [[ "$status" -eq 0 ]]

    # Old versions should be preserved since user declined
    [[ -f "${cache}/base/0.9.0/${TEST_ARCH}.img" ]]
    [[ -f "${cache}/base/1.0.0/${TEST_ARCH}.img" ]]
    # New version should exist
    [[ -d "${cache}/base/2.0.0" ]]
}

@test "image pull: old version cleanup removes empty tag directories" {
    local cache="${HOME}/mps/cache/images"

    _mps_check_image_staleness() { echo "stale"; }
    export -f _mps_check_image_staleness

    _mps_pull_image() {
        local name="$1"
        mkdir -p "${HOME}/mps/cache/images/${name}/2.0.0"
        dd if=/dev/urandom of="${HOME}/mps/cache/images/${name}/2.0.0/${TEST_ARCH}.img" bs=1024 count=1 2>/dev/null
        printf '{"sha256":"new_sha","build_date":"2026-01-01T00:00:00Z"}\n' \
            > "${HOME}/mps/cache/images/${name}/2.0.0/${TEST_ARCH}.meta.json"
        return 0
    }
    export -f _mps_pull_image

    mps_confirm() { return 0; }
    export -f mps_confirm

    run cmd_image pull base:1.0.0
    [[ "$status" -eq 0 ]]

    # Old version directories should be removed entirely (empty after cleanup)
    [[ ! -d "${cache}/base/0.9.0" ]]
    [[ "$output" == *"Removed base:"* ]]
}

# ================================================================
# _image_list --remote: remote image listing with jq formatting
# ================================================================

@test "image list --remote: formats remote manifest with jq" {
    # Set up MPS_IMAGE_BASE_URL so the remote listing code path triggers
    export MPS_IMAGE_BASE_URL="http://localhost:9999"

    # Override curl to return a valid manifest with image data
    curl() {
        # Only intercept the manifest.json fetch
        case "${*}" in
            *manifest.json*)
                cat <<'MANIFEST'
{
    "images": {
        "base": {
            "latest": "1.0.0",
            "description": "Base Ubuntu image",
            "min_profile": "lite",
            "versions": {
                "1.0.0": {
                    "amd64": {"sha256": "abc123", "build_date": "2025-01-01T00:00:00Z"},
                    "arm64": {"sha256": "def456", "build_date": "2025-01-01T00:00:00Z"}
                }
            }
        }
    }
}
MANIFEST
                return 0
                ;;
            *)
                command curl "$@"
                ;;
        esac
    }
    export -f curl

    run cmd_image list --remote
    [[ "$status" -eq 0 ]]
    # Should show remote images header
    [[ "$output" == *"Remote images"* ]]
    # Should show column headers for remote listing
    [[ "$output" == *"NAME"* ]]
    [[ "$output" == *"VERSION"* ]]
    # Should show the base image from manifest
    [[ "$output" == *"base"* ]]
    [[ "$output" == *"1.0.0"* ]]
}

# ================================================================
# _image_import: manifest metadata merge into .meta.json
# ================================================================

@test "image import: merges manifest metadata into .meta.json" {
    local src="${TEST_TEMP_DIR}/test-merge.qcow2"
    dd if=/dev/urandom of="$src" bs=1024 count=1 2>/dev/null

    # Override _mps_fetch_manifest to return a manifest with flavor metadata
    _mps_fetch_manifest() {
        cat <<'MANIFEST'
{
    "images": {
        "base": {
            "latest": "1.0.0",
            "disk_size": "20G",
            "min_profile": "lite",
            "min_disk": "15G",
            "min_memory": "2G",
            "min_cpus": 2,
            "description": "Base Ubuntu image",
            "versions": {
                "1.0.0": {
                    "amd64": {"sha256": "abc123"}
                }
            }
        }
    }
}
MANIFEST
        return 0
    }
    export -f _mps_fetch_manifest

    run cmd_image import "$src" --name base --tag 1.0.0 --arch amd64
    [[ "$status" -eq 0 ]]

    local meta="${HOME}/mps/cache/images/base/1.0.0/amd64.meta.json"
    [[ -f "$meta" ]]

    # Verify merged metadata fields
    local disk_size min_profile
    disk_size="$(jq -r '.disk_size' "$meta")"
    min_profile="$(jq -r '.min_profile' "$meta")"
    [[ "$disk_size" == "20G" ]]
    [[ "$min_profile" == "lite" ]]

    # sha256 should also be present (from the import itself)
    local sha
    sha="$(jq -r '.sha256' "$meta")"
    [[ -n "$sha" ]]
}

@test "image import: no merge when manifest fetch fails" {
    local src="${TEST_TEMP_DIR}/test-nomerge.qcow2"
    dd if=/dev/urandom of="$src" bs=1024 count=1 2>/dev/null

    # Override _mps_fetch_manifest to fail
    _mps_fetch_manifest() { return 1; }
    export -f _mps_fetch_manifest

    run cmd_image import "$src" --name custom --tag 1.0.0 --arch amd64
    [[ "$status" -eq 0 ]]

    local meta="${HOME}/mps/cache/images/custom/1.0.0/amd64.meta.json"
    [[ -f "$meta" ]]

    # Should only have sha256 (no merged fields)
    local disk_size
    disk_size="$(jq -r '.disk_size // "null"' "$meta")"
    [[ "$disk_size" == "null" ]]
}

# ================================================================
# _image_remove: nonexistent image and version not found
# ================================================================

@test "image remove: nonexistent image name dies with 'not found'" {
    run cmd_image remove "nonexistent-image" --force
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"not found"* ]] || [[ "$output" == *"Image not found"* ]]
}

@test "image remove: nonexistent version dies with 'not found'" {
    # base image exists but version 99.99.99 does not
    run cmd_image remove "base:99.99.99" --force
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"not found"* ]] || [[ "$output" == *"Image not found"* ]]
}
