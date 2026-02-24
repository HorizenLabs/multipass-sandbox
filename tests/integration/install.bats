#!/usr/bin/env bats
# Integration tests for install.sh
#
# Mode A (sourced): Source install.sh (guard prevents execution), call functions directly.
# Mode B (subprocess): Run install.sh via bash (guard runs _mps_install_main).
#
# shellcheck disable=SC1090  # dynamic source of $INSTALL_SCRIPT is intentional

load ../test_helper

INSTALL_SCRIPT="${MPS_ROOT}/install.sh"

# ================================================================
# Shared setup / teardown
# ================================================================

setup() {
    setup_home_override
    # Stubs directory for this test file
    stubs_dir="${TEST_TEMP_DIR}/stubs"
    mkdir -p "$stubs_dir"

    # --- Reusable stubs ---

    # snap stub
    printf '#!/usr/bin/env bash\necho "snap $*" >> "${MOCK_INSTALL_LOG:-/dev/null}"\nexit "${MOCK_SNAP_EXIT:-0}"\n' \
        > "${stubs_dir}/snap"
    chmod +x "${stubs_dir}/snap"

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

    # apt-get stub
    printf '#!/usr/bin/env bash\necho "apt-get $*" >> "${MOCK_INSTALL_LOG:-/dev/null}"\nexit "${MOCK_APT_EXIT:-0}"\n' \
        > "${stubs_dir}/apt-get"
    chmod +x "${stubs_dir}/apt-get"

    # uname stub (delegates to real uname for non-stubbed flags)
    cat > "${stubs_dir}/uname" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "-s" ]]; then
    echo "${MOCK_UNAME_S:-Linux}"
    exit 0
fi
/usr/bin/uname "$@"
STUB
    chmod +x "${stubs_dir}/uname"

    # mps stub (for verification step)
    printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "--version" ]]; then echo "mps version 0.0.0-test"; fi\nexit 0\n' \
        > "${stubs_dir}/mps"
    chmod +x "${stubs_dir}/mps"

    # sudo stub (reuse existing)
    ln -sf "${MPS_ROOT}/tests/stubs/sudo" "${stubs_dir}/sudo"

    # multipass stub (so install_dependency finds it — no confirm prompt)
    ln -sf "${MPS_ROOT}/tests/stubs/multipass" "${stubs_dir}/multipass"

    # Mock install log
    export MOCK_INSTALL_LOG="${TEST_TEMP_DIR}/install.log"
    : > "$MOCK_INSTALL_LOG"

    # Default env
    export MOCK_UNAME_S="Linux"
    export MOCK_BREW_PREFIX="/usr/local"
}

teardown() { teardown_home_override; }

# ================================================================
# Helper: hide commands from `command -v`
# ================================================================

# Override command builtin to hide specific commands.
# Usage: _hide_cmds=(multipass jq) — set before sourcing/calling.
command() {
    if [[ "${1:-}" == "-v" ]]; then
        local cmd="$2"
        local c
        for c in ${_hide_cmds[@]+"${_hide_cmds[@]}"}; do
            [[ "$c" == "$cmd" ]] && return 1
        done
    fi
    builtin command "$@"
}

# ================================================================
# Helper: run install.sh as subprocess
# ================================================================

_run_install() {
    local stdin_data="${1:-}"
    shift || true
    local env_args=(
        "HOME=${HOME}"
        "PATH=${stubs_dir}:${PATH}"
        "MOCK_UNAME_S=${MOCK_UNAME_S}"
        "MOCK_BREW_PREFIX=${MOCK_BREW_PREFIX}"
        "MOCK_INSTALL_LOG=${MOCK_INSTALL_LOG}"
        "SHELL=${SHELL:-/bin/bash}"
    )
    if [[ -n "${MPS_INSTALL_DIR:-}" ]]; then
        env_args+=("MPS_INSTALL_DIR=${MPS_INSTALL_DIR}")
    fi
    # Add any extra env vars passed as remaining args
    local arg
    for arg in "$@"; do
        env_args+=("$arg")
    done
    if [[ -n "$stdin_data" ]]; then
        printf '%s' "$stdin_data" | env "${env_args[@]}" bash "$INSTALL_SCRIPT"
    else
        env "${env_args[@]}" bash "$INSTALL_SCRIPT" < /dev/null
    fi
}

# ================================================================
# Mode A: Sourced function tests — detect_os
# ================================================================

@test "install: detect_os returns linux on Linux" {
    export PATH="${stubs_dir}:${PATH}"
    export MOCK_UNAME_S="Linux"
    # shellcheck source=../../install.sh
    source "$INSTALL_SCRIPT"
    run detect_os
    [[ "$status" -eq 0 ]]
    [[ "$output" == "linux" ]]
}

@test "install: detect_os returns macos on Darwin" {
    export PATH="${stubs_dir}:${PATH}"
    export MOCK_UNAME_S="Darwin"
    source "$INSTALL_SCRIPT"
    run detect_os
    [[ "$status" -eq 0 ]]
    [[ "$output" == "macos" ]]
}

