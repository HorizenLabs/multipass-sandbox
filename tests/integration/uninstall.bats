#!/usr/bin/env bats
# Integration tests for uninstall.sh
#
# All tests run uninstall.sh as a subprocess with stdin piped for confirm() prompts.
# Setup creates a "fully installed" state under fake HOME.

load ../test_helper

UNINSTALL_SCRIPT="${MPS_ROOT}/uninstall.sh"

# ================================================================
# Shared setup / teardown
# ================================================================

setup() {
    setup_home_override

    # Stubs directory
    stubs_dir="${TEST_TEMP_DIR}/stubs"
    mkdir -p "$stubs_dir"

    # brew stub
    cat > "${stubs_dir}/brew" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--prefix" ]]; then
    echo "${MOCK_BREW_PREFIX:-/usr/local}"
    exit 0
fi
echo "brew $*" >> "${MOCK_INSTALL_LOG:-/dev/null}"
exit "${MOCK_BREW_EXIT:-0}"
STUB
    chmod +x "${stubs_dir}/brew"

    # du stub
    printf '#!/usr/bin/env bash\necho "42K\t${2:-unknown}"\n' > "${stubs_dir}/du"
    chmod +x "${stubs_dir}/du"

    # multipass stub (reuse existing)
    ln -sf "${MPS_ROOT}/tests/stubs/multipass" "${stubs_dir}/multipass"

    # sudo stub (reuse existing)
    ln -sf "${MPS_ROOT}/tests/stubs/sudo" "${stubs_dir}/sudo"

    # Multipass stub env
    export MOCK_MP_FIXTURES_DIR="${MPS_ROOT}/tests/fixtures/multipass/running-mounted"
    export MOCK_MP_CALL_LOG="${TEST_TEMP_DIR}/call.log"
    : > "$MOCK_MP_CALL_LOG"

    export MOCK_BREW_PREFIX="${TEST_TEMP_DIR}/brew"
    export MOCK_INSTALL_LOG="${TEST_TEMP_DIR}/install.log"
    : > "$MOCK_INSTALL_LOG"

    # --- Create "fully installed" state ---
    install_dir="${HOME}/.local/bin"
    mkdir -p "$install_dir"
    ln -sf "${MPS_ROOT}/bin/mps" "${install_dir}/mps"

    # Bash completion (linux)
    comp_dir="${HOME}/.local/share/bash-completion/completions"
    mkdir -p "$comp_dir"
    ln -sf "${MPS_ROOT}/completions/mps.bash" "${comp_dir}/mps"

    # SSH configs
    mkdir -p "${HOME}/.ssh/config.d"
    echo "Host mps-test1" > "${HOME}/.ssh/config.d/mps-test1"
    echo "Host mps-test2" > "${HOME}/.ssh/config.d/mps-test2"
    echo "Host other-host" > "${HOME}/.ssh/config.d/other-host"

    # Instance metadata
    mkdir -p "${HOME}/.mps/instances"
    echo '{}' > "${HOME}/.mps/instances/mps-test.json"
    echo '{}' > "${HOME}/.mps/instances/mps-test.ports.json"
    echo 'MPS_NAME=test' > "${HOME}/.mps/instances/mps-test.env"

    # Cache
    mkdir -p "${HOME}/.mps/cache/images/base/1.0.0"
    echo "fake image" > "${HOME}/.mps/cache/images/base/1.0.0/amd64.img"

    # User config
    echo "MPS_PROFILE=standard" > "${HOME}/.mps/config"

    # Cloud-init dir (should survive uninstall — not empty after)
    mkdir -p "${HOME}/.mps/cloud-init"
}

teardown() { teardown_home_override; }

# ================================================================
# Helper: run uninstall.sh as subprocess
# ================================================================

_run_uninstall() {
    local stdin_data="${1:-}"
    shift || true
    local env_args=(
        "HOME=${HOME}"
        "PATH=${stubs_dir}:${PATH}"
        "MOCK_MP_FIXTURES_DIR=${MOCK_MP_FIXTURES_DIR}"
        "MOCK_MP_CALL_LOG=${MOCK_MP_CALL_LOG}"
        "MOCK_BREW_PREFIX=${MOCK_BREW_PREFIX}"
        "MOCK_INSTALL_LOG=${MOCK_INSTALL_LOG}"
    )
    if [[ -n "${MPS_INSTALL_DIR:-}" ]]; then
        env_args+=("MPS_INSTALL_DIR=${MPS_INSTALL_DIR}")
    fi
    local arg
    for arg in "$@"; do
        env_args+=("$arg")
    done
    if [[ -n "$stdin_data" ]]; then
        printf '%s' "$stdin_data" | env "${env_args[@]}" bash "$UNINSTALL_SCRIPT"
    else
        env "${env_args[@]}" bash "$UNINSTALL_SCRIPT" < /dev/null
    fi
}

# ================================================================
# 1. Symlink removal
# ================================================================

