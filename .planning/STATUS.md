# Implementation Status

## Completed Phases

- **Phase 1 — MVP Core**: bin/mps, lib/common.sh, lib/multipass.sh, all commands (create/up/down/destroy/shell/exec/list/status/ssh-config), config cascade, profiles, cloud-init
- **Phase 2 — Image System**: Packer pipeline, manifest.json, publish.sh, dual-arch builds (amd64+arm64), Ubuntu 24.04, QEMU TCG optimization, image import/resolution
- **Phase 3 — Port Forwarding**: SSH tunnels via `mps port forward/list`, auto-forward from MPS_PORTS, cleanup on down/destroy
- **Phase 4 — Polish & Build System**: Dockerized builds (builder+linter images), stamp-based caching, secure dependency installation (GPG/SHA256), SSH key refactor, repo restructure, image build improvements (15G disk, .qcow2.img, HWE kernel), cloud-init hardening, installers, shellcheck clean
- **Cross-Architecture Image Building**: QEMU cross-compilation, KVM/TCG detection, EFI firmware for arm64
- **File Transfer**: `mps transfer` with colon-prefix convention, `--transfer` flag on create/up

## Phase 5 — Core Changes: IN PROGRESS

- [x] Split monolithic cloud-init.yaml into composable layers (`images/layers/`)
- [x] Restructure `images/` directory (layers/, artifacts/, shared packer/build files)
- [x] Rewrite build.sh to accept flavor argument + yq merge
- [x] Add yq to Dockerfile.builder
- [x] Update Makefile with per-flavor build/import/publish/clean targets
- [x] Update manifest.json with 4 image flavors
- [x] Chained image builds (non-base flavors chain from parent QCOW2 via `--base-image`)
- [x] Dynamic Packer disk_size per flavor (x-mps metadata in layer YAMLs → build.sh → packer.pkr.hcl)
- [x] Auto-scaling resource profiles (micro/lite/standard/heavy with fraction/min/cap)
- [x] Default profile changed from standard to lite
- [x] Image flavor metadata in manifest.json (disk_size, min_profile, min_disk, min_memory, min_cpus)
- [x] .meta sidecar metadata on pull/import (from manifest/layer YAMLs)
- [x] Runtime validation warnings in mps create (check image requirements vs resolved resources)
- [ ] Build system logic refinements
- [ ] mps command changes as needed

## Phase 6 — Linting CI: NOT STARTED

- [ ] GitHub Actions workflow: `make lint` on push/PR

## Phase 7 — Image Distribution: NOT STARTED

- [ ] Backblaze B2 bucket + Cloudflare proxy setup (handled externally)
- [ ] End-to-end `mps image pull` flow
- [ ] Automated image builds

## Phase 8 — Testing: NOT STARTED

- [ ] BATS test suite for lib/common.sh, lib/multipass.sh, and command scripts
- [ ] Wire tests into GitHub Actions CI (lint + test on push/PR)

## Phase 9 — PowerShell Parity (Windows): NOT STARTED

- [ ] `bin/mps.ps1`
- [ ] `lib/common.ps1`
- [ ] `lib/multipass.ps1`
- [ ] `commands/*.ps1`
- [x] `install.ps1` — Windows installer (basic, PSScriptAnalyzer clean)

## Known Issues / TODO

(none currently)
