#!/usr/bin/env bats
# Tests for commands/*.sh argument parsing and flag handling.
#
# These tests exercise the while/case parsing loops and validation
# logic in each cmd_*() function WITHOUT requiring multipass.
# Post-parse logic (instance resolution, multipass calls) is stubbed.

load ../test_helper

# ---------- Stubs ----------
# Stub functions that commands call after argument parsing.
# These prevent tests from reaching multipass-dependent code.

# lib/multipass.sh wrappers
mp_instance_exists()  { return 1; }    # "does not exist" by default
mp_instance_state()   { echo "nonexistent"; }
mp_list_all()         { echo '[]'; }
mp_info()             { echo '{"info":{}}'; }
mp_launch()           { :; }
mp_start()            { :; }
mp_stop()             { :; }
mp_delete()           { :; }
mp_shell()            { :; }
mp_exec()             { :; }
mp_mount()            { :; }
mp_umount()           { :; }
mp_get_mounts()       { echo '{}'; }
mp_transfer()         { :; }
mp_wait_cloud_init()  { :; }
mp_ipv4()             { echo "10.0.0.1"; }
mp_docker_status()    { echo "not running"; }

# lib/common.sh functions that touch state
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

# Export stubs so subshells see them
export -f mp_instance_exists mp_instance_state mp_list_all mp_info
export -f mp_launch mp_start mp_stop mp_delete mp_shell mp_exec
export -f mp_mount mp_umount mp_get_mounts mp_transfer mp_wait_cloud_init
export -f mp_ipv4 mp_docker_status
export -f mps_require_exists mps_require_running mps_prepare_running_instance
export -f mps_resolve_image mps_auto_forward_ports mps_kill_port_forwards
export -f mps_reset_port_forwards mps_forward_port mps_confirm
export -f mps_save_instance_meta mps_check_image_requirements
export -f _mps_fetch_manifest _mps_warn_image_staleness
export -f _mps_warn_instance_staleness _mps_check_instance_staleness
export -f _mps_resolve_project_mounts

setup() {
    setup_temp_dir
    export REAL_HOME="$HOME"
    export HOME="${TEST_TEMP_DIR}/fakehome"
    mkdir -p "$HOME/.mps/instances" "$HOME/.mps/cache/images"
    # Source all command files
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
# --help: every command prints help and returns 0
# ================================================================

@test "cmd_create --help: returns 0" {
    run cmd_create --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mps create"* ]]
}

@test "cmd_create -h: returns 0" {
    run cmd_create -h
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mps create"* ]]
}

@test "cmd_up --help: returns 0" {
    run cmd_up --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mps up"* ]]
}

@test "cmd_down --help: returns 0" {
    run cmd_down --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mps down"* ]]
}

@test "cmd_destroy --help: returns 0" {
    run cmd_destroy --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mps destroy"* ]]
}

@test "cmd_shell --help: returns 0" {
    run cmd_shell --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mps shell"* ]]
}

@test "cmd_exec --help: returns 0" {
    run cmd_exec --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mps exec"* ]]
}

@test "cmd_list --help: returns 0" {
    run cmd_list --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mps list"* ]]
}

@test "cmd_status --help: returns 0" {
    run cmd_status --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mps status"* ]]
}

@test "cmd_ssh_config --help: returns 0" {
    run cmd_ssh_config --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mps ssh-config"* ]]
}

@test "cmd_image --help: returns 0" {
    run cmd_image --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mps image"* ]]
}

@test "cmd_mount --help: returns 0" {
    run cmd_mount --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mps mount"* ]]
}

@test "cmd_port --help: returns 0" {
    run cmd_port --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mps port"* ]]
}

@test "cmd_transfer --help: returns 0" {
    run cmd_transfer --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mps transfer"* ]]
}

# ================================================================
# Unknown flags: every command rejects unknown flags
# ================================================================

@test "cmd_create: unknown flag dies" {
    run cmd_create --bogus
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown flag"* ]]
}

@test "cmd_down: unknown flag dies" {
    run cmd_down --bogus
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown flag"* ]]
}

@test "cmd_destroy: unknown flag dies" {
    run cmd_destroy --bogus
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown flag"* ]]
}

@test "cmd_shell: unknown flag dies" {
    run cmd_shell --bogus
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown flag"* ]]
}

@test "cmd_exec: unknown flag dies" {
    run cmd_exec --bogus
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown flag"* ]]
}

@test "cmd_list: unknown flag dies" {
    run cmd_list --bogus
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown flag"* ]]
}

@test "cmd_status: unknown flag dies" {
    run cmd_status --bogus
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown flag"* ]]
}

@test "cmd_ssh_config: unknown flag dies" {
    run cmd_ssh_config --bogus
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown flag"* ]]
}

@test "cmd_transfer: unknown flag dies" {
    run cmd_transfer --bogus
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown flag"* ]]
}

# ================================================================
# Unexpected positional args: commands that reject positionals
# ================================================================

@test "cmd_down: unexpected positional dies" {
    run cmd_down somearg
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unexpected argument"* ]]
}

@test "cmd_destroy: unexpected positional dies" {
    run cmd_destroy somearg
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unexpected argument"* ]]
}

@test "cmd_shell: unexpected positional dies" {
    run cmd_shell somearg
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unexpected argument"* ]]
}

@test "cmd_list: unexpected positional dies" {
    run cmd_list somearg
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unexpected argument"* ]]
}

@test "cmd_status: unexpected positional dies" {
    run cmd_status somearg
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unexpected argument"* ]]
}

@test "cmd_ssh_config: unexpected positional dies" {
    run cmd_ssh_config somearg
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unexpected argument"* ]]
}

# ================================================================
# Missing flag values: flags that require a value die without one
# ================================================================

@test "cmd_create --name without value: dies" {
    run cmd_create --name
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"requires a value"* ]]
}