@test "uninstall: removes symlink pointing to MPS_ROOT" {
    # Prompts: VMs(y), cache(y), config(y)
    run _run_uninstall $'y\ny\ny\n'
    [[ "$status" -eq 0 ]]
    [[ ! -L "${HOME}/.local/bin/mps" ]]
    [[ "$output" == *"Removing symlink"* ]]
    [[ "$output" == *"Symlink:"* ]]
}

@test "uninstall: skips symlink with wrong target" {
    rm -f "${HOME}/.local/bin/mps"
    ln -sf "/some/other/path" "${HOME}/.local/bin/mps"
    run _run_uninstall $'y\ny\ny\n'
    [[ "$status" -eq 0 ]]
    # Symlink should still exist (not removed)
    [[ -L "${HOME}/.local/bin/mps" ]]
    [[ "$output" == *"Skipping"* ]]
}

@test "uninstall: skips non-symlink file" {
    rm -f "${HOME}/.local/bin/mps"
    echo "regular file" > "${HOME}/.local/bin/mps"
    run _run_uninstall $'y\ny\ny\n'
    [[ "$status" -eq 0 ]]
    [[ -f "${HOME}/.local/bin/mps" ]]
    [[ "$output" == *"not a symlink"* ]]
}

@test "uninstall: handles missing symlink" {
    rm -f "${HOME}/.local/bin/mps"
    run _run_uninstall $'y\ny\ny\n'
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"No symlink found"* ]]
}

# ================================================================
# 2. Bash completion
# ================================================================

@test "uninstall: removes linux completion symlink" {
    run _run_uninstall $'y\ny\ny\n'
    [[ "$status" -eq 0 ]]
    [[ ! -e "${HOME}/.local/share/bash-completion/completions/mps" ]]
    [[ "$output" == *"Removed bash completion"* ]]
}

@test "uninstall: removes brew completion" {
    mkdir -p "${MOCK_BREW_PREFIX}/etc/bash_completion.d"
    ln -sf "${MPS_ROOT}/completions/mps.bash" "${MOCK_BREW_PREFIX}/etc/bash_completion.d/mps"
    run _run_uninstall $'y\ny\ny\n'
    [[ "$status" -eq 0 ]]
    [[ ! -e "${MOCK_BREW_PREFIX}/etc/bash_completion.d/mps" ]]
}

@test "uninstall: handles no completion files" {
    rm -f "${HOME}/.local/share/bash-completion/completions/mps"
    rm -f "${stubs_dir}/brew"
    run _run_uninstall $'y\ny\ny\n'
    [[ "$status" -eq 0 ]]
    # Should not error — just skip silently
}

# ================================================================
# 3. VM cleanup
# ================================================================

@test "uninstall: finds mps VMs and deletes on confirm" {
    run _run_uninstall $'y\ny\ny\n'
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Found mps VMs"* ]]
    local log
    log="$(cat "$MOCK_MP_CALL_LOG")"
    [[ "$log" == *"stop mps-fixture-primary"* ]]
    [[ "$log" == *"delete mps-fixture-primary --purge"* ]]
    [[ "$log" == *"stop mps-fixture-secondary"* ]]
    [[ "$log" == *"delete mps-fixture-secondary --purge"* ]]
}

@test "uninstall: skips VM deletion on decline" {
    # First prompt is VMs — decline. Then cache(n), config(n).
    run _run_uninstall $'n\nn\nn\n'
    [[ "$status" -eq 0 ]]
    local log
    log="$(cat "$MOCK_MP_CALL_LOG")"
    # Should have list calls but no stop/delete
    [[ "$log" == *"list"* ]]
    [[ "$log" != *"stop "* ]]
    [[ "$log" != *"delete "* ]]
}

@test "uninstall: no mps VMs reports info" {
    # Empty fixture — no mps-prefixed VMs
    export MOCK_MP_FIXTURES_DIR="${TEST_TEMP_DIR}/empty_fixtures"
    mkdir -p "$MOCK_MP_FIXTURES_DIR"
    echo '{"list":[]}' > "${MOCK_MP_FIXTURES_DIR}/list.json"
    run _run_uninstall $'y\ny\n'
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"No mps VMs found"* ]]
}

@test "uninstall: skips when multipass unavailable" {
    rm -f "${stubs_dir}/multipass"
    run _run_uninstall $'y\ny\n'
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"multipass or jq not available"* ]]
}

# ================================================================
# 4. SSH config cleanup
# ================================================================

@test "uninstall: removes mps-* files from config.d" {
    run _run_uninstall $'y\ny\ny\n'
    [[ "$status" -eq 0 ]]
    [[ ! -e "${HOME}/.ssh/config.d/mps-test1" ]]
    [[ ! -e "${HOME}/.ssh/config.d/mps-test2" ]]
    [[ "$output" == *"Removed 2 SSH config"* ]]
}

@test "uninstall: preserves non-mps files" {
    run _run_uninstall $'y\ny\ny\n'
    [[ "$status" -eq 0 ]]
    [[ -f "${HOME}/.ssh/config.d/other-host" ]]
}

