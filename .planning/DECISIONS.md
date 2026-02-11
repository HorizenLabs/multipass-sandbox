# Architecture Decisions

Decisions made during planning sessions, preserved to avoid re-asking.

## Base Image Dependencies

**Decision**: The base cloud-init template (`templates/cloud-init/base.yaml`) installs a comprehensive dev toolchain, not a minimal image.

**Docker**: Official Docker apt repo (`docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`). V2 plugin only — no legacy `docker-compose` v1 standalone binary.

**Language Runtimes**:
- Node.js — Latest LTS via `nvm`, plus `pnpm`, `yarn`, `bun`
- Python — System Python 3 + `pip`, `venv`, `uv`, `pyenv` (version manager)
- Go — Latest stable from golang.org/dl (direct install to `/usr/local/go`, no version manager)
- Rust — Via `rustup`, per-user (`~ubuntu/.cargo`), plus `just` installed via cargo

**Build Toolchain**: `build-essential`, `pkg-config`, `autoconf`, `automake`, `libtool`, `clang`, `llvm`, `cmake`

**CLI Dev Tools**: `git`, `curl`, `wget`, `jq`, `yq`, `tmux`, `htop`, `tree`, `ripgrep`, `fd-find`, `vim`, `neovim`, `nano`, `shellcheck`, `hadolint` (from GitHub releases)

**Shell**: Bash as default shell. No zsh/oh-my-zsh.

**Editors**: vim + neovim + nano all installed, user chooses.

## Mount Behavior

**Decision**: Auto-mount host CWD by default, path-preserving semantics.

- Linux/macOS: identical path on host and guest (e.g., `/home/user/project` → `/home/user/project`)
- Windows: drive letter conversion (`C:\Users\foo\project` → `/c/Users/foo/project`)
- Read-write by default
- `mps shell`/`mps exec` auto-set working directory inside guest to the mounted path
- CLI path argument overrides CWD: `mps up /path/to/project`
- `MPS_MOUNTS` in `.mps.env` is additive (extra mounts on top of auto-mount)
- `MPS_NO_AUTOMOUNT=true` disables CWD auto-mount

## VM Auto-Naming

**Decision**: VMs are automatically named based on mount path, template, and profile.

- Format: `mps-<folder-basename>-<template>-<profile>` (e.g., `mps-myproject-base-standard`)
- Override with `--name` flag on any command, or `MPS_NAME` in `.mps.env`
- Long names (>40 chars, Multipass limit) are truncated with a 4-char md5 hash suffix for uniqueness
- Folder name is sanitized: lowercased, non-alphanumeric replaced with dashes
- `--no-mount` without `--name` errors out (can't derive name without a folder)
- Commands that operate on existing instances (down, destroy, shell, exec, status, ssh-config) auto-resolve from CWD + default template + default profile

## Config System

**Decision**: Simple KEY=VALUE env files. No YAML parsing in Bash.

Cascade (later wins): `config/defaults.env` → `~/.mps/config` → `.mps.env` → CLI flags

## Image Distribution

**Decision**: Backblaze B2 for storage, Cloudflare proxy for public serving. OCI registry planned for later.

- `MPS_IMAGE_BASE_URL` — public URL (Cloudflare-proxied, e.g., `https://images.example.com/mps`)
- `MPS_B2_BUCKET` / `MPS_B2_BUCKET_PREFIX` — B2 upload settings (for publish scripts)
- Bucket creation and Cloudflare config handled externally, not by this repo
- Manifest: `images/manifest.json` with SemVer versions + `latest` pointer per image
- Architecture-aware: separate `amd64`/`arm64` images per version
- SHA256 checksums verified on pull
- Local cache at `~/.mps/cache/images/`
- Publish via `images/publish.sh` using `b2` CLI

## Dockerized Build System

**Decision**: All build, test, lint, and publish commands run inside a Docker container for reproducibility.

- `Dockerfile.builder` — Ubuntu 24.04 + packer, shellcheck, hadolint, bats, b2 CLI, yamllint, checkmake, py-psscriptanalyzer, gosu
- `docker/entrypoint.sh` — Creates user matching host uid:gid via gosu, so artifacts have correct ownership
- `Makefile` detects `$(id -u):$(id -g)` and passes as `HOST_UID`/`HOST_GID` env vars
- All `make` targets (except `install`) use `docker run -v $PWD:/workdir`
- Lint targets: `lint-bash`, `lint-powershell`, `lint-dockerfile`, `lint-makefile`, `lint-yaml`, `lint-hcl`

## Linting Coverage

| File type | Linter | Files |
|---|---|---|
| Bash | shellcheck | `bin/mps`, `lib/*.sh`, `commands/*.sh`, `images/**/*.sh`, `install.sh` |
| PowerShell | py-psscriptanalyzer | `*.ps1` |
| Dockerfile | hadolint | `Dockerfile.builder` |
| Makefile | checkmake | `Makefile` |
| YAML | yamllint | `templates/cloud-init/*.yaml` |
| HCL | packer fmt -check | `images/**/*.pkr.hcl` |

## File Transfer

**Decision**: Colon-prefix convention for guest paths in `mps transfer`.

- `mps transfer` uses `:` prefix to distinguish guest paths from host paths (e.g., `:/home/ubuntu/file.txt`)
- The command auto-resolves the instance name and prepends it to guest paths before calling `multipass transfer`
- Supports host->guest (multiple sources), guest->host (single source only, multipass limitation)
- `mps create --transfer <host-path>:<guest-path>` seeds files after VM creation (always host->guest)
- `--transfer` on create uses first-colon split (host paths cannot start with `:`, guest paths are absolute)
- Transfer specs stored in instance metadata as `MPS_TRANSFER+=<spec>` for reference

## Windows Support

**Decision**: PowerShell parity planned (Phase 4), not yet implemented.

- `bin/mps.ps1` + `commands/*.ps1` + `lib/*.ps1`
- `ConvertFrom-Json` instead of `jq`
- Multipass on Windows uses Hyper-V (Pro/Enterprise) or VirtualBox (Home)
