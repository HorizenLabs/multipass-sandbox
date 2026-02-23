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
    setup_temp_dir

    export REAL_HOME="$HOME"
    export HOME="${TEST_TEMP_DIR}/fakehome"
    mkdir -p "$HOME/.mps/instances" "$HOME/.mps/cache/images"

    # Put stub ahead of any real multipass on PATH
    export PATH="${MPS_ROOT}/tests/stubs:${PATH}"

    # Default fixture scenario: running-mounted
    export MOCK_MP_FIXTURES_DIR="${MPS_ROOT}/tests/fixtures/multipass/running-mounted"

    # Call log for argument assertions
    export MOCK_MP_CALL_LOG="${TEST_TEMP_DIR}/call.log"
    : > "$MOCK_MP_CALL_LOG"

    # ---- Stub functions (network, SSH, interactive) ----
    mps_resolve_image()            { echo "file://${HOME}/.mps/cache/images/base/1.0.0/amd64.img"; }
    mps_auto_forward_ports()       { :; }
    mps_forward_port()             { :; }
    mps_reset_port_forwards()      { :; }
    mps_kill_port_forwards()       { :; }
    mps_cleanup_port_sockets()     { :; }
    mps_confirm()                  { return 0; }
    mps_check_image_requirements() { :; }
    _mps_fetch_manifest()          { return 1; }
    _mps_warn_image_staleness()    { :; }
    _mps_warn_instance_staleness() { :; }
    _mps_check_instance_staleness(){ echo "up-to-date"; }

    export -f mps_resolve_image mps_auto_forward_ports mps_forward_port
    export -f mps_reset_port_forwards mps_kill_port_forwards
    export -f mps_cleanup_port_sockets mps_confirm mps_check_image_requirements
    export -f _mps_fetch_manifest _mps_warn_image_staleness
    export -f _mps_warn_instance_staleness _mps_check_instance_staleness

    # Source multipass.sh then command files
    # shellcheck source=../../lib/multipass.sh
    source "${MPS_ROOT}/lib/multipass.sh"
    local f
    for f in "${MPS_ROOT}"/commands/*.sh; do
        # shellcheck disable=SC1090
        source "$f"
    done
}

teardown() {
    export HOME="$REAL_HOME"
    teardown_temp_dir
}

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

@test "cmd_status: shows image status from _mps_check_instance_staleness" {
    run cmd_status --name fixture-primary
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"up-to-date"* ]]
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
