#!/usr/bin/env bash
# tests/e2e.sh — End-to-end tests for the mps CLI
#
# Exercises real Multipass VMs: create, exec, cloud-init, SSH, ports,
# mounts, transfer, down/up lifecycle, destroy. Requires multipass + KVM
# on the host. Runs with coverage via BASH_ENV when _MPS_COV_DIR is set.
#
# Usage:
#   bash tests/e2e.sh                       # default: pull "base" image
#   MPS_E2E_IMAGE=base bash tests/e2e.sh    # same as above
#   MPS_E2E_IMAGE=/path/to.qcow2.img bash tests/e2e.sh  # import local
#   MPS_E2E_INSTALL=true bash tests/e2e.sh  # also test install/uninstall
#
# Environment:
#   MPS_E2E_IMAGE      Image name to pull or file path to import (default: base)
#   MPS_E2E_INSTALL    Run install.sh/uninstall.sh bookends (default: false)

set -euo pipefail

MPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
E2E_TMPDIR="${HOME}/mps-e2e-$$"
IMAGE_NAME="${MPS_E2E_IMAGE:-base}"
E2E_INSTALL="${MPS_E2E_INSTALL:-false}"

# VM instance variables (populated in phase_create)
FULL_NAME=""
SHORT=""

# Phase tracking
_e2e_vm_created=false

# ============================================================
# Assertion helpers (non-aborting, count pass/fail/skip)
# ============================================================

_e2e_pass=0
_e2e_fail=0
_e2e_skip=0

_e2e_log() {
    echo "[e2e] $*"
}

_e2e_log_phase() {
    echo ""
    echo "========================================"
    echo "  Phase: $*"
    echo "========================================"
}

_e2e_pass() {
    _e2e_pass=$((_e2e_pass + 1))
    echo "  PASS: $1"
}

_e2e_fail() {
    _e2e_fail=$((_e2e_fail + 1))
    echo "  FAIL: $1" >&2
    if [[ -n "${2:-}" ]]; then
        echo "        $2" >&2
    fi
}

_e2e_skip() {
    _e2e_skip=$((_e2e_skip + 1))
    echo "  SKIP: $1"
}

assert_eq() {
    local label="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        _e2e_pass "$label"
    else
        _e2e_fail "$label" "expected='${expected}' actual='${actual}'"
    fi
}

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        _e2e_pass "$label"
    else
        _e2e_fail "$label" "output does not contain '${needle}'"
    fi
}

assert_not_contains() {
    local label="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        _e2e_fail "$label" "output should not contain '${needle}'"
    else
        _e2e_pass "$label"
    fi
}

assert_exit_zero() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        _e2e_pass "$label"
    else
        _e2e_fail "$label" "command exited non-zero: $*"
    fi
}

assert_exit_nonzero() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        _e2e_fail "$label" "command should have failed but exited 0: $*"
    else
        _e2e_pass "$label"
    fi
}

assert_file_exists() {
    local label="$1" path="$2"
    if [[ -e "$path" ]]; then
        _e2e_pass "$label"
    else
        _e2e_fail "$label" "file does not exist: ${path}"
    fi
}

assert_file_not_exists() {
    local label="$1" path="$2"
    if [[ -e "$path" ]]; then
        _e2e_fail "$label" "file should not exist: ${path}"
    else
        _e2e_pass "$label"
    fi
}

# ============================================================
# Cleanup trap
# ============================================================

cleanup() {
    local rc=$?
    echo ""
    _e2e_log "Cleaning up..."

    # Destroy the test VM if it was created
    if [[ "$_e2e_vm_created" == "true" && -n "$FULL_NAME" ]]; then
        "${MPS_ROOT}/bin/mps" destroy --force --name "$SHORT" 2>/dev/null || \
            multipass delete --purge "$FULL_NAME" 2>/dev/null || true
    fi

    # Remove temp directory
    if [[ -d "$E2E_TMPDIR" ]]; then
        rm -rf "${E2E_TMPDIR:?}"
    fi

    return $rc
}
trap cleanup EXIT

# ============================================================
# Stale reaper: destroy leftover e2e instance from crashed runs
# ============================================================

