#!/usr/bin/env bats
# Integration tests for port forwarding pipeline:
#   mps_forward_port, mps_auto_forward_ports,
#   mps_kill_port_forwards, mps_reset_port_forwards
#
# Uses SSH/sudo stubs on PATH (no real SSH server).
# Multipass stub provides fixture data for instance IP resolution.

load ../test_helper

# ================================================================
# Shared setup / teardown
# ================================================================

setup() {
    setup_home_override
    mkdir -p "$HOME/.mps/instances" "$HOME/.mps/cache/images" "$HOME/.mps/sockets"
    setup_multipass_stub
    setup_ssh_stub
    # shellcheck source=../../lib/multipass.sh
    source "${MPS_ROOT}/lib/multipass.sh"
    export TEST_TEMP_DIR

    # Stub only non-port functions (image, staleness, confirm)
    mps_resolve_image()            { echo "file://${HOME}/.mps/cache/images/base/1.0.0/amd64.img"; }
    mps_confirm()                  { return 0; }
    mps_check_image_requirements() { :; }
    _mps_fetch_manifest()          { return 1; }
    _mps_warn_image_staleness()    { :; }
    _mps_warn_instance_staleness() { :; }
    _mps_check_instance_staleness(){ echo "up-to-date"; }
    export -f mps_resolve_image mps_confirm mps_check_image_requirements
    export -f _mps_fetch_manifest _mps_warn_image_staleness
    export -f _mps_warn_instance_staleness _mps_check_instance_staleness

    # Seed instance metadata with SSH key for fixture-primary
    _TEST_SSH_KEY="${HOME}/.ssh/id_ed25519"
    mkdir -p "$HOME/.ssh"
    touch "$_TEST_SSH_KEY"
    chmod 600 "$_TEST_SSH_KEY"

    local meta="${HOME}/.mps/instances/fixture-primary.json"
    cat > "$meta" <<EOF
{
    "name": "fixture-primary",
    "full_name": "mps-fixture-primary",
    "ssh": {"injected": true, "key": "${_TEST_SSH_KEY}"},
    "port_forwards": [],
    "workdir": null
}
EOF

    source_commands
}

teardown() { teardown_home_override; }

# ================================================================
# Group 1: mps_forward_port — Validation (8 tests)
# ================================================================

@test "forward_port: rejects empty port spec component" {
    run mps_forward_port "mps-fixture-primary" "fixture-primary" ":80" ""
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Invalid port spec"* ]]
}

@test "forward_port: rejects non-numeric ports" {
    run mps_forward_port "mps-fixture-primary" "fixture-primary" "abc:80" ""
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"must be numbers"* ]]
}

@test "forward_port: rejects port 0" {
    run mps_forward_port "mps-fixture-primary" "fixture-primary" "0:80" ""
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"1-65535"* ]]
}

@test "forward_port: rejects port above 65535" {
    run mps_forward_port "mps-fixture-primary" "fixture-primary" "70000:80" ""
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"1-65535"* ]]
}

@test "forward_port: rejects privileged port without --privileged" {
    run mps_forward_port "mps-fixture-primary" "fixture-primary" "80:80" ""
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"privileged port"* ]]
}

@test "forward_port: returns 1 when instance has no IP" {
    mp_ipv4() { echo ""; }
    export -f mp_ipv4
    run mps_forward_port "mps-fixture-primary" "fixture-primary" "8080:80" ""
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Cannot determine IP"* ]]
}

@test "forward_port: returns 1 when SSH not configured (no metadata)" {
    local meta="${HOME}/.mps/instances/fixture-primary.json"
    cat > "$meta" <<'JSON'
{"name": "fixture-primary", "full_name": "mps-fixture-primary"}
JSON
    run mps_forward_port "mps-fixture-primary" "fixture-primary" "8080:80" ""
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"SSH not configured"* ]]
}

@test "forward_port: returns 1 when SSH key file missing" {
    rm -f "$_TEST_SSH_KEY"
    run mps_forward_port "mps-fixture-primary" "fixture-primary" "8080:80" ""
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"SSH not configured"* ]]
}

# ================================================================
# Group 2: mps_forward_port — Happy Path & Dedup (6 tests)
# ================================================================

@test "forward_port: establishes tunnel successfully" {
    run mps_forward_port "mps-fixture-primary" "fixture-primary" "8080:80" ""
    [[ "$status" -eq 0 ]]
    # Verify SSH call log contains master mode tunnel creation
    log="$(cat "$MOCK_SSH_CALL_LOG")"
    [[ "$log" == *"-M -S"* ]]
    [[ "$log" == *"-N -f -L 8080:localhost:80"* ]]
    # Verify socket file was created
    local sock
    sock="$(mps_port_socket "fixture-primary" "8080")"
    [[ -e "$sock" ]]
}

