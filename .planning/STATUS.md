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
- [ ] `lib/multipass.sh` — mock `multipass` binary stub returning canned JSON (`mp_info`, `mp_list_all`, `mp_instance_exists`, etc.)
- [ ] `lib/common.sh` network functions — mock `curl`/`aria2c` or local HTTP server (`_mps_download_file`, `_mps_fetch_manifest`, staleness checks, CLI update check)
- [ ] `commands/*.sh` orchestration logic — multipass stub + fixture data

### CI integration
- [ ] Wire `make test` into GitHub Actions CI (lint + test on push/PR)

## Phase 12 — PowerShell Parity (Windows): NOT STARTED

- [ ] `bin/mps.ps1`
- [ ] `lib/common.ps1`
- [ ] `lib/multipass.ps1`
- [ ] `commands/*.ps1`
- [x] `install.ps1` — Windows installer (basic, PSScriptAnalyzer clean)

## Known Issues / TODO

### Bug: `commands/status.sh` reads wrong multipass JSON field names

`mps status` silently shows empty values for vCPUs and disk because the jq paths
don't match the actual `multipass info --format json` output (verified against
multipass 1.16.1):

| mps reads (status.sh) | Actual multipass JSON | Effect |
|---|---|---|
| `.cpus` (line 72) | `.cpu_count` | vCPUs never displayed |
| `.disk.used` (line 80) | `.disks.sda1.used` | Disk usage never displayed |
| `.disk.total` (line 82) | `.disks.sda1.total` | Disk total never displayed |

The `// empty` jq fallback masks the error — no failure, just missing output.
Also note: `disks.sda1.*` values are **strings** (e.g. `"5116440064"`) while
`memory.*` values are **numbers** (e.g. `474648576`) — an inconsistency from
multipass that jq expressions must account for.

### Investigation: multipass mounts persist across stop/suspend

Discovered during integration test fixture capture (multipass 1.16.1):

- `multipass mount` **succeeds on stopped/suspended instances** — registers the
  mount silently, activates on next start.
- `multipass info --format json` **reports mounts for stopped/suspended instances**
  in the `.mounts` object (same structure as Running).
- `multipass exec` on a stopped instance **auto-starts** it before running the
  command (exit 0, "Starting..." on stderr).

**Implications for mps adhoc mount behavior:**

- `mps mount add/remove/list` all gate on `mps_require_running` — they reject
  stopped instances. This is intentional: adhoc mounts are session-only by design.
- `mps down` explicitly cleans up adhoc mounts via `_down_cleanup_adhoc_mounts`
  before stopping. This is **necessary** because multipass would otherwise preserve
  them across the stop/start cycle, violating the "session-only" invariant.
- If a user bypasses mps and runs `multipass stop` directly, adhoc mounts will
  persist into the next start. This is a known limitation — mps cannot control
  out-of-band operations.
- `mps mount list` could arguably work on stopped instances (the data is available
  in multipass info JSON), but currently rejects them. Consider relaxing this gate
  if users report confusion about mount state after stopping.