@test "cmd_create --image without value: dies" {
    run cmd_create --image
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"requires a value"* ]]
}

@test "cmd_create --cpus without value: dies" {
    run cmd_create --cpus
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"requires a value"* ]]
}

@test "cmd_create --memory without value: dies" {
    run cmd_create --memory
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"requires a value"* ]]
}

@test "cmd_create --disk without value: dies" {
    run cmd_create --disk
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"requires a value"* ]]
}

@test "cmd_create --cloud-init without value: dies" {
    run cmd_create --cloud-init
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"requires a value"* ]]
}

@test "cmd_create --profile without value: dies" {
    run cmd_create --profile
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"requires a value"* ]]
}

@test "cmd_create --mount without value: dies" {
    run cmd_create --mount
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"requires a value"* ]]
}

@test "cmd_create --port without value: dies" {
    run cmd_create --port
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"requires a value"* ]]
}

@test "cmd_create --transfer without value: dies" {
    run cmd_create --transfer
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"requires a value"* ]]
}

@test "cmd_down --name without value: dies" {
    run cmd_down --name
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"requires a value"* ]]
}

@test "cmd_destroy --name without value: dies" {
    run cmd_destroy --name
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"requires a value"* ]]
}

@test "cmd_shell --name without value: dies" {
    run cmd_shell --name
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"requires a value"* ]]
}

@test "cmd_shell --workdir without value: dies" {
    run cmd_shell --workdir
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"requires a value"* ]]
}

@test "cmd_exec --name without value: dies" {
    run cmd_exec --name
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"requires a value"* ]]
}

@test "cmd_status --name without value: dies" {
    run cmd_status --name
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"requires a value"* ]]
}

@test "cmd_ssh_config --name without value: dies" {
    run cmd_ssh_config --name
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"requires a value"* ]]
}

@test "cmd_ssh_config --ssh-key without value: dies" {
    run cmd_ssh_config --ssh-key
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"requires a value"* ]]
}

@test "cmd_transfer --name without value: dies" {
    run cmd_transfer --name
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"requires a value"* ]]
}

# ================================================================
# Short flag aliases
# ================================================================

@test "cmd_down -n: accepts short flag alias" {
    run cmd_down -n myname
    # Should not die on parsing (may fail later on instance resolution, that's ok)
    [[ "$output" != *"Unknown flag"* ]]
}

@test "cmd_down -f: accepts short --force alias" {
    run cmd_down -f
    [[ "$output" != *"Unknown flag"* ]]
}

@test "cmd_create -n: accepts short --name alias" {
    run cmd_create -n myname
    [[ "$output" != *"Unknown flag"* ]]
}

@test "cmd_create --mem: accepts --mem alias for --memory" {
    run cmd_create --mem 4G
    [[ "$output" != *"Unknown flag"* ]]
}

@test "cmd_shell -w: accepts short --workdir alias" {
    run cmd_shell -w /tmp
    [[ "$output" != *"Unknown flag"* ]]
}

