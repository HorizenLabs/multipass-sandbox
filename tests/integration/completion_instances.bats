#!/usr/bin/env bats
# Integration tests for __complete instances path in bin/mps.
#
# The __complete early-exit path (bin/mps:153-157) never sources lib/common.sh,
# so setup is minimal — no function stubs, no HOME/mps/instances, no resource
# pre-sets needed. Tests invoke bin/mps as a subprocess via BATS `run`.

load ../test_helper

# ================================================================
# Shared setup / teardown
# ================================================================

setup() {
    setup_home_override
    setup_multipass_stub
    MPS_BIN="${MPS_ROOT}/bin/mps"
}
teardown() { teardown_home_override; }

# ================================================================
# __complete instances
# ================================================================

@test "__complete instances: returns short names for mps-prefixed instances" {
    run "$MPS_BIN" __complete instances
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"fixture-primary"* ]]
    [[ "$output" == *"fixture-secondary"* ]]
}

@test "__complete instances: excludes non-mps-prefixed instances" {
    run "$MPS_BIN" __complete instances
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"fixture-foreign"* ]]
}

@test "__complete instances: returns one name per line (count = 2)" {
    run "$MPS_BIN" __complete instances
    [[ "$status" -eq 0 ]]
    local count=0
    while IFS= read -r line; do
        [[ -n "$line" ]] && count=$((count + 1))
    done <<< "$output"
    [[ "$count" -eq 2 ]]
}

@test "__complete instances: empty instance list returns empty output" {
    export MOCK_MP_FIXTURES_DIR="${TEST_TEMP_DIR}/empty-fixtures"
    mkdir -p "$MOCK_MP_FIXTURES_DIR"
    echo '{"list":[]}' > "${MOCK_MP_FIXTURES_DIR}/list.json"

    run "$MPS_BIN" __complete instances
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "__complete instances: missing multipass returns graceful empty" {
    # Build a restricted PATH with jq but no multipass
    local restricted="${TEST_TEMP_DIR}/restricted-bin"
    mkdir -p "$restricted"
    ln -s "$(command -v bash)" "$restricted/bash"
    ln -s "$(command -v dirname)" "$restricted/dirname"
    ln -s "$(command -v readlink)" "$restricted/readlink"
    ln -s "$(command -v jq)" "$restricted/jq"
    # env is needed by /usr/bin/env bash shebang
    ln -s "$(command -v env)" "$restricted/env"

    PATH="$restricted" run "$MPS_BIN" __complete instances
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "__complete instances: missing jq returns graceful empty" {
    # Build a restricted PATH with multipass but no jq
    local restricted="${TEST_TEMP_DIR}/restricted-bin"
    mkdir -p "$restricted"
    ln -s "$(command -v bash)" "$restricted/bash"
    ln -s "$(command -v dirname)" "$restricted/dirname"
    ln -s "$(command -v readlink)" "$restricted/readlink"
    ln -s "${MPS_ROOT}/tests/stubs/multipass" "$restricted/multipass"
    ln -s "$(command -v env)" "$restricted/env"

    PATH="$restricted" run "$MPS_BIN" __complete instances
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "__complete instances: custom MPS_INSTANCE_PREFIX" {
    # With MPS_INSTANCE_PREFIX=fixture, the prefix becomes "fixture-"
    # So "fixture-foreign" matches (strip → "foreign") while "mps-fixture-*" don't match
    export MPS_INSTANCE_PREFIX=fixture

    run "$MPS_BIN" __complete instances
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"foreign"* ]]
    # mps-fixture-primary doesn't start with "fixture-", so excluded
    [[ "$output" != *"fixture-primary"* ]]
    [[ "$output" != *"fixture-secondary"* ]]
}

@test "__complete instances: call log contains list --format json" {
    run "$MPS_BIN" __complete instances
    [[ "$status" -eq 0 ]]
    local log
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"list --format json"* ]]
}
