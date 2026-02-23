#!/usr/bin/env bats
# Tests for resource validation and auto-scaling in lib/common.sh:
#   mps_validate_resources, _mps_compute_resources

load test_helper

# ================================================================
# mps_validate_resources
# ================================================================

@test "mps_validate_resources: accepts valid resources" {
    mps_validate_resources "4" "8G" "50G"
}

@test "mps_validate_resources: accepts megabyte memory" {
    mps_validate_resources "2" "512M" "20G"
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
