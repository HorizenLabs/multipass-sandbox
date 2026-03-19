#!/usr/bin/env bash
set -euo pipefail

# MPS Image: Base layer install script
# Installs: HWE kernel, Docker, Neovim, yq, shellcheck, hadolint,
#           nvm/bun/globals, uv, Claude Code, AI assistants, multipass-sshfs
#
# Environment variables (set by Packer):
#   FLAVOR             — image flavor (base, protocol-dev, etc.)
#   YQ_VERSION         — yq release tag (e.g., v4.52.4)
#   SHELLCHECK_VERSION — shellcheck release tag (e.g., v0.11.0)
#   HADOLINT_VERSION   — hadolint release tag (e.g., v2.14.0)

_ts() { echo "[$(date '+%H:%M:%S')] $*"; }

_ts "=== install-base.sh (flavor: ${FLAVOR:-base}) ==="

# ---------- HWE edge kernel (with recommends for firmware/headers) ----------
if ! dpkg -l linux-virtual-hwe-24.04-edge 2>/dev/null | grep -q '^ii'; then
    _ts "--- Installing HWE edge kernel ---"
    apt-get install -y --install-recommends linux-virtual-hwe-24.04-edge
fi

# ---------- Docker (official repo) ----------
if ! command -v docker &>/dev/null; then
    _ts "--- Installing Docker ---"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    # shellcheck disable=SC2154  # VERSION_CODENAME sourced from os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable docker
    systemctl start docker
    usermod -aG docker ubuntu
fi

# ---------- Neovim (latest stable via PPA) ----------
if ! command -v nvim &>/dev/null; then
    _ts "--- Installing Neovim ---"
    add-apt-repository -y ppa:neovim-ppa/stable
    apt-get update
    apt-get install -y neovim
fi

# ---------- yq (SHA256-verified) ----------
if ! command -v yq &>/dev/null; then
    _ts "--- Installing yq ${YQ_VERSION} ---"
    ARCH=$(dpkg --print-architecture)
    YQ_FILE="yq_linux_${ARCH}"
    curl -fSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_FILE}" -o /tmp/"${YQ_FILE}"
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/checksums" -o /tmp/yq_checksums
    # yq uses goreleaser multi-hash checksums; SHA-256 is field 19
    EXPECTED=$(awk "/^${YQ_FILE} /{print \$19}" /tmp/yq_checksums)
    echo "${EXPECTED}  /tmp/${YQ_FILE}" | sha256sum -c -
    install -m 755 /tmp/"${YQ_FILE}" /usr/local/bin/yq
    rm /tmp/"${YQ_FILE}" /tmp/yq_checksums
fi

# ---------- shellcheck ----------
if ! command -v shellcheck &>/dev/null; then
    _ts "--- Installing shellcheck ${SHELLCHECK_VERSION} ---"
    ARCH=$(uname -m)
    curl -fSL "https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/shellcheck-${SHELLCHECK_VERSION}.linux.${ARCH}.tar.xz" \
        | tar -xJf - --strip-components=1 -C /usr/local/bin "shellcheck-${SHELLCHECK_VERSION}/shellcheck"
    chmod +x /usr/local/bin/shellcheck
fi

# ---------- hadolint (SHA256-verified) ----------
if ! command -v hadolint &>/dev/null; then
    _ts "--- Installing hadolint ${HADOLINT_VERSION} ---"
    ARCH=$(dpkg --print-architecture)
    if [ "$ARCH" = "amd64" ]; then HL_ARCH="x86_64"; else HL_ARCH="arm64"; fi
    HL_FILE="hadolint-Linux-${HL_ARCH}"
    curl -fSL "https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}/${HL_FILE}" -o /tmp/"${HL_FILE}"
    curl -fsSL "https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}/${HL_FILE}.sha256" -o /tmp/"${HL_FILE}.sha256"
    echo "$(awk '{print $1}' /tmp/"${HL_FILE}.sha256")  /tmp/${HL_FILE}" | sha256sum -c -
    install -m 755 /tmp/"${HL_FILE}" /usr/local/bin/hadolint
    rm /tmp/"${HL_FILE}" /tmp/"${HL_FILE}.sha256"
fi

# ---------- Node.js via nvm + bun (as ubuntu user) ----------
if ! sudo -u ubuntu bash -c 'export HOME=/home/ubuntu; [ -s "$HOME/.nvm/nvm.sh" ]'; then
    _ts "--- Installing nvm + Node.js + bun ---"
    sudo -u ubuntu bash -c '
        set -euo pipefail
        export HOME=/home/ubuntu
        curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
        nvm install --lts
        nvm alias default lts/*
        # Install bun runtime
        curl -fsSL https://bun.sh/install | bash
        export PATH="$HOME/.bun/bin:$PATH"
        # Install global package managers via bun
        bun install -g pnpm yarn
    '
fi

# ---------- Python: uv ----------
if ! sudo -u ubuntu bash -c 'export HOME=/home/ubuntu; [ -f "$HOME/.local/bin/uv" ]'; then
    _ts "--- Installing uv ---"
    sudo -u ubuntu bash -c '
        set -euo pipefail
        export HOME=/home/ubuntu
        curl -LsSf https://astral.sh/uv/install.sh | sh
    '
fi

# ---------- AI coding assistants ----------
# Claude Code (native binary installer)
# Check for .claude directory (always created by installer) — command -v won't find
# the binary in chained builds because PATH doesn't include ~/.claude/local/bin
if ! [ -d /home/ubuntu/.claude ]; then
    _ts "--- Installing Claude Code ---"
    # Workaround: claude.ai serves Cloudflare browser challenges to curl.
    # Use the direct bootstrap URL instead of the 302 redirect.
    # https://github.com/anthropics/claude-code/issues/36306
    sudo -u ubuntu bash -c '
        set -euo pipefail
        export HOME=/home/ubuntu
        curl -fsSL https://downloads.claude.ai/claude-code-releases/bootstrap.sh | bash
    '
fi

# Crush, OpenCode, Gemini CLI, Codex CLI (via bun)
if ! sudo -u ubuntu bash -c 'export HOME=/home/ubuntu; export PATH="$HOME/.bun/bin:$PATH"; command -v crush &>/dev/null'; then
    _ts "--- Installing AI assistants (crush, opencode, gemini, codex) ---"
    sudo -u ubuntu bash -c '
        set -euo pipefail
        export HOME=/home/ubuntu
        export PATH="$HOME/.bun/bin:$PATH"
        bun install -g @charmland/crush opencode-ai @google/gemini-cli @openai/codex
    '
fi

# ---------- multipass-sshfs (mount support for multipass) ----------
if ! snap list multipass-sshfs &>/dev/null; then
    _ts "--- Installing multipass-sshfs ---"
    systemctl enable snapd.socket
    snap wait system seed.loaded
    snap install multipass-sshfs
fi

_ts "=== install-base.sh complete ==="
