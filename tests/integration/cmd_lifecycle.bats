#!/usr/bin/env bats
# Integration tests for command orchestration: cmd_down, cmd_destroy, cmd_create, cmd_up.
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
    mkdir -p "$HOME/mps/instances" "$HOME/mps/cache/images" "$HOME/.ssh/config.d"
    setup_multipass_stub
    # shellcheck source=../../lib/multipass.sh
    source "${MPS_ROOT}/lib/multipass.sh"

    # Image cache for create tests
    mkdir -p "${HOME}/mps/cache/images/base/1.0.0"
    : > "${HOME}/mps/cache/images/base/1.0.0/amd64.img"
    printf '{"sha256":"abc123def456","build_date":"2025-01-01T00:00:00Z"}\n' \
        > "${HOME}/mps/cache/images/base/1.0.0/amd64.meta.json"

    setup_integration_stubs
    # Override: record port lifecycle calls
    mps_reset_port_forwards()  { echo "$*" > "${TEST_TEMP_DIR}/reset_ports.marker"; }
    mps_kill_port_forwards()   { echo "$*" > "${TEST_TEMP_DIR}/kill_ports.marker"; }
    export -f mps_reset_port_forwards mps_kill_port_forwards
    source_commands
}
teardown() { teardown_home_override; }

# ================================================================
# cmd_down
# ================================================================

@test "cmd_down: stops a Running instance" {
    run cmd_down --name fixture-primary
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"stop mps-fixture-primary"* ]]
}

@test "cmd_down --force: passes --force to mp_stop" {
    run cmd_down --force --name fixture-primary
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"stop mps-fixture-primary --force"* ]]
}

@test "cmd_down: already-Stopped instance returns early without calling stop" {
    export MOCK_MP_FIXTURES_DIR="${MPS_ROOT}/tests/fixtures/multipass/all-stopped"
    run cmd_down --name fixture-primary
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"already stopped"* ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" != *"stop "* ]]
}

@test "cmd_down: dies if instance does not exist" {
    run cmd_down --name nonexistent-vm
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"does not exist"* ]]
}

@test "cmd_down: calls mps_reset_port_forwards with instance name" {
    run cmd_down --name fixture-primary
    [[ "$status" -eq 0 ]]
    [[ -f "${TEST_TEMP_DIR}/reset_ports.marker" ]]
    local marker
    marker="$(cat "${TEST_TEMP_DIR}/reset_ports.marker")"
    [[ "$marker" == *"mps-fixture-primary"* ]]
}

@test "cmd_down: cleans up adhoc mounts, preserves persistent" {
    # Create metadata with workdir = /mnt/test-a (persistent auto-mount)
    cat > "${HOME}/mps/instances/fixture-primary.json" <<'METAJSON'
{
    "name": "fixture-primary",
    "full_name": "mps-fixture-primary",
    "workdir": "/mnt/test-a",
    "image": null
}
METAJSON

    run cmd_down --name fixture-primary
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    # /mnt/test-b is NOT in workdir or MPS_MOUNTS → adhoc → should be unmounted
    [[ "$log" == *"umount mps-fixture-primary:/mnt/test-b"* ]]
    # /mnt/test-a IS the workdir → persistent → should NOT be unmounted
    [[ "$log" != *"umount mps-fixture-primary:/mnt/test-a"* ]]
}

@test "cmd_down: prints success message with short name" {
    run cmd_down --name fixture-primary
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"fixture-primary"* ]]
    [[ "$output" == *"stopped"* ]]
}

# ================================================================
# cmd_destroy
# ================================================================

@test "cmd_destroy: deletes with purge" {
    run cmd_destroy --force --name fixture-primary
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"delete mps-fixture-primary --purge"* ]]
}

