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
    setup_cmd_integration
    mkdir -p "$HOME/.ssh/config.d"

    # Image cache for create tests
    mkdir -p "${HOME}/mps/cache/images/base/1.0.0"
    : > "${HOME}/mps/cache/images/base/1.0.0/amd64.img"
    printf '{"sha256":"abc123def456","build_date":"2025-01-01T00:00:00Z"}\n' \
        > "${HOME}/mps/cache/images/base/1.0.0/amd64.meta.json"

    # Override: record port lifecycle calls
    mps_reset_port_forwards()  { echo "$*" > "${TEST_TEMP_DIR}/reset_ports.marker"; }
    mps_kill_port_forwards()   { echo "$*" > "${TEST_TEMP_DIR}/kill_ports.marker"; }
    export -f mps_reset_port_forwards mps_kill_port_forwards
}
teardown() { teardown_home_override; }

# Create a custom multipass fixture with a specific instance state.
# Usage: _mock_fixture_state <instance_short_name> <state> [mounts_json] [ipv4_json]
# Defaults: mounts='{}', ipv4='[]'
_mock_fixture_state() {
    local name="$1" state="$2"
    local mounts="${3:-{}}" ipv4="${4:-[]}"
    local custom_dir="${TEST_TEMP_DIR}/fixture-${name}-${state}"
    mkdir -p "$custom_dir"
    cp "${MPS_ROOT}/tests/fixtures/multipass/running-mounted/list.json" "$custom_dir/"
    cat > "${custom_dir}/info-mps-${name}.json" <<EOF
{
    "errors": [],
    "info": {
        "mps-${name}": {
            "state": "${state}",
            "ipv4": ${ipv4},
            "image_release": "24.04 LTS",
            "image_hash": "abc123",
            "cpu_count": "1",
            "memory": {"total": 474644480, "used": 210464768},
            "disks": {"sda1": {"total": "5116440064", "used": "2143233536"}},
            "mounts": ${mounts},
            "release": "Ubuntu 24.04.4 LTS",
            "load": [0.24, 0.13, 0.05],
            "snapshot_count": "0"
        }
    }
}
EOF
    export MOCK_MP_FIXTURES_DIR="$custom_dir"
}

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

@test "cmd_destroy: confirmation declined aborts without deleting" {
    mps_confirm() { return 1; }
    export -f mps_confirm

    run cmd_destroy --name fixture-primary
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Aborted"* ]]
    # Should NOT have called delete
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" != *"delete"* ]]
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
    _mock_fixture_state "fixture-primary" "Deleted"

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

# ================================================================
# cmd_create: --mount flag (extra mounts)
# ================================================================

@test "cmd_create --mount: extra mount appears in launch args" {
    local mount_src="${HOME}/extra-src"
    mkdir -p "$mount_src"
    local phys_src
    phys_src="$(cd "$mount_src" && pwd -P)"

    run cmd_create --name test-extra-mount --no-mount --mount "${mount_src}:/mnt/extra"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"--mount ${phys_src}:/mnt/extra"* ]]
}

@test "cmd_create --mount: multiple extra mounts all appear in launch args" {
    local src_a="${HOME}/mount-a"
    local src_b="${HOME}/mount-b"
    mkdir -p "$src_a" "$src_b"

    run cmd_create --name test-multi-mount --no-mount \
        --mount "${src_a}:/mnt/a" --mount "${src_b}:/mnt/b"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"--mount"*"/mnt/a"* ]]
    [[ "$log" == *"--mount"*"/mnt/b"* ]]
}

# ================================================================
# cmd_create: --port flag (port forward metadata)
# ================================================================

@test "cmd_create --port: stores port forward rule in metadata" {
    run cmd_create --name test-port --no-mount --port 8080:80
    [[ "$status" -eq 0 ]]
    local meta="${HOME}/mps/instances/test-port.json"
    [[ -f "$meta" ]]
    local pf
    pf="$(jq -r '.port_forwards[0]' "$meta")"
    [[ "$pf" == "8080:80" ]]
}

@test "cmd_create --port: multiple port rules stored in metadata" {
    run cmd_create --name test-ports --no-mount --port 8080:80 --port 9090:90
    [[ "$status" -eq 0 ]]
    local meta="${HOME}/mps/instances/test-ports.json"
    local count
    count="$(jq '.port_forwards | length' "$meta")"
    [[ "$count" -eq 2 ]]
    local first second
    first="$(jq -r '.port_forwards[0]' "$meta")"
    second="$(jq -r '.port_forwards[1]' "$meta")"
    [[ "$first" == "8080:80" ]]
    [[ "$second" == "9090:90" ]]
}

# ================================================================
# cmd_create: --transfer flag (file transfer after create)
# ================================================================

