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

## Completed Phases (1–5)

**Phase 1 — MVP Core**: Entry point (`bin/mps`), shared libraries (`lib/common.sh`, `lib/multipass.sh`), all core commands (create, up, down, destroy, shell, exec, list, status, ssh-config), config cascade system, resource profiles, cloud-init templates, mount behavior with path-preserving semantics, VM auto-naming.

**Phase 2 — Image System**: `mps image list/pull/import`, Packer build pipeline for base QCOW2 images, dual-arch builds (amd64+arm64 via QEMU TCG), Ubuntu 24.04, manifest with SemVer versioning, SHA256 verification, Backblaze B2 publishing.

**Phase 3 — Port Forwarding**: `mps port forward/list`, SSH local port forwarding with PID tracking, auto-forward from `MPS_PORTS` config, cleanup on stop/destroy.

**Phase 4 — Polish & Build System**: Dockerized build system (builder + linter images), Makefile with stamp-based caching, secure dependency installation (GPG/SHA256 verification), SSH key refactor (user-provided keys, no sudo), repo restructure, image build improvements (15G disk, HWE kernel, qemu-img compaction), cloud-init hardening, installers, shellcheck clean.

**Phase 5 — Core Changes**: Image flavors (composable layers in `images/layers/`, chained builds via `--base-image`, dynamic disk sizes from `x-mps` metadata). Auto-scaling resource profiles (micro/lite/standard/heavy with fraction/min/cap). Image metadata pipeline (layer YAMLs → manifest.json → .meta sidecar → runtime validation). Installer refinement (auto-install deps, `~/.local/bin`). Uninstaller (`uninstall.sh`).

---

## Phase 6 — Image Distribution

- Backblaze B2 bucket + Cloudflare proxy setup (handled externally)
- Publishing scripts, metadata handling and versioning
- First publish to B2
- End-to-end `mps image pull` flow (code complete, needs E2E testing against live infra)
- Parallel image downloads via aria2c (optional, curl fallback)

## Phase 7 — GH Actions CI/CD Pipeline

- CI workflow (`ci.yml`): run `make lint` + `make test` on push/PR to `main`
- Image build/publish workflow (`images.yml`): GPG-signed tag trigger + weekly cron + manual dispatch, WarpBuild native KVM runners (amd64+arm64), pipelined build+upload, fan-in manifest update, Cloudflare cache purge, Slack failure notifications
- Tool release workflow (`release.yml`): GPG-signed tag trigger, lint+test, GitHub Release with install scripts
- Submodule update workflow (`update-submodule.yml`): keep vendor submodule in sync
- GPG tag verification: composite action (`.github/actions/verify-gpg-tag/`) shared by images and release workflows, validates signatures against `MAINTAINER_KEYS` repo variable
- actionlint added to linter image for GitHub Actions workflow linting
- Full CI design doc: `.planning/CI.md`

## Phase 8 — Update Documentation

- Update README.md (project overview, installation, usage, configuration, image system, contributing)
- Review and update all `--help` messages across commands for accuracy and consistency
- Add GitHub PR templates, issue templates, and CODEOWNERS

## Phase 9 — Testing

- BATS test suite for `lib/common.sh`, `lib/multipass.sh`, and command scripts
- Wire tests into GitHub Actions CI (lint + test on push/PR)

## Phase 10 — PowerShell Parity (Windows)

- `bin/mps.ps1` + `commands/*.ps1` + `lib/*.ps1`
- `ConvertFrom-Json` instead of `jq`
- Windows path handling