# ================================================================
# exec: command-specific parsing
# ================================================================

@test "cmd_exec: no command specified dies" {
    run cmd_exec --
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"No command specified"* ]]
}

@test "cmd_exec: positional before -- dies" {
    run cmd_exec somearg
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unexpected argument"* ]]
}

@test "cmd_exec: -- separates command correctly" {
    run cmd_exec --name testinst -- echo hello
    # Should reach mp_exec stub without dying
    [[ "$status" -eq 0 ]]
}

@test "cmd_exec --help before --: returns 0" {
    run cmd_exec --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mps exec"* ]]
}

# ================================================================
# transfer: validation
# ================================================================

@test "cmd_transfer: fewer than 2 file args dies" {
    run cmd_transfer onlyonepath
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"At least one source and one destination"* ]]
}

@test "cmd_transfer: no guest path dies" {
    run cmd_transfer /tmp/a /tmp/b
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"No guest path"* ]]
}

@test "cmd_transfer: guest-to-guest dies" {
    run cmd_transfer :/guest/src :/guest/dst
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Cannot transfer guest-to-guest"* ]]
}

@test "cmd_transfer: mixed host and guest sources dies" {
    # Destination is a host path so guest-to-guest check doesn't fire first
    run cmd_transfer /host/file :/guest/file /host/dst
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Cannot mix host and guest"* ]]
}

@test "cmd_transfer: multiple guest sources dies" {
    run cmd_transfer :/guest/a :/guest/b /host/dst
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Only one guest source"* ]]
}

@test "cmd_transfer: -- separates flags from file args" {
    run cmd_transfer --name testinst -- /tmp/a :/tmp/b
    # Should reach mp_transfer stub without dying
    [[ "$status" -eq 0 ]]
}

# ================================================================
# image: subcommand routing
# ================================================================

@test "cmd_image: no subcommand shows usage and exits 1" {
    run cmd_image
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"mps image"* ]]
}

@test "cmd_image: unknown subcommand exits 1" {
    run cmd_image bogus
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Unknown image subcommand"* ]]
}

@test "cmd_image list --help: returns 0" {
    run cmd_image list --help
    [[ "$status" -eq 0 ]]
}

@test "cmd_image pull --help: returns 0" {
    run cmd_image pull --help
    [[ "$status" -eq 0 ]]
}

@test "cmd_image import --help: returns 0" {
    run cmd_image import --help
    [[ "$status" -eq 0 ]]
}

@test "cmd_image remove --help: returns 0" {
    run cmd_image remove --help
    [[ "$status" -eq 0 ]]
}

@test "cmd_image import: no file dies" {
    run cmd_image import
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage"* ]]
}

@test "cmd_image import: nonexistent file dies" {
    run cmd_image import /nonexistent/file.qcow2
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"File not found"* ]]
}

@test "cmd_image import --tag: invalid tag dies" {
    local f="${TEST_TEMP_DIR}/fake.img"
    echo "data" > "$f"
    run cmd_image import "$f" --tag "bad_tag"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Invalid tag"* ]]
}

@test "cmd_image import --arch: invalid arch dies" {
    local f="${TEST_TEMP_DIR}/fake.img"
    echo "data" > "$f"
    run cmd_image import "$f" --arch "ppc64"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Invalid architecture"* ]]
}

@test "cmd_image import --tag: semver accepted" {
    local f="${TEST_TEMP_DIR}/fake.img"
    echo "data" > "$f"
    run cmd_image import "$f" --tag 1.2.3 --arch amd64
    [[ "$status" -eq 0 ]]
}

@test "cmd_image import --tag: 'local' accepted" {
    local f="${TEST_TEMP_DIR}/fake.img"
    echo "data" > "$f"
    run cmd_image import "$f" --tag local --arch amd64
    [[ "$status" -eq 0 ]]
}

@test "cmd_image pull: no image spec dies" {
    run cmd_image pull
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage"* ]]
}

@test "cmd_image remove: no spec and no --all dies" {
    run cmd_image remove
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage"* ]]
}

@test "cmd_image remove: --all with spec dies" {
    run cmd_image remove --all base
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"--all cannot be used with"* ]]
}

@test "cmd_image remove: --all with --arch dies" {
    run cmd_image remove --all --arch amd64
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"--arch cannot be used with --all"* ]]
}