@test "cmd_create --transfer: calls multipass transfer and stores in metadata" {
    local src_file="${HOME}/transfer-test.txt"
    echo "hello" > "$src_file"

    run cmd_create --name test-xfer --no-mount --transfer "${src_file}:/tmp/dest.txt"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"transfer"* ]]
    # Metadata should have the transfer entry
    local meta="${HOME}/mps/instances/test-xfer.json"
    local tf
    tf="$(jq -r '.transfers[0]' "$meta")"
    [[ "$tf" == "${src_file}:/tmp/dest.txt" ]]
}

@test "cmd_create --transfer: prints transfer count in summary" {
    local src_file="${HOME}/xfer-count.txt"
    echo "data" > "$src_file"

    run cmd_create --name test-xfer-count --no-mount --transfer "${src_file}:/tmp/d.txt"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Transferred:"* ]]
    [[ "$output" == *"1 path(s)"* ]]
}

@test "cmd_create --transfer: dies on invalid format (no colon)" {
    local src_file="${HOME}/bad-xfer.txt"
    echo "data" > "$src_file"

    run cmd_create --name test-xfer-bad --no-mount --transfer "${src_file}"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Invalid --transfer format"* ]]
}

@test "cmd_create --transfer: dies on missing source file" {
    run cmd_create --name test-xfer-miss --no-mount --transfer "${HOME}/nonexistent.txt:/tmp/d.txt"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"not found"* ]]
}

# ================================================================
# cmd_create: stock Ubuntu image passthrough
# ================================================================

@test "cmd_create --image stock: metadata source is 'stock' for Ubuntu version" {
    # Override stubs so the stock-image code path fires
    mps_resolve_image() { echo "24.04"; }
    _mps_is_mps_image() { return 1; }
    export -f mps_resolve_image _mps_is_mps_image

    run cmd_create --name test-stock --no-mount --image 24.04
    [[ "$status" -eq 0 ]]
    local meta="${HOME}/mps/instances/test-stock.json"
    [[ -f "$meta" ]]
    local src
    src="$(jq -r '.image.source' "$meta")"
    [[ "$src" == "stock" ]]
    local img_name
    img_name="$(jq -r '.image.name' "$meta")"
    [[ "$img_name" == "24.04" ]]
}

# ================================================================
# cmd_up: staleness checks with real functions
# ================================================================

@test "cmd_up: staleness checks run for Running instance with metadata" {
    # Un-stub staleness functions and use markers to verify they run
    _mps_warn_image_staleness() {
        echo "image-staleness-called" > "${TEST_TEMP_DIR}/staleness_image.marker"
    }
    _mps_warn_instance_staleness() {
        echo "instance-staleness-called:$*" > "${TEST_TEMP_DIR}/staleness_instance.marker"
    }
    export -f _mps_warn_image_staleness _mps_warn_instance_staleness

    # Create metadata with image info so staleness checks have data to work with
    cat > "${HOME}/mps/instances/fixture-primary.json" <<'METAJSON'
{
    "name": "fixture-primary",
    "full_name": "mps-fixture-primary",
    "workdir": null,
    "image": {"name": "base", "version": "1.0.0", "arch": "amd64", "sha256": "abc123def456", "source": "pulled"}
}
METAJSON

    run cmd_up --name fixture-primary --no-mount
    [[ "$status" -eq 0 ]]
    # Image staleness should have been called (image file exists from setup)
    [[ -f "${TEST_TEMP_DIR}/staleness_image.marker" ]]
    # Instance staleness should have been called with --skip-manifest
    [[ -f "${TEST_TEMP_DIR}/staleness_instance.marker" ]]
    local marker
    marker="$(cat "${TEST_TEMP_DIR}/staleness_instance.marker")"
    [[ "$marker" == *"--skip-manifest"* ]]
}

# ================================================================
# cmd_down: unexpected state handling
# ================================================================

@test "cmd_down: dies with error for unexpected state (Starting)" {
    _mock_fixture_state "fixture-primary" "Starting"

    run cmd_down --name fixture-primary
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"unexpected state"* ]]
}

# ================================================================
# cmd_down: empty mount info during cleanup
# ================================================================

@test "cmd_down: cleanup adhoc mounts returns immediately when mount info is empty" {
    _mock_fixture_state "fixture-primary" "Running" '{}' '["10.179.45.118"]'

    run cmd_down --name fixture-primary
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    # Should have called stop but NOT umount (no mounts to clean up)
    [[ "$log" == *"stop mps-fixture-primary"* ]]
    [[ "$log" != *"umount"* ]]
}

# ================================================================
# cmd_up: flag parsing (skip and shift for known/unknown flags)
# ================================================================

@test "cmd_up: --image flag is skipped (shift 2) without error" {
    # --image is a known flag that up doesn't handle directly — shift 2
    # Instance already exists as Running, so it should report "already running"
    run cmd_up --image base --name fixture-primary --no-mount
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"already running"* ]]
}