@test "forward_port: records tunnel in .ports.json" {
    mps_forward_port "mps-fixture-primary" "fixture-primary" "8080:80" ""
    local pf
    pf="$(mps_ports_file "fixture-primary")"
    [[ -f "$pf" ]]
    local guest_port
    guest_port="$(jq -r '.["8080"].guest_port' "$pf")"
    [[ "$guest_port" == "80" ]]
    local sudo_val
    sudo_val="$(jq -r '.["8080"].sudo' "$pf")"
    [[ "$sudo_val" == "false" ]]
    local sock_val
    sock_val="$(jq -r '.["8080"].socket' "$pf")"
    [[ -n "$sock_val" ]]
    [[ "$sock_val" != "null" ]]
}

@test "forward_port: returns 2 for already-active tunnel" {
    # Pre-create a socket that the stub will find alive
    local sock
    sock="$(mps_port_socket "fixture-primary" "8080")"
    touch "$sock"
    run mps_forward_port "mps-fixture-primary" "fixture-primary" "8080:80" ""
    [[ "$status" -eq 2 ]]
    # Call log should show only check, no -M
    log="$(cat "$MOCK_SSH_CALL_LOG")"
    [[ "$log" == *"-O check"* ]]
    [[ "$log" != *"-M -S"* ]]
}

@test "forward_port: removes stale socket and re-establishes" {
    # Pre-create a socket file but mark it as stale
    local sock
    sock="$(mps_port_socket "fixture-primary" "8080")"
    touch "$sock"
    export MOCK_SSH_STALE_SOCKETS="$sock"
    run mps_forward_port "mps-fixture-primary" "fixture-primary" "8080:80" ""
    [[ "$status" -eq 0 ]]
    # Call log should show check (fail) then master creation
    log="$(cat "$MOCK_SSH_CALL_LOG")"
    [[ "$log" == *"-O check"* ]]
    [[ "$log" == *"-M -S"* ]]
}

@test "forward_port: uses sudo for privileged port with --privileged" {
    run mps_forward_port "mps-fixture-primary" "fixture-primary" "80:80" "--privileged"
    [[ "$status" -eq 0 ]]
    # Call log should show sudo ssh -M (sudo stub passes through to ssh stub)
    log="$(cat "$MOCK_SSH_CALL_LOG")"
    [[ "$log" == *"-M -S"* ]]
    # .ports.json should record sudo: true
    local pf
    pf="$(mps_ports_file "fixture-primary")"
    local sudo_val
    sudo_val="$(jq -r '.["80"].sudo' "$pf")"
    [[ "$sudo_val" == "true" ]]
}

@test "forward_port: passes correct SSH options" {
    mps_forward_port "mps-fixture-primary" "fixture-primary" "8080:80" ""
    log="$(cat "$MOCK_SSH_CALL_LOG")"
    [[ "$log" == *"-o StrictHostKeyChecking=accept-new"* ]]
    [[ "$log" == *"-o UserKnownHostsFile=/dev/null"* ]]
    [[ "$log" == *"-o LogLevel=ERROR"* ]]
    [[ "$log" == *"-i ${_TEST_SSH_KEY}"* ]]
    [[ "$log" == *"ubuntu@10.179.45.118"* ]]
}

# ================================================================
# Group 3: mps_forward_port — Failure Paths (3 tests)
# ================================================================

@test "forward_port: returns 1 when SSH tunnel command fails" {
    export MOCK_SSH_TUNNEL_EXIT=1
    run mps_forward_port "mps-fixture-primary" "fixture-primary" "8080:80" ""
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Failed to forward"* ]]
}

@test "forward_port: returns 0 but warns when post-verify fails" {
    export MOCK_SSH_TUNNEL_NO_SOCKET=true
    run mps_forward_port "mps-fixture-primary" "fixture-primary" "8080:80" ""
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"control socket check failed"* ]]
    # No .ports.json entry should exist
    local pf
    pf="$(mps_ports_file "fixture-primary")"
    if [[ -f "$pf" ]]; then
        local entry
        entry="$(jq -r '.["8080"] // empty' "$pf")"
        [[ -z "$entry" ]]
    fi
}

@test "forward_port: appends to existing .ports.json" {
    # Pre-populate with port 3000
    local pf
    pf="$(mps_ports_file "fixture-primary")"
    cat > "$pf" <<'JSON'
{"3000": {"guest_port": 3000, "socket": "/tmp/existing.sock", "sudo": false}}
JSON
    chmod 600 "$pf"

    mps_forward_port "mps-fixture-primary" "fixture-primary" "8080:80" ""

    # Both ports should be present
    local count
    count="$(jq 'length' "$pf")"
    [[ "$count" -eq 2 ]]
    [[ "$(jq -r '.["3000"].guest_port' "$pf")" == "3000" ]]
    [[ "$(jq -r '.["8080"].guest_port' "$pf")" == "80" ]]
}

