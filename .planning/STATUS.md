# Implementation Plan & Status

## Context

A blockchain software development company needs an internal tool to spin up isolated sandbox development environments for developers and AI agents. Docker containers alone don't provide strong enough isolation, so the tool uses Multipass (Canonical) to create full VMs with Docker daemons running inside. The tool must work on Linux and macOS, support pre-built distributable images, allow customization, and provide shell + SSH access for VS Code integration. Windows/PowerShell support is planned as future work (Phase 11).

**Key decisions:**
- **VM Engine**: Canonical Multipass
- **CLI**: Bash (macOS/Linux); PowerShell planned (Phase 11)
- **Command name**: `mps` (short form), project name "Multi Pass Sandbox"
- **Image distribution**: Backblaze B2 + Cloudflare proxy
- **Only external dependency**: `jq` (JSON parsing of `multipass` output)

> Project structure and conventions: see `CLAUDE.md`
> Architecture decisions and rationale: see `DECISIONS.md`
> CI/CD pipeline design: `.github/CI.md`

---

## Completed Phases

- **Phase 1 — MVP Core**: bin/mps, lib/common.sh, lib/multipass.sh, all commands (create/up/down/destroy/shell/exec/list/status/ssh-config), config cascade, profiles, cloud-init
- **Phase 2 — Image System**: Packer pipeline, manifest.json, publish.sh, dual-arch builds (amd64+arm64), Ubuntu 24.04, QEMU TCG optimization, image import/resolution
- **Phase 3 — Port Forwarding**: SSH tunnels via `mps port forward/list`, auto-forward from MPS_PORTS, cleanup on down/destroy
- **Phase 4 — Polish & Build System**: Dockerized builds (builder+linter images), stamp-based caching, secure dependency installation (GPG/SHA256), SSH key refactor, repo restructure, image build improvements (15G disk, .qcow2.img, HWE kernel), cloud-init hardening, installers, shellcheck clean
- **Cross-Architecture Image Building**: QEMU cross-compilation, KVM/TCG detection, EFI firmware for arm64
- **File Transfer**: `mps transfer` with colon-prefix convention, `--transfer` flag on create/up
- **Phase 5 — Core Changes**: Image flavors (composable layers, chained builds, dynamic disk sizes), auto-scaling profiles (micro/lite/standard/heavy), image metadata + runtime validation, build system refinements, installer/uninstaller
- **Phase 6 — Image Distribution**: B2+Cloudflare publish pipeline, fan-in manifest, autoindex HTML, staleness detection, parallel downloads (aria2c), SemVer versioning
- **Phase 7 — CI/CD Pipeline**: GitHub Actions (ci, images, release, update-submodule), GPG tag verification, CF cache invalidation, Slack notifications, actionlint
- **Phase 8 — Update Documentation**: README, help messages, GitHub templates, CODEOWNERS

## Phase 9 — User Acceptance Testing (Alpha): IN PROGRESS

First round of alpha-tester feedback across macOS and Linux.

- [x] Fix arm64 `.sha256` sidecar containing `efivars.fd` (breaks image validation on macOS)
- [x] Fix staleness detection race condition during image publishing window
- [ ] Audit and fix Bash 3.2 incompatibilities in client-side scripts (macOS default shell)
- [ ] Verify README.md example commands work end-to-end and fix any that don't
- [ ] Re-publish corrected sidecars/manifest for affected images on B2
- [x] Remove references to Windows support from docs (README, STATUS context, CLAUDE.md) — deferred to Phase 11
- [ ] Audit and remove dead code paths (unused functions, unreferenced variables, dead metadata writes)
- [ ] Triage and fix additional alpha-tester findings

## Phase 10 — Testing: NOT STARTED

- [ ] BATS test suite for lib/common.sh, lib/multipass.sh, and command scripts
- [ ] Wire tests into GitHub Actions CI (lint + test on push/PR)

## Phase 11 — PowerShell Parity (Windows): NOT STARTED

- [ ] `bin/mps.ps1`
- [ ] `lib/common.ps1`
- [ ] `lib/multipass.ps1`
- [ ] `commands/*.ps1`
- [x] `install.ps1` — Windows installer (basic, PSScriptAnalyzer clean)

## Known Issues / TODO

(none currently)
