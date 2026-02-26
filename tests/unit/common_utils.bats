#!/usr/bin/env bats
# Tests for utility functions in lib/common.sh:
#   _mps_sha256, _mps_md5, mps_require_cmd

load ../test_helper

setup()    { setup_home_override; }
teardown() { teardown_home_override; }

# ================================================================
# _mps_sha256
# ================================================================

@test "_mps_sha256: hashes a file" {
    echo -n "hello" > "${TEST_TEMP_DIR}/testfile"
    result="$(_mps_sha256 "${TEST_TEMP_DIR}/testfile")"
    # SHA256 of "hello" = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
    [[ "$result" == *"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"* ]]
}

@test "_mps_sha256: output includes filename" {
    echo -n "test" > "${TEST_TEMP_DIR}/myfile.txt"
    result="$(_mps_sha256 "${TEST_TEMP_DIR}/myfile.txt")"
    [[ "$result" == *"myfile.txt"* ]]
}

@test "_mps_sha256: hashes stdin" {
    result="$(echo -n "hello" | _mps_sha256)"
    [[ "$result" == *"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"* ]]
}

@test "_mps_sha256: different content produces different hash" {
    echo -n "aaa" > "${TEST_TEMP_DIR}/file1"
    echo -n "bbb" > "${TEST_TEMP_DIR}/file2"
    hash1="$(_mps_sha256 "${TEST_TEMP_DIR}/file1" | awk '{print $1}')"
    hash2="$(_mps_sha256 "${TEST_TEMP_DIR}/file2" | awk '{print $1}')"
    [[ "$hash1" != "$hash2" ]]
}

@test "_mps_sha256: hash is 64 hex characters" {
    echo -n "test" > "${TEST_TEMP_DIR}/testfile"
    hash="$(_mps_sha256 "${TEST_TEMP_DIR}/testfile" | awk '{print $1}')"
    [[ ${#hash} -eq 64 ]]
    [[ "$hash" =~ ^[a-f0-9]{64}$ ]]
}

# ================================================================
# _mps_md5
# ================================================================

@test "_mps_md5: hashes a file" {
    echo -n "hello" > "${TEST_TEMP_DIR}/testfile"
    result="$(_mps_md5 "${TEST_TEMP_DIR}/testfile")"
    # MD5 of "hello" = 5d41402abc4b2a76b9719d911017c592
    [[ "$result" == *"5d41402abc4b2a76b9719d911017c592"* ]]
}

@test "_mps_md5: output includes filename" {
    echo -n "test" > "${TEST_TEMP_DIR}/myfile.txt"
    result="$(_mps_md5 "${TEST_TEMP_DIR}/myfile.txt")"
    [[ "$result" == *"myfile.txt"* ]]
}

@test "_mps_md5: hash is 32 hex characters" {
    echo -n "test" > "${TEST_TEMP_DIR}/testfile"
    hash="$(_mps_md5 "${TEST_TEMP_DIR}/testfile" | awk '{print $1}')"
    [[ ${#hash} -eq 32 ]]
    [[ "$hash" =~ ^[a-f0-9]{32}$ ]]
}

@test "_mps_md5: different content produces different hash" {
    echo -n "aaa" > "${TEST_TEMP_DIR}/file1"
    echo -n "bbb" > "${TEST_TEMP_DIR}/file2"
    hash1="$(_mps_md5 "${TEST_TEMP_DIR}/file1" | awk '{print $1}')"
    hash2="$(_mps_md5 "${TEST_TEMP_DIR}/file2" | awk '{print $1}')"
    [[ "$hash1" != "$hash2" ]]
}

# ================================================================
# mps_require_cmd
# ================================================================

@test "mps_require_cmd: succeeds for existing command" {
    run mps_require_cmd "bash"
    [[ "$status" -eq 0 ]]
}

@test "mps_require_cmd: succeeds silently" {
    result="$(mps_require_cmd "bash")"
    [[ -z "$result" ]]
}

@test "mps_require_cmd: dies for missing command" {
    run mps_require_cmd "nonexistent-cmd-xyz-12345"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"is not installed"* ]]
}

@test "mps_require_cmd: shows multipass-specific message" {
    # Skip if multipass happens to be installed in the test container
    if command -v multipass &>/dev/null; then
        skip "multipass is installed"
    fi
    run mps_require_cmd "multipass"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"multipass.run"* ]]
}

@test "mps_require_cmd: shows jq-specific message" {
    # Hide jq by pointing PATH to an empty temp directory
    local empty_dir
    empty_dir="$(mktemp -d)"
    PATH="$empty_dir" run mps_require_cmd "jq"
    rmdir "$empty_dir"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"brew install jq"* ]]
}

