# Multi Pass Sandbox (mps)

Internal CLI tool for spinning up isolated VM-based development environments using Canonical Multipass. Provides stronger isolation than Docker containers alone — full VMs with Docker daemons running inside.

## Tech Stack

- **CLI**: Bash (macOS/Linux)
- **VM Engine**: Canonical Multipass
- **Config**: KEY=VALUE .env files (no YAML parsing in Bash)
- **Dependencies**: `multipass`, `jq`
- **Image builds**: Packer (QCOW2, `.qcow2.img` extension), published to Backblaze B2 (served via Cloudflare)
- **Image versioning**: SemVer (x.y.z) with `latest` pointer, weekly rebuilds for OS patches
- **Build/Test**: All run inside Docker containers (`mps-builder` for image builds, `mps-linter` for lint/test, `mps-publisher` for B2 uploads)
- **Tests**: BATS (unit + integration in Docker linter container, dual Bash 4+ / 3.2)

## Project Structure

- `bin/mps` — Main entry point, subcommand dispatch
- `lib/common.sh` — Logging, config cascade, path conversion, mount resolution, auto-naming, auto-scaling resources
- `lib/multipass.sh` — Thin wrappers around `multipass` CLI with `--format json` + `jq`
- `commands/*.sh` — One file per subcommand (create, up, down, destroy, shell, exec, list, status, ssh-config, image, mount, port, transfer), each exports `cmd_<name>()` function
- `completions/mps.bash` — Bash tab-completion via `_mps_completions()`, installed by `install.sh`
- `templates/cloud-init/` — Minimal cloud-init templates for VM launch customization
- `images/layers/` — Composable cloud-init layer files (base, protocol-dev, smart-contract-dev, smart-contract-audit). Declarative only: `packages:`, `write_files:`, `x-mps:` metadata. No `runcmd:`.
- `images/build.sh` — Image build script (takes flavor arg, merges layers with yq, resolves tool versions from GitHub API via `_resolve_gh_latest()` with `GITHUB_TOKEN` auth in CI and pinned fallbacks locally)
- `images/scripts/install-{base,protocol-dev,smart-contract-dev,smart-contract-audit}.sh` — Per-layer Packer shell provisioner scripts (`set -euo pipefail`). Each self-selects via `FLAVOR` env var, idempotent for layered amd64 chain builds.
- `images/scripts/validate-image.sh` — Post-install Packer provisioner that asserts all expected tools are present (hard failure if missing)
- `images/scripts/post-provision.sh` — Post-build cleanup (kernel, apt cache, cloud-init reset, zero free space)
- `images/packer.pkr.hcl`, `packer-user-data.pkrtpl.hcl`, `arch-config.sh` — Packer build config (template, cloud-init wrapper, per-arch variable resolution)
- `images/publish.sh`, `update-manifest.sh`, `generate-index.sh`, `publish-release-meta.sh` — B2 publish pipeline (`lib/publish-common.sh` for shared helpers)
- `images/artifacts/` — Built QCOW2 images (gitignored)
- `templates/profiles/` — Resource profiles (micro, lite, standard, heavy) with auto-scaling CPU/memory
- `VERSION` — Tool version (SemVer), read by `bin/mps` at startup
- `config/defaults.env` — Shipped defaults
- `docker/Dockerfile.{builder,linter,publisher,bash32}` + `entrypoint.sh` — Container images (builder: Packer/QEMU, linter: shellcheck/hadolint/BATS/etc., publisher: b2/jq/yq, bash32: Bash 3.2.57)
- `docker/lint-bash32-compat.sh`, `docker/bash-3.2/` — Bash 3.2 compatibility linter and pre-built binaries
- `Makefile` — All targets run inside Docker containers via `docker run`
- `install.sh`, `uninstall.sh` — Installer and uninstaller (macOS/Linux)
- `checkmake.ini`, `.yamllint`, `.github/actionlint.yaml` — Linter configuration files
- `CODEOWNERS` — GitHub code ownership for PR review routing
- `.github/workflows/` — GitHub Actions CI/CD pipelines (ci, images, release, update-submodule)
- `.github/actions/verify-gpg-tag/` — Composite action for GPG tag signature verification
- `vendor/hl-claude-marketplace` — Git submodule: private Claude Code plugin marketplace (relative URL)
- `.claude/skills/` — Claude Code skills (`audit-docs`: doc staleness audit, `init-template`: cloud-init template generator)
- `tests/` — BATS test suites (`unit/`, `integration/`), shared `test_helper.bash`, `stubs/` (multipass, ssh, sudo, http_server.py), coverage scripts (`coverage-trap.sh`, `coverage-report.sh`), `tap-summary.sh`, `capture-fixtures.sh`, `e2e.sh` (full VM lifecycle), `TESTING.md` (strategy and coverage map)
- `.github/scripts/` — CI helper scripts: `ci-preflight.sh` (snap confinement checks), `ci-setup-submodule.sh` (SSH deploy key + submodule init), `ci-check-kvm.sh` (KVM module loading), `ci-detect-e2e.sh` (e2e change detection for ci.yml), `e2e-image-drift.sh` (image drift detection vs latest tag)
- `.planning/` — Implementation plan, architecture decisions, status tracking

