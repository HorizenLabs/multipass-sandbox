# Multi Pass Sandbox (mps) — Implementation Plan

## Context

A blockchain software development company needs an internal tool to spin up isolated sandbox development environments for developers and AI agents. Docker containers alone don't provide strong enough isolation, so the tool uses Multipass (Canonical) to create full VMs with Docker daemons running inside. The tool must work across Linux, macOS, and Windows, support pre-built distributable images, allow customization, and provide shell + SSH access for VS Code integration.

**Key decisions:**
- **VM Engine**: Canonical Multipass
- **CLI**: Bash (macOS/Linux), PowerShell (Windows)
- **Command name**: `mps` (short form), project name "Multi Pass Sandbox"
- **Image distribution**: Backblaze B2 + Cloudflare proxy
- **Only external dependency**: `jq` (JSON parsing of `multipass` output; PowerShell has `ConvertFrom-Json` built-in)

> Project structure and conventions: see `CLAUDE.md`
> Architecture decisions and rationale: see `.planning/DECISIONS.md`
> Implementation status: see `.planning/STATUS.md`

---

## Completed Phases (1–4)

**Phase 1 — MVP Core**: Entry point (`bin/mps`), shared libraries (`lib/common.sh`, `lib/multipass.sh`), all core commands (create, up, down, destroy, shell, exec, list, status, ssh-config), config cascade system, resource profiles, cloud-init templates, mount behavior with path-preserving semantics, VM auto-naming.

**Phase 2 — Image System**: `mps image list/pull/import`, Packer build pipeline for base QCOW2 images, dual-arch builds (amd64+arm64 via QEMU TCG), Ubuntu 24.04, manifest with SemVer versioning, SHA256 verification, Backblaze B2 publishing.

**Phase 3 — Port Forwarding**: `mps port forward/list`, SSH local port forwarding with PID tracking, auto-forward from `MPS_PORTS` config, cleanup on stop/destroy.

**Phase 4 — Polish & Build System**: Dockerized build system (builder + linter images), Makefile with stamp-based caching, secure dependency installation (GPG/SHA256 verification), SSH key refactor (user-provided keys, no sudo), repo restructure, image build improvements (15G disk, HWE kernel, qemu-img compaction), cloud-init hardening, installers, shellcheck clean.

---

## Phase 5 — Core Changes

- **Image flavors**: Split monolithic `cloud-init.yaml` into composable layers (`images/layers/`): base, protocol-dev, smart-contract-dev, smart-contract-audit. Build-time yq merge produces the final cloud-init per flavor.
- **Directory restructure**: Shared build files (`packer.pkr.hcl`, `build.sh`, `packer-user-data.pkrtpl.hcl`) moved from `images/base/` to `images/`. Artifacts go to `images/artifacts/`.
- **Chained image builds**: Non-base flavors chain from their parent's QCOW2, applying only the delta cloud-init layer. Packer `iso_url`/`iso_checksum` made configurable; `build.sh` accepts `--base-image`; Makefile wires inter-flavor stamp dependencies.
- Build system logic refinements
- mps command changes as needed

## Phase 6 — Linting CI

- GitHub Actions workflow: run `make lint` on push/PR
- Quick win — linter image and targets already exist

## Phase 7 — Image Distribution

- Backblaze B2 bucket + Cloudflare proxy setup (handled externally)
- End-to-end `mps image pull` flow
- Automated image builds

## Phase 8 — Testing

- BATS test suite for `lib/common.sh`, `lib/multipass.sh`, and command scripts
- Wire tests into GitHub Actions CI (lint + test on push/PR)

## Phase 9 — PowerShell Parity (Windows)

- `bin/mps.ps1` + `commands/*.ps1` + `lib/*.ps1`
- `ConvertFrom-Json` instead of `jq`
- Windows path handling
