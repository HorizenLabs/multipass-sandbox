#!/usr/bin/env bats
# Integration tests for command orchestration: cmd_port (forward/list).
#
# These tests let most functions flow through to real code backed by the
# multipass stub + fixture data. Network/SSH functions are stubbed.

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

    export TEST_TEMP_DIR

    # ---- Stub functions (network, SSH, interactive) ----
    mps_resolve_image()            { echo "file://${HOME}/.mps/cache/images/base/1.0.0/amd64.img"; }
    mps_confirm()                  { return 0; }
    mps_check_image_requirements() { :; }
    _mps_fetch_manifest()          { return 1; }
    _mps_warn_image_staleness()    { :; }
    _mps_warn_instance_staleness() { :; }
    _mps_check_instance_staleness(){ echo "up-to-date"; }

    # Stub mps_forward_port — record call, return configurable exit code
    _STUB_FORWARD_PORT_RC=0
    mps_forward_port() {
        echo "mps_forward_port $*" >> "${TEST_TEMP_DIR}/forward_port.log"
        return "${_STUB_FORWARD_PORT_RC}"
    }
    mps_auto_forward_ports()       { :; }
    mps_reset_port_forwards()      { :; }
    mps_kill_port_forwards()       { :; }
    mps_cleanup_port_sockets()     { :; }

    export -f mps_resolve_image mps_confirm mps_check_image_requirements
    export -f _mps_fetch_manifest _mps_warn_image_staleness
    export -f _mps_warn_instance_staleness _mps_check_instance_staleness
    export -f mps_forward_port mps_auto_forward_ports
    export -f mps_reset_port_forwards mps_kill_port_forwards
    export -f mps_cleanup_port_sockets

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
# _port_forward
# ================================================================

@test "port forward: happy path resolves instance and calls mps_forward_port" {
    run cmd_port forward fixture-primary 3000:3000
    [[ "$status" -eq 0 ]]
    [[ -f "${TEST_TEMP_DIR}/forward_port.log" ]]
    log="$(cat "${TEST_TEMP_DIR}/forward_port.log")"
    [[ "$log" == *"mps-fixture-primary"* ]]
    [[ "$log" == *"3000:3000"* ]]
}

@test "port forward: already-forwarded (rc=2) logs warning, no die" {
    _STUB_FORWARD_PORT_RC=2
    mps_forward_port() {
        echo "mps_forward_port $*" >> "${TEST_TEMP_DIR}/forward_port.log"
        return 2
    }
    export -f mps_forward_port

    run cmd_port forward fixture-primary 3000:3000
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"already forwarded"* ]]
}

@test "port forward: instance not running dies with state message" {
    export MOCK_MP_FIXTURES_DIR="${MPS_ROOT}/tests/fixtures/multipass/all-stopped"
    run cmd_port forward fixture-primary 3000:3000
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"not running"* ]]
}

@test "port forward: nonexistent instance dies" {
    run cmd_port forward nonexistent-vm 3000:3000
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"not running"* ]]
}

@test "port forward: missing port spec dies with usage" {
    run cmd_port forward fixture-primary
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage"* ]]
}

@test "port forward: --privileged flag is passed through" {
    run cmd_port forward --privileged fixture-primary 80:80
    [[ "$status" -eq 0 ]]
    log="$(cat "${TEST_TEMP_DIR}/forward_port.log")"
    [[ "$log" == *"--privileged"* ]]
}

@test "port forward: prints success message with port numbers" {
    run cmd_port forward fixture-primary 8080:80
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"8080"* ]]
    [[ "$output" == *"80"* ]]
}

# ================================================================
# _port_list
# ================================================================

@test "port list: shows header columns" {
    # Create a .ports.json to have something to display
    local state_dir="${HOME}/.mps/instances"
    cat > "${state_dir}/fixture-primary.ports.json" <<'JSON'
{"3000": {"guest_port": 3000, "socket": "/tmp/fake.sock", "sudo": false}}
JSON
    cat > "${state_dir}/fixture-primary.json" <<'JSON'
{"name": "fixture-primary", "full_name": "mps-fixture-primary"}
JSON

    run cmd_port list
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"SANDBOX"* ]]
    [[ "$output" == *"HOST PORT"* ]]
    [[ "$output" == *"GUEST PORT"* ]]
    [[ "$output" == *"STATUS"* ]]
}

