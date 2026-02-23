#!/usr/bin/env bats
# Smoke tests for the mock multipass stub and mp_* wrapper functions.
#
# Validates that the stub serves fixture JSON correctly and that
# lib/multipass.sh functions work against it.

load ../test_helper

setup() {
    setup_temp_dir

    export REAL_HOME="$HOME"
    export HOME="${TEST_TEMP_DIR}/fakehome"
    mkdir -p "$HOME"

    # Put stub ahead of any real multipass on PATH
    export PATH="${MPS_ROOT}/tests/stubs:${PATH}"

    # Default fixture scenario
    export MOCK_MP_FIXTURES_DIR="${MPS_ROOT}/tests/fixtures/multipass/running-mounted"

    # Call log for lifecycle assertions
    export MOCK_MP_CALL_LOG="${TEST_TEMP_DIR}/call.log"
    : > "$MOCK_MP_CALL_LOG"

    # Source multipass.sh (provides mp_* functions)
    # shellcheck source=../lib/multipass.sh
    source "${MPS_ROOT}/lib/multipass.sh"
}

teardown() {
    export HOME="$REAL_HOME"
    teardown_temp_dir
}

# ================================================================
# Stub: list
# ================================================================

@test "stub: list --format json returns valid JSON with expected instances" {
    run multipass list --format json
    [[ "$status" -eq 0 ]]
    # Verify it's valid JSON with three instances
    count="$(echo "$output" | jq '.list | length')"
    [[ "$count" -eq 3 ]]
}

@test "stub: list includes mps-fixture-primary" {
    run multipass list --format json
    [[ "$status" -eq 0 ]]
    names="$(echo "$output" | jq -r '.list[].name')"
    [[ "$names" == *"mps-fixture-primary"* ]]
}

# ================================================================
# Stub: info
# ================================================================

@test "stub: info returns JSON for known instance with correct state" {
    run multipass info mps-fixture-primary --format json
    [[ "$status" -eq 0 ]]
    state="$(echo "$output" | jq -r '.info["mps-fixture-primary"].state')"
    [[ "$state" == "Running" ]]
}

@test "stub: info for unknown instance exits 2 with error on stderr" {
    run multipass info nonexistent-vm --format json
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"does not exist"* ]]
}

# ================================================================
# Stub: lifecycle commands + call logging
# ================================================================

@test "stub: lifecycle commands logged to call log with correct arguments" {
    multipass start mps-fixture-primary
    multipass stop mps-fixture-primary --force
    multipass delete mps-fixture-primary --purge
    [[ -f "$MOCK_MP_CALL_LOG" ]]
    run cat "$MOCK_MP_CALL_LOG"
    [[ "$output" == *"start mps-fixture-primary"* ]]
    [[ "$output" == *"stop mps-fixture-primary --force"* ]]
    [[ "$output" == *"delete mps-fixture-primary --purge"* ]]
}

@test "stub: default exit code 0 for lifecycle commands" {
    run multipass start test-vm
    [[ "$status" -eq 0 ]]
    run multipass stop test-vm
    [[ "$status" -eq 0 ]]
    run multipass mount /tmp test-vm:/mnt
    [[ "$status" -eq 0 ]]
}

@test "stub: MOCK_MP_EXIT_CODE overrides default" {
    export MOCK_MP_EXIT_CODE=3
    run multipass start test-vm
    [[ "$status" -eq 3 ]]
    run multipass stop test-vm
    [[ "$status" -eq 3 ]]
}

@test "stub: per-command exit code overrides blanket default" {
    export MOCK_MP_EXIT_CODE=3
    export MOCK_MP_START_EXIT=0
    export MOCK_MP_STOP_EXIT=5
    run multipass start test-vm
    [[ "$status" -eq 0 ]]
    run multipass stop test-vm
    [[ "$status" -eq 5 ]]
}

# ================================================================
# Stub: exec
# ================================================================

@test "stub: exec returns MOCK_MP_EXEC_OUTPUT" {
    export MOCK_MP_EXEC_OUTPUT="hello from mock"
    run multipass exec mps-fixture-primary -- echo test
    [[ "$status" -eq 0 ]]
    [[ "$output" == "hello from mock" ]]
}

@test "stub: exec with docker info returns MOCK_MP_DOCKER_VERSION" {
    export MOCK_MP_DOCKER_VERSION="27.0.3"
    run multipass exec mps-fixture-primary -- docker info --format '{{.ServerVersion}}'
    [[ "$status" -eq 0 ]]
    [[ "$output" == "27.0.3" ]]
}

@test "stub: exec docker info without MOCK_MP_DOCKER_VERSION exits 1" {
    unset MOCK_MP_DOCKER_VERSION 2>/dev/null || true
    run multipass exec mps-fixture-primary -- docker info
    [[ "$status" -eq 1 ]]
}

# ================================================================
# Stub: version
# ================================================================

@test "stub: version returns valid JSON" {
    run multipass version --format json
    [[ "$status" -eq 0 ]]
    echo "$output" | jq -e '.multipass' >/dev/null
}

# ================================================================
# mp_* functions against the stub
# ================================================================

@test "mp_list_all: filters to mps-prefixed instances only" {
    result="$(mp_list_all)"
    count="$(echo "$result" | jq 'length')"
    # Should exclude fixture-foreign (no mps- prefix)
    [[ "$count" -eq 2 ]]
    # Verify the correct ones are included
    names="$(echo "$result" | jq -r '.[].name')"
    [[ "$names" == *"mps-fixture-primary"* ]]
    [[ "$names" == *"mps-fixture-secondary"* ]]
    [[ "$names" != *"fixture-foreign"* ]]
}

@test "mp_state: returns correct state from fixture" {
    result="$(mp_state mps-fixture-primary)"
    [[ "$result" == "Running" ]]
}

@test "mp_state: returns Stopped for secondary" {
    result="$(mp_state mps-fixture-secondary)"
    [[ "$result" == "Stopped" ]]
}

@test "mp_instance_exists: returns 0 for known instance" {
    mp_instance_exists mps-fixture-primary
}

@test "mp_instance_exists: returns 1 for unknown instance" {
    run mp_instance_exists nonexistent-vm-xyz
    [[ "$status" -ne 0 ]]
}

@test "mp_get_mounts: returns mount JSON for mounted instance" {
    result="$(mp_get_mounts mps-fixture-primary)"
    [[ -n "$result" ]]
    # Should have two mount entries
    count="$(echo "$result" | jq 'keys | length')"
    [[ "$count" -eq 2 ]]
    # Verify mount paths
    keys="$(echo "$result" | jq -r 'keys[]')"
    [[ "$keys" == *"/mnt/test-a"* ]]
    [[ "$keys" == *"/mnt/test-b"* ]]
}

@test "mp_get_mounts: returns empty for unmounted instance" {
    result="$(mp_get_mounts mps-fixture-secondary)"
    [[ -z "$result" ]]
}

@test "mp_ipv4: returns IP address for running instance" {
    result="$(mp_ipv4 mps-fixture-primary)"
    [[ -n "$result" ]]
    # Should look like an IP address
    [[ "$result" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}
