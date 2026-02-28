#!/usr/bin/env bats
# Tests for resource validation and auto-scaling in lib/common.sh:
#   mps_validate_resources, _mps_compute_resources

load ../test_helper

# ================================================================
# mps_validate_resources
# ================================================================

@test "mps_validate_resources: accepts valid resources" {
    mps_validate_resources "4" "8G" "50G"
}

@test "mps_validate_resources: accepts GiB suffix" {
    mps_validate_resources "4" "8GiB" "50GiB"
}

@test "mps_validate_resources: accepts megabyte memory" {
    mps_validate_resources "2" "512M" "20G"
}

@test "mps_validate_resources: accepts MiB suffix" {
    mps_validate_resources "2" "512MiB" "20GiB"
}

@test "mps_validate_resources: accepts empty values (optional)" {
    mps_validate_resources "" "" ""
}

@test "mps_validate_resources: rejects non-numeric cpus" {
    run mps_validate_resources "abc" "" ""
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Invalid vCPU count"* ]]
}

@test "mps_validate_resources: rejects zero cpus" {
    run mps_validate_resources "0" "" ""
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"at least 1"* ]]
}

@test "mps_validate_resources: rejects invalid memory format" {
    run mps_validate_resources "" "abc" ""
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Invalid memory"* ]]
}

@test "mps_validate_resources: rejects memory below 512M" {
    run mps_validate_resources "" "256M" ""
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"at least 512M"* ]]
}

@test "mps_validate_resources: rejects invalid disk format" {
    run mps_validate_resources "" "" "abc"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Invalid disk"* ]]
}

@test "mps_validate_resources: rejects disk below 1G" {
    run mps_validate_resources "" "" "512M"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"at least 1G"* ]]
}

@test "mps_validate_resources: accepts lowercase units" {
    mps_validate_resources "2" "2g" "20g"
}

@test "mps_validate_resources: accepts GB/MB suffixes" {
    mps_validate_resources "4" "8GB" "50GB"
}

@test "mps_validate_resources: accepts K/KB/KiB suffixes" {
    mps_validate_resources "2" "524288K" "10485760KB"
}

@test "mps_validate_resources: accepts B suffix" {
    mps_validate_resources "2" "536870912B" "1073741824B"
}

@test "mps_validate_resources: accepts bare number (bytes)" {
    mps_validate_resources "2" "536870912" "1073741824"
}

# ================================================================
# _mps_compute_resources
# ================================================================

@test "_mps_compute_resources: skips when both MPS_CPUS and MPS_MEMORY set" {
    export MPS_CPUS=4
    export MPS_MEMORY=8G
    _mps_compute_resources
    # Should remain unchanged
    [[ "$MPS_CPUS" == "4" ]]
    [[ "$MPS_MEMORY" == "8G" ]]
}

@test "_mps_compute_resources: computes CPUs from fraction" {
    unset MPS_CPUS
    export MPS_MEMORY=2G
    export MPS_CPUS_FRACTION_NUM=1
    export MPS_CPUS_FRACTION_DEN=4
    export MPS_CPUS_MIN=1
    _mps_compute_resources
    # On any machine with >= 4 cores, this should be at least 1
    [[ -n "$MPS_CPUS" ]]
    [[ "$MPS_CPUS" -ge 1 ]]
}

@test "_mps_compute_resources: enforces CPU minimum" {
    unset MPS_CPUS
    export MPS_MEMORY=2G
    # Fraction that would yield 0 on most machines: 1/1000
    export MPS_CPUS_FRACTION_NUM=1
    export MPS_CPUS_FRACTION_DEN=1000
    export MPS_CPUS_MIN=2
    _mps_compute_resources
    [[ "$MPS_CPUS" -ge 2 ]]
}