@test "mps_require_cmd: generic message for unknown commands" {
    run mps_require_cmd "totally-unknown-tool-xyz"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"'totally-unknown-tool-xyz' is not installed."* ]]
}

# ================================================================
# mps_resolve_image: fallthrough cases
# ================================================================

@test "mps_resolve_image: empty cache dir echoes spec as-is" {
    # Set up an image dir with a version subdir but NO .img files
    local cache_dir="${HOME}/mps/cache/images/base"
    mkdir -p "${cache_dir}/1.0.0"
    # No .img file created — _has_images stays false
    # Not an mps image URL (starts with digit) so it falls through
    # Use a non-mps image name (starts with digit) to trigger echo passthrough
    result="$(mps_resolve_image "24.04")"
    [[ "$result" == "24.04" ]]
}

@test "mps_resolve_image: no images at all falls through for non-mps spec" {
    # image_dir does not exist, and name starts with digit → echo spec
    result="$(mps_resolve_image "22.04")"
    [[ "$result" == "22.04" ]]
}

@test "mps_resolve_image: no version dirs with images echoes spec" {
    # Create image dir with a version subdir that has NO .img files inside
    # _has_images stays false, _mps_is_mps_image returns true, but no BASE_URL
    # → dies with "not found locally and MPS_IMAGE_BASE_URL not configured"
    local cache_dir="${HOME}/mps/cache/images/emptyimg"
    mkdir -p "${cache_dir}/1.0.0"
    # No .img files at all in version dir
    unset MPS_IMAGE_BASE_URL 2>/dev/null || true
    run mps_resolve_image "emptyimg"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"not found locally"* ]]
}

@test "mps_resolve_image: latest tag no matching arch dies with available" {
    # Create a cache dir with an image for a DIFFERENT arch than what we detect
    local arch
    arch="$(mps_detect_arch)"
    local cache_dir="${HOME}/mps/cache/images/testimg"
    mkdir -p "${cache_dir}/1.0.0"
    touch "${cache_dir}/1.0.0/other-arch.img"
    # _has_images=true, tag=latest, _mps_resolve_latest_version returns empty
    # because the only version has other-arch, not our arch
    # → dies with "no <arch> build" message listing available arches
    run mps_resolve_image "testimg"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"no ${arch} build"* ]]
}

@test "_mps_resolve_latest_version: skips non-SemVer tags" {
    # Create cache with a non-SemVer, non-"local" tag (e.g., "dev-build")
    local arch
    arch="$(mps_detect_arch)"
    local image_dir="${HOME}/mps/cache/images/testimg2"
    mkdir -p "${image_dir}/dev-build"
    touch "${image_dir}/dev-build/${arch}.img"
    # The only tag is "dev-build" which is not SemVer and not "local"
    # _mps_resolve_latest_version should return empty string
    result="$(_mps_resolve_latest_version "$image_dir" "$arch")"
    [[ -z "$result" ]]
}

@test "_mps_resolve_latest_version: skips non-SemVer but finds SemVer" {
    local arch
    arch="$(mps_detect_arch)"
    local image_dir="${HOME}/mps/cache/images/testimg3"
    mkdir -p "${image_dir}/dev-build"
    mkdir -p "${image_dir}/2.0.0"
    touch "${image_dir}/dev-build/${arch}.img"
    touch "${image_dir}/2.0.0/${arch}.img"
    # Should skip "dev-build" and return "2.0.0"
    result="$(_mps_resolve_latest_version "$image_dir" "$arch")"
    [[ "$result" == "2.0.0" ]]
}

@test "mps_resolve_image: tag exists but wrong arch dies" {
    # Create a cache dir with a specific tag but wrong arch
    local arch
    arch="$(mps_detect_arch)"
    local cache_dir="${HOME}/mps/cache/images/wrongarch"
    mkdir -p "${cache_dir}/1.0.0"
    touch "${cache_dir}/1.0.0/other-arch.img"
    # Requesting an explicit version that exists but has wrong arch
    run mps_resolve_image "wrongarch:1.0.0"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"not for ${arch}"* ]]
}

@test "mps_resolve_image: explicit tag not in cache passes through" {
    # Create a cache dir with one version but request a different one
    local arch
    arch="$(mps_detect_arch)"
    local cache_dir="${HOME}/mps/cache/images/passthru"
    mkdir -p "${cache_dir}/1.0.0"
    touch "${cache_dir}/1.0.0/${arch}.img"
    # Request a version that does NOT exist (tag dir missing entirely)
    # _has_images=true, tag="2.0.0", img_file doesn't exist, tag_dir doesn't exist
    # → falls through to echo "$image_spec" (line 701)
    result="$(mps_resolve_image "passthru:2.0.0")"
    [[ "$result" == "passthru:2.0.0" ]]
}
