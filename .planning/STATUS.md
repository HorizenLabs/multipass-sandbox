# Implementation Status

## Completed Phases

- **Phase 1 — MVP Core**: bin/mps, lib/common.sh, lib/multipass.sh, all commands (create/up/down/destroy/shell/exec/list/status/ssh-config), config cascade, profiles, cloud-init
- **Phase 2 — Image System**: Packer pipeline, manifest.json, publish.sh, dual-arch builds (amd64+arm64), Ubuntu 24.04, QEMU TCG optimization, image import/resolution
- **Phase 3 — Port Forwarding**: SSH tunnels via `mps port forward/list`, auto-forward from MPS_PORTS, cleanup on down/destroy
- **Phase 4 — Polish & Build System**: Dockerized builds (builder+linter images), stamp-based caching, secure dependency installation (GPG/SHA256), SSH key refactor, repo restructure, image build improvements (15G disk, .qcow2.img, HWE kernel), cloud-init hardening, installers, shellcheck clean
- **Cross-Architecture Image Building**: QEMU cross-compilation, KVM/TCG detection, EFI firmware for arm64
- **File Transfer**: `mps transfer` with colon-prefix convention, `--transfer` flag on create/up
- **Phase 5 — Core Changes**: Image flavors (composable layers, chained builds, dynamic disk sizes), auto-scaling profiles (micro/lite/standard/heavy), image metadata + runtime validation, build system refinements, installer/uninstaller

## Phase 6 — Image Distribution: IN PROGRESS

- [x] Backblaze B2 bucket + Cloudflare proxy setup (`mpsandbox` bucket, `mpsandbox.horizenlabs.io` domain, CF rewrite rules for index.html)
- [x] Publishing scripts: remote-first manifest, build_date tracking, B2 old version cleanup, unfinished large file cancellation
- [x] Shared publish helpers: `images/lib/publish-common.sh` (DRY refactor of publish/update-manifest)
- [x] Drop `MPS_B2_BUCKET_PREFIX` — files at bucket root, URLs map 1:1
- [x] `file_size` in manifest entries (from `stat` local, `contentLength` CI)
- [x] Autoindex HTML generation: `images/generate-index.sh` (root, per-flavor, per-version pages)
- [x] Image versioning conventions: SemVer for tooling, weekly rebuilds for OS patches
- [ ] First publish to B2
- [ ] Client-side staleness detection (compare cached SHA256 vs remote manifest)
- [x] `mps image pull` + auto-pull on `mps create`/`mps up` (code complete, needs E2E testing against live infra)

## Phase 7 — GH Actions CI/CD Pipeline: NOT STARTED

- [ ] GitHub Actions workflow: `make lint` on push/PR
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
