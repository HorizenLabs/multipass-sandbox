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

## Completed Phases

Phases 1–7 are complete. See `STATUS.md` for detailed checklists.

- **Phase 1** — MVP Core (entry point, commands, config cascade, profiles, mounts)
- **Phase 2** — Image System (Packer pipeline, dual-arch builds, manifest)
- **Phase 3** — Port Forwarding (SSH tunnels, auto-forward, cleanup)
- **Phase 4** — Polish & Build System (Dockerized builds, secure deps, installers)
- **Phase 5** — Core Changes (composable layers, chained builds, auto-scaling profiles)
- **Phase 6** — Image Distribution (B2 + Cloudflare, publish scripts, staleness detection)
- **Phase 7** — CI/CD Pipeline (GitHub Actions: lint, image builds, releases, GPG verification)

CI design doc: `.github/CI.md`

---

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