@test "cmd_destroy: removes metadata file from state dir" {
    cat > "${HOME}/mps/instances/fixture-primary.json" <<'METAJSON'
{"name": "fixture-primary", "full_name": "mps-fixture-primary"}
METAJSON

    run cmd_destroy --force --name fixture-primary
    [[ "$status" -eq 0 ]]
    [[ ! -f "${HOME}/mps/instances/fixture-primary.json" ]]
}

@test "cmd_destroy: removes ports file from state dir" {
    echo '[]' > "${HOME}/mps/instances/fixture-primary.ports.json"

    run cmd_destroy --force --name fixture-primary
    [[ "$status" -eq 0 ]]
    [[ ! -f "${HOME}/mps/instances/fixture-primary.ports.json" ]]
}

@test "cmd_destroy: removes SSH config file" {
    touch "${HOME}/.ssh/config.d/mps-fixture-primary"

    run cmd_destroy --force --name fixture-primary
    [[ "$status" -eq 0 ]]
    [[ ! -f "${HOME}/.ssh/config.d/mps-fixture-primary" ]]
}

@test "cmd_destroy: dies if instance does not exist" {
    run cmd_destroy --force --name nonexistent-vm
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"does not exist"* ]]
}

@test "cmd_destroy --force: skips confirmation and kills port forwards" {
    run cmd_destroy --force --name fixture-primary
    [[ "$status" -eq 0 ]]
    # Verify kill_port_forwards was called with the instance name
    [[ -f "${TEST_TEMP_DIR}/kill_ports.marker" ]]
    local marker
    marker="$(cat "${TEST_TEMP_DIR}/kill_ports.marker")"
    [[ "$marker" == *"fixture-primary"* ]]
}

@test "cmd_destroy: prints success message with short name" {
    run cmd_destroy --force --name fixture-primary
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"fixture-primary"* ]]
    [[ "$output" == *"destroyed"* ]]
}

# ================================================================
# cmd_create
# ================================================================

@test "cmd_create: happy path launches, waits cloud-init, saves metadata" {
    run cmd_create --name test-create --no-mount
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    # Should call launch
    [[ "$log" == *"launch"* ]]
    # Should wait for cloud-init
    [[ "$log" == *"cloud-init status --wait"* ]]
    # Should save metadata
    [[ -f "${HOME}/mps/instances/test-create.json" ]]
}

@test "cmd_create: call log shows correct launch args" {
    run cmd_create --name test-create --no-mount --cpus 4 --memory 4G --disk 30G
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"launch"* ]]
    [[ "$log" == *"--name mps-test-create"* ]]
    [[ "$log" == *"--cpus 4"* ]]
    [[ "$log" == *"--memory 4G"* ]]
    [[ "$log" == *"--disk 30G"* ]]
}

@test "cmd_create: saves instance metadata JSON" {
    run cmd_create --name test-create --no-mount
    [[ "$status" -eq 0 ]]
    local meta="${HOME}/mps/instances/test-create.json"
    [[ -f "$meta" ]]
    local name
    name="$(jq -r '.name' "$meta")"
    [[ "$name" == "test-create" ]]
    local full
    full="$(jq -r '.full_name' "$meta")"
    [[ "$full" == "mps-test-create" ]]
}

@test "cmd_create --name: uses explicit name in launch call" {
    run cmd_create --name my-explicit-name --no-mount
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"--name mps-my-explicit-name"* ]]
}

@test "cmd_create --no-mount: skips mount args in launch call" {
    run cmd_create --name test-nomount --no-mount
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" != *"--mount"* ]]
}

@test "cmd_create --profile micro: applies profile resources" {
    run cmd_create --name test-profile --no-mount --profile micro
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    # micro profile sets disk=10G
    [[ "$log" == *"--disk 10G"* ]]
}

@test "cmd_create --no-mount without --name: dies with error" {
    # This error path happens inside command substitution where mps_die doesn't
    # propagate from sourced functions. Test via subprocess to catch the exit.
    local MPS_BIN="${MPS_ROOT}/bin/mps"
    export MPS_CHECK_UPDATES=false
    run "$MPS_BIN" create --no-mount
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"--name"* ]] || [[ "$output" == *"--no-mount"* ]]
}