@test "cmd_up: --profile flag is skipped (shift 2) without error" {
    run cmd_up --profile lite --name fixture-primary --no-mount
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"already running"* ]]
}

@test "cmd_up: unknown -* flag is skipped (shift 1) without error" {
    # Unknown flags with no value get shift 1
    run cmd_up --unknown-flag --name fixture-primary --no-mount
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"already running"* ]]
}

# ================================================================
# cmd_create: --transfer with relative host path
# ================================================================

@test "cmd_create --transfer: resolves relative host path to absolute" {
    # Create a file in the project directory (simulated by HOME)
    local project_dir="${HOME}/test-project"
    mkdir -p "$project_dir"
    echo "content" > "${project_dir}/rel-file.txt"

    # Set MPS_PROJECT_DIR so relative path resolution uses it
    export MPS_PROJECT_DIR="$project_dir"

    run cmd_create --name test-xfer-rel --no-mount --transfer "rel-file.txt:/tmp/rel-file.txt"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    # The transfer call should use the absolute resolved path
    [[ "$log" == *"transfer"* ]]
    [[ "$log" == *"${project_dir}/rel-file.txt"* ]]
    # Summary should show the transfer count
    [[ "$output" == *"Transferred:"* ]]
    [[ "$output" == *"1 path(s)"* ]]
}

@test "cmd_up: Stopped instance restores config mounts from MPS_MOUNTS" {
    # Build stopped fixture with empty mounts
    local custom_dir="${TEST_TEMP_DIR}/stopped-cfg-mounts"
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

    # Create the config mount source directory
    local cfg_src="${HOME}/extra-lib"
    mkdir -p "$cfg_src"
    local phys_cfg_src
    phys_cfg_src="$(cd "$cfg_src" && pwd -P)"

    # Set MPS_MOUNTS so config mount restoration fires
    export MPS_MOUNTS="${cfg_src}:/mnt/extra-lib"

    # Metadata with a different workdir so config mount isn't skipped as duplicate
    cat > "${HOME}/mps/instances/fixture-primary.json" <<METAJSON
{
    "name": "fixture-primary",
    "full_name": "mps-fixture-primary",
    "workdir": "${HOME}/project",
    "image": {"name": "base", "version": "1.0.0", "arch": "amd64", "sha256": null, "source": "pulled"}
}
METAJSON

    # Provide mount source for auto-mount too
    mkdir -p "${HOME}/project"

    run cmd_up "${HOME}/project" --name fixture-primary
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    # Should have started the instance
    [[ "$log" == *"start mps-fixture-primary"* ]]
    # Should have called mount for the config mount
    [[ "$log" == *"mount ${phys_cfg_src} mps-fixture-primary:/mnt/extra-lib"* ]]
}

# ================================================================
# cmd_create: --cloud-init flag
# ================================================================

@test "cmd_create --cloud-init: passes cloud-init file to launch" {
    echo "#cloud-config" > "${TEST_TEMP_DIR}/ci.yaml"

    run cmd_create --name test-ci --no-mount --cloud-init "${TEST_TEMP_DIR}/ci.yaml"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"launch"* ]]
    [[ "$log" == *"--cloud-init ${TEST_TEMP_DIR}/ci.yaml"* ]]
}

@test "_complete_create flag-values --cloud-init: returns __cloud_init__" {
    run _complete_create flag-values --cloud-init
    [[ "$status" -eq 0 ]]
    [[ "$output" == "__cloud_init__" ]]
}

# ================================================================
# cmd_up: --cloud-init delegation to create
# ================================================================

@test "cmd_up --cloud-init: delegates to create with cloud-init for nonexistent instance" {
    echo "#cloud-config" > "${TEST_TEMP_DIR}/ci.yaml"

    run cmd_up --cloud-init "${TEST_TEMP_DIR}/ci.yaml" --name test-ci-up --no-mount
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    # Should delegate to create (launch)
    [[ "$log" == *"launch"* ]]
    [[ "$log" == *"--cloud-init ${TEST_TEMP_DIR}/ci.yaml"* ]]
    [[ "$output" == *"does not exist. Creating"* ]]
}

@test "_complete_up flag-values --cloud-init: returns __cloud_init__" {
    run _complete_up flag-values --cloud-init
    [[ "$status" -eq 0 ]]
    [[ "$output" == "__cloud_init__" ]]
}

# ================================================================
# cmd_create: MPS_MOUNTS config mounts
# ================================================================

@test "cmd_create: MPS_MOUNTS adds config mounts to launch args" {
    local cfg_src="${HOME}/config-mount-src"
    mkdir -p "$cfg_src"
    local phys_cfg_src
    phys_cfg_src="$(cd "$cfg_src" && pwd -P)"

    export MPS_MOUNTS="${cfg_src}:/mnt/test"

    run cmd_create --name test-cfgmount --no-mount
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"--mount ${phys_cfg_src}:/mnt/test"* ]]
}