# ================================================================
# Group 4: mps_auto_forward_ports (6 tests)
# ================================================================

@test "auto_forward_ports: returns 0 silently when no ports configured" {
    unset MPS_PORTS 2>/dev/null || true
    run mps_auto_forward_ports "mps-fixture-primary" "fixture-primary"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "auto_forward_ports: forwards all ports from MPS_PORTS" {
    export MPS_PORTS="3000:3000 8080:80"
    run mps_auto_forward_ports "mps-fixture-primary" "fixture-primary"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_SSH_CALL_LOG")"
    [[ "$log" == *"3000:localhost:3000"* ]]
    [[ "$log" == *"8080:localhost:80"* ]]
    # Both should be in .ports.json
    local pf
    pf="$(mps_ports_file "fixture-primary")"
    [[ "$(jq -r '.["3000"].guest_port' "$pf")" == "3000" ]]
    [[ "$(jq -r '.["8080"].guest_port' "$pf")" == "80" ]]
}

@test "auto_forward_ports: logs count with default verb" {
    export MPS_PORTS="3000:3000 8080:80"
    run mps_auto_forward_ports "mps-fixture-primary" "fixture-primary"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Forwarded 2 port forward(s)"* ]]
}

@test "auto_forward_ports: skips already-active without counting" {
    export MPS_PORTS="3000:3000 8080:80"
    # Pre-create socket for 3000 so it gets dedup-skipped (rc=2)
    local sock
    sock="$(mps_port_socket "fixture-primary" "3000")"
    touch "$sock"
    run mps_auto_forward_ports "mps-fixture-primary" "fixture-primary"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Forwarded 1 port forward(s)"* ]]
}

@test "auto_forward_ports: continues past errors without dying" {
    export MPS_PORTS="abc:def 8080:80"
    run mps_auto_forward_ports "mps-fixture-primary" "fixture-primary"
    [[ "$status" -eq 0 ]]
    # Should warn about the invalid spec
    [[ "$output" == *"must be numbers"* ]]
    # Should still forward the valid one
    [[ "$output" == *"Forwarded 1 port forward(s)"* ]]
}

@test "auto_forward_ports: uses custom verb" {
    export MPS_PORTS="8080:80"
    run mps_auto_forward_ports "mps-fixture-primary" "fixture-primary" "Re-established"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Re-established 1 port forward(s)"* ]]
}

# ================================================================
# Group 5: mps_kill_port_forwards (5 tests)
# ================================================================

@test "kill_port_forwards: returns 0 silently when no .ports file" {
    run mps_kill_port_forwards "fixture-primary"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "kill_port_forwards: sends -O exit to each tracked socket" {
    # Create ports file with two entries
    local pf
    pf="$(mps_ports_file "fixture-primary")"
    local sock1 sock2
    sock1="$(mps_port_socket "fixture-primary" "3000")"
    sock2="$(mps_port_socket "fixture-primary" "8080")"
    touch "$sock1" "$sock2"
    cat > "$pf" <<EOF
{
    "3000": {"guest_port": 3000, "socket": "${sock1}", "sudo": false},
    "8080": {"guest_port": 80, "socket": "${sock2}", "sudo": false}
}
EOF
    chmod 600 "$pf"

    mps_kill_port_forwards "fixture-primary"
    log="$(cat "$MOCK_SSH_CALL_LOG")"
    [[ "$log" == *"-O exit -S ${sock1}"* ]]
    [[ "$log" == *"-O exit -S ${sock2}"* ]]
}

@test "kill_port_forwards: removes socket files after exit" {
    local pf
    pf="$(mps_ports_file "fixture-primary")"
    local sock1
    sock1="$(mps_port_socket "fixture-primary" "3000")"
    touch "$sock1"
    cat > "$pf" <<EOF
{"3000": {"guest_port": 3000, "socket": "${sock1}", "sudo": false}}
EOF
    chmod 600 "$pf"

    mps_kill_port_forwards "fixture-primary"
    [[ ! -e "$sock1" ]]
}

@test "kill_port_forwards: uses sudo for entries with sudo true" {
    local pf
    pf="$(mps_ports_file "fixture-primary")"
    local sock1
    sock1="$(mps_port_socket "fixture-primary" "80")"
    touch "$sock1"
    cat > "$pf" <<EOF
{"80": {"guest_port": 80, "socket": "${sock1}", "sudo": true}}
EOF
    chmod 600 "$pf"

    mps_kill_port_forwards "fixture-primary"
    log="$(cat "$MOCK_SSH_CALL_LOG")"
    # The sudo stub strips sudo and calls ssh, so we see the ssh call
    # but the actual code path invoked "sudo ssh -n -O exit ..."
    [[ "$log" == *"-O exit -S ${sock1}"* ]]
}

@test "kill_port_forwards: skips entries with null socket" {
    local pf
    pf="$(mps_ports_file "fixture-primary")"
    cat > "$pf" <<'JSON'
{"3000": {"guest_port": 3000, "socket": null, "sudo": false}}
JSON
    chmod 600 "$pf"

    run mps_kill_port_forwards "fixture-primary"
    [[ "$status" -eq 0 ]]
    # No SSH calls should have been made
    log="$(cat "$MOCK_SSH_CALL_LOG")"
    [[ -z "$log" ]]
}

# ================================================================
# Group 6: mps_reset_port_forwards (5 tests)
# ================================================================

@test "reset_port_forwards: kills, removes ports file, cleans sockets" {
    local pf
    pf="$(mps_ports_file "fixture-primary")"
    local sock1
    sock1="$(mps_port_socket "fixture-primary" "3000")"
    touch "$sock1"
    cat > "$pf" <<EOF
{"3000": {"guest_port": 3000, "socket": "${sock1}", "sudo": false}}
EOF
    chmod 600 "$pf"

    mps_reset_port_forwards "mps-fixture-primary" "fixture-primary"
    # Ports file should be removed
    [[ ! -f "$pf" ]]
    # Socket should be cleaned up
    [[ ! -e "$sock1" ]]
    # SSH exit command should have been sent
    log="$(cat "$MOCK_SSH_CALL_LOG")"
    [[ "$log" == *"-O exit"* ]]
}

@test "reset_port_forwards: without --auto-forward does not re-establish" {
    local pf
    pf="$(mps_ports_file "fixture-primary")"
    local sock1
    sock1="$(mps_port_socket "fixture-primary" "3000")"
    touch "$sock1"
    cat > "$pf" <<EOF
{"3000": {"guest_port": 3000, "socket": "${sock1}", "sudo": false}}
EOF
    chmod 600 "$pf"

    export MPS_PORTS="8080:80"
    mps_reset_port_forwards "mps-fixture-primary" "fixture-primary"
    log="$(cat "$MOCK_SSH_CALL_LOG")"
    # Should have exit commands but no -M (no re-establishment)
    [[ "$log" == *"-O exit"* ]]
    [[ "$log" != *"-M -S"* ]]
}

@test "reset_port_forwards: with --auto-forward re-establishes from config" {
    local pf
    pf="$(mps_ports_file "fixture-primary")"
    local sock1
    sock1="$(mps_port_socket "fixture-primary" "3000")"
    touch "$sock1"
    cat > "$pf" <<EOF
{"3000": {"guest_port": 3000, "socket": "${sock1}", "sudo": false}}
EOF
    chmod 600 "$pf"

    export MPS_PORTS="8080:80"
    mps_reset_port_forwards "mps-fixture-primary" "fixture-primary" "--auto-forward"
    log="$(cat "$MOCK_SSH_CALL_LOG")"
    # Should have both exit commands and new tunnel creation
    [[ "$log" == *"-O exit"* ]]
    [[ "$log" == *"-M -S"* ]]
    [[ "$log" == *"8080:localhost:80"* ]]
    # New ports file should exist with 8080
    [[ -f "$pf" ]]
    [[ "$(jq -r '.["8080"].guest_port' "$pf")" == "80" ]]
}

@test "reset_port_forwards: handles missing ports file gracefully" {
    run mps_reset_port_forwards "mps-fixture-primary" "fixture-primary"
    [[ "$status" -eq 0 ]]
}

@test "reset_port_forwards: full cycle — old ports killed, new ports established" {
    # Set up old port forwards
    local pf
    pf="$(mps_ports_file "fixture-primary")"
    local old_sock
    old_sock="$(mps_port_socket "fixture-primary" "3000")"
    touch "$old_sock"
    cat > "$pf" <<EOF
{"3000": {"guest_port": 3000, "socket": "${old_sock}", "sudo": false}}
EOF
    chmod 600 "$pf"

    # Configure new ports
    export MPS_PORTS="8080:80 9090:9090"
    mps_reset_port_forwards "mps-fixture-primary" "fixture-primary" "--auto-forward"

    # Old socket should be cleaned
    [[ ! -e "$old_sock" ]]
    # New .ports.json should have only the new ports
    [[ -f "$pf" ]]
    [[ "$(jq 'has("3000")' "$pf")" == "false" ]]
    [[ "$(jq -r '.["8080"].guest_port' "$pf")" == "80" ]]
    [[ "$(jq -r '.["9090"].guest_port' "$pf")" == "9090" ]]
}
