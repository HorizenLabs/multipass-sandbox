#!/usr/bin/env bats
# Integration tests for lib/multipass.sh lifecycle, execution, mount, and transfer functions.
#
# Uses the mock multipass stub with call-log assertions and configurable exit codes.
# Complements stub_smoke.bats (which covers info & query wrappers).

load ../test_helper

setup() {
    setup_home_override
    setup_multipass_stub
    # shellcheck source=../../lib/multipass.sh
    source "${MPS_ROOT}/lib/multipass.sh"
}
teardown() { teardown_home_override; }

# ================================================================
# mp_info
# ================================================================

@test "mp_info: returns full JSON for known instance" {
    result="$(mp_info mps-fixture-primary)"
    state="$(echo "$result" | jq -r '.info["mps-fixture-primary"].state')"
    [[ "$state" == "Running" ]]
}

@test "mp_info: includes expected fields in JSON" {
    result="$(mp_info mps-fixture-primary)"
    release="$(echo "$result" | jq -r '.info["mps-fixture-primary"].image_release')"
    [[ "$release" == "24.04 LTS" ]]
}

@test "mp_info: dies on unknown instance" {
    run mp_info nonexistent-vm
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Failed to get info"* ]]
}

# ================================================================
# mp_info_field
# ================================================================

@test "mp_info_field: extracts state field" {
    result="$(mp_info_field mps-fixture-primary state)"
    [[ "$result" == "Running" ]]
}

@test "mp_info_field: extracts image_release field" {
    result="$(mp_info_field mps-fixture-primary image_release)"
    [[ "$result" == "24.04 LTS" ]]
}

@test "mp_info_field: returns empty for nonexistent field" {
    result="$(mp_info_field mps-fixture-primary nonexistent_field)"
    [[ -z "$result" ]]
}

# ================================================================
# mp_instance_state
# ================================================================

@test "mp_instance_state: returns state for existing instance" {
    result="$(mp_instance_state mps-fixture-primary)"
    [[ "$result" == "Running" ]]
}

@test "mp_instance_state: returns nonexistent for unknown instance" {
    result="$(mp_instance_state nonexistent-vm)"
    [[ "$result" == "nonexistent" ]]
}

# ================================================================
# mp_launch
# ================================================================

@test "mp_launch: constructs correct multipass command with all args (bytes)" {
    run mp_launch "mps-test" "22.04" "4" "4G" "30G" ""
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"launch 22.04 --name mps-test --cpus 4 --memory 4294967296 --disk 32212254720 --timeout 600"* ]]
}

@test "mp_launch: defaults to base image and env resources (bytes)" {
    run mp_launch "mps-test"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"launch base --name mps-test --cpus 2 --memory 2147483648 --disk 21474836480 --timeout 600"* ]]
}

@test "mp_launch: GiB suffix also accepted (converts to bytes)" {
    run mp_launch "mps-test" "22.04" "4" "4GiB" "30GiB" ""
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"--memory 4294967296 --disk 32212254720"* ]]
}

@test "mp_launch: includes --cloud-init when provided" {
    local ci_file="${TEST_TEMP_DIR}/cloud-init.yaml"
    echo "#cloud-config" > "$ci_file"
    run mp_launch "mps-test" "base" "2" "2G" "20G" "$ci_file"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"--cloud-init ${ci_file}"* ]]
}

@test "mp_launch: omits --cloud-init when empty" {
    run mp_launch "mps-test" "base" "2" "2G" "20G" ""
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" != *"--cloud-init"* ]]
}

@test "mp_launch: passes extra args through" {
    run mp_launch "mps-test" "base" "2" "2G" "20G" "" "--mount" "/tmp:/mnt"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"--mount /tmp:/mnt"* ]]
}

@test "mp_launch: dies on failure" {
    export MOCK_MP_LAUNCH_EXIT=1
    run mp_launch "mps-test" "base" "2" "2G" "20G" ""
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Failed to launch"* ]]
}

# ================================================================
# mp_start
# ================================================================

@test "mp_start: calls multipass start with instance name" {
    run mp_start "mps-fixture-primary"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"start mps-fixture-primary"* ]]
}

@test "mp_start: logs success message" {
    run mp_start "mps-fixture-primary"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"started"* ]]
}

@test "mp_start: dies on failure" {
    export MOCK_MP_START_EXIT=1
    run mp_start "mps-fixture-primary"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Failed to start"* ]]
}

# ================================================================
# mp_stop
# ================================================================

@test "mp_stop: calls multipass stop without --force by default" {
    run mp_stop "mps-fixture-primary"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"stop mps-fixture-primary"* ]]
    [[ "$log" != *"--force"* ]]
}

@test "mp_stop: includes --force when force=true" {
    run mp_stop "mps-fixture-primary" "true"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"stop mps-fixture-primary --force"* ]]
}

@test "mp_stop: dies on failure" {
    export MOCK_MP_STOP_EXIT=1
    run mp_stop "mps-fixture-primary"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Failed to stop"* ]]
}

