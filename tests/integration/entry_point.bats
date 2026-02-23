#!/usr/bin/env bats
# Integration tests for bin/mps main() dispatch as a subprocess.
#
# These tests go through the full bin/mps path — lib/common.sh IS sourced,
# mps_load_config IS called. Must handle:
#   - MPS_CHECK_UPDATES=false to prevent network access
#   - MPS_CPUS=2 / MPS_MEMORY=2G (inherited from test_helper) to skip hw detection
#   - Multipass stub on PATH for mps_check_deps

load ../test_helper

# ================================================================
# Shared setup / teardown
# ================================================================

setup() {
    setup_temp_dir

    export REAL_HOME="$HOME"
    export HOME="${TEST_TEMP_DIR}/fakehome"
    mkdir -p "$HOME/.mps/instances" "$HOME/.mps/cache/images"

    # Put multipass stub on PATH
    export PATH="${MPS_ROOT}/tests/stubs:${PATH}"

    # Default fixture scenario
    export MOCK_MP_FIXTURES_DIR="${MPS_ROOT}/tests/fixtures/multipass/running-mounted"

    # Call log
    export MOCK_MP_CALL_LOG="${TEST_TEMP_DIR}/call.log"
    : > "$MOCK_MP_CALL_LOG"

    # Prevent network access for CLI update check
    export MPS_CHECK_UPDATES=false

    MPS_BIN="${MPS_ROOT}/bin/mps"
}

teardown() {
    export HOME="$REAL_HOME"
    teardown_temp_dir
}

# ================================================================
# --help / --version
# ================================================================

@test "entry point: --help shows usage and commands" {
    run "$MPS_BIN" --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"Commands:"* ]]
}

@test "entry point: -h shows usage" {
    run "$MPS_BIN" -h
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Usage:"* ]]
}

@test "entry point: --version shows mps version with VERSION file content" {
    local expected_version
    expected_version="$(cat "${MPS_ROOT}/VERSION")"
    expected_version="${expected_version%$'\n'}"

    run "$MPS_BIN" --version
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mps version"* ]]
    [[ "$output" == *"${expected_version}"* ]]
}

@test "entry point: -v shows mps version" {
    run "$MPS_BIN" -v
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mps version"* ]]
}

# ================================================================
# No args
# ================================================================

@test "entry point: no args exits 1 with usage" {
    run "$MPS_BIN"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Usage:"* ]]
}

# ================================================================
# --debug
# ================================================================

@test "entry point: --debug enables debug logging on stderr" {
    local stderr_file="${TEST_TEMP_DIR}/stderr.log"
    # Run with stderr redirected to file; stdout captured by run
    run bash -c "\"$MPS_BIN\" --debug list 2>\"$stderr_file\""
    [[ "$status" -eq 0 ]]
    local stderr_content
    stderr_content="$(cat "$stderr_file")"
    [[ "$stderr_content" == *"[mps DEBUG]"* ]]
}

# ================================================================
# Command validation (reject invalid names)
# ================================================================

@test "entry point: path traversal rejected" {
    run "$MPS_BIN" ../etc
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Usage:"* ]]
}

@test "entry point: uppercase command rejected" {
    run "$MPS_BIN" Create
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Usage:"* ]]
}

@test "entry point: dot-prefix command rejected" {
    run "$MPS_BIN" .hidden
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Usage:"* ]]
}

@test "entry point: unknown valid-format command exits 1 with usage" {
    run "$MPS_BIN" nonexistent-cmd
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Usage:"* ]]
}

# ================================================================
# Command-specific --help (dispatch to command, skip deps)
# ================================================================

@test "entry point: command-specific --help shows command usage" {
    run "$MPS_BIN" list --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"--json"* ]]
}
