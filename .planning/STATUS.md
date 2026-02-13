# Implementation Status

## Phase 1 — MVP Core: DONE

- [x] `config/defaults.env` — Default configuration values (updated for B2)
- [x] `lib/common.sh` — Logging, config cascade, path conversion, mount resolution, auto-naming, validation
- [x] `lib/multipass.sh` — Multipass CLI wrappers with JSON parsing
- [x] `bin/mps` — Main entry point with subcommand dispatch
- [x] `templates/cloud-init/base.yaml` — Base cloud-init (Docker, Node.js, Python, Go, Rust, dev tools, Solana, Anchor, Foundry, Hardhat)
- [x] `templates/profiles/lite.env` — 2 CPU, 2GB RAM, 20GB disk
- [x] `templates/profiles/standard.env` — 4 CPU, 4GB RAM, 50GB disk
- [x] `templates/profiles/heavy.env` — 8 CPU, 8GB RAM, 100GB disk
- [x] `commands/create.sh` — Create sandbox with auto-naming, mount, cloud-init, profile
- [x] `commands/up.sh` — Create-or-start sandbox
- [x] `commands/down.sh` — Stop sandbox (with --force)
- [x] `commands/destroy.sh` — Remove sandbox (with confirmation)
- [x] `commands/shell.sh` — Interactive shell with auto-workdir
- [x] `commands/exec.sh` — Execute command with auto-workdir
- [x] `commands/list.sh` — List sandboxes (table + --json)
- [x] `commands/status.sh` — Detailed status (resources, mounts, Docker health)
- [x] `commands/ssh-config.sh` — VS Code SSH integration (--print, --append)

## Phase 2 — Image System: DONE

- [x] `commands/image.sh` — `image list` (local + --remote) and `image pull` (SemVer + latest resolution, SHA256 verify)
- [x] `images/manifest.json` — Manifest template with SemVer versions + latest pointer
- [x] `images/publish.sh` — Publish images to Backblaze B2 via `b2` CLI, update manifest
- [x] `images/base/build.sh` + `packer.pkr.hcl` + `scripts/setup-base.sh`
- [x] Packer build verified end-to-end (`make image-base` completes ~10 min)
- [x] Fixed YAML syntax error in `base.yaml` — heredoc terminator broke YAML block scalar, preventing cloud-init from parsing any directives
- [x] `images/base/packer-user-data.pkrtpl.hcl` — Build-time cloud-init wrapper that prepends password auth + sshd_config.d override to base template
- [x] `packer.pkr.hcl` — Added `ssh_password`, `iso_checksum` (SHA256SUMS), templatized `ubuntu_version`/`target_arch`, serial console qemuargs
- [x] `images/arch-config.sh` — Passes `target_arch` instead of `iso_url` (URL constructed in HCL)
- [x] `scripts/setup-base.sh` — Post-build credential cleanup (lock password, remove sshd override, disable password SSH)
- [x] `build.sh` — Output to `/tmp` to avoid cross-device rename on WSL2 Docker volumes; defensive `${VAR:?}` on `rm -rf`
- [x] `make image-base` builds both amd64 and arm64 images regardless of host architecture (cross-arch via QEMU TCG)
- [x] Base image uses Ubuntu 24.04 (noble) instead of 22.04 (jammy)
- [x] QEMU TCG performance: `-cpu max,pauth-impdef=on,sve=off`, `disk_cache=unsafe`, `-display none` (arm64 build 2h18m → 1h29m, 35% faster)

## Phase 3 — Port Forwarding: DONE

- [x] `commands/port.sh` — `port forward` (SSH tunnel) and `port list` (PID tracking)
- [x] Auto-forwarding from `MPS_PORTS` config and `--port` flags on `mps create`/`mps up`
- [x] Port forward cleanup on `mps down` (kill + truncate) and `mps destroy` (kill + delete)
- [x] Shared port helpers in `lib/common.sh` (collect, forward, auto-forward, kill)
- [x] `commands/port.sh` refactored to use shared `mps_forward_port()` helper

