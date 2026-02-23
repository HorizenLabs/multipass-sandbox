#!/usr/bin/env bats
# Tests for naming functions in lib/common.sh:
#   mps_instance_name, mps_short_name, mps_auto_name,
#   mps_validate_name, mps_resolve_name, mps_resolve_instance_name

load test_helper

setup() {
    setup_temp_dir
    export REAL_HOME="$HOME"
    export HOME="${TEST_TEMP_DIR}/fakehome"
    mkdir -p "$HOME"
}

teardown() {
    export HOME="$REAL_HOME"
    teardown_temp_dir
}

# ================================================================
# mps_instance_name
# ================================================================

@test "mps_instance_name: adds prefix to bare name" {
    result="$(mps_instance_name "mydev")"
    [[ "$result" == "mps-mydev" ]]
}

@test "mps_instance_name: does not double-prefix" {
    result="$(mps_instance_name "mps-mydev")"
    [[ "$result" == "mps-mydev" ]]
}

@test "mps_instance_name: respects custom prefix" {
    MPS_INSTANCE_PREFIX="test" result="$(mps_instance_name "mydev")"
    [[ "$result" == "test-mydev" ]]
}

@test "mps_instance_name: custom prefix no double-prefix" {
    MPS_INSTANCE_PREFIX="test" result="$(mps_instance_name "test-mydev")"
    [[ "$result" == "test-mydev" ]]
}

# ================================================================
# mps_short_name
# ================================================================

@test "mps_short_name: strips default prefix" {
    result="$(mps_short_name "mps-mydev")"
    [[ "$result" == "mydev" ]]
}

@test "mps_short_name: name without prefix unchanged" {
    result="$(mps_short_name "mydev")"
    [[ "$result" == "mydev" ]]
}

@test "mps_short_name: strips only leading prefix" {
    result="$(mps_short_name "mps-my-mps-project")"
    [[ "$result" == "my-mps-project" ]]
}

@test "mps_short_name: respects custom prefix" {
    MPS_INSTANCE_PREFIX="test" result="$(mps_short_name "test-mydev")"
    [[ "$result" == "mydev" ]]
}

# ================================================================
# mps_validate_name
# ================================================================

@test "mps_validate_name: accepts simple alphanumeric" {
    mps_validate_name "mydev"
}

@test "mps_validate_name: accepts name with dashes" {
    mps_validate_name "my-dev-box"
}

@test "mps_validate_name: accepts name with dots" {
    mps_validate_name "my.dev"
}

@test "mps_validate_name: accepts name with underscores" {
    mps_validate_name "my_dev"
}

@test "mps_validate_name: rejects name starting with dash" {
    run mps_validate_name "-badname"
    [[ "$status" -ne 0 ]]
}

@test "mps_validate_name: rejects name starting with dot" {
    run mps_validate_name ".hidden"
    [[ "$status" -ne 0 ]]
}

@test "mps_validate_name: rejects name with spaces" {
    run mps_validate_name "bad name"
    [[ "$status" -ne 0 ]]
}

@test "mps_validate_name: rejects name with slashes" {
    run mps_validate_name "bad/name"
    [[ "$status" -ne 0 ]]
}

@test "mps_validate_name: rejects empty name" {
    run mps_validate_name ""
    [[ "$status" -ne 0 ]]
}

# ================================================================
# mps_auto_name
# ================================================================

@test "mps_auto_name: basic derivation from path" {
    result="$(mps_auto_name "/home/user/myproject" "default")"
    [[ "$result" == "mps-myproject-default" ]]
}

@test "mps_auto_name: sanitizes uppercase to lowercase" {
    result="$(mps_auto_name "/home/user/MyProject" "default")"
    [[ "$result" == "mps-myproject-default" ]]
}

@test "mps_auto_name: sanitizes special chars to dashes" {
    result="$(mps_auto_name "/home/user/my_project.v2" "default")"
    [[ "$result" == "mps-my-project-v2-default" ]]
}

@test "mps_auto_name: uses default template when not specified" {
    export MPS_CLOUD_INIT=""
    export MPS_DEFAULT_CLOUD_INIT="default"
    result="$(mps_auto_name "/home/user/myproject")"
    [[ "$result" == "mps-myproject-default" ]]
}

