# Multi Pass Sandbox (mps)

Internal CLI tool for spinning up isolated VM-based development environments using Canonical Multipass. Provides stronger isolation than Docker containers alone — full VMs with Docker daemons running inside.

## Tech Stack

- **CLI**: Bash (macOS/Linux), PowerShell planned (Windows)
- **VM Engine**: Canonical Multipass
- **Config**: KEY=VALUE .env files (no YAML parsing in Bash)
- **Dependencies**: `multipass`, `jq`
- **Image builds**: Packer (QCOW2), published to Backblaze B2 (served via Cloudflare)
- **Image versioning**: SemVer (x.y.z) with `latest` pointer
- **Build/Test**: All run inside `mps-builder` Docker container for reproducibility
- **Tests**: BATS (planned)

## Project Structure

- `bin/mps` — Main entry point, subcommand dispatch
- `lib/common.sh` — Logging, config cascade, path conversion, mount resolution, auto-naming
- `lib/multipass.sh` — Thin wrappers around `multipass` CLI with `--format json` + `jq`
- `commands/*.sh` — One file per subcommand, each exports `cmd_<name>()` function
- `templates/cloud-init/` — Cloud-init YAML templates (base, blockchain, ai-agent)
- `templates/profiles/` — Resource profiles (lite, standard, heavy)
- `config/defaults.env` — Shipped defaults
- `images/` — Packer build scripts + `publish.sh` for B2 upload + `manifest.json`
- `Dockerfile.builder` + `docker/entrypoint.sh` — Builder image with all dev tools
- `Makefile` — All targets run inside builder container via `docker run`

## Key Conventions

- **Auto-naming**: `mps-<folder-basename>-<template>-<profile>` (e.g., `mps-myproject-base-standard`)
  - Override with `--name` flag or `MPS_NAME` in `.mps.env`
  - Long names truncated with short hash suffix (max 40 chars for Multipass)
  - `--no-mount` without `--name` errors (can't derive folder name)
- Config cascade: `config/defaults.env` → `~/.mps/config` → `.mps.env` → CLI flags
- Default mount: host CWD → guest at same absolute path (read-write)
- Windows path conversion: `C:\foo\bar` → `/c/foo/bar`
- `MPS_MOUNTS` is additive (on top of auto-mount), `MPS_NO_AUTOMOUNT=true` to opt out
- `mps shell`/`mps exec` auto-set workdir to the mounted project path
- Commands use `while/case/shift` arg parsing, private `_<cmd>_usage()` helpers
- Color output uses `$'\033[...]'` ANSI-C quoting (not double-quoted `\033`)

## Build System

All build/test/lint runs inside the `mps-builder` Docker image:
```
make builder          # Build the builder image
make lint             # Run all linters (shellcheck, hadolint, yamllint, checkmake, packer fmt, py-psscriptanalyzer)
make test             # Run BATS tests
make image-base       # Build base VM image with Packer
make publish-base VERSION=1.0.0   # Publish to Backblaze B2
```

The Makefile detects host uid:gid and the entrypoint uses gosu to step down from root, so build artifacts match host ownership.

## Planning & Status

- Full implementation plan: `.planning/PLAN.md`
- Architecture decisions: `.planning/DECISIONS.md`
- Implementation status: `.planning/STATUS.md`
