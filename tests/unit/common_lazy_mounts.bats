#!/usr/bin/env bats
# Unit tests for _mps_lazy_restore_mounts in lib/common.sh.
#
# Tests the lazy mount re-establishment logic in isolation with stubbed
# multipass wrappers and controlled metadata.

load ../test_helper

setup() {
    setup_home_override
    mkdir -p "$HOME/mps/instances"

    # Source common.sh (provides _mps_lazy_restore_mounts and helpers)
    source "${MPS_ROOT}/lib/common.sh"

    # Stub multipass wrappers
    export MOUNT_CALL_LOG="${TEST_TEMP_DIR}/mount_calls.log"
    : > "$MOUNT_CALL_LOG"

    mp_get_mounts() { echo ""; }
    mp_mount() {
        echo "$1 $2 $3" >> "$MOUNT_CALL_LOG"
        return 0
    }
    export -f mp_get_mounts mp_mount
}
teardown() { teardown_home_override; }

# ================================================================
# _mps_lazy_restore_mounts: basic behavior
# ================================================================

@test "_mps_lazy_restore_mounts: re-establishes missing auto-mount from metadata" {
    local mount_dir="${HOME}/project"
    mkdir -p "$mount_dir"

    cat > "${HOME}/mps/instances/test-vm.json" <<METAJSON
{"name": "test-vm", "full_name": "mps-test-vm", "workdir": "${mount_dir}"}
METAJSON

    run _mps_lazy_restore_mounts "mps-test-vm" "test-vm"
    [[ "$status" -eq 0 ]]
    [[ -s "$MOUNT_CALL_LOG" ]]
    log="$(cat "$MOUNT_CALL_LOG")"
    [[ "$log" == *"${mount_dir} mps-test-vm ${mount_dir}"* ]]
}

@test "_mps_lazy_restore_mounts: no-op when no metadata exists" {
    run _mps_lazy_restore_mounts "mps-test-vm" "test-vm"
    [[ "$status" -eq 0 ]]
    [[ ! -s "$MOUNT_CALL_LOG" ]]
}

@test "_mps_lazy_restore_mounts: no-op when metadata has no workdir" {
    cat > "${HOME}/mps/instances/test-vm.json" <<'METAJSON'
{"name": "test-vm", "full_name": "mps-test-vm", "workdir": null}
METAJSON

    run _mps_lazy_restore_mounts "mps-test-vm" "test-vm"
    [[ "$status" -eq 0 ]]
    [[ ! -s "$MOUNT_CALL_LOG" ]]
}

@test "_mps_lazy_restore_mounts: skips mount already present" {
    local mount_dir="${HOME}/project"
    mkdir -p "$mount_dir"

    cat > "${HOME}/mps/instances/test-vm.json" <<METAJSON
{"name": "test-vm", "full_name": "mps-test-vm", "workdir": "${mount_dir}"}
METAJSON

    mp_get_mounts() {
        echo "{\"${mount_dir}\": {\"source_path\": \"${mount_dir}\"}}"
    }
    export -f mp_get_mounts

    run _mps_lazy_restore_mounts "mps-test-vm" "test-vm"
    [[ "$status" -eq 0 ]]
    [[ ! -s "$MOUNT_CALL_LOG" ]]
}

@test "_mps_lazy_restore_mounts: skips when source directory missing on host" {
    cat > "${HOME}/mps/instances/test-vm.json" <<'METAJSON'
{"name": "test-vm", "full_name": "mps-test-vm", "workdir": "/nonexistent/path"}
METAJSON

    run _mps_lazy_restore_mounts "mps-test-vm" "test-vm"
    [[ "$status" -eq 0 ]]
    [[ ! -s "$MOUNT_CALL_LOG" ]]
}

@test "_mps_lazy_restore_mounts: warns on mount failure without dying" {
    local mount_dir="${HOME}/project"
    mkdir -p "$mount_dir"

    cat > "${HOME}/mps/instances/test-vm.json" <<METAJSON
{"name": "test-vm", "full_name": "mps-test-vm", "workdir": "${mount_dir}"}
METAJSON

    mp_mount() {
        echo "$1 $2 $3" >> "$MOUNT_CALL_LOG"
        return 1
    }
    export -f mp_mount

    run _mps_lazy_restore_mounts "mps-test-vm" "test-vm"
    [[ "$status" -eq 0 ]]
    [[ -s "$MOUNT_CALL_LOG" ]]
    [[ "$output" == *"Could not re-establish"* ]]
}

@test "_mps_lazy_restore_mounts: re-establishes config mount from MPS_MOUNTS" {
    local mount_dir="${HOME}/project"
    local cfg_dir="${HOME}/config-src"
    mkdir -p "$mount_dir" "$cfg_dir"

    cat > "${HOME}/mps/instances/test-vm.json" <<METAJSON
{"name": "test-vm", "full_name": "mps-test-vm", "workdir": "${mount_dir}"}
METAJSON

    # Write MPS_MOUNTS into the project .mps.env
    echo "MPS_MOUNTS=${cfg_dir}:/mnt/cfg" > "${mount_dir}/.mps.env"

    run _mps_lazy_restore_mounts "mps-test-vm" "test-vm"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOUNT_CALL_LOG")"
    # Both auto-mount and config mount should be re-established
    [[ "$log" == *"${mount_dir} mps-test-vm ${mount_dir}"* ]]
    [[ "$log" == *"${cfg_dir} mps-test-vm /mnt/cfg"* ]]
}

@test "_mps_lazy_restore_mounts: mixed present and missing mounts" {
    local mount_dir="${HOME}/project"
    local cfg_dir="${HOME}/config-src"
    mkdir -p "$mount_dir" "$cfg_dir"

    cat > "${HOME}/mps/instances/test-vm.json" <<METAJSON
{"name": "test-vm", "full_name": "mps-test-vm", "workdir": "${mount_dir}"}
METAJSON

    echo "MPS_MOUNTS=${cfg_dir}:/mnt/cfg" > "${mount_dir}/.mps.env"

    # Auto-mount present, config mount missing
    mp_get_mounts() {
        echo "{\"${mount_dir}\": {\"source_path\": \"${mount_dir}\"}}"
    }
    export -f mp_get_mounts

    run _mps_lazy_restore_mounts "mps-test-vm" "test-vm"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOUNT_CALL_LOG")"
    # Only the config mount should be re-established
    local mount_count
    mount_count="$(wc -l < "$MOUNT_CALL_LOG")"
    [[ "$mount_count" -eq 1 ]]
    [[ "$log" == *"${cfg_dir} mps-test-vm /mnt/cfg"* ]]
}
