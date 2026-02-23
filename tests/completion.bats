#!/usr/bin/env bats
# Tests for bash completion system:
#   _complete_*() metadata functions in commands/*.sh (13 commands)
#   _mps_dispatch_complete() dispatcher in bin/mps

load test_helper

setup() {
    setup_temp_dir
    # Override HOME so dispatcher filesystem tests use controlled dirs
    export REAL_HOME="$HOME"
    export HOME="${TEST_TEMP_DIR}/fakehome"
    mkdir -p "$HOME"
    # Source all command files to get _complete_* functions
    local f
    for f in "${MPS_ROOT}"/commands/*.sh; do
        source "$f"
    done
}

teardown() {
    export HOME="$REAL_HOME"
    teardown_temp_dir
}

# ================================================================
# Smoke: _complete_* flags (all 13 commands)
# ================================================================

@test "_complete_create: flags is non-empty and includes --help" {
    result="$(_complete_create flags)"
    [[ -n "$result" ]]
    [[ " $result " == *" --help "* ]]
}

@test "_complete_up: flags is non-empty and includes --help" {
    result="$(_complete_up flags)"
    [[ -n "$result" ]]
    [[ " $result " == *" --help "* ]]
}

@test "_complete_down: flags is non-empty and includes --help" {
    result="$(_complete_down flags)"
    [[ -n "$result" ]]
    [[ " $result " == *" --help "* ]]
}

@test "_complete_destroy: flags is non-empty and includes --help" {
    result="$(_complete_destroy flags)"
    [[ -n "$result" ]]
    [[ " $result " == *" --help "* ]]
}

@test "_complete_shell: flags is non-empty and includes --help" {
    result="$(_complete_shell flags)"
    [[ -n "$result" ]]
    [[ " $result " == *" --help "* ]]
}

@test "_complete_exec: flags is non-empty and includes --help" {
    result="$(_complete_exec flags)"
    [[ -n "$result" ]]
    [[ " $result " == *" --help "* ]]
}

@test "_complete_list: flags is non-empty and includes --help" {
    result="$(_complete_list flags)"
    [[ -n "$result" ]]
    [[ " $result " == *" --help "* ]]
}

@test "_complete_status: flags is non-empty and includes --help" {
    result="$(_complete_status flags)"
    [[ -n "$result" ]]
    [[ " $result " == *" --help "* ]]
}

@test "_complete_ssh_config: flags is non-empty and includes --help" {
    result="$(_complete_ssh_config flags)"
    [[ -n "$result" ]]
    [[ " $result " == *" --help "* ]]
}

@test "_complete_transfer: flags is non-empty and includes --help" {
    result="$(_complete_transfer flags)"
    [[ -n "$result" ]]
    [[ " $result " == *" --help "* ]]
}

@test "_complete_image: flags (no subcmd) is non-empty and includes --help" {
    result="$(_complete_image flags "")"
    [[ -n "$result" ]]
    [[ " $result " == *" --help "* ]]
}

@test "_complete_mount: flags (no subcmd) is non-empty and includes --help" {
    result="$(_complete_mount flags "")"
    [[ -n "$result" ]]
    [[ " $result " == *" --help "* ]]
}

@test "_complete_port: flags (no subcmd) is non-empty and includes --help" {
    result="$(_complete_port flags "")"
    [[ -n "$result" ]]
    [[ " $result " == *" --help "* ]]
}

# ================================================================
# Subcommand routing: image, mount, port
# ================================================================

@test "_complete_image: subcmds returns list pull import remove" {
    result="$(_complete_image subcmds)"
    [[ "$result" == "list pull import remove" ]]
}

@test "_complete_mount: subcmds returns add remove list" {
    result="$(_complete_mount subcmds)"
    [[ "$result" == "add remove list" ]]
}

@test "_complete_port: subcmds returns forward list" {
    result="$(_complete_port subcmds)"
    [[ "$result" == "forward list" ]]
}

# ================================================================
# Per-subcommand flags
# ================================================================

@test "_complete_image: flags for pull includes --force" {
    result="$(_complete_image flags pull)"
    [[ " $result " == *" --force "* ]]
}

@test "_complete_image: flags for import includes --arch" {
    result="$(_complete_image flags import)"
    [[ " $result " == *" --arch "* ]]
}

@test "_complete_image: flags for list includes --remote" {
    result="$(_complete_image flags list)"
    [[ " $result " == *" --remote "* ]]
}

@test "_complete_mount: flags for add includes --name" {
    result="$(_complete_mount flags add)"
    [[ " $result " == *" --name "* ]]
}

@test "_complete_port: flags for forward includes --privileged" {
    result="$(_complete_port flags forward)"
    [[ " $result " == *" --privileged "* ]]
}

@test "_complete_port: flags for list does not include --privileged" {
    result="$(_complete_port flags list)"
    [[ " $result " != *" --privileged "* ]]
}

# ================================================================
# Flag-values magic tokens
# ================================================================

@test "_complete_create: --profile flag-values returns __profiles__" {
    result="$(_complete_create flag-values --profile)"
    [[ "$result" == "__profiles__" ]]
}

@test "_complete_create: --image flag-values returns __images__" {
    result="$(_complete_create flag-values --image)"
    [[ "$result" == "__images__" ]]
}

@test "_complete_create: --cloud-init flag-values returns __cloud_init__" {
    result="$(_complete_create flag-values --cloud-init)"
    [[ "$result" == "__cloud_init__" ]]
}

@test "_complete_create: --name flag-values returns __instances__" {
    result="$(_complete_create flag-values --name)"
    [[ "$result" == "__instances__" ]]
}

@test "_complete_up: --profile flag-values returns __profiles__ (mirrors create)" {
    result="$(_complete_up flag-values --profile)"
    [[ "$result" == "__profiles__" ]]
}

@test "_complete_image: --arch flag-values returns __archs__" {
    result="$(_complete_image flag-values --arch)"
    [[ "$result" == "__archs__" ]]
}

@test "_complete_ssh_config: --ssh-key flag-values returns __files__" {
    result="$(_complete_ssh_config flag-values --ssh-key)"
    [[ "$result" == "__files__" ]]
}

@test "_complete_down: unknown flag flag-values returns empty" {
    result="$(_complete_down flag-values --nonexistent)"
    [[ -z "$result" ]]
}

# ================================================================
# Dispatcher: token collection (commands, profiles, images, cloud_init)
# ================================================================

@test "__complete commands: lists all 13 command basenames" {
    run "${MPS_ROOT}/bin/mps" __complete commands
    [[ "$status" -eq 0 ]]
    # Count lines — one per command
    local count=0
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && count=$((count + 1))
    done <<< "$output"
    [[ "$count" -eq 13 ]]
}

@test "__complete commands: includes create, image, and ssh-config" {
    run "${MPS_ROOT}/bin/mps" __complete commands
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"create"* ]]
    [[ "$output" == *"image"* ]]
    [[ "$output" == *"ssh-config"* ]]
}

@test "__complete profiles: lists profile basenames" {
    run "${MPS_ROOT}/bin/mps" __complete profiles
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"micro"* ]]
    [[ "$output" == *"lite"* ]]
    [[ "$output" == *"standard"* ]]
    [[ "$output" == *"heavy"* ]]
}

@test "__complete images: lists layer basenames" {
    run "${MPS_ROOT}/bin/mps" __complete images
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"base"* ]]
    [[ "$output" == *"protocol-dev"* ]]
}

@test "__complete images: includes cached images from HOME" {
    mkdir -p "${HOME}/.mps/cache/images/custom-image"
    run "${MPS_ROOT}/bin/mps" __complete images
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"custom-image"* ]]
}

@test "__complete images: deduplicates layer and cached images" {
    mkdir -p "${HOME}/.mps/cache/images/base"
    run "${MPS_ROOT}/bin/mps" __complete images
    [[ "$status" -eq 0 ]]
    local count=0
    local line
    while IFS= read -r line; do
        [[ "$line" == "base" ]] && count=$((count + 1))
    done <<< "$output"
    [[ "$count" -eq 1 ]]
}

@test "__complete cloud_init: lists project templates" {
    run "${MPS_ROOT}/bin/mps" __complete cloud_init
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"default"* ]]
}

@test "__complete cloud_init: includes personal templates from HOME" {
    mkdir -p "${HOME}/.mps/cloud-init"
    echo "# personal" > "${HOME}/.mps/cloud-init/personal.yaml"
    run "${MPS_ROOT}/bin/mps" __complete cloud_init
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"personal"* ]]
}

# ================================================================
# Dispatcher: command-level routing
# ================================================================

@test "__complete: routes flags query to command" {
    run "${MPS_ROOT}/bin/mps" __complete create flags
    [[ "$status" -eq 0 ]]
    [[ " $output " == *" --name "* ]]
    [[ " $output " == *" --profile "* ]]
}

@test "__complete: routes subcmds query to command" {
    run "${MPS_ROOT}/bin/mps" __complete image subcmds
    [[ "$status" -eq 0 ]]
    [[ "$output" == "list pull import remove" ]]
}

@test "__complete: routes subcommand flags query" {
    run "${MPS_ROOT}/bin/mps" __complete image pull flags
    [[ "$status" -eq 0 ]]
    [[ " $output " == *" --force "* ]]
}

@test "__complete: routes flag-values query to command" {
    run "${MPS_ROOT}/bin/mps" __complete create flag-values --profile
    [[ "$status" -eq 0 ]]
    [[ "$output" == "__profiles__" ]]
}

# ================================================================
# Dispatcher: edge cases
# ================================================================

@test "__complete: unknown command returns empty with exit 0" {
    run "${MPS_ROOT}/bin/mps" __complete nonexistent flags
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "__complete: ssh-config hyphen normalized to ssh_config function" {
    run "${MPS_ROOT}/bin/mps" __complete ssh-config flags
    [[ "$status" -eq 0 ]]
    [[ " $output " == *" --name "* ]]
}