@test "install: detect_os returns unknown for unrecognized OS" {
    export PATH="${stubs_dir}:${PATH}"
    export MOCK_UNAME_S="FreeBSD"
    source "$INSTALL_SCRIPT"
    run detect_os
    [[ "$status" -eq 0 ]]
    [[ "$output" == "unknown" ]]
}

# ================================================================
# Mode A: Sourced function tests — confirm
# ================================================================

@test "install: confirm accepts y" {
    source "$INSTALL_SCRIPT"
    run bash -c 'source "'"$INSTALL_SCRIPT"'" && echo y | confirm "ok?"'
    [[ "$status" -eq 0 ]]
}

@test "install: confirm accepts Yes" {
    run bash -c 'source "'"$INSTALL_SCRIPT"'" && echo Yes | confirm "ok?"'
    [[ "$status" -eq 0 ]]
}

@test "install: confirm rejects n" {
    run bash -c 'source "'"$INSTALL_SCRIPT"'" && echo n | confirm "ok?"'
    [[ "$status" -eq 1 ]]
}

@test "install: confirm rejects empty" {
    run bash -c 'source "'"$INSTALL_SCRIPT"'" && echo "" | confirm "ok?"'
    [[ "$status" -eq 1 ]]
}

# ================================================================
# Mode A: Sourced function tests — install_dependency
# ================================================================

@test "install: install_dependency returns 0 when command found" {
    export PATH="${stubs_dir}:${PATH}"
    source "$INSTALL_SCRIPT"
    # jq is available in linter container
    run install_dependency "jq"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Found"* ]]
}

@test "install: install_dependency multipass missing linux+snap offers snap install" {
    export PATH="${stubs_dir}:${PATH}"
    _hide_cmds=(multipass)
    source "$INSTALL_SCRIPT"
    OS=linux
    confirm() { return 0; }
    run install_dependency "multipass"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_INSTALL_LOG")"
    [[ "$log" == *"snap install multipass"* ]]
}

@test "install: install_dependency multipass missing linux+snap user declines" {
    export PATH="${stubs_dir}:${PATH}"
    _hide_cmds=(multipass)
    source "$INSTALL_SCRIPT"
    OS=linux
    confirm() { return 1; }
    run install_dependency "multipass"
    [[ "$status" -eq 1 ]]
}

@test "install: install_dependency multipass missing linux no snap warns" {
    export PATH="${stubs_dir}:${PATH}"
    _hide_cmds=(multipass snap)
    source "$INSTALL_SCRIPT"
    OS=linux
    run install_dependency "multipass"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"snap not found"* ]]
}

@test "install: install_dependency multipass missing macos+brew offers brew install" {
    export PATH="${stubs_dir}:${PATH}"
    _hide_cmds=(multipass)
    source "$INSTALL_SCRIPT"
    OS=macos
    confirm() { return 0; }
    run install_dependency "multipass"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_INSTALL_LOG")"
    [[ "$log" == *"brew install --cask multipass"* ]]
}

@test "install: install_dependency jq missing linux+apt offers apt install" {
    export PATH="${stubs_dir}:${PATH}"
    _hide_cmds=(jq)
    source "$INSTALL_SCRIPT"
    OS=linux
    confirm() { return 0; }
    run install_dependency "jq"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_INSTALL_LOG")"
    [[ "$log" == *"apt-get install -y jq"* ]]
}

@test "install: install_dependency jq missing macos+brew offers brew install" {
    export PATH="${stubs_dir}:${PATH}"
    _hide_cmds=(jq)
    source "$INSTALL_SCRIPT"
    OS=macos
    confirm() { return 0; }
    run install_dependency "jq"
    [[ "$status" -eq 0 ]]
    log="$(cat "$MOCK_INSTALL_LOG")"
    [[ "$log" == *"brew install jq"* ]]
}

@test "install: install_dependency unknown platform returns 1" {
    export PATH="${stubs_dir}:${PATH}"
    _hide_cmds=(multipass)
    source "$INSTALL_SCRIPT"
    # shellcheck disable=SC2034  # OS is read by install_dependency()
    OS=unknown
    run install_dependency "multipass"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Cannot auto-install"* ]]
}

# ================================================================
# Mode B: Subprocess tests — directory structure
# ================================================================

@test "install: creates ~/.mps directory structure" {
    run _run_install ""
    [[ "$status" -eq 0 ]]
    [[ -d "${HOME}/.mps/instances" ]]
    [[ -d "${HOME}/.mps/cache/images" ]]
    [[ -d "${HOME}/.mps/cloud-init" ]]
    [[ -d "${HOME}/.ssh/config.d" ]]
}

@test "install: creates INSTALL_DIR" {
    export MPS_INSTALL_DIR="${HOME}/.local/bin"
    run _run_install ""
    [[ "$status" -eq 0 ]]
    [[ -d "${HOME}/.local/bin" ]]
}

