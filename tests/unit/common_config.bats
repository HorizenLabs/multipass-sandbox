#!/usr/bin/env bats
# Tests for configuration functions in lib/common.sh:
#   _mps_load_env_file, _mps_apply_profile, mps_load_config

load ../test_helper

setup() {
    setup_temp_dir
}

teardown() {
    teardown_temp_dir
}

# ================================================================
# _mps_load_env_file
# ================================================================

@test "_mps_load_env_file: loads MPS_ variables" {
    cat > "${TEST_TEMP_DIR}/test.env" <<'EOF'
MPS_FOO=bar
MPS_BAZ=qux
EOF
    unset MPS_FOO MPS_BAZ 2>/dev/null || true
    _mps_load_env_file "${TEST_TEMP_DIR}/test.env"
    [[ "$MPS_FOO" == "bar" ]]
    [[ "$MPS_BAZ" == "qux" ]]
}

@test "_mps_load_env_file: ignores non-MPS variables" {
    cat > "${TEST_TEMP_DIR}/test.env" <<'EOF'
OTHER_VAR=secret
MPS_GOOD=yes
EOF
    unset OTHER_VAR MPS_GOOD 2>/dev/null || true
    _mps_load_env_file "${TEST_TEMP_DIR}/test.env" 2>/dev/null
    [[ "${OTHER_VAR:-}" == "" ]]
    [[ "$MPS_GOOD" == "yes" ]]
}

@test "_mps_load_env_file: skips comments and blank lines" {
    cat > "${TEST_TEMP_DIR}/test.env" <<'EOF'
# This is a comment
MPS_A=1

# Another comment
MPS_B=2
EOF
    unset MPS_A MPS_B 2>/dev/null || true
    _mps_load_env_file "${TEST_TEMP_DIR}/test.env"
    [[ "$MPS_A" == "1" ]]
    [[ "$MPS_B" == "2" ]]
}

@test "_mps_load_env_file: strips double quotes from values" {
    cat > "${TEST_TEMP_DIR}/test.env" <<'EOF'
MPS_QUOTED="hello world"
EOF
    unset MPS_QUOTED 2>/dev/null || true
    _mps_load_env_file "${TEST_TEMP_DIR}/test.env"
    [[ "$MPS_QUOTED" == "hello world" ]]
}

@test "_mps_load_env_file: strips single quotes from values" {
    cat > "${TEST_TEMP_DIR}/test.env" <<'EOF'
MPS_QUOTED='hello world'
EOF
    unset MPS_QUOTED 2>/dev/null || true
    _mps_load_env_file "${TEST_TEMP_DIR}/test.env"
    [[ "$MPS_QUOTED" == "hello world" ]]
}

@test "_mps_load_env_file: handles whitespace around key/value" {
    cat > "${TEST_TEMP_DIR}/test.env" <<'EOF'
  MPS_SPACED  =  value
EOF
    unset MPS_SPACED 2>/dev/null || true
    _mps_load_env_file "${TEST_TEMP_DIR}/test.env"
    [[ "$MPS_SPACED" == "value" ]]
}

# ================================================================
# _mps_apply_profile
# ================================================================

@test "_mps_apply_profile: sets unset variables from profile" {
    cat > "${TEST_TEMP_DIR}/profile.env" <<'EOF'
MPS_PROFILE_DISK=20G
MPS_PROFILE_CPUS_MIN=2
EOF
    unset MPS_DISK MPS_CPUS_MIN 2>/dev/null || true
    _mps_apply_profile "${TEST_TEMP_DIR}/profile.env"
    [[ "$MPS_DISK" == "20G" ]]
    [[ "$MPS_CPUS_MIN" == "2" ]]
}

@test "_mps_apply_profile: does not override already-set variables" {
    cat > "${TEST_TEMP_DIR}/profile.env" <<'EOF'
MPS_PROFILE_DISK=20G
EOF
    export MPS_DISK="50G"
    _mps_apply_profile "${TEST_TEMP_DIR}/profile.env"
    [[ "$MPS_DISK" == "50G" ]]
}

@test "_mps_apply_profile: skips comments" {
    cat > "${TEST_TEMP_DIR}/profile.env" <<'EOF'
# MPS Profile: test
MPS_PROFILE_DISK=10G
EOF
    unset MPS_DISK 2>/dev/null || true
    _mps_apply_profile "${TEST_TEMP_DIR}/profile.env"
    [[ "$MPS_DISK" == "10G" ]]
}

# ================================================================
# mps_load_config: basic smoke test
# ================================================================