# ================================================================
# cmd_create / cmd_up: port count display in summary
# ================================================================

@test "cmd_create: shows port forward count in summary when ports are active" {
    # Create a ports file so mps_port_forward_count returns > 0
    echo '[{"host_port":"3000","guest_port":"3000"}]' \
        > "${HOME}/mps/instances/test-portdisplay.ports.json"

    run cmd_create --name test-portdisplay --no-mount
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Ports:"* ]]
    [[ "$output" == *"forwarded"* ]]
}

@test "cmd_up: shows port forward count in summary when ports are active" {
    # Create a ports file for fixture-primary
    echo '[{"host_port":"3000","guest_port":"3000"}]' \
        > "${HOME}/mps/instances/fixture-primary.ports.json"

    run cmd_up --name fixture-primary --no-mount
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Ports:"* ]]
    [[ "$output" == *"forwarded"* ]]
}

# ================================================================
# cmd_up: auto-mount already present (debug log, no re-mount)
# ================================================================

@test "cmd_up: Running instance with auto-mount already present skips remount" {
    # The default running-mounted fixture already has mounts.
    # Build a custom fixture where the mount target matches MPS_MOUNT_TARGET.
    local mount_dir="${HOME}/project"
    mkdir -p "$mount_dir"
    local phys_dir
    phys_dir="$(cd "$mount_dir" && pwd -P)"

    # Custom stopped fixture with mount already present at the auto-mount target
    local custom_dir="${TEST_TEMP_DIR}/stopped-mount-present"
    mkdir -p "$custom_dir"
    cp "${MPS_ROOT}/tests/fixtures/multipass/all-stopped/list.json" "$custom_dir/"
    cat > "${custom_dir}/info-mps-fixture-primary.json" <<JSON
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
            "mounts": {
                "${phys_dir}": {
                    "gid_mappings": ["1000:default"],
                    "source_path": "${phys_dir}",
                    "uid_mappings": ["1000:default"]
                }
            },
            "release": "",
            "load": [],
            "snapshot_count": "0"
        }
    }
}
JSON
    export MOCK_MP_FIXTURES_DIR="$custom_dir"

    # Create metadata so up knows the workdir
    cat > "${HOME}/mps/instances/fixture-primary.json" <<METAJSON
{
    "name": "fixture-primary",
    "full_name": "mps-fixture-primary",
    "workdir": "${phys_dir}",
    "image": {"name": "base", "version": "1.0.0", "arch": "amd64", "sha256": null, "source": "pulled"}
}
METAJSON

    run cmd_up "$mount_dir" --name fixture-primary
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    # Should have started, but NOT called mount (already present)
    [[ "$log" == *"start mps-fixture-primary"* ]]
    # Count mount calls — should only be the info calls, not an explicit mount
    local mount_count
    mount_count="$(grep -c "^multipass mount " "$MOCK_MP_CALL_LOG" || true)"
    [[ "$mount_count" -eq 0 ]]
}

# ================================================================
# _status_human_bytes: small-value branches
# ================================================================

@test "_status_human_bytes: KiB range formats correctly" {
    run _status_human_bytes 500000
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"KiB"* ]]
}

@test "_status_human_bytes: bytes range formats correctly" {
    run _status_human_bytes 500
    [[ "$status" -eq 0 ]]
    [[ "$output" == "500B" ]]
}

@test "_status_human_bytes: non-numeric input passes through as-is" {
    run _status_human_bytes "N/A"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "N/A" ]]
}

@test "_status_human_bytes: empty input passes through as-is" {
    run _status_human_bytes ""
    [[ "$status" -eq 0 ]]
    [[ "$output" == "" ]]
}

# ================================================================
# cmd_status: unknown/unusual state display
# ================================================================

@test "cmd_status: unknown state displays with yellow formatting" {
    _mock_fixture_state "fixture-primary" "Suspending"

    run cmd_status --name fixture-primary
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Suspending"* ]]
}

# ================================================================
# cmd_list: unknown state display
# ================================================================

@test "cmd_list: unknown state instance displays in output" {
    local custom_dir="${TEST_TEMP_DIR}/custom-list"
    mkdir -p "$custom_dir"
    # Create a list with an instance in an unusual state
    cat > "${custom_dir}/list.json" <<'JSON'
{
    "list": [
        {
            "ipv4": [],
            "name": "mps-fixture-primary",
            "release": "Ubuntu 24.04 LTS",
            "state": "Suspending"
        }
    ]
}
JSON
    export MOCK_MP_FIXTURES_DIR="$custom_dir"

    run cmd_list
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"fixture-primary"* ]]
    [[ "$output" == *"Suspending"* ]]
}

