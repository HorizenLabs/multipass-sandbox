#!/usr/bin/env bats
# Integration tests for command orchestration: cmd_list, cmd_status.
#
# Unlike cmd_parsing.bats (which stubs all mp_*/mps_* to isolate parsing),
# these tests let most functions flow through to real code backed by the
# multipass stub + fixture data. Only network, SSH, and interactive functions
# are stubbed.

load ../test_helper

# ================================================================
# Shared setup / teardown
# ================================================================

setup() {
    setup_home_override
    mkdir -p "$HOME/.mps/instances" "$HOME/.mps/cache/images"
    setup_multipass_stub
    # shellcheck source=../../lib/multipass.sh
    source "${MPS_ROOT}/lib/multipass.sh"
    setup_integration_stubs
    source_commands
}
teardown() { teardown_home_override; }

# ================================================================
# cmd_list
# ================================================================

@test "cmd_list: returns formatted table with mps-prefixed instances" {
    run cmd_list
    [[ "$status" -eq 0 ]]
    # Should show short names (prefix stripped)
    [[ "$output" == *"fixture-primary"* ]]
    [[ "$output" == *"fixture-secondary"* ]]
    # Foreign (non-mps) instance should NOT appear
    [[ "$output" != *"fixture-foreign"* ]]
}

@test "cmd_list: shows correct state text (Running, Stopped)" {
    run cmd_list
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Running"* ]]
    [[ "$output" == *"Stopped"* ]]
}

@test "cmd_list: shows IP for running instance" {
    run cmd_list
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"10.179.45.118"* ]]
}

@test "cmd_list: --json returns raw JSON array" {
    run cmd_list --json
    [[ "$status" -eq 0 ]]
    # Should be valid JSON array with mps-prefixed instances
    local count
    count="$(echo "$output" | jq 'length')"
    [[ "$count" -eq 2 ]]
}

@test "cmd_list: handles empty instance list" {
    export MOCK_MP_FIXTURES_DIR="${TEST_TEMP_DIR}/empty-fixtures"
    mkdir -p "$MOCK_MP_FIXTURES_DIR"
    # Create a list.json with no mps-prefixed instances
    echo '{"list":[]}' > "${MOCK_MP_FIXTURES_DIR}/list.json"

    run cmd_list
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"No sandboxes found."* ]]
}

@test "cmd_list: calls mp_list_all (verify via call log)" {
    run cmd_list
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"list --format json"* ]]
}

@test "cmd_list: shows image release column" {
    run cmd_list
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"IMAGE"* ]]
    [[ "$output" == *"Ubuntu 24.04 LTS"* ]]
}

# ================================================================
# cmd_status
# ================================================================

@test "cmd_status: shows detailed info for running instance" {
    run cmd_status --name fixture-primary
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"fixture-primary"* ]]
    [[ "$output" == *"Running"* ]]
    [[ "$output" == *"10.179.45.118"* ]]
    [[ "$output" == *"vCPUs:"* ]]
    [[ "$output" == *"Memory:"* ]]
    [[ "$output" == *"Disk:"* ]]
}

@test "cmd_status: --json returns raw multipass info JSON" {
    run cmd_status --json --name fixture-primary
    [[ "$status" -eq 0 ]]
    # Should be valid JSON with info key
    local state
    state="$(echo "$output" | jq -r '.info["mps-fixture-primary"].state')"
    [[ "$state" == "Running" ]]
}

@test "cmd_status: shows image info with hash prefix" {
    run cmd_status --name fixture-primary
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Image:"* ]]
    [[ "$output" == *"24.04 LTS"* ]]
    # Hash prefix: first 12 chars of 2f9acc20a381...
    [[ "$output" == *"2f9acc20a381"* ]]
}

@test "cmd_status: shows 'up-to-date' for up-to-date instance" {
    _mps_check_instance_staleness() { echo "up-to-date"; }
    export -f _mps_check_instance_staleness
    run cmd_status --name fixture-primary
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Image Status:"* ]]
    [[ "$output" == *"up-to-date"* ]]
}

@test "cmd_status: shows 'stale' for stale instance" {
    _mps_check_instance_staleness() { echo "stale"; }
    export -f _mps_check_instance_staleness
    run cmd_status --name fixture-primary
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Image Status:"* ]]
    [[ "$output" == *"stale (rebuild available)"* ]]
}

@test "cmd_status: shows 'stale:manifest' for manifest-only staleness" {
    _mps_check_instance_staleness() { echo "stale:manifest"; }
    export -f _mps_check_instance_staleness
    run cmd_status --name fixture-primary
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Image Status:"* ]]
    [[ "$output" == *"stale (rebuild available, not yet pulled)"* ]]
}

@test "cmd_status: shows update available with version" {
    _mps_check_instance_staleness() { echo "update:2.0.0"; }
    export -f _mps_check_instance_staleness
    run cmd_status --name fixture-primary
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Image Status:"* ]]
    [[ "$output" == *"update available (2.0.0)"* ]]
}

@test "cmd_status: shows manifest update available with version" {
    _mps_check_instance_staleness() { echo "update:manifest:3.1.0"; }
    export -f _mps_check_instance_staleness
    run cmd_status --name fixture-primary
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Image Status:"* ]]
    [[ "$output" == *"update available (3.1.0, not yet pulled)"* ]]
}

@test "cmd_status: omits Image Status line for unknown staleness" {
    _mps_check_instance_staleness() { echo "unknown"; }
    export -f _mps_check_instance_staleness
    run cmd_status --name fixture-primary
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"Image Status:"* ]]
}

@test "cmd_status: shows mount list with origin annotations" {
    # Create metadata so origin derivation works
    local meta_dir="${HOME}/.mps/instances"
    mkdir -p "$meta_dir"
    cat > "${meta_dir}/fixture-primary.json" <<'METAJSON'
{
    "name": "fixture-primary",
    "full_name": "mps-fixture-primary",
    "workdir": "/mnt/test-a",
    "image": {"name": "base", "version": "1.0.0", "arch": "amd64", "sha256": null, "source": "pulled"}
}
METAJSON

    run cmd_status --name fixture-primary
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Mounts:"* ]]
    # /mnt/test-a matches workdir → auto
    [[ "$output" == *"(auto)"* ]]
    # /mnt/test-b does not match workdir or config → adhoc
    [[ "$output" == *"(adhoc)"* ]]
}

@test "cmd_status: shows docker status when available" {
    export MOCK_MP_DOCKER_VERSION="27.0.3"
    run cmd_status --name fixture-primary
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Docker:"* ]]
    [[ "$output" == *"27.0.3"* ]]
}

@test "cmd_status: skips docker check for stopped instance" {
    export MOCK_MP_FIXTURES_DIR="${MPS_ROOT}/tests/fixtures/multipass/all-stopped"
    run cmd_status --name fixture-primary
    [[ "$status" -eq 0 ]]
    # Docker section should not appear for stopped instances
    [[ "$output" != *"Docker:"* ]]
}

@test "cmd_status: dies if instance does not exist" {
    run cmd_status --name nonexistent-vm
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"does not exist"* ]]
}
