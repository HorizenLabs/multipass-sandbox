#!/usr/bin/env bats
# Tests for parsing/conversion functions in lib/common.sh:
#   _mps_parse_size_mb, _mps_size_to_bytes, _mps_semver_gt, _mps_is_mps_image

load ../test_helper

# ================================================================
# _mps_parse_size_mb
# ================================================================

@test "_mps_parse_size_mb: parses gigabytes uppercase" {
    result="$(_mps_parse_size_mb "4G")"
    [[ "$result" -eq 4096 ]]
}

@test "_mps_parse_size_mb: parses gigabytes lowercase" {
    result="$(_mps_parse_size_mb "4g")"
    [[ "$result" -eq 4096 ]]
}

@test "_mps_parse_size_mb: parses megabytes uppercase" {
    result="$(_mps_parse_size_mb "512M")"
    [[ "$result" -eq 512 ]]
}

@test "_mps_parse_size_mb: parses megabytes lowercase" {
    result="$(_mps_parse_size_mb "512m")"
    [[ "$result" -eq 512 ]]
}

@test "_mps_parse_size_mb: parses bare number as bytes" {
    # 1073741824 bytes = 1024 MB
    result="$(_mps_parse_size_mb "1073741824")"
    [[ "$result" -eq 1024 ]]
}

@test "_mps_parse_size_mb: parses GB suffix" {
    result="$(_mps_parse_size_mb "4GB")"
    [[ "$result" -eq 4096 ]]
}

@test "_mps_parse_size_mb: parses MB suffix" {
    result="$(_mps_parse_size_mb "512MB")"
    [[ "$result" -eq 512 ]]
}

@test "_mps_parse_size_mb: parses kilobytes" {
    # 1048576K = 1048576 * 1024 bytes = 1024 MB
    result="$(_mps_parse_size_mb "1048576K")"
    [[ "$result" -eq 1024 ]]
}

@test "_mps_parse_size_mb: parses KB suffix" {
    # 1024KB = 1024 * 1024 bytes = 1 MB
    result="$(_mps_parse_size_mb "1024KB")"
    [[ "$result" -eq 1 ]]
}

@test "_mps_parse_size_mb: parses KiB suffix" {
    result="$(_mps_parse_size_mb "1024KiB")"
    [[ "$result" -eq 1 ]]
}

@test "_mps_parse_size_mb: parses B suffix" {
    # 1073741824B = 1024 MB
    result="$(_mps_parse_size_mb "1073741824B")"
    [[ "$result" -eq 1024 ]]
}

@test "_mps_parse_size_mb: parses 1G as 1024" {
    result="$(_mps_parse_size_mb "1G")"
    [[ "$result" -eq 1024 ]]
}

@test "_mps_parse_size_mb: parses 20G correctly" {
    result="$(_mps_parse_size_mb "20G")"
    [[ "$result" -eq 20480 ]]
}

@test "_mps_parse_size_mb: returns 0 for invalid input" {
    run _mps_parse_size_mb "abc"
    [[ "$output" == "0" ]]
    [[ "$status" -eq 1 ]]
}

@test "_mps_parse_size_mb: returns 0 for empty string" {
    run _mps_parse_size_mb ""
    [[ "$output" == "0" ]]
    [[ "$status" -eq 1 ]]
}

@test "_mps_parse_size_mb: parses GiB uppercase" {
    result="$(_mps_parse_size_mb "4GiB")"
    [[ "$result" -eq 4096 ]]
}

@test "_mps_parse_size_mb: parses gib lowercase" {
    result="$(_mps_parse_size_mb "4gib")"
    [[ "$result" -eq 4096 ]]
}

@test "_mps_parse_size_mb: parses MiB uppercase" {
    result="$(_mps_parse_size_mb "512MiB")"
    [[ "$result" -eq 512 ]]
}

@test "_mps_parse_size_mb: parses mib lowercase" {
    result="$(_mps_parse_size_mb "512mib")"
    [[ "$result" -eq 512 ]]
}

@test "_mps_parse_size_mb: parses 20GiB correctly" {
    result="$(_mps_parse_size_mb "20GiB")"
    [[ "$result" -eq 20480 ]]
}

# ================================================================
# _mps_size_to_bytes
# ================================================================

@test "_mps_size_to_bytes: 1G = 1073741824" {
    result="$(_mps_size_to_bytes "1G")"
    [[ "$result" -eq 1073741824 ]]
}