@test "cmd_create: dies if instance already exists" {
    # Use running-mounted fixture where mps-fixture-primary exists
    run cmd_create --name fixture-primary --no-mount
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"already exists"* ]]
}

@test "cmd_create: prints summary with instance info" {
    run cmd_create --name test-summary --no-mount
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Instance:"* ]]
    [[ "$output" == *"test-summary"* ]]
    [[ "$output" == *"Image:"* ]]
    [[ "$output" == *"Profile:"* ]]
    [[ "$output" == *"vCPUs:"* ]]
    [[ "$output" == *"Memory:"* ]]
    [[ "$output" == *"Disk:"* ]]
}

@test "cmd_create: auto-mount includes --mount in launch args" {
    # Use a mount path under fake HOME so validate_mount_source passes
    local mount_dir="${HOME}/test-project"
    mkdir -p "$mount_dir"
    # mps_resolve_mount_source returns physical path (pwd -P)
    local phys_dir
    phys_dir="$(cd "$mount_dir" && pwd -P)"

    run cmd_create --name test-mount "$mount_dir"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"--mount ${phys_dir}:${phys_dir}"* ]]
}

@test "cmd_create: image metadata extraction from sidecar" {
    run cmd_create --name test-meta --no-mount
    [[ "$status" -eq 0 ]]
    local meta="${HOME}/mps/instances/test-meta.json"
    [[ -f "$meta" ]]
    local sha
    sha="$(jq -r '.image.sha256' "$meta")"
    [[ "$sha" == "abc123def456" ]]
    local src
    src="$(jq -r '.image.source' "$meta")"
    [[ "$src" == "pulled" ]]
}

# ================================================================
# cmd_up
# ================================================================

@test "cmd_up: nonexistent instance delegates to cmd_create" {
    run cmd_up --name test-newvm --no-mount
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    # Should call launch (delegated to cmd_create)
    [[ "$log" == *"launch"* ]]
    [[ "$output" == *"does not exist. Creating"* ]]
}

@test "cmd_up: Stopped instance starts it" {
    export MOCK_MP_FIXTURES_DIR="${MPS_ROOT}/tests/fixtures/multipass/all-stopped"
    run cmd_up --name fixture-primary --no-mount
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"start mps-fixture-primary"* ]]
    [[ "$output" == *"stopped"* ]] || [[ "$output" == *"Starting"* ]]
}

@test "cmd_up: Running instance prints info without starting" {
    run cmd_up --name fixture-primary --no-mount
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    # Should NOT have called start
    [[ "$log" != *"start "* ]]
    [[ "$output" == *"already running"* ]]
}

@test "cmd_up: Suspended instance starts it" {
    export MOCK_MP_FIXTURES_DIR="${MPS_ROOT}/tests/fixtures/multipass/suspended"
    run cmd_up --name fixture-primary --no-mount
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"start mps-fixture-primary"* ]]
}

