#!/usr/bin/env bash
set -euo pipefail
_ts() { echo "[$(date '+%H:%M:%S')] $*"; }

# MPS Image: Post-install validation
# Asserts that every tool expected for the current FLAVOR is present.
# Runs as a Packer provisioner after all install scripts, before post-provision cleanup.
#
# Environment variables (set by Packer):
#   FLAVOR — image flavor (base, protocol-dev, etc.)

_ts "=== validate-image.sh (flavor: ${FLAVOR:-base}) ==="

PASS=0
FAIL=0
ARCH=$(dpkg --print-architecture)

# ---------- Assertion helpers ----------

# Check a command exists (system-wide PATH)
assert_cmd() {
    local name="$1"
    if command -v "$name" &>/dev/null; then
        echo "  OK: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name not found" >&2
        FAIL=$((FAIL + 1))
    fi
}

# Check a command exists in the ubuntu user's environment
assert_user_cmd() {
    local name="$1"
    local extra_path="${2:-}"
    if sudo -u ubuntu bash -c "
        export HOME=/home/ubuntu
        export PATH=\"${extra_path}\${PATH:+:\$PATH}\"
        export NVM_DIR=\"\$HOME/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\" 2>/dev/null
        command -v $name
    " &>/dev/null; then
        echo "  OK: $name (user)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name not found (user)" >&2
        FAIL=$((FAIL + 1))
    fi
}

# Check a path exists
assert_path() {
    local label="$1" path="$2"
    if [ -e "$path" ]; then
        echo "  OK: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label — $path not found" >&2
        FAIL=$((FAIL + 1))
    fi
}

# Conditional: only assert if on the right architecture
assert_cmd_arch() {
    local required_arch="$1" name="$2"
    if [ "$ARCH" = "$required_arch" ]; then
        assert_cmd "$name"
    else
        echo "  SKIP: $name ($required_arch only)"
    fi
}

assert_user_cmd_arch() {
    local required_arch="$1" name="$2"
    local extra_path="${3:-}"
    if [ "$ARCH" = "$required_arch" ]; then
        assert_user_cmd "$name" "$extra_path"
    else
        echo "  SKIP: $name ($required_arch only)"
    fi
}

# ---------- Base layer ----------
echo "--- base tools ---"
assert_cmd docker
assert_cmd nvim
assert_cmd yq
assert_cmd shellcheck
assert_cmd hadolint
assert_cmd snap
assert_user_cmd node "\$HOME/.nvm/versions/node/\$(ls \$HOME/.nvm/versions/node/ 2>/dev/null | tail -1)/bin:"
assert_user_cmd bun "\$HOME/.bun/bin:"
assert_user_cmd pnpm "\$HOME/.bun/bin:"
assert_user_cmd yarn "\$HOME/.bun/bin:"
assert_user_cmd uv "\$HOME/.local/bin:"
assert_path "claude dir" /home/ubuntu/.claude
assert_user_cmd crush "\$HOME/.bun/bin:"
assert_user_cmd opencode "\$HOME/.bun/bin:"
assert_user_cmd gemini "\$HOME/.bun/bin:"
assert_user_cmd codex "\$HOME/.bun/bin:"

# ---------- Protocol-dev layer ----------
case "${FLAVOR:-base}" in
    protocol-dev|smart-contract-dev|smart-contract-audit)
        echo "--- protocol-dev tools ---"
        assert_path "go binary" /usr/local/go/bin/go
        assert_path "go profile.d" /etc/profile.d/golang.sh
        assert_user_cmd rustc "\$HOME/.cargo/bin:"
        assert_user_cmd cargo "\$HOME/.cargo/bin:"
        assert_user_cmd cargo-audit "\$HOME/.cargo/bin:"
        ;;&  # fall through
esac

# ---------- Smart-contract-dev layer ----------
case "${FLAVOR:-base}" in
    smart-contract-dev|smart-contract-audit)
        echo "--- smart-contract-dev tools ---"
        assert_user_cmd_arch amd64 solana "\$HOME/.local/share/solana/install/active_release/bin:"
        assert_user_cmd_arch amd64 anchor "\$HOME/.cargo/bin:"
        assert_user_cmd forge "\$HOME/.foundry/bin:"
        assert_user_cmd cast "\$HOME/.foundry/bin:"
        assert_user_cmd anvil "\$HOME/.foundry/bin:"
        assert_user_cmd chisel "\$HOME/.foundry/bin:"
        assert_user_cmd hardhat "\$HOME/.bun/bin:"
        assert_user_cmd solhint "\$HOME/.bun/bin:"
        ;;&  # fall through
esac

# ---------- Smart-contract-audit layer ----------
case "${FLAVOR:-base}" in
    smart-contract-audit)
        echo "--- smart-contract-audit tools ---"
        assert_cmd cosign
        assert_user_cmd slither "\$HOME/.local/bin:"
        assert_user_cmd solc-select "\$HOME/.local/bin:"
        assert_user_cmd_arch amd64 myth "\$HOME/.local/bin:"
        assert_user_cmd_arch amd64 halmos "\$HOME/.local/bin:"
        assert_user_cmd aderyn "\$HOME/.aderyn/bin:\$HOME/.cargo/bin:"
        assert_cmd echidna
        assert_user_cmd medusa "/usr/local/go/bin:\$HOME/go/bin:"
        ;;
esac

# ---------- Summary ----------
echo ""
_ts "=== Validation: ${PASS} passed, ${FAIL} failed ==="

if [ "$FAIL" -gt 0 ]; then
    echo "ERROR: ${FAIL} tool(s) missing from ${FLAVOR:-base} image" >&2
    exit 1
fi
