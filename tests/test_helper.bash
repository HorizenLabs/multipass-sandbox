#!/usr/bin/env bash
# test_helper.bash — Shared setup/teardown for BATS tests of lib/common.sh
#
# Sources lib/common.sh with a minimal environment so pure functions are
# available without requiring multipass/jq on the test runner.

# Resolve MPS_ROOT relative to this helper (tests/ lives one level below root)
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MPS_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
export MPS_ROOT

# Stub out MPS_VERSION (normally read from VERSION file by bin/mps)
export MPS_VERSION="0.0.0-test"

# ---------- Temp directory for test isolation ----------

setup_temp_dir() {
    TEST_TEMP_DIR="$(mktemp -d)"
    export TEST_TEMP_DIR
}

teardown_temp_dir() {
    if [[ -n "${TEST_TEMP_DIR:-}" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "${TEST_TEMP_DIR:?}"
    fi
}

# ---------- HOME isolation ----------

setup_home_override() {
    setup_temp_dir
    export REAL_HOME="$HOME"
    export HOME="${TEST_TEMP_DIR}/fakehome"
    mkdir -p "$HOME"
}

teardown_home_override() {
    export HOME="$REAL_HOME"
    teardown_temp_dir
}

# ---------- Multipass stub setup ----------

setup_multipass_stub() {
    local fixture_dir="${1:-running-mounted}"
    export PATH="${MPS_ROOT}/tests/stubs:${PATH}"
    export MOCK_MP_FIXTURES_DIR="${MPS_ROOT}/tests/fixtures/multipass/${fixture_dir}"
    export MOCK_MP_CALL_LOG="${TEST_TEMP_DIR}/call.log"
    : > "$MOCK_MP_CALL_LOG"
}

setup_ssh_stub() {
    export PATH="${MPS_ROOT}/tests/stubs:${PATH}"
    export MOCK_SSH_CALL_LOG="${TEST_TEMP_DIR}/ssh_call.log"
    : > "$MOCK_SSH_CALL_LOG"
}

# ---------- Integration stub functions ----------

setup_integration_stubs() {
    mps_resolve_image()            { echo "file://${HOME}/mps/cache/images/base/1.0.0/amd64.img"; }
    mps_auto_forward_ports()       { :; }
    mps_forward_port()             { :; }
    mps_reset_port_forwards()      { :; }
    mps_kill_port_forwards()       { :; }
    mps_cleanup_port_sockets()     { :; }
    mps_confirm()                  { return 0; }
    mps_check_image_requirements() { :; }
    _mps_fetch_manifest()          { return 1; }
    _mps_warn_image_staleness()    { :; }
    _mps_warn_instance_staleness() { :; }
    _mps_check_instance_staleness(){ echo "up-to-date"; }

    export -f mps_resolve_image mps_auto_forward_ports mps_forward_port
    export -f mps_reset_port_forwards mps_kill_port_forwards
    export -f mps_cleanup_port_sockets mps_confirm mps_check_image_requirements
    export -f _mps_fetch_manifest _mps_warn_image_staleness
    export -f _mps_warn_instance_staleness _mps_check_instance_staleness
}

# ---------- Source command files ----------

source_commands() {
    local f
    for f in "${MPS_ROOT}"/commands/*.sh; do
        # shellcheck disable=SC1090
        source "$f"
    done
}

# ---------- Source common.sh ----------
# Suppress _mps_compute_resources by pre-setting both values
export MPS_CPUS=2
export MPS_MEMORY=2G

# Source common.sh (provides all functions under test)
# shellcheck source=../lib/common.sh
source "${MPS_ROOT}/lib/common.sh"
