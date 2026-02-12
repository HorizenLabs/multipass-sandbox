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
- [ ] Actual Backblaze B2 bucket + Cloudflare proxy setup (handled externally)
- [ ] CI pipeline (GitHub Actions) for automated image builds

## Phase 3 — Port Forwarding: DONE

- [x] `commands/port.sh` — `port forward` (SSH tunnel) and `port list` (PID tracking)
- [x] Auto-forwarding from `MPS_PORTS` config and `--port` flags on `mps create`/`mps up`
- [x] Port forward cleanup on `mps down` (kill + truncate) and `mps destroy` (kill + delete)
- [x] Shared port helpers in `lib/common.sh` (collect, forward, auto-forward, kill)
- [x] `commands/port.sh` refactored to use shared `mps_forward_port()` helper

## Phase 4 — PowerShell Parity (Windows): NOT STARTED

- [ ] `bin/mps.ps1`
- [ ] `lib/common.ps1`
- [ ] `lib/multipass.ps1`
- [ ] `commands/*.ps1`
- [x] `install.ps1` — Windows installer (basic)

## Phase 5 — Polish & CI: DONE (build system)

- [x] `Dockerfile.builder` — Builder image with Packer, b2, gosu, QEMU (x86+arm64)
- [x] `Dockerfile.linter` — Linter/test image with shellcheck, hadolint, BATS, yamllint, checkmake, py-psscriptanalyzer, Packer (for fmt)
- [x] `docker/entrypoint.sh` — uid:gid matching entrypoint, KVM group handling
- [x] `Makefile` — Dockerized: builder, linter, lint (6 sub-targets), test, image-base, publish-base
- [x] `Makefile` — `.stamp-builder`/`.stamp-linter` dependencies: auto-build images when Dockerfile or entrypoint changes
- [x] `Makefile` — `ARCH=` variable for cross-architecture builds, conditional `--device /dev/kvm` passthrough
- [x] `install.sh` — Installer (symlink + dep check)
- [x] `.gitignore`
- [x] `README.md`
- [x] Shellcheck clean — all warnings resolved (SC2154 directives for sourced color vars, real bug fixes)
- [ ] BATS test suite
- [ ] GitHub Actions CI pipeline

## Cross-Architecture Image Building: DONE

- [x] `Dockerfile.builder` — Added qemu-system-x86, qemu-utils, qemu-system-arm, qemu-efi-aarch64
- [x] `docker/entrypoint.sh` — KVM device group detection + usermod for builder user
- [x] `images/arch-config.sh` — Shared arch detection: HOST_ARCH, TARGET_ARCH, KVM vs TCG, PACKER_ARCH_VARS array
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

- README.md needs updating to reflect auto-naming, --name flag, B2 image system, dockerized build, and `mps transfer` command
- `lint-powershell` fails because `pwsh` is not installed in the builder image (py-psscriptanalyzer needs it)
- Hadolint warns on `Dockerfile.builder`: unpinned apt/pip versions and missing `SHELL ["/bin/bash", "-o", "pipefail", "-c"]`
