#!/usr/bin/env bats
# Unit tests for _create_recover_mounts in commands/create.sh.
#
# These tests exercise the mount recovery function in isolation with
# stubbed dependencies (mp_get_mounts, mp_mount, sleep, etc.).

load ../test_helper

# ---------- Stubs ----------

# Stub everything commands/create.sh sources so we can call _create_recover_mounts directly.
mp_instance_exists()  { return 1; }
mp_instance_state()   { echo "nonexistent"; }
mp_list_all()         { echo '[]'; }
mp_info()             { echo '{"info":{}}'; }
mp_launch()           { :; }
mp_start()            { :; }
mp_stop()             { :; }
mp_delete()           { :; }
mp_shell()            { :; }
mp_exec()             { :; }
mp_umount()           { :; }
mp_transfer()         { :; }
mp_wait_cloud_init()  { :; }
mp_ipv4()             { echo "10.0.0.1"; }
mp_docker_status()    { echo "not running"; }

mps_require_exists()           { :; }
mps_require_running()          { :; }
mps_prepare_running_instance() { echo "stubbed"; }
mps_resolve_image()            { echo "file:///stub.img"; }
mps_auto_forward_ports()       { :; }
mps_kill_port_forwards()       { :; }
mps_reset_port_forwards()      { :; }
mps_forward_port()             { :; }
mps_confirm()                  { return 0; }
mps_save_instance_meta()       { :; }
mps_check_image_requirements() { :; }

_mps_fetch_manifest()          { return 1; }
_mps_warn_image_staleness()    { :; }
_mps_warn_instance_staleness() { :; }
_mps_check_instance_staleness(){ echo ""; }
_mps_resolve_project_mounts()  { echo ""; }

export -f mp_instance_exists mp_instance_state mp_list_all mp_info
export -f mp_launch mp_start mp_stop mp_delete mp_shell mp_exec
export -f mp_umount mp_transfer mp_wait_cloud_init
export -f mp_ipv4 mp_docker_status
export -f mps_require_exists mps_require_running mps_prepare_running_instance
export -f mps_resolve_image mps_auto_forward_ports mps_kill_port_forwards
export -f mps_reset_port_forwards mps_forward_port mps_confirm
export -f mps_save_instance_meta mps_check_image_requirements
export -f _mps_fetch_manifest _mps_warn_image_staleness
export -f _mps_warn_instance_staleness _mps_check_instance_staleness
export -f _mps_resolve_project_mounts

setup() {
    setup_home_override
    mkdir -p "$HOME/mps/instances" "$HOME/mps/cache/images"
    source_commands

    # Shared test state: track mp_mount calls
    export MOUNT_CALL_LOG="${TEST_TEMP_DIR}/mount_calls.log"
    : > "$MOUNT_CALL_LOG"

    # Default stubs for recovery tests
    mp_get_mounts() { echo ""; }
    export -f mp_get_mounts

    mp_mount() {
        echo "$1 $2 $3" >> "$MOUNT_CALL_LOG"
        return 0
    }
    export -f mp_mount

    sleep() { :; }
    export -f sleep
}
teardown() { teardown_home_override; }

# ================================================================
# _create_recover_mounts: basic behavior
# ================================================================

@test "_create_recover_mounts: retries a single missing mount" {
    run _create_recover_mounts "mps-test" "/home/user/proj:/home/user/proj"
    [[ "$status" -eq 0 ]]
    [[ -s "$MOUNT_CALL_LOG" ]]
    log="$(cat "$MOUNT_CALL_LOG")"
    [[ "$log" == *"/home/user/proj mps-test /home/user/proj"* ]]
}

@test "_create_recover_mounts: no-op when no mount args provided" {
    run _create_recover_mounts "mps-test"
    [[ "$status" -eq 0 ]]
    # No mount calls should have been made
    [[ ! -s "$MOUNT_CALL_LOG" ]]
}

@test "_create_recover_mounts: skips mount already present in actual mounts" {
    mp_get_mounts() {
        echo '{ "/mnt/present": { "source_path": "/home/user/a" } }'
    }
    export -f mp_get_mounts

    run _create_recover_mounts "mps-test" "/home/user/a:/mnt/present"
    [[ "$status" -eq 0 ]]
    [[ ! -s "$MOUNT_CALL_LOG" ]]
}

# ================================================================
# _create_recover_mounts: mixed present/missing
# ================================================================

@test "_create_recover_mounts: retries only missing mounts when some survive" {
    mp_get_mounts() {
        echo '{ "/mnt/ok": { "source_path": "/home/user/a" } }'
    }
    export -f mp_get_mounts

    run _create_recover_mounts "mps-test" \
        "/home/user/a:/mnt/ok" \
        "/home/user/b:/mnt/missing"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOUNT_CALL_LOG")"
    # Only the missing mount should have been retried
    local mount_count
    mount_count="$(wc -l < "$MOUNT_CALL_LOG")"
    [[ "$mount_count" -eq 1 ]]
    [[ "$log" == *"/home/user/b mps-test /mnt/missing"* ]]
}

# ================================================================
# _create_recover_mounts: retry behavior
# ================================================================

@test "_create_recover_mounts: succeeds on second attempt" {
    local attempt_count=0
    mp_mount() {
        echo "$1 $2 $3" >> "$MOUNT_CALL_LOG"
        attempt_count=$((attempt_count + 1))
        if [[ $attempt_count -le 1 ]]; then
            return 1
        fi
        return 0
    }
    export -f mp_mount
    export attempt_count

    run _create_recover_mounts "mps-test" "/home/user/proj:/mnt/proj"
    [[ "$status" -eq 0 ]]
    local mount_count
    mount_count="$(wc -l < "$MOUNT_CALL_LOG")"
    [[ "$mount_count" -eq 2 ]]
}

@test "_create_recover_mounts: warns after all retries exhausted" {
    mp_mount() {
        echo "$1 $2 $3" >> "$MOUNT_CALL_LOG"
        return 1
    }
    export -f mp_mount

    run _create_recover_mounts "mps-test" "/home/user/proj:/mnt/proj"
    [[ "$status" -eq 0 ]]
    # Should have attempted 3 times
    local mount_count
    mount_count="$(wc -l < "$MOUNT_CALL_LOG")"
    [[ "$mount_count" -eq 3 ]]
    # Should warn about exhausted retries
    [[ "$output" == *"failed after 3 retries"* ]]
}

@test "_create_recover_mounts: multiple missing mounts each get retried independently" {
    run _create_recover_mounts "mps-test" \
        "/home/user/a:/mnt/a" \
        "/home/user/b:/mnt/b"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOUNT_CALL_LOG")"
    [[ "$log" == *"/home/user/a mps-test /mnt/a"* ]]
    [[ "$log" == *"/home/user/b mps-test /mnt/b"* ]]
}