@test "_mps_compute_resources: enforces minimum of 1 CPU" {
    unset MPS_CPUS
    export MPS_MEMORY=2G
    export MPS_CPUS_FRACTION_NUM=1
    export MPS_CPUS_FRACTION_DEN=10000
    unset MPS_CPUS_MIN
    _mps_compute_resources
    [[ "$MPS_CPUS" -ge 1 ]]
}

@test "_mps_compute_resources: formats memory as G when evenly divisible" {
    export MPS_CPUS=2
    unset MPS_MEMORY
    export MPS_MEMORY_FRACTION_NUM=1
    export MPS_MEMORY_FRACTION_DEN=1
    export MPS_MEMORY_MIN=1G
    export MPS_MEMORY_CAP=2G
    _mps_compute_resources
    # Cap is 2G, so result should be "2G" (not "2048M")
    [[ "$MPS_MEMORY" == "2G" ]]
}

@test "_mps_compute_resources: applies memory cap" {
    export MPS_CPUS=2
    unset MPS_MEMORY
    export MPS_MEMORY_FRACTION_NUM=1
    export MPS_MEMORY_FRACTION_DEN=1
    unset MPS_MEMORY_MIN
    export MPS_MEMORY_CAP=4G
    _mps_compute_resources
    local mem_mb
    mem_mb="$(_mps_parse_size_mb "$MPS_MEMORY")"
    [[ "$mem_mb" -le 4096 ]]
}

@test "_mps_compute_resources: applies memory minimum" {
    export MPS_CPUS=2
    unset MPS_MEMORY
    export MPS_MEMORY_FRACTION_NUM=1
    export MPS_MEMORY_FRACTION_DEN=10000
    export MPS_MEMORY_MIN=2G
    unset MPS_MEMORY_CAP
    _mps_compute_resources
    local mem_mb
    mem_mb="$(_mps_parse_size_mb "$MPS_MEMORY")"
    [[ "$mem_mb" -ge 2048 ]]
}

@test "_mps_compute_resources: memory below 1024 MB formats as NM" {
    # Unset pre-existing values so _mps_compute_resources actually runs
    unset MPS_CPUS MPS_MEMORY 2>/dev/null || true
    # Set up fraction so that 2048 * 1 / 6 = 341 MB (< 1024)
    export MPS_CPUS_FRACTION_NUM=1
    export MPS_CPUS_FRACTION_DEN=4
    export MPS_CPUS_MIN=1
    export MPS_MEMORY_FRACTION_NUM=1
    export MPS_MEMORY_FRACTION_DEN=6
    export MPS_MEMORY_MIN="256M"
    export MPS_MEMORY_CAP="512M"

    # Override /proc/meminfo by making host_memory_mb small
    # _mps_compute_resources reads /proc/meminfo directly, so we need to work around it.
    # We can't easily stub /proc/meminfo, but we can set a small enough cap
    # that the result is < 1024 regardless of host memory.
    # With cap=512M, computed_mem_mb will be capped at 512 → formats as "512M"
    _mps_compute_resources
    [[ "$MPS_MEMORY" =~ ^[0-9]+M$ ]]
    # Verify it's a reasonable value (should be capped at 512)
    local mem_num="${MPS_MEMORY%M}"
    [[ "$mem_num" -le 512 ]]
    [[ "$mem_num" -ge 256 ]]
}

@test "_mps_compute_resources: memory exactly 1024 MB formats as 1G" {
    unset MPS_CPUS MPS_MEMORY 2>/dev/null || true
    export MPS_CPUS_FRACTION_NUM=1
    export MPS_CPUS_FRACTION_DEN=4
    export MPS_CPUS_MIN=1
    export MPS_MEMORY_FRACTION_NUM=1
    export MPS_MEMORY_FRACTION_DEN=6
    export MPS_MEMORY_MIN="1G"
    export MPS_MEMORY_CAP="1G"
    # Both min and cap are 1G (1024 MB), so result will be exactly 1024 MB → "1G"
    _mps_compute_resources
    [[ "$MPS_MEMORY" == "1G" ]]
}