@test "_mps_size_to_bytes: 1GB = 1073741824" {
    result="$(_mps_size_to_bytes "1GB")"
    [[ "$result" -eq 1073741824 ]]
}

@test "_mps_size_to_bytes: 1GiB = 1073741824" {
    result="$(_mps_size_to_bytes "1GiB")"
    [[ "$result" -eq 1073741824 ]]
}

@test "_mps_size_to_bytes: 1024M = 1073741824" {
    result="$(_mps_size_to_bytes "1024M")"
    [[ "$result" -eq 1073741824 ]]
}

@test "_mps_size_to_bytes: 1024MB = 1073741824" {
    result="$(_mps_size_to_bytes "1024MB")"
    [[ "$result" -eq 1073741824 ]]
}

@test "_mps_size_to_bytes: 1024MiB = 1073741824" {
    result="$(_mps_size_to_bytes "1024MiB")"
    [[ "$result" -eq 1073741824 ]]
}

@test "_mps_size_to_bytes: 1048576K = 1073741824" {
    result="$(_mps_size_to_bytes "1048576K")"
    [[ "$result" -eq 1073741824 ]]
}

@test "_mps_size_to_bytes: 1048576KB = 1073741824" {
    result="$(_mps_size_to_bytes "1048576KB")"
    [[ "$result" -eq 1073741824 ]]
}

@test "_mps_size_to_bytes: 1048576KiB = 1073741824" {
    result="$(_mps_size_to_bytes "1048576KiB")"
    [[ "$result" -eq 1073741824 ]]
}

@test "_mps_size_to_bytes: 1073741824B = 1073741824" {
    result="$(_mps_size_to_bytes "1073741824B")"
    [[ "$result" -eq 1073741824 ]]
}

@test "_mps_size_to_bytes: bare number = bytes" {
    result="$(_mps_size_to_bytes "1073741824")"
    [[ "$result" -eq 1073741824 ]]
}

@test "_mps_size_to_bytes: case insensitive (4gib)" {
    result="$(_mps_size_to_bytes "4gib")"
    [[ "$result" -eq 4294967296 ]]
}

@test "_mps_size_to_bytes: returns 0 for invalid input" {
    run _mps_size_to_bytes "abc"
    [[ "$output" == "0" ]]
    [[ "$status" -eq 1 ]]
}

# ================================================================
# _mps_semver_gt
# ================================================================

@test "_mps_semver_gt: 2.0.0 > 1.0.0" {
    _mps_semver_gt "2.0.0" "1.0.0"
}

@test "_mps_semver_gt: 1.1.0 > 1.0.0" {
    _mps_semver_gt "1.1.0" "1.0.0"
}

@test "_mps_semver_gt: 1.0.1 > 1.0.0" {
    _mps_semver_gt "1.0.1" "1.0.0"
}

@test "_mps_semver_gt: 1.0.0 is NOT > 1.0.0 (equal)" {
    run _mps_semver_gt "1.0.0" "1.0.0"
    [[ "$status" -ne 0 ]]
}

@test "_mps_semver_gt: 1.0.0 is NOT > 2.0.0" {
    run _mps_semver_gt "1.0.0" "2.0.0"
    [[ "$status" -ne 0 ]]
}

@test "_mps_semver_gt: 1.0.0 is NOT > 1.1.0" {
    run _mps_semver_gt "1.0.0" "1.1.0"
    [[ "$status" -ne 0 ]]
}

@test "_mps_semver_gt: 10.0.0 > 9.0.0 (numeric comparison)" {
    _mps_semver_gt "10.0.0" "9.0.0"
}

@test "_mps_semver_gt: 1.10.0 > 1.9.0 (numeric comparison)" {
    _mps_semver_gt "1.10.0" "1.9.0"
}

# ================================================================
# _mps_is_mps_image
# ================================================================

@test "_mps_is_mps_image: 'base' is an mps image" {
    _mps_is_mps_image "base"
}

@test "_mps_is_mps_image: 'protocol-dev' is an mps image" {
    _mps_is_mps_image "protocol-dev"
}

@test "_mps_is_mps_image: '24.04' is NOT an mps image" {
    run _mps_is_mps_image "24.04"
    [[ "$status" -ne 0 ]]
}

@test "_mps_is_mps_image: '22.04' is NOT an mps image" {
    run _mps_is_mps_image "22.04"
    [[ "$status" -ne 0 ]]
}