@test "mps_load_config: loads defaults.env" {
    # Reset config values that defaults.env should set
    unset MPS_DEFAULT_IMAGE MPS_DEFAULT_CPUS MPS_NO_AUTOMOUNT 2>/dev/null || true
    # Ensure profile fractions don't interfere (pre-set MPS_CPUS/MEMORY to skip compute)
    export MPS_CPUS=2
    export MPS_MEMORY=2G
    mps_load_config
    [[ "${MPS_DEFAULT_IMAGE:-}" == "base" ]]
    [[ "${MPS_NO_AUTOMOUNT:-}" == "false" ]]
}

@test "mps_load_config: project config overrides defaults" {
    export MPS_PROJECT_DIR="${TEST_TEMP_DIR}"
    cat > "${TEST_TEMP_DIR}/.mps.env" <<'EOF'
MPS_DEFAULT_IMAGE=protocol-dev
EOF
    unset MPS_DEFAULT_IMAGE 2>/dev/null || true
    export MPS_CPUS=2
    export MPS_MEMORY=2G
    mps_load_config
    [[ "${MPS_DEFAULT_IMAGE}" == "protocol-dev" ]]
}

@test "mps_load_config: auto-scales CPU and memory when not pre-set" {
    unset MPS_CPUS MPS_MEMORY MPS_DEFAULT_IMAGE 2>/dev/null || true
    mps_load_config
    # CPU must be a positive integer
    [[ -n "${MPS_CPUS:-}" ]]
    [[ "$MPS_CPUS" -ge 1 ]]
    # Memory must match nG or nM format
    [[ -n "${MPS_MEMORY:-}" ]]
    [[ "$MPS_MEMORY" =~ ^[0-9]+[GM]$ ]]
}

@test "mps_load_config: rejects non-https MPS_IMAGE_BASE_URL" {
    export MPS_PROJECT_DIR="${TEST_TEMP_DIR}"
    # Set the invalid URL via project config so it survives defaults.env sourcing
    cat > "${TEST_TEMP_DIR}/.mps.env" <<'EOF'
MPS_IMAGE_BASE_URL=http://insecure.example.com
EOF
    export MPS_CPUS=2
    export MPS_MEMORY=2G
    run mps_load_config
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"must use https://"* ]]
}

# ================================================================
# mps_load_config: ~/mps/config loading
# ================================================================

@test "mps_load_config: loads ~/mps/config when present" {
    # Override HOME to a controlled temp directory
    local saved_home="$HOME"
    export HOME="${TEST_TEMP_DIR}/fakehome"
    mkdir -p "${HOME}/mps"
    cat > "${HOME}/mps/config" <<'EOF'
MPS_CHECK_UPDATES=false
EOF
    unset MPS_CHECK_UPDATES 2>/dev/null || true
    export MPS_CPUS=2
    export MPS_MEMORY=2G
    mps_load_config
    [[ "${MPS_CHECK_UPDATES}" == "false" ]]
    export HOME="$saved_home"
}

@test "mps_load_config: ~/mps/config overrides defaults.env" {
    local saved_home="$HOME"
    export HOME="${TEST_TEMP_DIR}/fakehome"
    mkdir -p "${HOME}/mps"
    # Set a value in ~/mps/config that differs from defaults.env
    cat > "${HOME}/mps/config" <<'EOF'
MPS_DEFAULT_IMAGE=protocol-dev
EOF
    unset MPS_DEFAULT_IMAGE 2>/dev/null || true
    export MPS_CPUS=2
    export MPS_MEMORY=2G
    mps_load_config
    [[ "${MPS_DEFAULT_IMAGE}" == "protocol-dev" ]]
    export HOME="$saved_home"
}

@test "mps_load_config: project .mps.env overrides ~/mps/config" {
    local saved_home="$HOME"
    export HOME="${TEST_TEMP_DIR}/fakehome"
    mkdir -p "${HOME}/mps"
    cat > "${HOME}/mps/config" <<'EOF'
MPS_DEFAULT_IMAGE=protocol-dev
EOF
    export MPS_PROJECT_DIR="${TEST_TEMP_DIR}"
    cat > "${TEST_TEMP_DIR}/.mps.env" <<'EOF'
MPS_DEFAULT_IMAGE=smart-contract-dev
EOF
    unset MPS_DEFAULT_IMAGE 2>/dev/null || true
    export MPS_CPUS=2
    export MPS_MEMORY=2G
    mps_load_config
    # .mps.env loads after ~/mps/config, so its value wins
    [[ "${MPS_DEFAULT_IMAGE}" == "smart-contract-dev" ]]
    export HOME="$saved_home"
}

# ================================================================
# mps_parse_extra_mounts
# ================================================================