@test "port list: shows ports from .ports.json" {
    local state_dir="${HOME}/.mps/instances"
    cat > "${state_dir}/fixture-primary.ports.json" <<'JSON'
{"3000": {"guest_port": 3000, "socket": "/tmp/fake.sock", "sudo": false}}
JSON
    cat > "${state_dir}/fixture-primary.json" <<'JSON'
{"name": "fixture-primary", "full_name": "mps-fixture-primary"}
JSON

    run cmd_port list
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"fixture-primary"* ]]
    [[ "$output" == *"3000"* ]]
}

@test "port list: filters by name" {
    local state_dir="${HOME}/.mps/instances"
    cat > "${state_dir}/fixture-primary.ports.json" <<'JSON'
{"3000": {"guest_port": 3000, "socket": "/tmp/fake-p.sock", "sudo": false}}
JSON
    cat > "${state_dir}/fixture-primary.json" <<'JSON'
{"name": "fixture-primary", "full_name": "mps-fixture-primary"}
JSON
    cat > "${state_dir}/fixture-secondary.ports.json" <<'JSON'
{"4000": {"guest_port": 4000, "socket": "/tmp/fake-s.sock", "sudo": false}}
JSON
    cat > "${state_dir}/fixture-secondary.json" <<'JSON'
{"name": "fixture-secondary", "full_name": "mps-fixture-secondary"}
JSON

    run cmd_port list fixture-primary
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"fixture-primary"* ]]
    [[ "$output" == *"3000"* ]]
    [[ "$output" != *"4000"* ]]
}

@test "port list: no port forwards shows message" {
    run cmd_port list
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"No active port forwards."* ]]
}

@test "port list: dead socket shows dead status" {
    local state_dir="${HOME}/.mps/instances"
    # Socket path points to non-existent file → ssh -O check fails → dead
    cat > "${state_dir}/fixture-primary.ports.json" <<'JSON'
{"3000": {"guest_port": 3000, "socket": "/tmp/nonexistent-socket", "sudo": false}}
JSON
    cat > "${state_dir}/fixture-primary.json" <<'JSON'
{"name": "fixture-primary", "full_name": "mps-fixture-primary"}
JSON

    run cmd_port list
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"dead"* ]]
}

@test "port list: multiple sandboxes are all shown" {
    local state_dir="${HOME}/.mps/instances"
    cat > "${state_dir}/fixture-primary.ports.json" <<'JSON'
{"3000": {"guest_port": 3000, "socket": "/tmp/fake-p.sock", "sudo": false}}
JSON
    cat > "${state_dir}/fixture-primary.json" <<'JSON'
{"name": "fixture-primary", "full_name": "mps-fixture-primary"}
JSON
    cat > "${state_dir}/fixture-secondary.ports.json" <<'JSON'
{"4000": {"guest_port": 4000, "socket": "/tmp/fake-s.sock", "sudo": false}}
JSON
    cat > "${state_dir}/fixture-secondary.json" <<'JSON'
{"name": "fixture-secondary", "full_name": "mps-fixture-secondary"}
JSON

    run cmd_port list
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"fixture-primary"* ]]
    [[ "$output" == *"3000"* ]]
    [[ "$output" == *"fixture-secondary"* ]]
    [[ "$output" == *"4000"* ]]
}

@test "port list: re-establishes dead forwards for running instances" {
    local state_dir="${HOME}/.mps/instances"
    cat > "${state_dir}/fixture-primary.ports.json" <<'JSON'
{"3000": {"guest_port": 3000, "socket": "/tmp/nonexistent.sock", "sudo": false}}
JSON
    cat > "${state_dir}/fixture-primary.json" <<'JSON'
{"name": "fixture-primary", "full_name": "mps-fixture-primary"}
JSON

    # Track mps_auto_forward_ports calls
    mps_auto_forward_ports() {
        echo "auto_forward_ports $*" >> "${TEST_TEMP_DIR}/auto_fwd.log"
    }
    export -f mps_auto_forward_ports

    run cmd_port list
    [[ "$status" -eq 0 ]]
    # auto_forward_ports should have been called for the running instance
    [[ -f "${TEST_TEMP_DIR}/auto_fwd.log" ]]
    log="$(cat "${TEST_TEMP_DIR}/auto_fwd.log")"
    [[ "$log" == *"mps-fixture-primary"* ]]
}

@test "port forward: missing name and port spec dies" {
    run cmd_port forward
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage"* ]]
}
