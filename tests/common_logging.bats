#!/usr/bin/env bats
# Tests for logging functions in lib/common.sh:
#   mps_log_info, mps_log_warn, mps_log_error, mps_log_debug, mps_die

load test_helper

# ================================================================
# mps_log_info
# ================================================================

@test "mps_log_info: outputs to stderr with [mps] prefix" {
    run mps_log_info "hello world"
    # 'run' captures both stdout+stderr for the exit code check
    # The log functions write to stderr; BATS 'run' merges them
    [[ "$output" == *"[mps]"* ]]
    [[ "$output" == *"hello world"* ]]
}

# ================================================================
# mps_log_warn
# ================================================================

@test "mps_log_warn: outputs with [mps WARN] prefix" {
    run mps_log_warn "danger"
    [[ "$output" == *"[mps WARN]"* ]]
    [[ "$output" == *"danger"* ]]
}

# ================================================================
# mps_log_error
# ================================================================

@test "mps_log_error: outputs with [mps ERROR] prefix" {
    run mps_log_error "something broke"
    [[ "$output" == *"[mps ERROR]"* ]]
    [[ "$output" == *"something broke"* ]]
}

# ================================================================
# mps_log_debug
# ================================================================

@test "mps_log_debug: silent when MPS_DEBUG is not true" {
    MPS_DEBUG=false run mps_log_debug "hidden message"
    [[ -z "$output" ]]
}

@test "mps_log_debug: outputs when MPS_DEBUG=true" {
    MPS_DEBUG=true run mps_log_debug "debug message"
    [[ "$output" == *"[mps DEBUG]"* ]]
    [[ "$output" == *"debug message"* ]]
}

@test "mps_log_debug: silent when MPS_DEBUG is unset" {
    unset MPS_DEBUG
    run mps_log_debug "hidden"
    [[ -z "$output" ]]
}

# ================================================================
# mps_die
# ================================================================

@test "mps_die: exits with non-zero status" {
    run mps_die "fatal error"
    [[ "$status" -ne 0 ]]
}

@test "mps_die: outputs error message" {
    run mps_die "fatal error"
    [[ "$output" == *"[mps ERROR]"* ]]
    [[ "$output" == *"fatal error"* ]]
}