@test "mps_parse_extra_mounts: returns mount spec from MPS_MOUNTS env" {
    # Create a source directory that the relative path resolves to
    mkdir -p "${TEST_TEMP_DIR}/project/src"
    export MPS_PROJECT_DIR="${TEST_TEMP_DIR}/project"
    export MPS_MOUNTS="./src:/mnt/src"
    result="$(mps_parse_extra_mounts)"
    # The result should contain the resolved absolute path and the target
    [[ "$result" == *"/src:/mnt/src"* ]]
}

@test "mps_parse_extra_mounts: returns empty for unset MPS_MOUNTS" {
    unset MPS_MOUNTS 2>/dev/null || true
    result="$(mps_parse_extra_mounts)"
    [[ -z "$result" ]]
}

@test "mps_parse_extra_mounts: resolves absolute paths" {
    mkdir -p "${TEST_TEMP_DIR}/abs-src"
    export MPS_MOUNTS="${TEST_TEMP_DIR}/abs-src:/mnt/data"
    result="$(mps_parse_extra_mounts)"
    [[ "$result" == "${TEST_TEMP_DIR}/abs-src:/mnt/data" ]]
}

# ================================================================
# _mps_resolve_project_mounts: reads MPS_MOUNTS from config files
# ================================================================

@test "_mps_resolve_project_mounts: reads MPS_MOUNTS from .mps.env" {
    local saved_home="$HOME"
    export HOME="${TEST_TEMP_DIR}/fakehome"
    mkdir -p "${HOME}/mps/instances"
    # Create a project directory with .mps.env containing MPS_MOUNTS
    local workdir="${TEST_TEMP_DIR}/project"
    mkdir -p "${workdir}/src"
    cat > "${workdir}/.mps.env" <<EOF
MPS_MOUNTS=./src:/mnt/src
EOF
    # Create instance metadata with workdir set
    local meta_file="${HOME}/mps/instances/test-inst.json"
    cat > "$meta_file" <<EOF
{"workdir": "${workdir}"}
EOF
    # Unset MPS_MOUNTS in current env so the function falls back to .mps.env
    unset MPS_MOUNTS 2>/dev/null || true
    result="$(_mps_resolve_project_mounts "test-inst")"
    # Should contain the auto-mount (workdir:workdir) plus the config mount
    [[ "$result" == *"${workdir}:${workdir}"* ]]
    [[ "$result" == *"/src:/mnt/src"* ]]
    export HOME="$saved_home"
}

@test "_mps_resolve_project_mounts: reads MPS_MOUNTS from ~/mps/config" {
    local saved_home="$HOME"
    export HOME="${TEST_TEMP_DIR}/fakehome"
    mkdir -p "${HOME}/mps/instances"
    # Create a project directory WITHOUT .mps.env
    local workdir="${TEST_TEMP_DIR}/project2"
    mkdir -p "${workdir}/data"
    # Put MPS_MOUNTS in ~/mps/config instead
    mkdir -p "${HOME}/mps"
    cat > "${HOME}/mps/config" <<EOF
MPS_MOUNTS=./data:/mnt/data
EOF
    # Create instance metadata with workdir set
    local meta_file="${HOME}/mps/instances/test-inst2.json"
    cat > "$meta_file" <<EOF
{"workdir": "${workdir}"}
EOF
    unset MPS_MOUNTS 2>/dev/null || true
    result="$(_mps_resolve_project_mounts "test-inst2")"
    # Should contain the auto-mount plus the config mount from ~/mps/config
    [[ "$result" == *"${workdir}:${workdir}"* ]]
    [[ "$result" == *"/data:/mnt/data"* ]]
    export HOME="$saved_home"
}

# ================================================================
# mps_auto_name — max_folder clamping (line 331)
# ================================================================

@test "mps_auto_name: clamps folder to 1 char when overhead exceeds max length" {
    local orig_max="$MPS_MAX_INSTANCE_NAME_LEN"
    MPS_MAX_INSTANCE_NAME_LEN=10
    result="$(mps_auto_name "/home/user/myproject" "very-long-template-name-for-testing")"
    MPS_MAX_INSTANCE_NAME_LEN="$orig_max"
    [[ "$result" =~ ^[a-zA-Z] ]]
    [[ -n "$result" ]]
}

@test "mps_auto_name: truncation with tiny max produces valid name with hash" {
    local orig_max="$MPS_MAX_INSTANCE_NAME_LEN"
    MPS_MAX_INSTANCE_NAME_LEN=15
    result="$(mps_auto_name "/home/user/myproject" "default")"
    MPS_MAX_INSTANCE_NAME_LEN="$orig_max"
    [[ "$result" =~ [a-f0-9]{4} ]]
    [[ "$result" =~ ^[a-zA-Z] ]]
}
