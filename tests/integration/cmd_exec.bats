#!/usr/bin/env bats
# Integration tests for command orchestration: cmd_shell, cmd_exec, cmd_transfer, cmd_mount.
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
    setup_cmd_integration
    export TEST_TEMP_DIR
}
teardown() { teardown_home_override; }

# ================================================================
# cmd_shell
# ================================================================

@test "cmd_shell: calls mp_shell with correct instance name" {
    run cmd_shell --name fixture-primary
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"shell mps-fixture-primary"* ]] || [[ "$log" == *"exec mps-fixture-primary"* ]]
}

@test "cmd_shell --workdir: passes workdir" {
    run cmd_shell --name fixture-primary --workdir /tmp/mydir
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    # mp_shell with workdir uses exec + bash -c cd
    [[ "$log" == *"exec mps-fixture-primary"* ]]
    [[ "$log" == *"/tmp/mydir"* ]]
}

@test "cmd_shell: uses metadata workdir when no --workdir flag" {
    # Create metadata with workdir
    cat > "${HOME}/mps/instances/fixture-primary.json" <<'METAJSON'
{
    "name": "fixture-primary",
    "full_name": "mps-fixture-primary",
    "workdir": "/home/ubuntu/project",
    "image": null
}
METAJSON

    run cmd_shell --name fixture-primary
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"/home/ubuntu/project"* ]]
}

@test "cmd_shell: dies if instance does not exist" {
    run cmd_shell --name nonexistent-vm
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"does not exist"* ]]
}

@test "cmd_shell: dies if instance not running" {
    export MOCK_MP_FIXTURES_DIR="${MPS_ROOT}/tests/fixtures/multipass/all-stopped"
    run cmd_shell --name fixture-primary
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"not running"* ]]
}

# ================================================================
# cmd_exec
# ================================================================

@test "cmd_exec: executes command with -- separator" {
    export MOCK_MP_EXEC_OUTPUT="hello world"
    run cmd_exec --name fixture-primary -- echo hello
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"exec mps-fixture-primary"* ]]
    [[ "$log" == *"-- echo hello"* ]]
}

@test "cmd_exec --workdir: passes working directory" {
    run cmd_exec --name fixture-primary --workdir /tmp -- ls
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"--working-directory /tmp"* ]]
}

@test "cmd_exec: uses metadata workdir when no --workdir" {
    cat > "${HOME}/mps/instances/fixture-primary.json" <<'METAJSON'
{
    "name": "fixture-primary",
    "full_name": "mps-fixture-primary",
    "workdir": "/home/ubuntu/project",
    "image": null
}
METAJSON

    run cmd_exec --name fixture-primary -- pwd
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"--working-directory /home/ubuntu/project"* ]]
}

@test "cmd_exec: forwards exit code from command" {
    export MOCK_MP_EXEC_EXIT=42
    run cmd_exec --name fixture-primary -- false
    [[ "$status" -eq 42 ]]
}

@test "cmd_exec: dies if instance not running" {
    export MOCK_MP_FIXTURES_DIR="${MPS_ROOT}/tests/fixtures/multipass/all-stopped"
    run cmd_exec --name fixture-primary -- ls
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"not running"* ]]
}

# ================================================================
# cmd_transfer
# ================================================================

@test "cmd_transfer: host-to-guest resolves paths" {
    local src="${TEST_TEMP_DIR}/testfile.txt"
    echo "test data" > "$src"

    run cmd_transfer --name fixture-primary -- "$src" :/tmp/testfile.txt
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"transfer"* ]]
    [[ "$log" == *"mps-fixture-primary:/tmp/testfile.txt"* ]]
}

@test "cmd_transfer: guest-to-host resolves :path prefix" {
    run cmd_transfer --name fixture-primary -- :/tmp/remote.txt "${TEST_TEMP_DIR}/local.txt"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"transfer"* ]]
    [[ "$log" == *"mps-fixture-primary:/tmp/remote.txt"* ]]
}

@test "cmd_transfer: dies for stopped instance" {
    export MOCK_MP_FIXTURES_DIR="${MPS_ROOT}/tests/fixtures/multipass/all-stopped"
    run cmd_transfer --name fixture-primary -- /tmp/a :/tmp/b
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"not running"* ]]
}

@test "cmd_transfer: prints transfer direction message" {
    local src="${TEST_TEMP_DIR}/testfile.txt"
    echo "test data" > "$src"

    run cmd_transfer --name fixture-primary -- "$src" :/tmp/testfile.txt
    [[ "$status" -eq 0 ]]
    # Host-to-guest message: "Transferring N path(s) host -> <short_name>..."
    [[ "$output" == *"host -> fixture-primary"* ]]
}

