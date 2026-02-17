# Multi Pass Sandbox (mps)

Internal CLI tool for spinning up isolated VM-based development environments using Canonical Multipass. Provides stronger isolation than Docker containers alone — full VMs with Docker daemons running inside.

## Tech Stack

- **CLI**: Bash (macOS/Linux), PowerShell planned (Windows)
- **VM Engine**: Canonical Multipass
- **Config**: KEY=VALUE .env files (no YAML parsing in Bash)
- **Dependencies**: `multipass`, `jq`
- **Image builds**: Packer (QCOW2, `.qcow2.img` extension), published to Backblaze B2 (served via Cloudflare)
- **Image versioning**: SemVer (x.y.z) with `latest` pointer, weekly rebuilds for OS patches
- **Build/Test**: All run inside Docker containers (`mps-builder` for image builds, `mps-linter` for lint/test, `mps-publisher` for B2 uploads)
- **Tests**: BATS (planned)

## Project Structure

- `bin/mps` — Main entry point, subcommand dispatch
- `lib/common.sh` — Logging, config cascade, path conversion, mount resolution, auto-naming, auto-scaling resources
- `lib/multipass.sh` — Thin wrappers around `multipass` CLI with `--format json` + `jq`
- `commands/*.sh` — One file per subcommand, each exports `cmd_<name>()` function
- `templates/cloud-init/` — Minimal cloud-init templates for VM launch customization
- `images/layers/` — Composable cloud-init layer files (base, protocol-dev, smart-contract-dev, smart-contract-audit)
- `images/build.sh` — Image build script (takes flavor arg, merges layers with yq)
- `images/packer.pkr.hcl` — Packer template (shared across all flavors)
- `images/packer-user-data.pkrtpl.hcl` — Packer user-data template (cloud-init wrapper for builds)
- `images/arch-config.sh` — Per-arch Packer variable resolution (KVM vs TCG, EFI firmware, CPU/memory auto-detect)
- `images/artifacts/` — Built QCOW2 images (gitignored)
- `images/scripts/post-provision.sh` — Post-build cleanup (runs after cloud-init)
- `images/manifest.json` — Local skeleton manifest (image descriptions + metadata); live manifest lives in B2
- `images/lib/publish-common.sh` — Shared helpers for publish, update-manifest, and generate-index scripts
- `images/publish.sh` — Upload images to B2 (`--upload-only` for CI, default includes manifest update for local dev)
- `images/update-manifest.sh` — Fan-in manifest update: downloads .sha256 sidecars from B2, single manifest write
- `images/generate-index.sh` — Generate autoindex HTML pages from manifest and upload to B2
- `templates/profiles/` — Resource profiles (micro, lite, standard, heavy) with auto-scaling CPU/memory
- `VERSION` — Tool version (SemVer), read by `bin/mps` at startup
- `config/defaults.env` — Shipped defaults
- `Dockerfile.builder` + `docker/entrypoint.sh` — Builder image (Packer, QEMU — no B2 credentials)
- `Dockerfile.linter` — Linter/test image (shellcheck, hadolint, BATS, PSScriptAnalyzer, yamllint, etc.)
- `Dockerfile.publisher` — Publisher image (b2, jq, yq — credential-isolated from builder)
- `Makefile` — All targets run inside Docker containers via `docker run`
- `install.sh` / `install.ps1` — Installer scripts
- `uninstall.sh` — Uninstaller (removes symlink, VMs, caches, configs)
- `checkmake.ini`, `.yamllint`, `.github/actionlint.yaml` — Linter configuration files
- `CODEOWNERS` — GitHub code ownership for PR review routing
- `.github/workflows/` — GitHub Actions CI/CD pipelines (ci, images, release, update-submodule)
- `.github/actions/verify-gpg-tag/` — Composite action for GPG tag signature verification
- `vendor/hl-claude-marketplace` — Git submodule: private Claude Code plugin marketplace (relative URL)
- `.planning/` — Implementation plan, architecture decisions, CI design, status tracking

## Commands

- `mps create` / `mps up` / `mps down` / `mps destroy` — VM lifecycle
- `mps shell` / `mps exec` — Interactive shell / run command (auto-workdir)
- `mps list` / `mps status` — List all / detailed info
- `mps ssh-config` — Generate SSH config for VS Code (also injects SSH keys)
- `mps image [list|pull|import|remove]` — Manage pre-built QCOW2 images
- `mps port [forward|list]` — SSH port forwarding
- `mps transfer` — File copy between host and guest (`:` prefix = guest path)

## Key Conventions