@test "cmd_image remove: invalid --arch dies" {
    run cmd_image remove base --arch ppc64
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Invalid architecture"* ]]
}

# ================================================================
# mount: subcommand routing
# ================================================================

@test "cmd_mount: no subcommand shows usage and exits 1" {
    run cmd_mount
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"mps mount"* ]]
}

@test "cmd_mount: unknown subcommand exits 1" {
    run cmd_mount bogus
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Unknown mount subcommand"* ]]
}

@test "cmd_mount add --help: returns 0" {
    run cmd_mount add --help
    [[ "$status" -eq 0 ]]
}

@test "cmd_mount remove --help: returns 0" {
    run cmd_mount remove --help
    [[ "$status" -eq 0 ]]
}

@test "cmd_mount list --help: returns 0" {
    run cmd_mount list --help
    [[ "$status" -eq 0 ]]
}

@test "cmd_mount add: no mount spec dies" {
    run cmd_mount add --name testinst
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage"* ]]
}

@test "cmd_mount add: invalid spec (no colon) dies" {
    run cmd_mount add --name testinst /just/a/path
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Invalid mount format"* ]]
}

@test "cmd_mount remove: no guest path dies" {
    run cmd_mount remove --name testinst
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage"* ]]
}

@test "cmd_mount list: unexpected positional dies" {
    run cmd_mount list somearg
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unexpected argument"* ]]
}

# ================================================================
# port: subcommand routing
# ================================================================

@test "cmd_port: no subcommand shows usage and exits 1" {
    run cmd_port
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"mps port"* ]]
}

@test "cmd_port: unknown subcommand exits 1" {
    run cmd_port bogus
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Unknown port subcommand"* ]]
}

@test "cmd_port forward --help: returns 0" {
    run cmd_port forward --help
    [[ "$status" -eq 0 ]]
}

@test "cmd_port list --help: returns 0" {
    run cmd_port list --help
    [[ "$status" -eq 0 ]]
}

@test "cmd_port forward: missing name and port spec dies" {
    run cmd_port forward
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage"* ]]
}

@test "cmd_port forward: missing port spec dies" {
    run cmd_port forward myinst
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage"* ]]
}

@test "cmd_port forward: non-numeric ports die" {
    run cmd_port forward myinst abc:def
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Ports must be numbers"* ]]
}

@test "cmd_port forward: non-numeric host port dies" {
    run cmd_port forward myinst abc:80
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Ports must be numbers"* ]]
}

@test "cmd_port forward: non-numeric guest port dies" {
    run cmd_port forward myinst 80:abc
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Ports must be numbers"* ]]
}

@test "cmd_port forward: valid port spec accepted" {
    # Override stub: port forward requires instance to be Running
    mp_instance_state() { echo "Running"; }
    export -f mp_instance_state
    run cmd_port forward myinst 8080:80
    [[ "$status" -eq 0 ]]
}

@test "cmd_port forward --privileged: flag accepted" {
    mp_instance_state() { echo "Running"; }
    export -f mp_instance_state
    run cmd_port forward --privileged myinst 80:80
    [[ "$status" -eq 0 ]]
}

# ================================================================
# list: --json flag
# ================================================================

@test "cmd_list --json: returns 0" {
    run cmd_list --json
    [[ "$status" -eq 0 ]]
    # mp_list_all stub returns '[]'
    [[ "$output" == "[]" ]]
}

# ================================================================
# create: profile validation
# ================================================================

@test "cmd_create --profile: unknown profile dies" {
    run cmd_create --profile nonexistent --name testinst --no-mount
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown profile"* ]]
}

@test "cmd_create --profile lite: valid profile accepted" {
    run cmd_create --profile lite --name testinst --no-mount
    [[ "$status" -eq 0 ]]
}

# ================================================================
# create: --no-mount flag
# ================================================================

@test "cmd_create --no-mount: sets MPS_NO_AUTOMOUNT" {
    # --no-mount flag is parsed and exports MPS_NO_AUTOMOUNT=true.
    # (Full error path when combined with missing --name happens inside
    # command substitution where mps_die doesn't propagate — tested in E2E.)
    run cmd_create --no-mount --name testinst
    [[ "$output" != *"Unknown flag"* ]]
}

# ================================================================
# create: second positional arg rejected
# ================================================================

@test "cmd_create: second positional dies" {
    run cmd_create /path/one /path/two
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unexpected argument"* ]]
}