@test "cmd_transfer: calls mps_prepare_running_instance" {
    local src="${TEST_TEMP_DIR}/testfile.txt"
    echo "test data" > "$src"

    run cmd_transfer --name fixture-primary -- "$src" :/tmp/testfile.txt
    [[ "$status" -eq 0 ]]
    # mps_prepare_running_instance calls mps_require_running + auto_forward_ports
    # If we got here without error, it was called and passed
    log="$(cat "$MOCK_MP_CALL_LOG")"
    # The info call confirms state check happened
    [[ "$log" == *"info mps-fixture-primary"* ]]
}

# ================================================================
# cmd_mount
# ================================================================

@test "cmd_mount list: shows mounts with origin annotations" {
    # Create metadata with workdir for origin derivation
    cat > "${HOME}/mps/instances/fixture-primary.json" <<'METAJSON'
{
    "name": "fixture-primary",
    "full_name": "mps-fixture-primary",
    "workdir": "/mnt/test-a",
    "image": null
}
METAJSON

    run cmd_mount list --name fixture-primary
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"SOURCE"* ]]
    [[ "$output" == *"TARGET"* ]]
    [[ "$output" == *"ORIGIN"* ]]
    [[ "$output" == *"auto"* ]]
    [[ "$output" == *"adhoc"* ]]
}

@test "cmd_mount list: 'No mounts.' for unmounted instance" {
    export MOCK_MP_FIXTURES_DIR="${MPS_ROOT}/tests/fixtures/multipass/running-mounted"
    # Use secondary which has empty mounts
    run cmd_mount list --name fixture-secondary
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"No mounts."* ]]
}

@test "cmd_mount add: calls mp_mount with correct args" {
    local mount_src="${HOME}/test-mount-src"
    mkdir -p "$mount_src"

    run cmd_mount add "${mount_src}:/mnt/new-mount" --name fixture-primary
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"mount ${mount_src} mps-fixture-primary:/mnt/new-mount"* ]]
}

@test "cmd_mount add: already-mounted path returns early with info message" {
    local mount_src="${HOME}/test-mount-src"
    mkdir -p "$mount_src"

    # /mnt/test-a is already mounted per fixture
    run cmd_mount add "${mount_src}:/mnt/test-a" --name fixture-primary
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"already present"* ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    # Should NOT have called mount (beyond info)
    [[ "$log" != *"mount ${mount_src}"* ]]
}

@test "cmd_mount remove: calls mp_umount" {
    run cmd_mount remove /mnt/test-a --name fixture-primary
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"umount mps-fixture-primary:/mnt/test-a"* ]]
}

@test "cmd_mount remove: dies if mount does not exist" {
    run cmd_mount remove /mnt/nonexistent --name fixture-primary
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"No mount found"* ]]
}

@test "cmd_mount add: unknown option dies" {
    run cmd_mount add --bogus
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown option"* ]]
}

@test "cmd_mount add: nonexistent source dies" {
    run cmd_mount add "no-such-dir-12345:/mnt/target" --name fixture-primary
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"does not exist"* ]]
}

@test "cmd_mount remove: unknown option dies" {
    run cmd_mount remove --bogus
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown option"* ]]
}

@test "cmd_mount list: unknown option dies" {
    run cmd_mount list --bogus
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown option"* ]]
}

@test "cmd_mount remove: persistent mount warns about persistence" {
    # Create metadata with workdir for origin derivation
    cat > "${HOME}/mps/instances/fixture-primary.json" <<'METAJSON'
{
    "name": "fixture-primary",
    "full_name": "mps-fixture-primary",
    "workdir": "/mnt/test-a",
    "image": null
}
METAJSON

    # /mnt/test-a is auto-mount (workdir) → persistent
    run cmd_mount remove /mnt/test-a --name fixture-primary
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"persistent"* ]]
}

@test "cmd_mount list: shows 'config' origin for MPS_MOUNTS entries" {
    cat > "${HOME}/mps/instances/fixture-primary.json" <<'METAJSON'
{
    "name": "fixture-primary",
    "full_name": "mps-fixture-primary",
    "workdir": "/mnt/test-a",
    "image": null
}
METAJSON

    export MPS_MOUNTS="/some/host/path:/mnt/test-b"

    run cmd_mount list --name fixture-primary
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"auto"* ]]
    [[ "$output" == *"config"* ]]
}