@test "install: creates symlink to bin/mps" {
    run _run_install ""
    [[ "$status" -eq 0 ]]
    local link="${HOME}/.local/bin/mps"
    [[ -L "$link" ]]
    local target
    target="$(readlink "$link")"
    [[ "$target" == "${MPS_ROOT}/bin/mps" ]]
}

@test "install: replaces existing symlink" {
    mkdir -p "${HOME}/.local/bin"
    ln -sf /dev/null "${HOME}/.local/bin/mps"
    run _run_install ""
    [[ "$status" -eq 0 ]]
    local target
    target="$(readlink "${HOME}/.local/bin/mps")"
    [[ "$target" == "${MPS_ROOT}/bin/mps" ]]
}

@test "install: exits 1 if non-symlink file at target" {
    mkdir -p "${HOME}/.local/bin"
    echo "not a symlink" > "${HOME}/.local/bin/mps"
    run _run_install ""
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"not a symlink"* ]]
}

@test "install: MPS_INSTALL_DIR override" {
    export MPS_INSTALL_DIR="${HOME}/custom-bin"
    run _run_install ""
    [[ "$status" -eq 0 ]]
    [[ -L "${HOME}/custom-bin/mps" ]]
    local target
    target="$(readlink "${HOME}/custom-bin/mps")"
    [[ "$target" == "${MPS_ROOT}/bin/mps" ]]
}

# ================================================================
# Mode B: Subprocess tests — bash completion
# ================================================================

@test "install: bash completion on linux" {
    run _run_install ""
    [[ "$status" -eq 0 ]]
    local comp="${HOME}/.local/share/bash-completion/completions/mps"
    [[ -L "$comp" ]]
}

@test "install: bash completion on macos with brew" {
    export MOCK_UNAME_S="Darwin"
    export MOCK_BREW_PREFIX="${TEST_TEMP_DIR}/brew"
    mkdir -p "${MOCK_BREW_PREFIX}/etc/bash_completion.d"
    run _run_install ""
    [[ "$status" -eq 0 ]]
    [[ -L "${MOCK_BREW_PREFIX}/etc/bash_completion.d/mps" ]]
}

@test "install: bash completion fallback without brew" {
    export MOCK_UNAME_S="Darwin"
    # Remove brew from stubs so it's not found
    rm -f "${stubs_dir}/brew"
    run _run_install ""
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Could not auto-install"* ]]
}

@test "install: zsh hint when SHELL is zsh" {
    run _run_install "" "SHELL=/bin/zsh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"bashcompinit"* ]]
}

# ================================================================
# Mode B: Subprocess tests — PATH check
# ================================================================

@test "install: PATH already includes INSTALL_DIR suppresses warning" {
    export MPS_INSTALL_DIR="${HOME}/.local/bin"
    # Add install dir to PATH so the warning is suppressed
    run _run_install "" "PATH=${HOME}/.local/bin:${stubs_dir}:${PATH}"
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"not in your PATH"* ]]
}

@test "install: PATH prompt accepted appends to bashrc" {
    run _run_install $'y\n'
    [[ "$status" -eq 0 ]]
    [[ -f "${HOME}/.bashrc" ]]
    local rc_content
    rc_content="$(cat "${HOME}/.bashrc")"
    [[ "$rc_content" == *"export PATH="* ]]
}

@test "install: PATH prompt uses .zshrc for zsh" {
    run _run_install $'y\n' "SHELL=/bin/zsh"
    [[ "$status" -eq 0 ]]
    [[ -f "${HOME}/.zshrc" ]]
    local rc_content
    rc_content="$(cat "${HOME}/.zshrc")"
    [[ "$rc_content" == *"export PATH="* ]]
}

@test "install: PATH prompt declined does not modify rc" {
    run _run_install $'n\n'
    [[ "$status" -eq 0 ]]
    [[ ! -f "${HOME}/.bashrc" ]]
}

# ================================================================
# Mode B: Subprocess tests — missing deps + verification
# ================================================================

@test "install: missing deps warns but continues" {
    # Remove stubs for multipass and jq, and hide real jq
    rm -f "${stubs_dir}/multipass"
    # Create a wrapper that hides jq
    cat > "${stubs_dir}/jq" <<'STUB'
#!/usr/bin/env bash
exit 127
STUB
    chmod +x "${stubs_dir}/jq"
    # Pipe n for all prompts (dep installs + PATH)
    run _run_install $'n\nn\nn\n'
    [[ "$output" == *"Some dependencies are missing"* ]]
    # Dirs and symlink still created
    [[ -d "${HOME}/.mps/instances" ]]
    [[ -L "${HOME}/.local/bin/mps" ]]
}

@test "install: verification shows complete when mps on PATH" {
    # mps stub is on stubs_dir PATH
    run _run_install "" "PATH=${HOME}/.local/bin:${stubs_dir}:${PATH}"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Installation complete"* ]]
}