- **Auto-naming**: `mps-<folder-basename>-<template>-<profile>` (e.g., `mps-myproject-default-lite`)
  - Override with `--name` flag or `MPS_NAME` in `.mps.env`
  - Long names truncated with short hash suffix (max 40 chars for Multipass)
  - `--no-mount` without `--name` errors (can't derive folder name)
- Config cascade: `config/defaults.env` → `~/.mps/config` → `.mps.env` → profile → auto-scaling → CLI flags
- **Default profile**: `lite` (auto-scales CPU/memory from host hardware fractions with min/cap)
- **Profiles**: micro (1/8 CPU, 1/16 mem), lite (1/4, 1/6), standard (1/3, 1/4), heavy (1/2, 1/3)
- **Image metadata**: `x-mps:` blocks in layer YAMLs define disk_size, min_profile, min_disk/memory/cpus
- `mps create` warns when resolved resources are below image minimums (never blocks)
- Default mount: host CWD → guest at same absolute path (read-write)
- Windows path conversion: `C:\foo\bar` → `/c/foo/bar`
- `MPS_MOUNTS` is additive (on top of auto-mount), `MPS_NO_AUTOMOUNT=true` to opt out
- `mps shell`/`mps exec` auto-set workdir to the mounted project path
- Commands use `while/case/shift` arg parsing, private `_<cmd>_usage()` helpers
- Color output uses `$'\033[...]'` ANSI-C quoting (not double-quoted `\033`)
- **Cross-platform**: Scripts in `bin/`, `commands/`, `lib/`, `config/`, and `install.sh` must work on both GNU/Linux and BSD/macOS, targeting Bash 3.2+ (macOS default). Avoid: `${var,,}` (use `tr`), `readlink -f` (use loop), `md5sum`/`sha256sum` (use `_mps_md5`/`_mps_sha256` from `lib/common.sh`). Scripts in `images/` run inside Docker and may use GNU-only tools.

## Build System

Build/test/lint runs inside Docker containers — linter image for lint/test, builder image for Packer builds:
```
make build-docker-linter    # Build the linter image (shellcheck, hadolint, BATS, etc.)
make build-docker-builder   # Build the builder image (Packer, QEMU — no credentials)
make build-docker-publisher # Build the publisher image (b2, jq, yq — credential-isolated)
make lint             # Run all linters (shellcheck, hadolint, yamllint, checkmake, packer fmt, py-psscriptanalyzer, actionlint)
make lint-actions      # Lint GitHub Actions workflows with actionlint
make test             # Run BATS tests
make image-base       # Build base VM image (both archs in parallel via sub-make -j2)
make image-base-amd64 # Build base VM image (amd64 only)
make image-base-arm64 # Build base VM image (arm64 only)
make image-protocol-dev           # Build protocol-dev image (base + C/C++/Go/Rust)
make image-smart-contract-dev     # Build smart-contract-dev image (+ Solana/Foundry/Hardhat)
make image-smart-contract-audit   # Build smart-contract-audit image (+ Slither/Echidna/Medusa)
make import-base                       # Import host-arch base image into mps cache
make upload-base-amd64 VERSION=1.0.0   # CI: upload image+sidecar to B2 (no manifest)
make update-manifest VERSION=1.0.0     # CI fan-in: single manifest write (downloads sidecars from B2)
make publish-base-amd64 VERSION=1.0.0  # Local: upload + manifest (single arch)
make publish-base VERSION=1.0.0        # Local: upload + manifest (both archs)
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
- **Publishing** uses a fan-in pattern for CI, with a dedicated publisher container (credential-isolated from the builder). B2 credentials (`B2_APPLICATION_KEY_ID`, `B2_APPLICATION_KEY`) are passed as env vars at runtime. Old image file versions in B2 are cleaned up; manifest versions are kept for audit trail.
  - **CI flow**: Runners call `publish.sh --upload-only` to upload images + `.sha256` sidecars to B2 (no manifest touch). A fan-in job then runs `update-manifest.sh` which downloads sidecars from B2 and performs a single manifest read-modify-write. Zero race window.
  - **Local flow**: `publish.sh` (no flag) does upload + manifest update in one shot, same as before.

## Workflow

- After modifying any linted file, run `make lint` before committing. Linted files:
  - **Bash**: `bin/mps`, `lib/*.sh`, `commands/*.sh`, `images/**/*.sh`, `install.sh`, `uninstall.sh`
  - **PowerShell**: `*.ps1`
  - **Dockerfile**: `Dockerfile.builder`, `Dockerfile.linter`, `Dockerfile.publisher`
  - **Makefile**: `Makefile`
  - **YAML**: `templates/**/*.yaml`, `images/layers/*.yaml`
  - **HCL**: `images/**/*.pkr.hcl`
  - **GitHub Actions**: `.github/workflows/*.yml`
- Linting requires Docker. The linter image is built automatically if missing (`make lint` depends on the stamp file).
- Fix all lint errors before committing — do not bypass with `--no-verify` or inline disables unless there is a documented reason.

## Planning & Status

- Full implementation plan: `.planning/PLAN.md`
- Architecture decisions: `.planning/DECISIONS.md`
- Implementation status: `.planning/STATUS.md`
- CI/CD pipeline design: `.github/CI.md`
