#!/usr/bin/env bats
# Tests for configuration functions in lib/common.sh:
#   _mps_load_env_file, _mps_apply_profile, mps_load_config

load test_helper

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
