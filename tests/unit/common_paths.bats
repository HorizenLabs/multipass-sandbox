#!/usr/bin/env bats
# Tests for path/OS/arch functions in lib/common.sh:
#   mps_detect_os, mps_detect_arch, mps_host_to_guest_path,
#   mps_resolve_mount_source, mps_resolve_mount, mps_validate_mount_source,
#   mps_parse_extra_mounts

load ../test_helper

setup() {
    setup_temp_dir
}

teardown() {
    teardown_temp_dir
}

# ================================================================
# mps_detect_os
# ================================================================

@test "mps_detect_os: returns linux on Linux" {
    result="$(mps_detect_os)"
    # We're running in Docker Linux
    [[ "$result" == "linux" ]]
}

# ================================================================
# mps_detect_arch
# ================================================================

@test "mps_detect_arch: returns amd64 or arm64" {
    result="$(mps_detect_arch)"
    [[ "$result" == "amd64" || "$result" == "arm64" ]]
}

# ================================================================
# mps_host_to_guest_path
# ================================================================

@test "mps_host_to_guest_path: identity on Linux" {
    result="$(mps_host_to_guest_path "/home/user/project")"
    [[ "$result" == "/home/user/project" ]]
}

@test "mps_host_to_guest_path: preserves complex paths" {
    result="$(mps_host_to_guest_path "/home/user/my project/src")"
    [[ "$result" == "/home/user/my project/src" ]]
}

# ================================================================
# mps_resolve_mount_source
# ================================================================

@test "mps_resolve_mount_source: returns physical CWD when no arg" {
    result="$(mps_resolve_mount_source "")"
    expected="$(pwd -P)"
    [[ "$result" == "$expected" ]]
}

@test "mps_resolve_mount_source: resolves absolute path to physical path" {
    result="$(mps_resolve_mount_source "${TEST_TEMP_DIR}")"
    expected="$(cd "${TEST_TEMP_DIR}" && pwd -P)"
    [[ "$result" == "$expected" ]]
}

@test "mps_resolve_mount_source: resolves symlinks to physical path" {
    local real_dir="${TEST_TEMP_DIR}/real-target"
    local link_dir="${TEST_TEMP_DIR}/symlinked"
    mkdir -p "$real_dir"
    ln -sfn "$real_dir" "$link_dir"

    result="$(mps_resolve_mount_source "$link_dir")"
    [[ "$result" == "$real_dir" ]]
}

# ================================================================
# mps_resolve_mount
# ================================================================

@test "mps_resolve_mount: sets source and target from CWD" {
    MPS_NO_AUTOMOUNT=false
    mps_resolve_mount ""
    [[ -n "$MPS_MOUNT_SOURCE" ]]
    [[ -n "$MPS_MOUNT_TARGET" ]]
    # On Linux, source == target (identity path conversion)
    [[ "$MPS_MOUNT_SOURCE" == "$MPS_MOUNT_TARGET" ]]
}

@test "mps_resolve_mount: respects MPS_NO_AUTOMOUNT" {
    MPS_NO_AUTOMOUNT=true
    mps_resolve_mount ""
    [[ -z "$MPS_MOUNT_SOURCE" ]]
    [[ -z "$MPS_MOUNT_TARGET" ]]
}

@test "mps_resolve_mount: explicit path overrides automount opt-out" {
    export MPS_NO_AUTOMOUNT=true
    mps_resolve_mount "${TEST_TEMP_DIR}"
    local expected
    expected="$(cd "${TEST_TEMP_DIR}" && pwd -P)"
    [[ "$MPS_MOUNT_SOURCE" == "$expected" ]]
}

# ================================================================
# mps_validate_mount_source
# ================================================================

@test "mps_validate_mount_source: accepts path within HOME" {
    mps_validate_mount_source "${HOME}/some/project"
}

@test "mps_validate_mount_source: rejects path outside HOME" {
    run mps_validate_mount_source "/etc/passwd"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"within your home directory"* ]]
}

@test "mps_validate_mount_source: warns when mounting HOME directly" {
    run mps_validate_mount_source "${HOME}"
    # Should succeed but with a warning
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"entire home directory"* ]]
}

# ================================================================
# mps_parse_extra_mounts
# ================================================================

@test "mps_parse_extra_mounts: returns empty for no mounts" {
    MPS_MOUNTS=""
    result="$(mps_parse_extra_mounts)"
    [[ -z "$result" ]]
}

@test "mps_parse_extra_mounts: parses absolute src:dst pairs" {
    MPS_MOUNTS="${TEST_TEMP_DIR}:/guest/path"
    result="$(mps_parse_extra_mounts)"
    [[ "$result" == "${TEST_TEMP_DIR}:/guest/path" ]]
}

@test "mps_parse_extra_mounts: parses multiple mount specs" {
    mkdir -p "${TEST_TEMP_DIR}/a" "${TEST_TEMP_DIR}/b"
    export MPS_MOUNTS="${TEST_TEMP_DIR}/a:/mnt/a ${TEST_TEMP_DIR}/b:/mnt/b"
    result="$(mps_parse_extra_mounts)"
    [[ "$result" == *"${TEST_TEMP_DIR}/a:/mnt/a"* ]]
    [[ "$result" == *"${TEST_TEMP_DIR}/b:/mnt/b"* ]]
}

# ================================================================
# _mps_snap_confined
# ================================================================

