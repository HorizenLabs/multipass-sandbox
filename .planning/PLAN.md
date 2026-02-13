# Multi Pass Sandbox (mps) — Implementation Plan

## Context

A blockchain software development company needs an internal tool to spin up isolated sandbox development environments for developers and AI agents. Docker containers alone don't provide strong enough isolation, so the tool uses Multipass (Canonical) to create full VMs with Docker daemons running inside. The tool must work across Linux, macOS, and Windows, support pre-built distributable images, allow customization, and provide shell + SSH access for VS Code integration.

**Key decisions:**
- **VM Engine**: Canonical Multipass
- **CLI**: Bash (macOS/Linux), PowerShell (Windows)
- **Command name**: `mps` (short form), project name "Multi Pass Sandbox"
- **Image distribution**: HTTP/S3 for MVP, OCI registry later
- **Only external dependency**: `jq` (JSON parsing of `multipass` output; PowerShell has `ConvertFrom-Json` built-in)

---

## Project Structure

```
/work/
├── bin/
│   ├── mps                        # Main entry point (Bash, macOS/Linux)
│   └── mps.ps1                    # Main entry point (PowerShell, Windows)
│
├── lib/
│   ├── common.sh                  # Shared Bash functions (logging, config, validation)
│   ├── common.ps1                 # Shared PowerShell functions
│   ├── multipass.sh               # Multipass wrapper (launch, exec, info, list, etc.)
│   └── multipass.ps1              # Multipass wrapper (PowerShell)
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
│   ├── image.sh                   # mps image [list|pull]
│   ├── port.sh                    # mps port [forward|list]
│   └── transfer.sh                # mps transfer (host<->guest file copy)
│   # (PowerShell equivalents: create.ps1, up.ps1, etc.)
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
│   └── base/
│       ├── build.sh               # Packer build script for base image
│       ├── cloud-init.yaml        # Full provisioning template (baked into images)
│       ├── packer.pkr.hcl         # Packer template (parameterized for amd64/arm64)
│       └── scripts/
│           └── setup-base.sh      # Post-provisioning cleanup for image distribution
│
├── config/
│   └── defaults.env               # Default configuration values
│
├── install.sh                     # Installer script (adds mps to PATH)
├── install.ps1                    # Windows installer
├── Makefile                       # Build images, run tests, lint
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
MPS_IMAGE_BASE_URL=https://your-s3-bucket.s3.amazonaws.com/mps-images
MPS_INSTANCE_PREFIX=mps
MPS_SSH_AUTO_CONFIG=true
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

**`base.yaml`**: Docker (official repo, v2 compose plugin only), Node.js (nvm + pnpm/yarn/bun), Python (pip/venv/uv/pyenv), Go (golang.org), Rust (rustup + just), build-essential + clang/llvm, vim/neovim/nano, tmux/htop/ripgrep/fd-find, shellcheck, hadolint, yq, Solana CLI/Anchor, Foundry (forge/cast/anvil/chisel), Hardhat

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
- Manifest format: `manifest.json` on S3 with per-arch URLs and checksums
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
- Shellcheck clean (done — SC2154 directives + bug fixes)
- Makefile targets (done — `.stamp-builder`/`.stamp-linter` auto-build images as dependency of lint/test)
- Dockerized build system: `Dockerfile.builder` (Packer, QEMU, b2), `Dockerfile.linter` (shellcheck, hadolint, BATS, pwsh, py-psscriptanalyzer, yamllint, checkmake, Packer)

### Phase 4 Reopened — Polish & Refactor

- SSH key refactor: user-provided keys via `mps ssh-config`, on-demand injection, no sudo
- Repo restructure: moved full cloud-init to `images/base/cloud-init.yaml`, new minimal `templates/cloud-init/base.yaml`
- Image build: HWE edge kernel, old kernel removal, 16G disk size, `.qcow2.img` extension, qemu-img compaction
- `mps port forward` requires prior `mps ssh-config` setup (clear error message if not configured)

### Phase 4 Reopened (2) — Secure Dependency Installation

- Packer installed via HashiCorp apt repo with GPG-verified signing key (both Dockerfiles)
- b2 CLI: standalone binary (v4.5.1) from GitHub replaces pip package, SHA256-verified; python3/pip/venv removed from builder
- shellcheck updated to v0.11.0
- BATS updated to v1.13.0
- hadolint updated to v2.14.0 with SHA256 checksum verification
- checkmake updated to v0.3.2 from `checkmake/checkmake` repo with checksum verification

### Phase 4 Reopened (3) — Image Build Improvements

- Removed blockchain image flavor from `manifest.json` (tools consolidated into base image)
- `build.sh`: Always generate SHA256 checksums after qemu-img compaction (packer-generated ones become stale)
- Renamed `scripts/setup-base.sh` → `scripts/post-provision-base.sh`
- `post-provision-base.sh`: Clear Rust/Cargo build caches (registry, git, package-cache) to reduce image size
- `cloud-init.yaml`: `package_upgrade: true` for fully up-to-date images
- `cloud-init.yaml`: yq installation with SHA-256 checksum verification (from rhash `checksums` file, field $19)
- `cloud-init.yaml`: hadolint installation with SHA-256 checksum verification (`.sha256` sidecar file)
- `cloud-init.yaml`: `just` moved from `cargo install` to apt package (available in Ubuntu 24.04 universe)
- `cloud-init.yaml`: Added `cargo-audit` (installed via cargo)
- `cloud-init.yaml`: Removed `pyenv` (uv handles Python version management)
- `cloud-init.yaml`: Added `libclang-dev` to packages

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
