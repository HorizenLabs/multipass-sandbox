# Implementation Plan & Status

## Context

A blockchain software development company needs an internal tool to spin up isolated sandbox development environments for developers and AI agents. Docker containers alone don't provide strong enough isolation, so the tool uses Multipass (Canonical) to create full VMs with Docker daemons running inside. The tool must work on Linux and macOS, support pre-built distributable images, allow customization, and provide shell + SSH access for VS Code integration. Windows/PowerShell support is planned as future work (Phase 12).

**Key decisions:**
- **VM Engine**: Canonical Multipass
- **CLI**: Bash (macOS/Linux); PowerShell planned (Phase 12)
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
- **Phase 9 — User Acceptance Testing (Alpha)**: Bash 3.2 compat linting, mount/port/metadata refactors, instance staleness detection, CLI update check, installer fixes, dead code audits, documentation updates
- **Phase 10 — Bash Completion**: Self-describing tab-completion via `mps __complete` hidden subcommand. `_complete_<cmd>()` metadata functions in all 13 command files, `completions/mps.bash` thin generic script, installer/uninstaller support, Makefile lint integration. Dynamic completion for instance names, profiles, images, cloud-init templates.

## Phase 11 — Testing: IN PROGRESS  *(see [TESTING.md](TESTING.md) for coverage inventory and mocking strategy)*

### Unit tests
- [x] `lib/common.sh` core functions (143 BATS tests across 8 files, dual Bash 4+ / 3.2)
- [x] `lib/common.sh` remaining unit-tier functions (54 new tests across 4 files): `mps_resolve_workdir`, `mps_save_instance_meta`, `mps_image_meta`, `_mps_read_cached_manifest`, `mps_cleanup_port_sockets`, `mps_resolve_instance_name`, `_mps_sha256`, `_mps_md5`, `mps_require_cmd`
- [x] Bash completion: `_complete_*()` metadata functions (smoke, subcommand routing, flag-values tokens) + `__complete` dispatcher (filesystem token collection) — 44 tests in `completion.bats`
- [x] `commands/*.sh` argument parsing / flag handling — 105 tests in `cmd_parsing.bats` covering --help, unknown flags, missing values, short aliases, subcommand routing, and command-specific validation (exec `--`, transfer direction, port numeric, image import/remove constraints)

### Integration tests
- [x] `lib/multipass.sh` info & query wrappers — mock `multipass` stub + canned JSON (`mp_list_all`, `mp_state`, `mp_instance_exists`, `mp_get_mounts`, `mp_ipv4`) — 20 tests in `stub_smoke.bats`
- [x] `lib/multipass.sh` lifecycle & execution wrappers — `mp_launch`, `mp_start`, `mp_stop`, `mp_delete`, `mp_exec`, `mp_shell`, `mp_mount`, `mp_umount`, `mp_transfer`, `mp_wait_cloud_init`, `mp_docker_status`, `mp_info`/`mp_info_field`, `mp_instance_state` — 40 tests in `mp_lifecycle.bats` (call log assertions, configurable exit codes, failure paths)
- [x] `lib/common.sh` network functions — local python3 HTTP server serving fixture files (`_mps_download_file`, `_mps_fetch_manifest`, staleness checks, CLI update check) — 53 tests in `network.bats`
- [x] `commands/*.sh` orchestration logic (batch 1) — `list`, `status`, `create`, `up`, `down`, `destroy`, `shell`, `exec`, `transfer`, `mount` — 60 tests across 3 files (`cmd_query.bats`, `cmd_lifecycle.bats`, `cmd_exec.bats`)
- [x] `commands/*.sh` orchestration logic (batch 2) — `port`, `ssh-config`, `image` — 53 tests across 3 files (`cmd_port.bats`, `cmd_ssh_config.bats`, `cmd_image.bats`). openssh-client in linter image, real ssh-keygen, multipass stub mktemp pattern.
- [x] `completions/` — `__complete instances` with multipass stub (dynamic instance name completion) — 8 tests in `completion_instances.bats`
- [x] `completions/mps.bash` — `_mps_completions()` completion driver (COMP_WORDS parsing, command/subcmd detection, global flag skipping, flag-value resolution, magic token expansion, `--` separator, `__files__` early return, `_init_completion` path, `complete -p` registration) — 36 tests in `completion_driver.bats`
- [x] `bin/mps` entry point — subprocess tests for `main()` dispatch — 11 tests in `entry_point.bats` (`--help`, `-h`, `--version`, `-v`, no args, `--debug`, path traversal, uppercase, dot-prefix, unknown command, command-specific `--help`)
- [x] `install.sh` — sourced function tests + subprocess tests with HOME/PATH isolation — 31 tests in `install.bats` (detect_os, confirm, install_dependency, directory structure, symlink, completion, PATH check, missing deps, verification)
- [x] `uninstall.sh` — subprocess tests with fully installed state under fake HOME — 26 tests in `uninstall.bats` (symlink removal, completion cleanup, VM cleanup, SSH config, instance metadata, cache, user config, directory cleanup, summary)

### Code coverage
- [ ] Add kcov to linter Docker image (single binary, no Ruby dep)
- [ ] `make test-coverage` target: run BATS through kcov with `--include-path=lib/,bin/,commands/`
- [ ] Merge Bash 4+ and 3.2 coverage runs (`kcov --merge`)
- [ ] Cobertura XML output for CI integration (Codecov / GitHub Actions summary)

### e2e tests locally
- [ ] TODO

### CI integration
- [ ] Wire `make test` into GitHub Actions CI (lint + test on push/PR)

## Phase 12 — PowerShell Parity (Windows): NOT STARTED

- [ ] `bin/mps.ps1`
- [ ] `lib/common.ps1`
- [ ] `lib/multipass.ps1`
- [ ] `commands/*.ps1`
- [x] `install.ps1` — Windows installer (basic, PSScriptAnalyzer clean)

## Known Issues / TODO

(none currently)
