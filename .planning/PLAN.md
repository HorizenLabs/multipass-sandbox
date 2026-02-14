# Multi Pass Sandbox (mps) — Implementation Plan

## Context

A blockchain software development company needs an internal tool to spin up isolated sandbox development environments for developers and AI agents. Docker containers alone don't provide strong enough isolation, so the tool uses Multipass (Canonical) to create full VMs with Docker daemons running inside. The tool must work across Linux, macOS, and Windows, support pre-built distributable images, allow customization, and provide shell + SSH access for VS Code integration.

**Key decisions:**
- **VM Engine**: Canonical Multipass
- **CLI**: Bash (macOS/Linux), PowerShell (Windows)
- **Command name**: `mps` (short form), project name "Multi Pass Sandbox"
- **Image distribution**: Backblaze B2 + Cloudflare proxy
- **Only external dependency**: `jq` (JSON parsing of `multipass` output; PowerShell has `ConvertFrom-Json` built-in)

---

## Project Structure

```
mpsandbox/
├── bin/
│   └── mps                        # Main entry point (Bash, macOS/Linux)
│
├── lib/
│   ├── common.sh                  # Shared Bash functions (logging, config, validation)
│   └── multipass.sh               # Multipass wrapper (launch, exec, info, list, etc.)
│
├── commands/
│   ├── create.sh                  # mps create
│   ├── up.sh                      # mps up (create + start)
│   ├── down.sh                    # mps down (stop)
│   ├── destroy.sh                 # mps destroy
│   ├── shell.sh                   # mps shell
│   ├── exec.sh                    # mps exec
│   ├── list.sh                    # mps list
│   ├── status.sh                  # mps status
│   ├── ssh-config.sh              # mps ssh-config
│   ├── image.sh                   # mps image [list|pull|import]
│   ├── port.sh                    # mps port [forward|list]
│   └── transfer.sh                # mps transfer (host<->guest file copy)
│
├── templates/
│   ├── cloud-init/
│   │   └── base.yaml              # Minimal customization template (for VM launch)
│   └── profiles/
│       ├── lite.env                # 2 CPU, 2GB RAM, 20GB disk
│       ├── standard.env            # 4 CPU, 4GB RAM, 50GB disk
│       └── heavy.env               # 8 CPU, 8GB RAM, 100GB disk
│
├── images/
│   ├── arch-config.sh             # Shared arch detection (KVM/TCG, PACKER_ARCH_VARS)
│   ├── manifest.json              # Image manifest (SemVer versions + latest pointer)
│   ├── publish.sh                 # Publish images to Backblaze B2
│   └── base/
│       ├── build.sh               # Packer build script for base image
│       ├── cloud-init.yaml        # Full provisioning template (baked into images)
│       ├── packer.pkr.hcl         # Packer template (parameterized for amd64/arm64)
│       ├── packer-user-data.pkrtpl.hcl  # Build-time cloud-init wrapper
│       └── scripts/
│           └── post-provision-base.sh   # Post-provisioning cleanup for image distribution
│
├── docker/
│   └── entrypoint.sh              # uid:gid matching entrypoint (setpriv)
│
├── config/
│   └── defaults.env               # Default configuration values
│
├── .planning/                     # Implementation plan, decisions, status
├── Dockerfile.builder             # Builder image (Packer, QEMU, b2)
├── Dockerfile.linter              # Linter/test image (shellcheck, hadolint, BATS, etc.)
├── Makefile                       # Build images, run tests, lint
├── checkmake.ini                  # checkmake linter config
├── .yamllint                      # yamllint linter config
├── install.sh                     # Installer script (adds mps to PATH)
├── install.ps1                    # Windows installer
├── .gitignore
├── README.md
└── CLAUDE.md                      # Claude Code project context (auto-loaded)
```

---

## Phase 1 — MVP Core

### 1.1 Main entry point: `bin/mps`

- Bash script with `#!/usr/bin/env bash` and `set -euo pipefail`
- Resolves its own install directory to find `lib/` and `commands/`
- Parses the first argument as a subcommand, dispatches to `commands/<subcommand>.sh`
- Handles `--help`, `--version`, and unknown commands
- Sources `lib/common.sh` for shared functions

### 1.2 Shared library: `lib/common.sh`

Key functions:
- `mps_log_info`, `mps_log_warn`, `mps_log_error` — colored terminal output
- `mps_load_config` — loads config cascade: `config/defaults.env` → `~/.mps/config` → `.mps.env` (project) → CLI flags
- `mps_require_cmd` — checks that `multipass` and `jq` are installed, prints install instructions if not
- `mps_resolve_name` — if no name given, reads from `.mps.env` in CWD or defaults to "default"
- `mps_instance_name` — prefixes sandbox names with `mps-` to namespace in Multipass
- `mps_state_dir` — returns `~/.mps/instances/`
- `mps_resolve_mount_path` — resolves CWD or provided path; on Windows converts `C:\foo\bar` → `/c/foo/bar`
- `mps_host_to_guest_path` — converts host absolute path to guest mount path (identity on Linux/macOS, drive-letter conversion on Windows)

### 1.3 Multipass wrapper: `lib/multipass.sh`

Thin wrappers around `multipass` CLI that:
- Always use `--format json` for machine-readable output
- Parse with `jq`
- Add error handling and timeouts
- Only operate on `mps-` prefixed instances

Key functions:
- `mp_launch` — `multipass launch` with cloud-init, resources, mounts
- `mp_start`, `mp_stop`, `mp_delete` — lifecycle
- `mp_exec` — `multipass exec`
- `mp_shell` — `multipass shell`
- `mp_info` — `multipass info --format json | jq`
- `mp_list` — `multipass list --format json | jq` (filtered to `mps-` prefix)
- `mp_mount`, `mp_umount` — file sharing
- `mp_transfer` — file transfer
- `mp_ssh_info` — extract SSH connection details (IP, key path)

