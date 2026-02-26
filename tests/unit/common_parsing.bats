#!/usr/bin/env bats
# Tests for parsing/conversion functions in lib/common.sh:
#   _mps_parse_size_mb, _mps_semver_gt, _mps_is_mps_image

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

@test "_mps_parse_size_mb: parses bare number as megabytes" {
    result="$(_mps_parse_size_mb "256")"
    [[ "$result" -eq 256 ]]
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