@test "_mps_snap_confined: returns false in test environment (no snap)" {
    run _mps_snap_confined
    [[ "$status" -ne 0 ]]
}

# ================================================================
# _mps_check_snap_path
# ================================================================

@test "_mps_check_snap_path: no-op when snap not confined" {
    # Default test env has no snap — all paths should pass
    _mps_check_snap_path "${HOME}/.hidden/foo" "Test"
    _mps_check_snap_path "${HOME}/visible/foo" "Test"
    _mps_check_snap_path "/tmp/anything" "Test"
}

@test "_mps_check_snap_path: dies on HOME dotdir when snap confined" {
    # Mock _mps_snap_confined to return true
    _mps_snap_confined() { return 0; }
    export -f _mps_snap_confined

    run _mps_check_snap_path "${HOME}/.hidden/foo" "Mount"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"hidden directory"* ]]
    [[ "$output" == *"snap confinement"* ]]
}

@test "_mps_check_snap_path: allows visible dir under HOME when snap confined" {
    _mps_snap_confined() { return 0; }
    export -f _mps_snap_confined

    _mps_check_snap_path "${HOME}/visible/foo" "Mount"
}

@test "_mps_check_snap_path: allows paths outside HOME when snap confined" {
    _mps_snap_confined() { return 0; }
    export -f _mps_snap_confined

    _mps_check_snap_path "/tmp/some/path" "Transfer"
}

@test "_mps_check_snap_path: allows nested dotdirs when snap confined" {
    # Only top-level dotdirs under HOME are blocked; nested ones are fine
    _mps_snap_confined() { return 0; }
    export -f _mps_snap_confined

    _mps_check_snap_path "${HOME}/visible/.hidden/foo" "Cloud-init"
}

@test "mps_validate_mount_source: dies on hidden HOME path when snap confined" {
    _mps_snap_confined() { return 0; }
    export -f _mps_snap_confined

    run mps_validate_mount_source "${HOME}/.secret/project"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"hidden directory"* ]]
    [[ "$output" == *"snap confinement"* ]]
}

# ================================================================
# mps_detect_arch: stub-driven architecture mapping
# ================================================================

@test "mps_detect_arch: maps x86_64 to amd64" {
    local stub_dir="${TEST_TEMP_DIR}/arch_stubs"
    mkdir -p "$stub_dir"
    printf '#!/bin/sh\necho x86_64\n' > "${stub_dir}/dpkg"
    chmod +x "${stub_dir}/dpkg"
    printf '#!/bin/sh\necho x86_64\n' > "${stub_dir}/uname"
    chmod +x "${stub_dir}/uname"
    result="$(PATH="${stub_dir}:${PATH}" mps_detect_arch)"
    [[ "$result" == "amd64" ]]
}

@test "mps_detect_arch: maps aarch64 to arm64" {
    local stub_dir="${TEST_TEMP_DIR}/arch_stubs"
    mkdir -p "$stub_dir"
    printf '#!/bin/sh\necho aarch64\n' > "${stub_dir}/dpkg"
    chmod +x "${stub_dir}/dpkg"
    result="$(PATH="${stub_dir}:${PATH}" mps_detect_arch)"
    [[ "$result" == "arm64" ]]
}

@test "mps_detect_arch: maps arm64 to arm64" {
    local stub_dir="${TEST_TEMP_DIR}/arch_stubs"
    mkdir -p "$stub_dir"
    printf '#!/bin/sh\necho arm64\n' > "${stub_dir}/dpkg"
    chmod +x "${stub_dir}/dpkg"
    result="$(PATH="${stub_dir}:${PATH}" mps_detect_arch)"
    [[ "$result" == "arm64" ]]
}

@test "mps_detect_arch: passes through unknown arch unchanged" {
    local stub_dir="${TEST_TEMP_DIR}/arch_stubs"
    mkdir -p "$stub_dir"
    printf '#!/bin/sh\necho s390x\n' > "${stub_dir}/dpkg"
    chmod +x "${stub_dir}/dpkg"
    result="$(PATH="${stub_dir}:${PATH}" mps_detect_arch)"
    [[ "$result" == "s390x" ]]
}

@test "mps_detect_arch: falls back to uname when dpkg unavailable" {
    local stub_dir="${TEST_TEMP_DIR}/arch_stubs"
    mkdir -p "$stub_dir"
    printf '#!/bin/sh\nexit 1\n' > "${stub_dir}/dpkg"
    chmod +x "${stub_dir}/dpkg"
    printf '#!/bin/sh\necho aarch64\n' > "${stub_dir}/uname"
    chmod +x "${stub_dir}/uname"
    result="$(PATH="${stub_dir}:${PATH}" mps_detect_arch)"
    [[ "$result" == "arm64" ]]
}

# ================================================================
# mps_resolve_mount_source: relative and error paths
# ================================================================

@test "mps_resolve_mount_source: resolves relative path to absolute" {
    local subdir="${TEST_TEMP_DIR}/rel_parent/child"
    mkdir -p "$subdir"
    result="$(cd "${TEST_TEMP_DIR}/rel_parent" && mps_resolve_mount_source "child")"
    expected="$(cd "$subdir" && pwd -P)"
    [[ "$result" == "$expected" ]]
}

@test "mps_resolve_mount_source: dies for nonexistent relative path" {
    run bash -c "cd '${TEST_TEMP_DIR}' && source '${MPS_ROOT}/lib/common.sh' && mps_resolve_mount_source 'no-such-dir'"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Path does not exist"* ]]
}
