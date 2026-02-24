#!/usr/bin/env bats
# Integration tests for command orchestration: cmd_image (list/import/pull/remove).
#
# These tests use a populated cache tree in $HOME/.mps/cache/images/ and let most
# functions flow through. Network functions (_mps_fetch_manifest, _mps_pull_image)
# are stubbed since they require real CDN access.

load ../test_helper

# ================================================================
# Shared setup / teardown
# ================================================================

setup() {
    setup_home_override
    mkdir -p "$HOME/.mps/instances" "$HOME/.mps/cache/images"
    setup_multipass_stub
    # shellcheck source=../../lib/multipass.sh
    source "${MPS_ROOT}/lib/multipass.sh"
    export TEST_TEMP_DIR

    # Populate image cache with real SHA
    local cache="${HOME}/.mps/cache/images"
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
    mps_resolve_image() { echo "file://${HOME}/.mps/cache/images/base/1.0.0/${TEST_ARCH}.img"; }
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
    rm -rf "${HOME}/.mps/cache/images"/*
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

@test "image list: distinguishes pulled vs imported" {
    local cache="${HOME}/.mps/cache/images"
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
    [[ -f "${HOME}/.mps/cache/images/testimg/1.0.0/amd64.img" ]]
}

@test "image import: auto-detects name from mps-<name>-<arch>.qcow2.img filename" {
    local src="${TEST_TEMP_DIR}/mps-myimage-amd64.qcow2.img"
    dd if=/dev/urandom of="$src" bs=1024 count=1 2>/dev/null

    run cmd_image import "$src"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"myimage"* ]]
    [[ -f "${HOME}/.mps/cache/images/myimage/local/amd64.img" ]]
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
    local meta="${HOME}/.mps/cache/images/testimg/1.0.0/amd64.meta.json"
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
    [[ -f "${HOME}/.mps/cache/images/custom/2.0.0/arm64.img" ]]
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
    [[ -d "${HOME}/.mps/cache/images/base/0.9.0" ]]
    run cmd_image remove base:0.9.0 --force
    [[ "$status" -eq 0 ]]
    [[ ! -d "${HOME}/.mps/cache/images/base/0.9.0" ]]
}

@test "image remove: --arch removes only specified arch files" {
    local cache="${HOME}/.mps/cache/images"
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
    [[ -d "${HOME}/.mps/cache/images" ]]
    local contents
    contents="$(ls -A "${HOME}/.mps/cache/images" 2>/dev/null)"
    [[ -z "$contents" ]]
}

@test "image remove: cleans up empty parent directories after arch removal" {
    local cache="${HOME}/.mps/cache/images"
    # Remove the only arch file from 0.9.0
    run cmd_image remove "base:0.9.0" --arch "$TEST_ARCH" --force
    [[ "$status" -eq 0 ]]
    # Tag dir should have been cleaned up (empty after removing the only arch)
    [[ ! -d "${cache}/base/0.9.0" ]]
}

@test "image remove --force: skips confirmation" {
    run cmd_image remove base:0.9.0 --force
    [[ "$status" -eq 0 ]]
    [[ ! -d "${HOME}/.mps/cache/images/base/0.9.0" ]]
}

@test "image remove: not found dies" {
    run cmd_image remove nonexistent:1.0.0 --force
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"not found"* ]] || [[ "$output" == *"Image not found"* ]]
}

@test "image remove: removes all versions when no tag specified" {
    run cmd_image remove base --force
    [[ "$status" -eq 0 ]]
    [[ ! -d "${HOME}/.mps/cache/images/base" ]]
}

@test "image remove: shows preview before removing" {
    run cmd_image remove base:0.9.0 --force
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"will be removed"* ]]
}