@test "cmd_up: Stopped instance restores auto-mount when missing from VM" {
    # Build a custom stopped fixture with EMPTY mounts so restore logic fires.
    # The real all-stopped fixture has mounts pre-populated, which causes the
    # restore code to skip re-mounting ("already present").
    local custom_dir="${TEST_TEMP_DIR}/stopped-no-mounts"
    mkdir -p "$custom_dir"
    cp "${MPS_ROOT}/tests/fixtures/multipass/all-stopped/list.json" "$custom_dir/"
    cat > "${custom_dir}/info-mps-fixture-primary.json" <<'JSON'
{
    "errors": [],
    "info": {
        "mps-fixture-primary": {
            "state": "Stopped",
            "ipv4": [],
            "image_release": "24.04 LTS",
            "image_hash": "abc123",
            "cpu_count": "",
            "memory": {},
            "disks": {"sda1": {}},
            "mounts": {},
            "release": "",
            "load": [],
            "snapshot_count": "0"
        }
    }
}
JSON
    export MOCK_MP_FIXTURES_DIR="$custom_dir"

    # Create metadata with a workdir so restore knows what to re-mount
    cat > "${HOME}/mps/instances/fixture-primary.json" <<'METAJSON'
{
    "name": "fixture-primary",
    "full_name": "mps-fixture-primary",
    "workdir": "/mnt/test-a",
    "image": {"name": "base", "version": "1.0.0", "arch": "amd64", "sha256": null, "source": "pulled"}
}
METAJSON

    # Provide arg_path matching the workdir so mps_resolve_mount succeeds.
    # Use the fakehome as the source (must be a real directory).
    local mount_src="${HOME}/project"
    mkdir -p "$mount_src"

    run cmd_up "$mount_src" --name fixture-primary
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    # Should have started the instance
    [[ "$log" == *"start mps-fixture-primary"* ]]
    # Should have called mount to restore the auto-mount (was missing from VM mounts)
    [[ "$log" == *"mount"* ]]
    [[ "$log" == *"mps-fixture-primary"* ]]
}

@test "cmd_up: Running instance shows IP in output" {
    run cmd_up --name fixture-primary --no-mount
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"IP:"* ]]
    [[ "$output" == *"10.179.45.118"* ]]
}

@test "cmd_up: shows instance name in output" {
    run cmd_up --name fixture-primary --no-mount
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Instance:"* ]]
    [[ "$output" == *"fixture-primary"* ]]
}

@test "cmd_up: unexpected state dies with error" {
    export MOCK_MP_FIXTURES_DIR="${MPS_ROOT}/tests/fixtures/multipass/synthetic"
    # synthetic fixture has mps-fixture-primary as Running, but we need
    # a custom fixture with unknown state. Use info-unknown.json.
    # The synthetic list has fixture-primary as Running — override with
    # a custom info file that has an unexpected state.
    local custom_dir="${TEST_TEMP_DIR}/custom-fixtures"
    mkdir -p "$custom_dir"
    cp "${MPS_ROOT}/tests/fixtures/multipass/running-mounted/list.json" "$custom_dir/"
    # Create info file with unexpected state
    cat > "${custom_dir}/info-mps-fixture-primary.json" <<'JSON'
{
    "errors": [],
    "info": {
        "mps-fixture-primary": {
            "state": "Deleted",
            "ipv4": [],
            "image_release": "24.04 LTS",
            "image_hash": "abc123",
            "cpu_count": "",
            "memory": {},
            "disks": {"sda1": {}},
            "mounts": {},
            "release": "",
            "load": [],
            "snapshot_count": "0"
        }
    }
}
JSON
    export MOCK_MP_FIXTURES_DIR="$custom_dir"

    run cmd_up --name fixture-primary --no-mount
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"unexpected state"* ]]
}

# ================================================================
# Mount validation: outside $HOME rejected before multipass call
# ================================================================

@test "cmd_create: path outside HOME dies before calling multipass launch" {
    local outside_dir="/tmp/mps-test-outside-home-$$"
    mkdir -p "$outside_dir"

    run cmd_create --name test-outside "$outside_dir"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"within your home directory"* ]]
    # Verify multipass was never called
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" != *"launch"* ]]

    rmdir "$outside_dir" 2>/dev/null || true
}

@test "cmd_up: path outside HOME dies before calling multipass" {
    local outside_dir="/tmp/mps-test-outside-home-$$"
    mkdir -p "$outside_dir"

    run cmd_up --name test-outside "$outside_dir"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"within your home directory"* ]]
    # Verify multipass was never called (no launch, no start)
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" != *"launch"* ]]
    [[ "$log" != *"start"* ]]

    rmdir "$outside_dir" 2>/dev/null || true
}