# ================================================================
# 5. Instance metadata
# ================================================================

@test "uninstall: removes .json .env .ports.json files" {
    run _run_uninstall $'y\ny\ny\n'
    [[ "$status" -eq 0 ]]
    [[ ! -e "${HOME}/.mps/instances/mps-test.json" ]]
    [[ ! -e "${HOME}/.mps/instances/mps-test.ports.json" ]]
    [[ ! -e "${HOME}/.mps/instances/mps-test.env" ]]
    [[ "$output" == *"instance metadata"* ]]
}

@test "uninstall: preserves non-matching files in instances" {
    echo "keep me" > "${HOME}/.mps/instances/README"
    run _run_uninstall $'y\ny\ny\n'
    [[ "$status" -eq 0 ]]
    [[ -f "${HOME}/.mps/instances/README" ]]
}

# ================================================================
# 6. Cached images
# ================================================================

@test "uninstall: removes cache on confirm" {
    run _run_uninstall $'y\ny\ny\n'
    [[ "$status" -eq 0 ]]
    [[ ! -d "${HOME}/.mps/cache" ]]
    [[ "$output" == *"Removed image cache"* ]]
}

@test "uninstall: preserves cache on decline" {
    # VMs(y), cache(n), config(n)
    run _run_uninstall $'y\nn\nn\n'
    [[ "$status" -eq 0 ]]
    [[ -d "${HOME}/.mps/cache" ]]
}

# ================================================================
# 7. User config
# ================================================================

@test "uninstall: removes user config on confirm" {
    run _run_uninstall $'y\ny\ny\n'
    [[ "$status" -eq 0 ]]
    [[ ! -f "${HOME}/.mps/config" ]]
    [[ "$output" == *"Removed user config"* ]]
}

@test "uninstall: preserves user config on decline" {
    # VMs(y), cache(y), config(n)
    run _run_uninstall $'y\ny\nn\n'
    [[ "$status" -eq 0 ]]
    [[ -f "${HOME}/.mps/config" ]]
}

@test "uninstall: handles missing config" {
    rm -f "${HOME}/.mps/config"
    run _run_uninstall $'y\ny\n'
    [[ "$status" -eq 0 ]]
    # No error — just skipped
}

# ================================================================
# 8. Directory cleanup
# ================================================================

@test "uninstall: removes empty ~/.mps" {
    # Remove cloud-init dir so .mps becomes empty after cleanup
    rm -rf "${HOME}/.mps/cloud-init"
    run _run_uninstall $'y\ny\ny\n'
    [[ "$status" -eq 0 ]]
    [[ ! -d "${HOME}/.mps" ]]
    [[ "$output" == *"Directory: ~/.mps"* ]]
}

@test "uninstall: preserves non-empty ~/.mps" {
    # cloud-init dir keeps .mps non-empty
    run _run_uninstall $'y\ny\ny\n'
    [[ "$status" -eq 0 ]]
    [[ -d "${HOME}/.mps" ]]
}

# ================================================================
# 9. Summary + misc
# ================================================================

@test "uninstall: summary lists removed items" {
    run _run_uninstall $'y\ny\ny\n'
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Removed:"* ]]
    [[ "$output" == *"Symlink:"* ]]
}

@test "uninstall: nothing removed when all declined/empty" {
    # Remove symlink and completion so nothing automatic happens
    rm -f "${HOME}/.local/bin/mps"
    rm -f "${HOME}/.local/share/bash-completion/completions/mps"
    rm -f "${stubs_dir}/brew"
    # Remove SSH configs and instance metadata
    rm -f "${HOME}/.ssh/config.d/mps-"*
    rm -f "${HOME}/.mps/instances/"*.json "${HOME}/.mps/instances/"*.env
    # Remove cache and config
    rm -rf "${HOME}/.mps/cache"
    rm -f "${HOME}/.mps/config"
    # Empty fixture
    export MOCK_MP_FIXTURES_DIR="${TEST_TEMP_DIR}/empty_fixtures"
    mkdir -p "$MOCK_MP_FIXTURES_DIR"
    echo '{"list":[]}' > "${MOCK_MP_FIXTURES_DIR}/list.json"
    run _run_uninstall ""
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Nothing was removed"* ]]
}

@test "uninstall: MPS_INSTALL_DIR override" {
    # Move symlink to custom dir
    custom_dir="${HOME}/custom-bin"
    mkdir -p "$custom_dir"
    ln -sf "${MPS_ROOT}/bin/mps" "${custom_dir}/mps"
    export MPS_INSTALL_DIR="$custom_dir"
    run _run_uninstall $'y\ny\ny\n'
    [[ "$status" -eq 0 ]]
    [[ ! -L "${custom_dir}/mps" ]]
}

@test "uninstall: shows source directory location" {
    run _run_uninstall $'y\ny\ny\n'
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"source directory remains at"* ]]
}
