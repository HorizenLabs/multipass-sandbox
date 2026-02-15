# Multi Pass Sandbox (mps)

Internal CLI tool for spinning up isolated VM-based development environments using Canonical Multipass. Provides stronger isolation than Docker containers alone — full VMs with Docker daemons running inside.

## Tech Stack

- **CLI**: Bash (macOS/Linux), PowerShell planned (Windows)
- **VM Engine**: Canonical Multipass
- **Config**: KEY=VALUE .env files (no YAML parsing in Bash)
- **Dependencies**: `multipass`, `jq`
- **Image builds**: Packer (QCOW2, `.qcow2.img` extension), published to Backblaze B2 (served via Cloudflare)
- **Image versioning**: SemVer (x.y.z) with `latest` pointer
- **Build/Test**: All run inside Docker containers (`mps-builder` for image builds, `mps-linter` for lint/test)
- **Tests**: BATS (planned)

## Project Structure

- `bin/mps` — Main entry point, subcommand dispatch
- `lib/common.sh` — Logging, config cascade, path conversion, mount resolution, auto-naming
- `lib/multipass.sh` — Thin wrappers around `multipass` CLI with `--format json` + `jq`
- `commands/*.sh` — One file per subcommand, each exports `cmd_<name>()` function
- `templates/cloud-init/` — Minimal cloud-init templates for VM launch customization
- `images/layers/` — Composable cloud-init layer files (base, protocol-dev, smart-contract-dev, smart-contract-audit)
- `images/build.sh` — Image build script (takes flavor arg, merges layers with yq)
- `images/packer.pkr.hcl` — Packer template (shared across all flavors)
- `images/packer-user-data.pkrtpl.hcl` — Packer user-data template (cloud-init wrapper for builds)
- `images/arch-config.sh` — Per-arch Packer variable resolution (KVM vs TCG, EFI firmware)
- `images/artifacts/` — Built QCOW2 images (gitignored)
- `images/scripts/post-provision.sh` — Post-build cleanup (runs after cloud-init)
- `images/manifest.json` — Image registry manifest (SemVer versions + `latest` pointer per flavor)
- `images/publish.sh` — Publish images to Backblaze B2 + update manifest
- `templates/profiles/` — Resource profiles (lite, standard, heavy)
- `config/defaults.env` — Shipped defaults
- `Dockerfile.builder` + `docker/entrypoint.sh` — Builder image (Packer, QEMU, b2)
- `Dockerfile.linter` — Linter/test image (shellcheck, hadolint, BATS, PSScriptAnalyzer, yamllint, etc.)
- `Makefile` — All targets run inside Docker containers via `docker run`
- `install.sh` / `install.ps1` — Installer scripts
- `checkmake.ini`, `.yamllint` — Linter configuration files
- `vendor/hl-claude-marketplace` — Git submodule: private Claude Code plugin marketplace (relative URL)
- `.planning/` — Implementation plan, architecture decisions, status tracking

## Commands

- `mps create` / `mps up` / `mps down` / `mps destroy` — VM lifecycle
- `mps shell` / `mps exec` — Interactive shell / run command (auto-workdir)
- `mps list` / `mps status` — List all / detailed info
- `mps ssh-config` — Generate SSH config for VS Code (also injects SSH keys)
- `mps image [list|pull|import]` — Manage pre-built QCOW2 images
- `mps port [forward|list]` — SSH port forwarding
- `mps transfer` — File copy between host and guest (`:` prefix = guest path)

## Key Conventions

- **Auto-naming**: `mps-<folder-basename>-<template>-<profile>` (e.g., `mps-myproject-base-standard`)
  - Override with `--name` flag or `MPS_NAME` in `.mps.env`
  - Long names truncated with short hash suffix (max 40 chars for Multipass)
  - `--no-mount` without `--name` errors (can't derive folder name)
- Config cascade: `config/defaults.env` → `~/.mps/config` → `.mps.env` → CLI flags
- Default mount: host CWD → guest at same absolute path (read-write)
- Windows path conversion: `C:\foo\bar` → `/c/foo/bar`
- `MPS_MOUNTS` is additive (on top of auto-mount), `MPS_NO_AUTOMOUNT=true` to opt out
- `mps shell`/`mps exec` auto-set workdir to the mounted project path
- Commands use `while/case/shift` arg parsing, private `_<cmd>_usage()` helpers
- Color output uses `$'\033[...]'` ANSI-C quoting (not double-quoted `\033`)

## Build System

Build/test/lint runs inside Docker containers — linter image for lint/test, builder image for Packer builds:
```
make linter           # Build the linter image (shellcheck, hadolint, BATS, etc.)
make builder          # Build the builder image (Packer, QEMU, b2)
make lint             # Run all linters (shellcheck, hadolint, yamllint, checkmake, packer fmt, py-psscriptanalyzer)
make test             # Run BATS tests
make image-base       # Build base VM image (both archs in parallel via sub-make -j2)
make image-base-amd64 # Build base VM image (amd64 only)
make image-base-arm64 # Build base VM image (arm64 only)
make image-protocol-dev           # Build protocol-dev image (base + C/C++/Go/Rust)
make image-smart-contract-dev     # Build smart-contract-dev image (+ Solana/Foundry/Hardhat)
make image-smart-contract-audit   # Build smart-contract-audit image (+ Slither/Echidna/Medusa)
make import-base              # Import host-arch base image into mps cache
make publish-base VERSION=1.0.0   # Publish to Backblaze B2
```

The Makefile detects host uid:gid and the entrypoint uses setpriv to step down from root, so build artifacts match host ownership.

## Workflow

- After modifying any linted file, run `make lint` before committing. Linted files:
  - **Bash**: `bin/mps`, `lib/*.sh`, `commands/*.sh`, `images/**/*.sh`, `install.sh`
  - **PowerShell**: `*.ps1`
  - **Dockerfile**: `Dockerfile.builder`, `Dockerfile.linter`
  - **Makefile**: `Makefile`
  - **YAML**: `templates/**/*.yaml`, `images/layers/*.yaml`
  - **HCL**: `images/**/*.pkr.hcl`
- Linting requires Docker. The linter image is built automatically if missing (`make lint` depends on the stamp file).
- Fix all lint errors before committing — do not bypass with `--no-verify` or inline disables unless there is a documented reason.

## Planning & Status

- Full implementation plan: `.planning/PLAN.md`
- Architecture decisions: `.planning/DECISIONS.md`
- Implementation status: `.planning/STATUS.md`