_E2E_EXPECTED_NAME="mps-project-cloud-init-e2e"
_e2e_log "Checking for stale e2e instance..."
if multipass list --format json 2>/dev/null \
    | jq -e --arg n "$_E2E_EXPECTED_NAME" '.list[]? | select(.name == $n)' &>/dev/null; then
    _e2e_log "  Destroying stale instance: $_E2E_EXPECTED_NAME"
    multipass delete --purge "$_E2E_EXPECTED_NAME" 2>/dev/null || true
    rm -f "${HOME}/mps/instances/project-cloud-init-e2e.json" 2>/dev/null || true
    rm -f "${HOME}/mps/instances/project-cloud-init-e2e.ports.json" 2>/dev/null || true
    rm -f "${HOME}/.ssh/config.d/${_E2E_EXPECTED_NAME}" 2>/dev/null || true
fi

# ============================================================
# SSH bootstrapping (non-destructive, idempotent)
# ============================================================

E2E_SSH_KEY="$HOME/.ssh/id_ed25519_mps_e2e"

# Ensure ~/.ssh/ exists
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"

# Generate dedicated e2e keypair if missing (never overwrite existing)
if [[ ! -f "$E2E_SSH_KEY" ]]; then
    ssh-keygen -t ed25519 -N "" -f "$E2E_SSH_KEY" -C "mps-e2e" >/dev/null 2>&1
fi

# Ensure ~/.ssh/config has Include config.d/* (append if missing, never overwrite)
mkdir -p "$HOME/.ssh/config.d"
if [[ ! -f "$HOME/.ssh/config" ]] || ! grep -q 'Include config.d/\*' "$HOME/.ssh/config" 2>/dev/null; then
    echo "" >> "$HOME/.ssh/config"
    echo "Include config.d/*" >> "$HOME/.ssh/config"
    chmod 600 "$HOME/.ssh/config"
fi

# ============================================================
# Helper: execute command as ubuntu user with full tool PATH
# ============================================================

_ubuntu_exec() {
    "${MPS_ROOT}/bin/mps" exec -- sudo -u ubuntu bash -c "
        export HOME=/home/ubuntu
        export PATH=\"\$HOME/.claude/bin:\$HOME/.local/bin:\$HOME/.bun/bin:\$PATH\"
        export NVM_DIR=\"\$HOME/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
        $1
    "
}

# ============================================================
# Temp directory setup
# ============================================================

_e2e_log "Setting up temp directory: ${E2E_TMPDIR}"
mkdir -p "${E2E_TMPDIR}/project" "${E2E_TMPDIR}/mountdir" "${E2E_TMPDIR}/adhocdir"

# Pre-populate mount content
echo "config-mount-content" > "${E2E_TMPDIR}/mountdir/configfile.txt"
echo "adhoc-content" > "${E2E_TMPDIR}/adhocdir/adhocfile.txt"

# Create .mps.env in the project directory
cat > "${E2E_TMPDIR}/project/.mps.env" << EOF
MPS_CLOUD_INIT=${E2E_TMPDIR}/cloud-init-e2e.yaml
MPS_PORTS=19000:9000
MPS_MOUNTS=${E2E_TMPDIR}/mountdir:/mnt/config-mount
EOF