## Phase 4 — Polish & Build System: DONE

- [x] `Dockerfile.builder` — Builder image with Packer, b2, QEMU (x86+arm64)
- [x] `Dockerfile.linter` — Linter/test image with shellcheck, hadolint, BATS, yamllint, checkmake, pwsh, py-psscriptanalyzer, Packer (for fmt)
- [x] `docker/entrypoint.sh` — uid:gid matching entrypoint, KVM group handling
- [x] `Makefile` — Dockerized: builder, linter, lint (6 sub-targets), test, image-base, publish-base
- [x] `Makefile` — `.stamp-builder`/`.stamp-linter` dependencies: auto-build images when Dockerfile or entrypoint changes
- [x] `Makefile` — `ARCH=` variable for cross-architecture builds, conditional `--device /dev/kvm` passthrough
- [x] `install.sh` — Installer (symlink + dep check)
- [x] `.gitignore`
- [x] `README.md`
- [x] Shellcheck clean — all warnings resolved (SC2154 directives for sourced color vars, real bug fixes)
- [x] `mps image import` — Import local QCOW2 files into `~/.mps/cache/images/` with auto-detected name/arch, SHA256 verify, `.meta` sidecar
- [x] `mps create --image base` — Unified image resolution: cache lookup → `file://` URL for Multipass, fallthrough for Ubuntu versions
- [x] `lib/common.sh` — `mps_detect_arch()`, `mps_resolve_image()`, SemVer comparison helpers
- [x] `mps image list` — SOURCE column showing imported vs pulled
- [x] `Makefile` — `import-base` target: build + import host-arch image in one step

### Phase 4 Reopened (2) — Secure Dependency Installation: DONE

- [x] Packer — HashiCorp apt repo with GPG-verified signing key (both Dockerfiles)
- [x] b2 CLI — standalone binary from GitHub (v4.5.1) replaces pip package, SHA256 verification via `_hashes.txt`; removed python3/pip/venv from builder
- [x] shellcheck — updated v0.10.0 → v0.11.0
- [x] BATS — updated v1.11.0 → v1.13.0
- [x] hadolint — updated v2.12.0 → v2.14.0, SHA256 checksum verification from GitHub release
- [x] checkmake — updated v0.2.2 → v0.3.2, moved from `mrtazz/checkmake` to `checkmake/checkmake`, checksum verification

### Phase 4 Reopened — Polish & Refactor: DONE

- [x] SSH key refactor — user-provided keys, on-demand injection via `mps ssh-config`
  - [x] `lib/common.sh` — SSH key helpers: `mps_resolve_ssh_pubkey()`, `mps_resolve_ssh_privkey()`, `mps_inject_ssh_key()`, `mps_ensure_ssh_key()`, `mps_require_ssh_key()`
  - [x] `commands/ssh-config.sh` — `--ssh-key` flag, key injection, no more `mp_ssh_info()` dependency
  - [x] `lib/common.sh` `mps_forward_port()` — uses `mps_require_ssh_key()` instead of `mp_ssh_info()`
  - [x] `lib/multipass.sh` `mp_ssh_info()` — removed OS-specific Multipass key path detection, reads from instance metadata
  - [x] `config/defaults.env` — replaced `MPS_SSH_AUTO_CONFIG` with `MPS_SSH_KEY=` (empty = auto-detect)
- [x] Repo restructure — cloud-init templates
  - [x] Moved `templates/cloud-init/base.yaml` → `images/base/cloud-init.yaml` (full provisioning for image builds)
  - [x] Created new minimal `templates/cloud-init/base.yaml` (customization template for VM launch)
  - [x] Updated `packer.pkr.hcl` to reference `${path.root}/cloud-init.yaml`
  - [x] Updated `Makefile` YAML_FILES to search `images/` in addition to `templates/`