@test "mps_auto_name: strips .yaml extension from template" {
    result="$(mps_auto_name "/home/user/myproject" "custom.yaml")"
    [[ "$result" == "mps-myproject-custom" ]]
}

@test "mps_auto_name: strips .yml extension from template" {
    result="$(mps_auto_name "/home/user/myproject" "custom.yml")"
    [[ "$result" == "mps-myproject-custom" ]]
}

@test "mps_auto_name: strips path from template name" {
    result="$(mps_auto_name "/home/user/myproject" "/path/to/cloud-init.yaml")"
    [[ "$result" == "mps-myproject-cloud-init" ]]
}

@test "mps_auto_name: truncates long names with hash" {
    # Create a long folder name that will exceed 40 chars
    result="$(mps_auto_name "/home/user/this-is-a-very-long-project-name-that-exceeds-limit" "default")"
    [[ ${#result} -le 40 ]]
}

@test "mps_auto_name: truncated names contain hash for uniqueness" {
    result="$(mps_auto_name "/home/user/this-is-a-very-long-project-name-that-exceeds-limit" "default")"
    # Should contain a 4-char hash segment
    [[ "$result" =~ -[a-f0-9]{4}- ]]
}

@test "mps_auto_name: dies when no mount path given" {
    run mps_auto_name "" "default"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Cannot auto-name"* ]]
}

@test "mps_auto_name: respects custom prefix" {
    MPS_INSTANCE_PREFIX="test" result="$(mps_auto_name "/home/user/myproject" "default")"
    [[ "$result" == "test-myproject-default" ]]
}

@test "mps_auto_name: ensures name starts with a letter" {
    # If prefix were somehow numeric, the name should get an 'm' prepended
    MPS_INSTANCE_PREFIX="123" result="$(mps_auto_name "/home/user/myproject" "default")"
    [[ "$result" =~ ^[a-zA-Z] ]]
}

# ================================================================
# mps_resolve_name
# ================================================================

@test "mps_resolve_name: explicit name takes priority" {
    result="$(mps_resolve_name "explicit" "/some/path" "default")"
    [[ "$result" == "mps-explicit" ]]
}

@test "mps_resolve_name: MPS_NAME from config takes second priority" {
    MPS_NAME="fromconfig" result="$(mps_resolve_name "" "/some/path" "default")"
    unset MPS_NAME
    [[ "$result" == "mps-fromconfig" ]]
}

@test "mps_resolve_name: auto-name from mount path as fallback" {
    unset MPS_NAME
    result="$(mps_resolve_name "" "/home/user/myproject" "default")"
    [[ "$result" == "mps-myproject-default" ]]
}

@test "mps_resolve_name: dies when no name can be derived" {
    unset MPS_NAME
    run mps_resolve_name "" "" ""
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Cannot determine instance name"* ]]
}

# ================================================================
# mps_resolve_instance_name
# ================================================================

@test "mps_resolve_instance_name: applies prefix to explicit name" {
    result="$(mps_resolve_instance_name "mydev")"
    [[ "$result" == "mps-mydev" ]]
}

@test "mps_resolve_instance_name: auto-derives from cwd" {
    mkdir -p "${TEST_TEMP_DIR}/testproj"
    cd "${TEST_TEMP_DIR}/testproj"
    export MPS_CLOUD_INIT="" MPS_DEFAULT_CLOUD_INIT="default"
    unset MPS_NAME
    result="$(mps_resolve_instance_name)"
    [[ "$result" == "mps-testproj-default" ]]
}

@test "mps_resolve_instance_name: uses MPS_CLOUD_INIT for template" {
    mkdir -p "${TEST_TEMP_DIR}/myapp"
    cd "${TEST_TEMP_DIR}/myapp"
    export MPS_CLOUD_INIT="protocol-dev" MPS_DEFAULT_CLOUD_INIT="default"
    unset MPS_NAME
    result="$(mps_resolve_instance_name)"
    [[ "$result" == "mps-myapp-protocol-dev" ]]
}

@test "mps_resolve_instance_name: validates explicit name" {
    run mps_resolve_instance_name "-starts-with-dash"
    [[ "$status" -ne 0 ]]
}

@test "mps_resolve_instance_name: does not double-prefix" {
    result="$(mps_resolve_instance_name "mps-already")"
    [[ "$result" == "mps-already" ]]
}
