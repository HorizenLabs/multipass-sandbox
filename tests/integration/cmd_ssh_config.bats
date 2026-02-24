#!/usr/bin/env bats
# Integration tests for command orchestration: cmd_ssh_config.
#
# Uses real ssh-keygen (from openssh-client) for keypair generation.
# Multipass exec/transfer handled by stub (mktemp pattern + generic exec).

load ../test_helper

# ================================================================
# Shared setup / teardown
# ================================================================

setup() {
    setup_home_override
    mkdir -p "$HOME/.mps/instances" "$HOME/.mps/cache/images" "$HOME/.ssh/config.d"
    setup_multipass_stub
    # shellcheck source=../../lib/multipass.sh
    source "${MPS_ROOT}/lib/multipass.sh"
    export TEST_TEMP_DIR
    ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" -q
    setup_integration_stubs
    source_commands
}
teardown() { teardown_home_override; }

# ================================================================
# _ssh_config_resolve_pubkey
# ================================================================

@test "ssh-config resolve_pubkey: auto-detects ~/.ssh/id_ed25519.pub" {
    run _ssh_config_resolve_pubkey ""
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"id_ed25519.pub"* ]]
}

@test "ssh-config resolve_pubkey: prefers ed25519 over rsa" {
    # Create RSA key alongside existing ed25519
    ssh-keygen -t rsa -b 2048 -f "$HOME/.ssh/id_rsa" -N "" -q
    run _ssh_config_resolve_pubkey ""
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"id_ed25519.pub"* ]]
    [[ "$output" != *"id_rsa.pub"* ]]
}

@test "ssh-config resolve_pubkey: explicit --ssh-key path (private key, derives .pub)" {
    local custom_key="${TEST_TEMP_DIR}/custom_key"
    ssh-keygen -t ed25519 -f "$custom_key" -N "" -q
    run _ssh_config_resolve_pubkey "$custom_key"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"custom_key.pub"* ]]
}

@test "ssh-config resolve_pubkey: missing key dies with message" {
    rm -f "$HOME/.ssh"/id_*.pub "$HOME/.ssh"/id_*
    run _ssh_config_resolve_pubkey ""
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"No SSH key found"* ]]
}

@test "ssh-config resolve_pubkey: explicit .pub path works directly" {
    run _ssh_config_resolve_pubkey "$HOME/.ssh/id_ed25519.pub"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"id_ed25519.pub"* ]]
}

# ================================================================
# _ssh_config_inject_key
# ================================================================

@test "ssh-config inject_key: calls exec mktemp, transfer, exec bash -c" {
    _ssh_config_inject_key "mps-fixture-primary" "fixture-primary" \
        "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ed25519"
    log="$(cat "$MOCK_MP_CALL_LOG")"
    # Should call mktemp
    [[ "$log" == *"exec mps-fixture-primary"*"mktemp"* ]]
    # Should call transfer
    [[ "$log" == *"transfer"* ]]
    # Should call exec bash -c for authorized_keys
    [[ "$log" == *"exec mps-fixture-primary"*"bash -c"* ]]
}

@test "ssh-config inject_key: updates instance metadata with ssh fields" {
    local meta="${HOME}/.mps/instances/fixture-primary.json"
    echo '{"name":"fixture-primary","full_name":"mps-fixture-primary"}' > "$meta"

    _ssh_config_inject_key "mps-fixture-primary" "fixture-primary" \
        "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ed25519"

    local injected
    injected="$(jq -r '.ssh.injected' "$meta")"
    [[ "$injected" == "true" ]]
    local key
    key="$(jq -r '.ssh.key' "$meta")"
    [[ "$key" == *"id_ed25519"* ]]
}

@test "ssh-config inject_key: skips if already injected" {
    local meta="${HOME}/.mps/instances/fixture-primary.json"
    printf '{"name":"fixture-primary","full_name":"mps-fixture-primary","ssh":{"injected":true,"key":"%s"}}\n' \
        "$HOME/.ssh/id_ed25519" > "$meta"

    : > "$MOCK_MP_CALL_LOG"
    _ssh_config_inject_key "mps-fixture-primary" "fixture-primary" \
        "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ed25519"

    log="$(cat "$MOCK_MP_CALL_LOG")"
    # Should NOT have called transfer (key already injected)
    [[ "$log" != *"transfer"* ]]
}

# ================================================================
# cmd_ssh_config
# ================================================================

@test "cmd_ssh_config: prints SSH config block with Host, HostName, User, IdentityFile" {
    run cmd_ssh_config --name fixture-primary
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Host fixture-primary"* ]]
    [[ "$output" == *"HostName 10.179.45.118"* ]]
    [[ "$output" == *"User ubuntu"* ]]
    [[ "$output" == *"IdentityFile"* ]]
    [[ "$output" == *"id_ed25519"* ]]
    [[ "$output" == *"StrictHostKeyChecking accept-new"* ]]
}

@test "cmd_ssh_config --append: writes config file to ~/.ssh/config.d/" {
    run cmd_ssh_config --append --name fixture-primary
    [[ "$status" -eq 0 ]]
    [[ -f "${HOME}/.ssh/config.d/mps-fixture-primary" ]]
    local config
    config="$(cat "${HOME}/.ssh/config.d/mps-fixture-primary")"
    [[ "$config" == *"Host fixture-primary"* ]]
    [[ "$config" == *"HostName 10.179.45.118"* ]]
}

@test "cmd_ssh_config --print --append: does both" {
    run cmd_ssh_config --print --append --name fixture-primary
    [[ "$status" -eq 0 ]]
    # Stdout should contain config block
    [[ "$output" == *"Host fixture-primary"* ]]
    # File should also be written
    [[ -f "${HOME}/.ssh/config.d/mps-fixture-primary" ]]
}

@test "cmd_ssh_config --append: config file has 600 permissions" {
    run cmd_ssh_config --append --name fixture-primary
    [[ "$status" -eq 0 ]]
    local perms
    perms="$(stat -c '%a' "${HOME}/.ssh/config.d/mps-fixture-primary" 2>/dev/null || stat -f '%Lp' "${HOME}/.ssh/config.d/mps-fixture-primary" 2>/dev/null)"
    [[ "$perms" == "600" ]]
}

@test "cmd_ssh_config: dies if instance not running" {
    export MOCK_MP_FIXTURES_DIR="${MPS_ROOT}/tests/fixtures/multipass/all-stopped"
    run cmd_ssh_config --name fixture-primary
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"not running"* ]]
}