### 1.4 Configuration system

**Format**: Simple `KEY=VALUE` env files (no YAML parsing needed in Bash).

**`config/defaults.env`**:
```bash
MPS_DEFAULT_IMAGE=24.04
MPS_DEFAULT_CPUS=4
MPS_DEFAULT_MEMORY=4G
MPS_DEFAULT_DISK=50G
MPS_DEFAULT_PROFILE=standard
MPS_DEFAULT_CLOUD_INIT=base
MPS_MOUNT_CWD=true
MPS_IMAGE_BASE_URL=https://images.example.com/mps
MPS_INSTANCE_PREFIX=mps
MPS_SSH_KEY=
```

**Merge order** (later wins): defaults.env → ~/.mps/config → .mps.env → CLI flags

### 1.5 Mount behavior

- **Default**: Auto-mount host CWD into guest at same absolute path (read-write)
  - Linux/macOS: host `/home/user/project` → guest `/home/user/project`
  - Windows: host `C:\Users\pippo\Documents\code-project` → guest `/c/Users/pippo/Documents/code-project`
- **CLI override**: `mps create /path/to/folder` or `mps up ./relative/path` mounts the provided path instead of CWD
- **Workdir**: `mps shell` and `mps exec` auto-set working directory inside guest to the mounted path
- **Config**: `MPS_MOUNTS` in `.mps.env` is additive (extra mounts on top of auto-mount)
- **Opt-out**: `MPS_NO_AUTOMOUNT=true`

### 1.6 Cloud-init templates

**`base.yaml`**: Docker (official repo, v2 compose plugin only), Node.js (nvm + pnpm/yarn/bun), Python (pip/venv/uv), Go (golang.org), Rust (rustup + just + cargo-audit), build-essential + clang/llvm, vim/neovim/nano, tmux/htop/ripgrep/fd-find, shellcheck, hadolint, yq, Solana CLI/Anchor, Foundry (forge/cast/anvil/chisel), Hardhat

### 1.7 Commands

- `mps create [name] [path]` — Launch VM with cloud-init, mounts, resources
- `mps up [name] [path]` — Create-or-start (delegates to create if nonexistent)
- `mps down [name]` — Stop (with --force)
- `mps destroy [name]` — Delete + purge + cleanup (with confirmation)
- `mps shell [name]` — Interactive shell with auto-workdir
- `mps exec [name] -- <cmd>` — Run command with auto-workdir
- `mps list` — Formatted table or --json
- `mps status [name]` — Detailed info (resources, mounts, Docker health)
- `mps ssh-config [name]` — Generate SSH config for VS Code (--print, --append)
- `mps transfer <src...> <dst>` — Transfer files between host and guest (`:` prefix for guest paths)

---

## Phase 2 — Image System

- `mps image list` — Local cached images + `--remote` from manifest
- `mps image pull <name:tag>` — Download QCOW2 with SHA256 verification
- Manifest format: `manifest.json` on B2 (served via Cloudflare) with per-arch URLs and checksums
- Packer build pipeline for base image
- `make image-base` produces both amd64 and arm64 images regardless of host architecture
- Base image uses Ubuntu 24.04 (noble) instead of 22.04 (jammy)
- QEMU TCG optimized: `-cpu max,pauth-impdef=on,sve=off`, `disk_cache=unsafe`, `-display none`

## Phase 3 — Port Forwarding & Advanced Networking

- `mps port forward <name> <host>:<guest>` — SSH local port forwarding
- `mps port list [name]` — Active forwards from PID file
- Auto-forwarding from `MPS_PORTS` config on `mps up`

## Phase 4 — Polish & Build System

- `install.sh` / `install.ps1`
- Shellcheck clean (SC2154 directives + bug fixes)
- Dockerized build system: `Dockerfile.builder` (Packer, QEMU, b2), `Dockerfile.linter` (shellcheck, hadolint, BATS, pwsh, PSScriptAnalyzer, py-psscriptanalyzer, yamllint, checkmake, Packer)
- Makefile: stamp-based caching (`.stamp-builder`/`.stamp-linter`), per-arch image build targets with parallel `-j2`, per-arch clean targets, linter configs
- Secure dependency installation: GPG-verified repos, SHA256-checked binaries, version bumps across all tools
- SSH key refactor: user-provided keys via `mps ssh-config`, on-demand injection, no sudo
- Repo restructure: moved full cloud-init to `images/base/cloud-init.yaml`, new minimal `templates/cloud-init/base.yaml`
- Image build improvements: HWE edge kernel, old kernel removal, 10G disk size, `.qcow2.img` extension, qemu-img compaction, post-build SHA256 checksums, Rust cache cleanup
- Cloud-init provisioning: `package_upgrade`, SHA-256 verified yq/hadolint installs, `just` via apt, `cargo-audit`, removed `pyenv` (uv), added `libclang-dev`

## Phase 5 — Testing

- BATS test suite for `lib/common.sh`, `lib/multipass.sh`, and command scripts

## Phase 6 — CI/CD

- GitHub Actions CI pipeline (lint + test on push/PR)
- Automated image builds
- Backblaze B2 bucket + Cloudflare proxy setup (handled externally)

## Phase 7 — PowerShell Parity (Windows)

- `bin/mps.ps1` + `commands/*.ps1` + `lib/*.ps1`
- `ConvertFrom-Json` instead of `jq`
- Windows path handling
