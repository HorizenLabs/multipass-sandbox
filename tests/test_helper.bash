#!/usr/bin/env bash
# test_helper.bash — Shared setup/teardown for BATS tests of lib/common.sh
#
# Sources lib/common.sh with a minimal environment so pure functions are
# available without requiring multipass/jq on the test runner.

# Resolve MPS_ROOT relative to this helper (tests/ lives one level below root)
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MPS_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

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

# ---------- Source common.sh ----------
# Suppress _mps_compute_resources by pre-setting both values
export MPS_CPUS=2
export MPS_MEMORY=2G

# Source common.sh (provides all functions under test)
# shellcheck source=../lib/common.sh
source "${MPS_ROOT}/lib/common.sh"