# ================================================================
# mp_delete
# ================================================================

@test "mp_delete: includes --purge by default" {
    run mp_delete "mps-fixture-primary"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"delete mps-fixture-primary --purge"* ]]
}

@test "mp_delete: omits --purge when purge=false" {
    run mp_delete "mps-fixture-primary" "false"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"delete mps-fixture-primary"* ]]
    [[ "$log" != *"--purge"* ]]
}

@test "mp_delete: dies on failure" {
    export MOCK_MP_DELETE_EXIT=1
    run mp_delete "mps-fixture-primary"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Failed to delete"* ]]
}

# ================================================================
# mp_exec
# ================================================================

@test "mp_exec: constructs command with -- separator and forwards output" {
    export MOCK_MP_EXEC_OUTPUT="hello"
    run mp_exec "mps-fixture-primary" "" echo "hello world"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "hello" ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"exec mps-fixture-primary -- echo hello world"* ]]
}

@test "mp_exec: includes --working-directory when provided" {
    export MOCK_MP_EXEC_OUTPUT="in workdir"
    run mp_exec "mps-fixture-primary" "/home/ubuntu/project" ls
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"exec mps-fixture-primary --working-directory /home/ubuntu/project -- ls"* ]]
}

@test "mp_exec: forwards exit code from command" {
    export MOCK_MP_EXEC_EXIT=42
    run mp_exec "mps-fixture-primary" "" false
    [[ "$status" -eq 42 ]]
}

# ================================================================
# mp_shell
# ================================================================

@test "mp_shell: calls multipass shell without workdir" {
    run mp_shell "mps-fixture-primary"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"shell mps-fixture-primary"* ]]
}

@test "mp_shell: uses exec with bash -c cd for workdir" {
    run mp_shell "mps-fixture-primary" "/home/ubuntu/project"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"exec mps-fixture-primary -- bash -c"* ]]
    [[ "$log" == *"/home/ubuntu/project"* ]]
}

# ================================================================
# mp_mount
# ================================================================

@test "mp_mount: calls multipass mount with source instance:target" {
    run mp_mount "/host/path" "mps-fixture-primary" "/guest/path"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"mount /host/path mps-fixture-primary:/guest/path"* ]]
}

@test "mp_mount: returns 1 on failure with warning (not die)" {
    export MOCK_MP_MOUNT_EXIT=1
    run mp_mount "/host/path" "mps-fixture-primary" "/guest/path"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Failed to mount"* ]]
}

# ================================================================
# mp_umount
# ================================================================

@test "mp_umount: calls multipass umount with instance:target" {
    run mp_umount "mps-fixture-primary" "/mnt/test-a"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"umount mps-fixture-primary:/mnt/test-a"* ]]
}

@test "mp_umount: swallows failure silently (exit 0)" {
    export MOCK_MP_UMOUNT_EXIT=1
    run mp_umount "mps-fixture-primary" "/mnt/test-a"
    [[ "$status" -eq 0 ]]
}

# ================================================================
# mp_transfer
# ================================================================

@test "mp_transfer: calls multipass transfer with correct args" {
    run mp_transfer "mps-fixture-primary:/tmp/file.txt" "/local/path"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"transfer mps-fixture-primary:/tmp/file.txt /local/path"* ]]
}

@test "mp_transfer: supports multiple source files" {
    run mp_transfer "/local/a.txt" "/local/b.txt" "mps-fixture-primary:/tmp/"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"transfer /local/a.txt /local/b.txt mps-fixture-primary:/tmp/"* ]]
}

@test "mp_transfer: dies with fewer than 2 arguments" {
    run mp_transfer "only-one-arg"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"requires at least 2 arguments"* ]]
}

@test "mp_transfer: dies on transfer failure" {
    export MOCK_MP_TRANSFER_EXIT=1
    run mp_transfer "mps-fixture-primary:/tmp/file.txt" "/local/path"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"File transfer failed"* ]]
}

# ================================================================
# mp_wait_cloud_init
# ================================================================

@test "mp_wait_cloud_init: calls exec with cloud-init status --wait" {
    run mp_wait_cloud_init "mps-fixture-primary"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"exec mps-fixture-primary -- cloud-init status --wait"* ]]
}

@test "mp_wait_cloud_init: warns but does not die on failure" {
    export MOCK_MP_EXEC_EXIT=1
    run mp_wait_cloud_init "mps-fixture-primary"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"may not have completed cleanly"* ]]
}

# ================================================================
# mp_docker_status
# ================================================================

@test "mp_docker_status: returns version string when docker available" {
    export MOCK_MP_DOCKER_VERSION="27.0.3"
    run mp_docker_status "mps-fixture-primary"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "27.0.3" ]]
}

@test "mp_docker_status: returns 'not running' when docker unavailable" {
    unset MOCK_MP_DOCKER_VERSION 2>/dev/null || true
    run mp_docker_status "mps-fixture-primary"
    [[ "$status" -eq 1 ]]
    [[ "$output" == "not running" ]]
}
