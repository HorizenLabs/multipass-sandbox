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