## Commands

- `mps create` / `mps up` / `mps down` / `mps destroy` — VM lifecycle
- `mps shell` / `mps exec` — Interactive shell / run command (auto-workdir)
- `mps list` / `mps status` — List all / detailed info
- `mps ssh-config` — Generate SSH config for VS Code (also injects SSH keys)
- `mps image [list|pull|import|remove]` — Manage pre-built QCOW2 images
- `mps mount [add|remove|list]` — Manage mounts (origin tracking: auto/config/adhoc)
- `mps port [forward|list]` — SSH port forwarding
- `mps transfer` — File copy between host and guest (`:` prefix = guest path)

## Key Conventions

- **Auto-naming**: `mps-<folder-basename>-<template>` (e.g., `mps-myproject-default`)
  - Override with `--name` flag or `MPS_NAME` in `.mps.env`
  - Long names truncated with short hash suffix (max 40 chars for Multipass)
  - `--no-mount` without `--name` errors (can't derive folder name)
- Config cascade: `config/defaults.env` → `~/mps/config` → `.mps.env` → profile → auto-scaling → CLI flags. No `ENV_VAR=x mps cmd` overrides — use `~/mps/config` or `.mps.env` to test config knobs. Key config keys: `MPS_CHECK_UPDATES` (CLI update check, default true), `MPS_IMAGE_CHECK_UPDATES` (image and instance staleness checks, default true), `MPS_PORTS` (space-separated `host:guest` pairs, auto-forwarded on up/create).
- **Default profile**: `lite` (auto-scales CPU/memory from host hardware fractions with min/cap)
- **Profiles**: micro (1/8 CPU, 1/16 mem), lite (1/4, 1/6), standard (1/3, 1/4), heavy (1/2, 1/3)
- **Image metadata**: `x-mps:` blocks in layer YAMLs define disk_size, min_profile, min_disk/memory/cpus
- `mps create` warns when resolved resources are below image minimums (never blocks)
- Default mount: host CWD → guest at same absolute path (read-write)
- `MPS_MOUNTS` is additive (on top of auto-mount), `MPS_NO_AUTOMOUNT=true` to opt out
- `mps shell`/`mps exec` auto-set workdir to the mounted project path
- **Cross-platform**: Scripts in `bin/`, `commands/`, `lib/`, `config/`, `install.sh`, and `uninstall.sh` must work on both GNU/Linux and BSD/macOS, targeting Bash 3.2+ (macOS default). Scripts in `images/` run inside Docker and may use GNU-only tools. Banned Bash 4+ features in client scripts:
  - `${var,,}` / `${var^^}` / `${var,}` / `${var^}` — use `tr '[:upper:]' '[:lower:]'` or `tr '[:lower:]' '[:upper:]'`
  - `declare -A` / `local -A` (associative arrays) — use delimited strings with `case` pattern matching
  - `declare -n` / `local -n` (namerefs) — use `echo`-based returns or positional params
  - `declare -g` (global from function) — use `export` or avoid `local` for the variable
  - `declare -l` / `declare -u` (auto-case attributes) — use `tr`
  - `mapfile` / `readarray` — use `while IFS= read -r` loops
  - `coproc` — use explicit FD redirections or temp files
  - `|&` (pipe stderr) — use `2>&1 |`
  - `&>>` (append both streams) — use `>> file 2>&1`
  - `[[ -v var ]]` (variable-existence test) — use `[[ -n "${var:-}" ]]` or `[[ -z "${var+x}" ]]` (**silent wrong behavior on 3.2** — parsed as non-empty string test, always true)
  - `${arr[-1]}` (negative array index) — use `${arr[${#arr[@]}-1]}` (**silent wrong behavior on 3.2** — evaluates as arithmetic, wrong index)
  - `"${arr[@]}"` (unguarded empty array) — use `${arr[@]+"${arr[@]}"}` (crashes under `set -u` in Bash 3.2)
  - `readlink -f` (GNU-only) — use a loop or `_mps_readlink` helper
  - `md5sum` / `sha256sum` (GNU-only) — use `_mps_md5` / `_mps_sha256` from `lib/common.sh`
  - `shopt -s globstar` / `**` recursive glob — use `find`
  - `shopt -s lastpipe` — use process substitution `< <(...)` instead of piped `while read`
  - `${var@operator}` (parameter transforms) — use `printf '%q'` or equivalent
  - `wait -n` — use explicit PID tracking with `wait $pid`
- **Safe `rm -rf`**: Any `rm -rf` (or `rm -r`) that uses a variable **must** guard with `${var:?}` — e.g., `rm -rf "${dir:?}"`. Prevents catastrophic deletion if the variable is unexpectedly empty. Literal paths (e.g., `rm -rf /tmp/*`) do not need the guard.
- **Windows/PowerShell**: Deferred to a future phase. `install.ps1` exists as a placeholder.
- **CI/local parity**: All CI operations (except GitHub-specific actions like creating releases) must be runnable locally via `make` targets. The pattern is: shell script with the logic → Makefile target wrapping it in `docker run` → CI workflow calls `make`. **CI/YAML boundary**: shell scripts own all logic; GitHub Actions YAML is limited to GitHub-specific glue (checkout, permissions, PR comments, artifact upload, notifications). If a step has an `if`/`for`/validation, it belongs in a script — not inline YAML.

## Build System

Build/test/lint runs inside Docker containers — linter image for lint/test, builder image for Packer builds:
```
make build-docker-linter    # Build the linter image (shellcheck, hadolint, BATS, etc.)
make build-docker-builder   # Build the builder image (Packer, QEMU — no credentials)
make build-docker-publisher # Build the publisher image (b2, jq, yq — credential-isolated)
make lint             # Run all linters (shellcheck, lint-bash32, hadolint, yamllint, checkmake, packer fmt, py-psscriptanalyzer, actionlint)
make lint-actions      # Lint GitHub Actions workflows with actionlint
make test             # Run all tests with coverage (Bash 4+ instrumented + Bash 3.2 compat)
make test-unit        # Run unit tests only (both Bash versions, no coverage)
make test-integration # Run integration tests only (both Bash versions, no coverage)
make image-base       # Build base VM image (both archs in parallel via sub-make -j2)
make image-base-amd64 # Build base VM image (amd64 only)
make image-base-arm64 # Build base VM image (arm64 only)
make image-protocol-dev           # Build protocol-dev image (base + C/C++/Go/Rust)
make image-smart-contract-dev     # Build smart-contract-dev image (+ Solana[amd64]/Foundry/Hardhat)
make image-smart-contract-audit   # Build smart-contract-audit image (+ Slither/Echidna/Medusa)
make import-base                       # Import host-arch base image into mps cache
make upload-base-amd64 VERSION=1.0.0   # CI: upload image+sidecar to B2 (no manifest)
make update-manifest VERSION=1.0.0     # CI fan-in: single manifest write (downloads sidecars from B2)
make publish-base-amd64 VERSION=1.0.0  # Local: upload + manifest (single arch)
make publish-base VERSION=1.0.0        # Local: upload + manifest (both archs)
make publish-release-meta VERSION=0.3.0 # Publish mps-release.json to B2 (CLI update check)
make build-bash32                      # Build Bash 3.2.57 binary for compat linting
make lint-bash32                       # Check client scripts for Bash 3.2 compatibility
make test-e2e                          # Run E2E tests against live VM (with coverage)
make test-e2e-report                   # Merge coverage from all tiers (unit/integration/e2e)
make capture-fixtures                  # Capture fresh multipass JSON fixtures (requires multipass on host)
make install                           # Install mps (symlink to PATH, runs on host)
make uninstall        # Uninstall mps (remove symlink, cleanup artifacts, runs on host)
```

On amd64, non-base flavors chain from their parent's QCOW2 image, applying only the delta cloud-init layer (`--base-image` flag in `build.sh`). On arm64, all flavors build from scratch (cumulative layers merged) — arm64 CI runners lack KVM, so parallel from-scratch jobs are faster than a serial layered chain. The Makefile wires this automatically via stamp dependencies and `CUMULATIVE_LAYERS_*` variables.

The Makefile detects host uid:gid and the entrypoint uses setpriv to step down from root, so build artifacts match host ownership.

## Image Versioning

- **SemVer `x.y.z`** tracks tooling changes (what's installed in the image), not OS patches
- **Weekly cron rebuilds** re-bake the current version to pick up OS security patches — same version, same B2 path, updated SHA256 + `build_date` in manifest
- The `latest` pointer in manifest tracks the highest published SemVer
- **When to bump**:
  - **Patch** (`1.0.0` → `1.0.1`): Tool version updates, minor config tweaks in layers
  - **Minor** (`1.0.0` → `1.1.0`): New tool added to a layer
  - **Major** (`1.0.0` → `2.0.0`): Breaking changes (Ubuntu version bump, tool removed, major restructure)
- **Publishing** uses a fan-in pattern for CI with credential-isolated publisher container — see DECISIONS.md "Image Distribution" for CI/local flow details.
- **CLI update metadata**: `mps-release.json` published to CDN root (`mpsandbox.horizenlabs.io/mps-release.json`) by `release.yml`. Contains `version`, `tag`, `commit_sha`. Clients check at most once per 24h via `_mps_check_cli_update()` in `lib/common.sh`.
- **Git tags**: `mps/v*` for tool releases (must match `VERSION` file), `images/v*` for all image flavors (shared version). GPG-signed by authorized maintainers.

## Workflow

- After modifying any linted or tested file, run `make lint` and `make test` before committing. Linted files:
  - **Bash**: `bin/mps`, `lib/*.sh`, `commands/*.sh`, `completions/*.bash`, `tests/**/*.bats`, `tests/**/*.bash`, `tests/**/*.sh`, `tests/stubs/multipass`, `images/**/*.sh`, `.github/scripts/*.sh`, `install.sh`, `uninstall.sh`
  - **Bash 3.2 compat**: `bin/mps`, `lib/*.sh`, `commands/*.sh`, `completions/*.bash`, `tests/**/*.bash`, `tests/**/*.sh` (excluding `coverage-*`), `tests/stubs/multipass`, `install.sh`, `uninstall.sh` (client scripts only — no `images/`, `.github/scripts/`, `*.bats`, or `tests/coverage-*`; BATS 3.2 compat is verified by `make test` which runs under both bash versions)
  - **PowerShell**: `*.ps1`
  - **Dockerfile**: `docker/Dockerfile.builder`, `docker/Dockerfile.linter`, `docker/Dockerfile.publisher`, `docker/Dockerfile.bash32`
  - **Makefile**: `Makefile`
  - **YAML**: `templates/**/*.yaml`, `images/layers/*.yaml`, `.github/ISSUE_TEMPLATE/*.yml`
  - **HCL**: `images/**/*.pkr.hcl`
  - **GitHub Actions**: `.github/workflows/*.yml`
- Linting requires Docker. The linter image is built automatically if missing (`make lint` depends on the stamp file).
- Fix all lint errors before committing — do not bypass with `--no-verify` or inline disables unless there is a documented reason.
- **Test coverage**: `make test` always generates coverage. Minimum threshold is 90% — do not merge changes that drop total coverage below this. Check the coverage summary at the end of `make test` output.
- **checkmake quirks**: `minphony` only parses the first line of `.PHONY` declarations — keep `test` and `clean` on the first line. `maxbodylength` default max is 15 lines per target body (configured in `checkmake.ini`).
- **Local verification**: `multipass` and `jq` are installed on the dev machine — run `mps` commands directly to verify changes.
- **Snap confinement**: Multipass is installed as a snap, which restricts file access to the user's home directory. Use paths under `$HOME` (not `/tmp`) for `mps transfer` tests and temp files that interact with the VM.
- **End-to-end verification**: After implementing changes to command files (`commands/*.sh`) or core libraries (`lib/*.sh`), run the verification steps from the plan against a live VM on the host — not just `make lint`. If the plan includes a test script, execute it. Create a temporary instance (e.g., `--profile micro --name <test-name>`) and clean it up with `mps destroy` afterward.
- **Automated verification in plans**: Plans must always include an automated verification script — never manual testing steps. The script should create temporary instances, assert expected behavior, and clean up afterward.
- **Capture long command output with tee.** For `make test`, `make lint`, etc., always use: `make test 2>&1 | tee /tmp/mps-test.log` (with optional chained `| head`, `| tail` as needed. To inspect results (grep for failures, check summaries), use `Read /tmp/mps-test.log` — don't re-run the command just to parse output differently.

## Planning & Status

- Implementation plan and status: `.planning/STATUS.md`
- Architecture decisions: `.planning/DECISIONS.md`
- Testing strategy and coverage map: `tests/TESTING.md`
- CI/CD pipeline design: `.github/CI.md`