# Generate cloud-init from default.yaml (uncomment all #:example blocks)
awk '
  /^#:example/  { uncomment=1; next }
  /^#:end/      { uncomment=0; next }
  uncomment     { sub(/# ?/, ""); print; next }
  { print }
' "${MPS_ROOT}/templates/cloud-init/default.yaml" \
  > "${E2E_TMPDIR}/cloud-init-e2e.yaml"

# ============================================================
# Phase 0: Install (conditional)
# ============================================================

phase_install() {
    _e2e_log_phase "0: Install"
    if [[ "$E2E_INSTALL" != "true" ]]; then
        _e2e_skip "install (MPS_E2E_INSTALL != true)"
        return
    fi

    yes | bash "${MPS_ROOT}/install.sh" || {
        _e2e_fail "install.sh exited non-zero"
        return
    }
    _e2e_pass "install.sh succeeded"

    assert_exit_zero "mps --version after install" mps --version
    assert_exit_zero "multipass available" multipass version
    assert_exit_zero "jq available" jq --version
    assert_file_exists "instances dir exists" "${HOME}/mps/instances"

    local comp_found=false
    if [[ -f "/etc/bash_completion.d/mps" ]] || \
       [[ -f "${HOME}/.local/share/bash-completion/completions/mps" ]]; then
        comp_found=true
    fi
    if [[ "$comp_found" == "true" ]]; then
        _e2e_pass "completion file installed"
    else
        _e2e_fail "completion file not found"
    fi
}

# ============================================================
# Phase 1: CLI Smoke (no VM)
# ============================================================

phase_smoke() {
    _e2e_log_phase "1: CLI Smoke"

    local mps_out expected_version
    mps_out="$("${MPS_ROOT}/bin/mps" --version 2>&1)"
    expected_version="$(cat "${MPS_ROOT}/VERSION")"
    expected_version="${expected_version%$'\n'}"
    assert_contains "mps --version contains version" "$mps_out" "$expected_version"

    mps_out="$("${MPS_ROOT}/bin/mps" --help 2>&1)"
    assert_contains "mps --help contains Usage" "$mps_out" "Usage"

    local cmd
    for cmd in create up down destroy shell exec list status ssh-config image mount port transfer; do
        assert_exit_zero "mps ${cmd} --help exits 0" "${MPS_ROOT}/bin/mps" "$cmd" --help
    done

    mps_out="$("${MPS_ROOT}/bin/mps" --debug list 2>&1)" || true
    assert_contains "mps --debug produces debug output" "$mps_out" "[mps DEBUG]"
}

# ============================================================
# Phase 2: Image Management
# ============================================================

phase_image() {
    _e2e_log_phase "2: Image Management"

    if [[ -f "$IMAGE_NAME" ]]; then
        assert_exit_zero "image import" "${MPS_ROOT}/bin/mps" image import "$IMAGE_NAME"
        local fname
        fname="$(basename "$IMAGE_NAME")"
        IMAGE_NAME="${fname#mps-}"
        IMAGE_NAME="${IMAGE_NAME%%-*}"
    else
        local remote_out
        remote_out="$("${MPS_ROOT}/bin/mps" image list --remote 2>&1)" || true
        assert_contains "image list --remote contains image" "$remote_out" "$IMAGE_NAME"
        assert_exit_zero "image pull" "${MPS_ROOT}/bin/mps" image pull "$IMAGE_NAME"
    fi

    local list_out
    list_out="$("${MPS_ROOT}/bin/mps" image list 2>&1)"
    assert_contains "image list shows image" "$list_out" "$IMAGE_NAME"
}

# ============================================================
# Phase 3: Create (FATAL gate — skip phases 4-13 on failure)
# ============================================================

phase_create() {
    _e2e_log_phase "3: Create (fatal gate)"

    cd "${E2E_TMPDIR}/project"

    local create_out
    create_out="$("${MPS_ROOT}/bin/mps" create --profile micro \
        --cloud-init "${E2E_TMPDIR}/cloud-init-e2e.yaml" 2>&1)" || {
        _e2e_fail "FATAL: mps create failed"
        echo "$create_out" >&2
        return 1
    }
    _e2e_pass "mps create succeeded"

    local list_json
    list_json="$("${MPS_ROOT}/bin/mps" list --json 2>&1)"
    FULL_NAME="$(echo "$list_json" | jq -r '.[]? | .name' | head -1)"
    SHORT="$(echo "$FULL_NAME" | sed 's/^mps-//')"

    if [[ -z "$FULL_NAME" ]]; then
        _e2e_fail "FATAL: could not derive instance name from mps list"
        return 1
    fi
    _e2e_log "Instance: FULL_NAME=${FULL_NAME} SHORT=${SHORT}"

    local status_json state
    status_json="$("${MPS_ROOT}/bin/mps" status --json 2>&1)"
    state="$(echo "$status_json" | jq -r '.info[].state' 2>/dev/null | head -1)"
    if [[ "$state" != "Running" ]]; then
        _e2e_fail "FATAL: instance state is '${state}', expected 'Running'"
        return 1
    fi
    _e2e_pass "instance is Running"
    _e2e_vm_created=true

    local mount_out
    mount_out="$("${MPS_ROOT}/bin/mps" mount list 2>&1)"
    assert_contains "auto-mount visible" "$mount_out" "auto"
    assert_contains "config mount visible" "$mount_out" "config"
    assert_contains "config mount target" "$mount_out" "/mnt/config-mount"

    local config_content
    config_content="$("${MPS_ROOT}/bin/mps" exec -- cat /mnt/config-mount/configfile.txt 2>/dev/null)"
    assert_eq "config mount content" "$config_content" "config-mount-content"

    assert_file_exists "metadata file" "${HOME}/mps/instances/${SHORT}.json"
    assert_exit_zero "metadata is valid JSON" jq '.' "${HOME}/mps/instances/${SHORT}.json"
}

# ============================================================
# Phase 4: Exec
# ============================================================

phase_exec() {
    _e2e_log_phase "4: Exec"

    local out
    out="$("${MPS_ROOT}/bin/mps" exec -- echo hello 2>/dev/null)"
    assert_eq "exec echo hello" "$out" "hello"

    out="$("${MPS_ROOT}/bin/mps" exec -- uname -s 2>/dev/null)"
    assert_eq "exec uname -s" "$out" "Linux"

    local host_arch
    host_arch="$(uname -m)"
    out="$("${MPS_ROOT}/bin/mps" exec -- uname -m 2>/dev/null)"
    assert_eq "exec uname -m matches host" "$out" "$host_arch"

    out="$("${MPS_ROOT}/bin/mps" exec -- pwd 2>/dev/null)"
    assert_eq "exec pwd matches auto-mount target" "$out" "${E2E_TMPDIR}/project"

    out="$("${MPS_ROOT}/bin/mps" exec --workdir /tmp -- pwd 2>/dev/null)"
    assert_eq "exec --workdir /tmp" "$out" "/tmp"

    local rc=0
    "${MPS_ROOT}/bin/mps" exec -- sh -c 'exit 42' 2>/dev/null || rc=$?
    assert_eq "exec exit code 42 forwarded" "$rc" "42"
}

# ============================================================
# Phase 5: Cloud-Init Validation
# ============================================================

phase_cloud_init() {
    _e2e_log_phase "5: Cloud-Init Validation"

    local ci_status
    ci_status="$("${MPS_ROOT}/bin/mps" exec -- cloud-init status 2>/dev/null)" || true
    assert_contains "cloud-init done" "$ci_status" "done"

    local ci_errors
    ci_errors="$("${MPS_ROOT}/bin/mps" exec -- \
        jq '.v1.errors | length' /run/cloud-init/result.json 2>/dev/null)" || true
    assert_eq "cloud-init zero errors" "$ci_errors" "0"

    # Packages
    assert_exit_zero "postgresql-client installed" \
        "${MPS_ROOT}/bin/mps" exec -- dpkg-query -W postgresql-client
    assert_exit_zero "redis-tools installed" \
        "${MPS_ROOT}/bin/mps" exec -- dpkg-query -W redis-tools
    assert_exit_zero "tree installed" \
        "${MPS_ROOT}/bin/mps" exec -- dpkg-query -W tree

    # Runcmd: hello.txt
    local hello
    hello="$("${MPS_ROOT}/bin/mps" exec -- cat /tmp/hello.txt 2>/dev/null)"
    assert_eq "hello.txt content" "$hello" "Hello from cloud-init"

    # write_files: .env
    local env_content
    env_content="$("${MPS_ROOT}/bin/mps" exec -- cat /home/ubuntu/.env 2>/dev/null)"
    assert_contains "write_files .env" "$env_content" "DATABASE_URL=postgres://localhost/mydb"

    local env_owner
    env_owner="$("${MPS_ROOT}/bin/mps" exec -- stat -c '%U:%G' /home/ubuntu/.env 2>/dev/null)"
    assert_eq ".env owner" "$env_owner" "ubuntu:ubuntu"

    local env_perms
    env_perms="$("${MPS_ROOT}/bin/mps" exec -- stat -c '%a' /home/ubuntu/.env 2>/dev/null)"
    assert_eq ".env permissions" "$env_perms" "600"

    # hostname
    local hname
    hname="$("${MPS_ROOT}/bin/mps" exec -- hostname 2>/dev/null)"
    assert_eq "hostname" "$hname" "my-sandbox"

    # timezone
    local tz
    tz="$("${MPS_ROOT}/bin/mps" exec -- timedatectl show -p Timezone --value 2>/dev/null)"
    assert_eq "timezone" "$tz" "America/New_York"

    # --- Claude Code plugins ---
    local plugin_list
    plugin_list="$(_ubuntu_exec 'claude plugin list' 2>&1)" || true

    # HorizenLabs (always active)
    assert_contains "plugin: zkverify-product-ideation" "$plugin_list" "zkverify-product-ideation"
    assert_contains "plugin: zkverify-product-development" "$plugin_list" "zkverify-product-development"
    assert_contains "plugin: context-utils" "$plugin_list" "context-utils"

    # Trail of Bits (spot-check)
    assert_contains "plugin: ask-questions-if-underspecified" "$plugin_list" "ask-questions-if-underspecified"
    assert_contains "plugin: building-secure-contracts" "$plugin_list" "building-secure-contracts"
    assert_contains "plugin: static-analysis" "$plugin_list" "static-analysis"
    assert_contains "plugin: variant-analysis" "$plugin_list" "variant-analysis"

    # Superpowers
    assert_contains "plugin: superpowers" "$plugin_list" "superpowers"

    # --- Optional third-party tools (soft assertions: skip if not installed) ---
    # These install from npm/git and may fail due to external factors.

    # GSD framework
    if _ubuntu_exec 'command -v get-shit-done-cc' >/dev/null 2>&1; then
        _e2e_pass "gsd installed"
    else
        _e2e_skip "gsd not installed (optional)"
    fi

    # SuperClaude framework
    if _ubuntu_exec 'command -v superclaude' >/dev/null 2>&1; then
        _e2e_pass "superclaude installed"
    else
        _e2e_skip "superclaude not installed (optional)"
    fi

    # BMAD Method
    if _ubuntu_exec 'test -d "\$HOME/.bmad" || test -d "\$HOME/bmm"' >/dev/null 2>&1; then
        _e2e_pass "bmad installed"
    else
        _e2e_skip "bmad not installed (optional)"
    fi

    # GitHub Spec Kit
    if _ubuntu_exec 'command -v specify-cli' >/dev/null 2>&1; then
        _e2e_pass "spec-kit installed"
    else
        _e2e_skip "spec-kit not installed (optional)"
    fi
}

# ============================================================
# Phase 6: Status & List
# ============================================================

phase_status() {
    _e2e_log_phase "6: Status & List"

    local status_out
    status_out="$("${MPS_ROOT}/bin/mps" status 2>&1)"
    assert_contains "status contains instance name" "$status_out" "$SHORT"
    assert_contains "status contains Running" "$status_out" "Running"

    local status_json json_state
    status_json="$("${MPS_ROOT}/bin/mps" status --json 2>&1)"
    assert_exit_zero "status --json is valid JSON" bash -c "echo '$status_json' | jq ."
    json_state="$(echo "$status_json" | jq -r '.info[].state' | head -1)"
    assert_eq "status --json state" "$json_state" "Running"

    local list_out
    list_out="$("${MPS_ROOT}/bin/mps" list 2>&1)"
    assert_contains "list contains short name" "$list_out" "$SHORT"
}

# ============================================================
# Phase 7: SSH Config
# ============================================================

phase_ssh() {
    _e2e_log_phase "7: SSH Config"

    local ssh_out
    ssh_out="$("${MPS_ROOT}/bin/mps" ssh-config --ssh-key "$E2E_SSH_KEY" --print 2>&1)"
    assert_contains "ssh-config --print contains Host" "$ssh_out" "Host ${SHORT}"

    "${MPS_ROOT}/bin/mps" ssh-config --ssh-key "$E2E_SSH_KEY" --append 2>/dev/null || true
    local ssh_config_file="${HOME}/.ssh/config.d/${FULL_NAME}"
    assert_file_exists "SSH config file created" "$ssh_config_file"

    local ssh_result
    ssh_result="$(ssh -o ConnectTimeout=5 -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
        "$SHORT" echo ssh-ok 2>/dev/null)" || true
    assert_eq "SSH connectivity" "$ssh_result" "ssh-ok"

    local ssh_out2
    ssh_out2="$("${MPS_ROOT}/bin/mps" ssh-config --ssh-key "$E2E_SSH_KEY" --print 2>&1)"
    assert_contains "ssh-config idempotent" "$ssh_out2" "Host ${SHORT}"
}

# ============================================================
# Phase 8: Lazy Port Init
# ============================================================

phase_lazy_ports() {
    _e2e_log_phase "8: Lazy Port Init"

    "${MPS_ROOT}/bin/mps" exec -- echo trigger-lazy-ports >/dev/null 2>&1 || true
    sleep 2

    local port_out
    port_out="$("${MPS_ROOT}/bin/mps" port list "$SHORT" 2>&1)"
    assert_contains "port 19000 visible" "$port_out" "19000"
    assert_contains "port 19000 active" "$port_out" "active"
}

# ============================================================
# Phase 9: Transfer
# ============================================================

phase_transfer() {
    _e2e_log_phase "9: Transfer"

    # Host -> guest
    echo "host-payload" > "${E2E_TMPDIR}/upload.txt"
    "${MPS_ROOT}/bin/mps" transfer "${E2E_TMPDIR}/upload.txt" :/tmp/upload.txt 2>/dev/null || true
    local dl
    dl="$("${MPS_ROOT}/bin/mps" exec -- cat /tmp/upload.txt 2>/dev/null)"
    assert_eq "transfer host->guest" "$dl" "host-payload"

    # Guest -> host
    "${MPS_ROOT}/bin/mps" exec -- sh -c 'echo guest-payload > /tmp/download.txt' 2>/dev/null || true
    "${MPS_ROOT}/bin/mps" transfer :/tmp/download.txt "${E2E_TMPDIR}/download.txt" 2>/dev/null || true
    local ul
    ul="$(cat "${E2E_TMPDIR}/download.txt")"
    assert_eq "transfer guest->host" "$ul" "guest-payload"
}

# ============================================================
# Phase 10: Mounts
# ============================================================

phase_mounts() {
    _e2e_log_phase "10: Mounts"

    local mount_out
    mount_out="$("${MPS_ROOT}/bin/mps" mount list 2>&1)"
    assert_contains "config mount present" "$mount_out" "/mnt/config-mount"
    assert_contains "config mount origin" "$mount_out" "config"

    # Add adhoc mount
    "${MPS_ROOT}/bin/mps" mount add "${E2E_TMPDIR}/adhocdir:/mnt/adhoc" 2>/dev/null || true
    local adhoc_content
    adhoc_content="$("${MPS_ROOT}/bin/mps" exec -- cat /mnt/adhoc/adhocfile.txt 2>/dev/null)"
    assert_eq "adhoc mount content" "$adhoc_content" "adhoc-content"

    # Bidirectional: guest writes, host reads
    "${MPS_ROOT}/bin/mps" exec -- sh -c 'echo from-guest > /mnt/adhoc/guestfile.txt' 2>/dev/null || true
    local guest_written
    guest_written="$(cat "${E2E_TMPDIR}/adhocdir/guestfile.txt")"
    assert_eq "bidirectional mount" "$guest_written" "from-guest"

    # Three origins visible
    mount_out="$("${MPS_ROOT}/bin/mps" mount list 2>&1)"
    assert_contains "auto mount in list" "$mount_out" "auto"
    assert_contains "config mount in list" "$mount_out" "config"
    assert_contains "adhoc mount in list" "$mount_out" "adhoc"

    # Remove adhoc mount
    "${MPS_ROOT}/bin/mps" mount remove /mnt/adhoc 2>/dev/null || true
    mount_out="$("${MPS_ROOT}/bin/mps" mount list 2>&1)"
    assert_not_contains "adhoc mount removed" "$mount_out" "/mnt/adhoc"
}

# ============================================================
# Phase 11: Port Forwarding
# ============================================================

phase_ports() {
    _e2e_log_phase "11: Port Forwarding"

    # Start HTTP service in VM
    "${MPS_ROOT}/bin/mps" exec -- \
        sh -c 'nohup python3 -m http.server 8111 </dev/null >/dev/null 2>&1 &' 2>/dev/null &
    local _http_pid=$!
    sleep 3
    kill "$_http_pid" 2>/dev/null || true; wait "$_http_pid" 2>/dev/null || true
    sleep 2

    # Unprivileged forward
    "${MPS_ROOT}/bin/mps" port forward "$SHORT" 18111:8111 2>/dev/null || true
    sleep 1
    local curl_out
    curl_out="$(curl -sf --max-time 5 http://localhost:18111/ 2>/dev/null)" || true
    if [[ -n "$curl_out" ]]; then
        _e2e_pass "unprivileged port forward works"
    else
        _e2e_fail "unprivileged port forward: no response from localhost:18111"
    fi

    # Privileged forward (requires passwordless sudo — soft assertion)
    "${MPS_ROOT}/bin/mps" port forward --privileged "$SHORT" 80:8111 2>/dev/null || true
    sleep 1
    curl_out="$(curl -sf --max-time 5 http://localhost:80/ 2>/dev/null)" || true
    if [[ -n "$curl_out" ]]; then
        _e2e_pass "privileged port forward works"
    else
        _e2e_fail "privileged port forward: no response from localhost:80"
    fi

    # Port list shows entries
    local port_out
    port_out="$("${MPS_ROOT}/bin/mps" port list "$SHORT" 2>&1)"
    assert_contains "port list 18111" "$port_out" "18111"
    assert_contains "port list 80" "$port_out" "80"
}

# ============================================================
# Phase 12: Down/Up + Tunnel Lifecycle
# ============================================================

phase_down_up_tunnels() {
    _e2e_log_phase "12: Down/Up + Tunnel Lifecycle"

    # Verify tunnels alive before down
    local port_out
    port_out="$("${MPS_ROOT}/bin/mps" port list "$SHORT" 2>&1)"
    assert_contains "pre-down: 18111 active" "$port_out" "18111"
    assert_contains "pre-down: 19000 active" "$port_out" "19000"

    # Down
    "${MPS_ROOT}/bin/mps" down 2>/dev/null || true

    # Verify stopped
    local status_json state
    status_json="$("${MPS_ROOT}/bin/mps" status --json 2>&1)"
    state="$(echo "$status_json" | jq -r '.info[].state' | head -1)"
    assert_eq "down: state Stopped" "$state" "Stopped"

    # All ports gone (ports file removed on down)
    port_out="$("${MPS_ROOT}/bin/mps" port list "$SHORT" 2>&1)"
    assert_contains "down: no port forwards" "$port_out" "No active port forwards"

    # Error on stopped VM: exec
    local exec_err
    exec_err="$("${MPS_ROOT}/bin/mps" exec -- echo hello 2>&1)" || true
    assert_contains "exec on stopped: not running" "$exec_err" "not running"

    # Error on stopped VM: port forward
    local pf_err
    pf_err="$("${MPS_ROOT}/bin/mps" port forward "$SHORT" 29000:9000 2>&1)" || true
    assert_contains "port forward on stopped: not running" "$pf_err" "not running"

    # Up
    "${MPS_ROOT}/bin/mps" up 2>/dev/null || true

    # Verify running
    status_json="$("${MPS_ROOT}/bin/mps" status --json 2>&1)"
    state="$(echo "$status_json" | jq -r '.info[].state' | head -1)"
    assert_eq "up: state Running" "$state" "Running"

    # Auto-mount restored (verify by reading file through mount)
    local auto_mount_file
    auto_mount_file="$("${MPS_ROOT}/bin/mps" exec -- cat "${E2E_TMPDIR}/project/.mps.env" 2>/dev/null)" || true
    assert_contains "auto-mount restored" "$auto_mount_file" "MPS_PORTS"

    # Config mount restored
    local config_content
    config_content="$("${MPS_ROOT}/bin/mps" exec -- cat /mnt/config-mount/configfile.txt 2>/dev/null)" || true
    assert_eq "config mount restored" "$config_content" "config-mount-content"

    # Mount list shows auto + config but NOT adhoc
    local mount_out
    mount_out="$("${MPS_ROOT}/bin/mps" mount list 2>&1)"
    assert_contains "mount list: auto after up" "$mount_out" "auto"
    assert_contains "mount list: config after up" "$mount_out" "config"
    assert_not_contains "mount list: no adhoc after up" "$mount_out" "/mnt/adhoc"

    # Lazy tunnel re-establishment via first exec
    "${MPS_ROOT}/bin/mps" exec -- echo alive >/dev/null 2>&1 || true
    sleep 2
    port_out="$("${MPS_ROOT}/bin/mps" port list "$SHORT" 2>&1)"
    assert_contains "lazy re-establish: 19000 active" "$port_out" "19000"

    # Manual re-forward (explicit forwards need manual re-forward after down/up)
    "${MPS_ROOT}/bin/mps" port forward "$SHORT" 18111:8111 2>/dev/null || true
    "${MPS_ROOT}/bin/mps" port forward --privileged "$SHORT" 80:8111 2>/dev/null || true

    # Restart HTTP service (killed by full shutdown)
    "${MPS_ROOT}/bin/mps" exec -- \
        sh -c 'nohup python3 -m http.server 8111 </dev/null >/dev/null 2>&1 &' 2>/dev/null &
    local _http_pid=$!
    sleep 3
    kill "$_http_pid" 2>/dev/null || true; wait "$_http_pid" 2>/dev/null || true
    sleep 2

    # Verify end-to-end
    local curl_out
    curl_out="$(curl -sf --max-time 5 http://localhost:18111/ 2>/dev/null)" || true
    if [[ -n "$curl_out" ]]; then
        _e2e_pass "post-up: unprivileged forward works"
    else
        _e2e_fail "post-up: no response from localhost:18111"
    fi

    curl_out="$(curl -sf --max-time 5 http://localhost:80/ 2>/dev/null)" || true
    if [[ -n "$curl_out" ]]; then
        _e2e_pass "post-up: privileged forward works"
    else
        _e2e_fail "post-up: no response from localhost:80"
    fi
}

# ============================================================
# Phase 13: Destroy + Cleanup Verification
# ============================================================

phase_destroy() {
    _e2e_log_phase "13: Destroy + Cleanup Verification"

    "${MPS_ROOT}/bin/mps" destroy --force 2>/dev/null || true

    local list_out
    list_out="$("${MPS_ROOT}/bin/mps" list 2>&1)"
    assert_not_contains "destroyed: not in list" "$list_out" "$SHORT"

    assert_file_not_exists "metadata removed" "${HOME}/mps/instances/${SHORT}.json"
    assert_file_not_exists "SSH config removed" "${HOME}/.ssh/config.d/${FULL_NAME}"

    # Mark as destroyed so cleanup trap doesn't double-destroy
    FULL_NAME=""
    _e2e_vm_created=false
}

# ============================================================
# Phase 14: Image Remove
# ============================================================

phase_image_remove() {
    _e2e_log_phase "14: Image Remove"

    "${MPS_ROOT}/bin/mps" image remove "$IMAGE_NAME" --force 2>/dev/null || true

    local list_out
    list_out="$("${MPS_ROOT}/bin/mps" image list 2>&1)"
    assert_not_contains "image removed" "$list_out" "$IMAGE_NAME"
}

# ============================================================
# Phase 15: Uninstall (conditional)
# ============================================================

phase_uninstall() {
    _e2e_log_phase "15: Uninstall"
    if [[ "$E2E_INSTALL" != "true" ]]; then
        _e2e_skip "uninstall (MPS_E2E_INSTALL != true)"
        return
    fi

    yes | bash "${MPS_ROOT}/uninstall.sh" || true

    assert_exit_nonzero "mps not found after uninstall" command -v mps

    local comp_exists=false
    if [[ -f "/etc/bash_completion.d/mps" ]] || \
       [[ -f "${HOME}/.local/share/bash-completion/completions/mps" ]]; then
        comp_exists=true
    fi
    if [[ "$comp_exists" == "false" ]]; then
        _e2e_pass "completion file removed"
    else
        _e2e_fail "completion file still exists"
    fi
}

# ============================================================
# Main execution
# ============================================================

_e2e_log "Starting E2E tests"
_e2e_log "  MPS_ROOT:       ${MPS_ROOT}"
_e2e_log "  E2E_TMPDIR:     ${E2E_TMPDIR}"
_e2e_log "  IMAGE_NAME:     ${IMAGE_NAME}"
_e2e_log "  E2E_INSTALL:    ${E2E_INSTALL}"
_e2e_log "  Host arch:      $(uname -m)"
echo ""

# Phase 0-2: independent (no VM needed)
phase_install
phase_smoke
phase_image

# Phase 3: Create (fatal gate)
if ! phase_create; then
    _e2e_log "FATAL: Create failed — skipping VM-dependent phases (4-13)"
    _e2e_skip "phases 4-13 (create failed)"

    phase_image_remove
    phase_uninstall

    echo ""
    echo "========================================"
    echo "  E2E Summary"
    echo "========================================"
    echo "  Pass: ${_e2e_pass}"
    echo "  Fail: ${_e2e_fail}"
    echo "  Skip: ${_e2e_skip}"
    echo "  Total: $((_e2e_pass + _e2e_fail + _e2e_skip))"
    echo "========================================"

    if [[ $_e2e_fail -gt 0 ]]; then
        exit 1
    fi
    exit 0
fi

# Phases 4-13: VM-dependent
phase_exec
phase_cloud_init
phase_status
phase_ssh
phase_lazy_ports
phase_transfer
phase_mounts
phase_ports
phase_down_up_tunnels
phase_destroy

# Phases 14-15: cleanup
phase_image_remove
phase_uninstall

# --- Summary ---
echo ""
echo "========================================"
echo "  E2E Summary"
echo "========================================"
echo "  Pass: ${_e2e_pass}"
echo "  Fail: ${_e2e_fail}"
echo "  Skip: ${_e2e_skip}"
echo "  Total: $((_e2e_pass + _e2e_fail + _e2e_skip))"
echo "========================================"

if [[ $_e2e_fail -gt 0 ]]; then
    exit 1
fi
exit 0