- [x] Image build improvements
  - [x] HWE edge kernel (`linux-virtual-hwe-24.04-edge`) added to cloud-init
  - [x] Old kernel removal in `setup-base.sh`
  - [x] `disk_size` reduced from 100G to 16G (Multipass + growpart auto-expands at launch)
  - [x] Output extension changed from `.qcow2` to `.qcow2.img` across packer, build.sh, Makefile, image.sh
  - [x] `qemu-img convert` compaction step added to `build.sh`
  - [x] `.gitignore` updated for `*.qcow2.img`

### Phase 4 Reopened (3) — Image Build Improvements: DONE

- [x] Removed blockchain image flavor from `manifest.json` (consolidated into base)
- [x] `build.sh` — Always generate SHA256 checksums after compaction
- [x] Renamed `scripts/setup-base.sh` → `scripts/post-provision-base.sh`
- [x] `post-provision-base.sh` — Clear Rust/Cargo build caches (registry, git, package-cache)
- [x] `cloud-init.yaml` — `package_upgrade: true`
- [x] `cloud-init.yaml` — yq: SHA-256 checksum verification via rhash `checksums` file
- [x] `cloud-init.yaml` — hadolint: SHA-256 checksum verification via `.sha256` sidecar
- [x] `cloud-init.yaml` — `just` moved from `cargo install` to apt package
- [x] `cloud-init.yaml` — Added `cargo-audit` (via cargo install)
- [x] `cloud-init.yaml` — Removed `pyenv` (uv manages Python versions)
- [x] `cloud-init.yaml` — Added `libclang-dev` to packages

## Phase 5 — Testing: NOT STARTED

- [ ] BATS test suite

## Phase 6 — CI/CD: NOT STARTED

- [ ] GitHub Actions CI pipeline
- [ ] CI pipeline for automated image builds
- [ ] Backblaze B2 bucket + Cloudflare proxy setup (handled externally)

## Phase 7 — PowerShell Parity (Windows): NOT STARTED

- [ ] `bin/mps.ps1`
- [ ] `lib/common.ps1`
- [ ] `lib/multipass.ps1`
- [ ] `commands/*.ps1`
- [x] `install.ps1` — Windows installer (basic, PSScriptAnalyzer clean)

## Cross-Architecture Image Building: DONE

- [x] `Dockerfile.builder` — Added qemu-system-x86, qemu-utils, qemu-system-arm, qemu-efi-aarch64
- [x] `docker/entrypoint.sh` — KVM device group detection + usermod for builder user
- [x] `images/arch-config.sh` — Shared arch detection: HOST_ARCH, TARGET_ARCH, KVM vs TCG, PACKER_ARCH_VARS array; EFI firmware uses AAVMF pflash files (64MB) for arm64
- [x] `images/base/packer.pkr.hcl` — Parameterized: target_arch, ubuntu_version, qemu_binary, machine_type, accelerator, cpu_type, efi_boot, efi_firmware_code/vars; iso_checksum via SHA256SUMS
- [x] `images/base/build.sh` — Sources arch-config.sh, passes PACKER_ARCH_VARS to packer build; /tmp output dir workaround for WSL2
- [x] `Makefile` — ARCH variable, HOST_ARCH detection, KVM_FLAG conditional, DOCKER_RUN_IMAGE for image targets

## File Transfer: DONE

- [x] `lib/multipass.sh` — Updated `mp_transfer()` to variadic with error handling
- [x] `commands/transfer.sh` — Standalone `mps transfer` command with `:` prefix guest path convention
- [x] `commands/create.sh` — `--transfer` flag for seeding files into new VMs after creation
- [x] `commands/up.sh` — `--transfer` passthrough to `cmd_create`
- [x] `bin/mps` — Updated help text with transfer command and `--name` flag pattern

## Known Issues / TODO

(none currently)
