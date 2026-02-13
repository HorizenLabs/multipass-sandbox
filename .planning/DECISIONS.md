# Architecture Decisions

Decisions made during planning sessions, preserved to avoid re-asking.

## Base Image Dependencies

**Decision**: The base cloud-init template (`images/base/cloud-init.yaml`) installs a comprehensive dev toolchain, not a minimal image. This template is baked into pre-built images via Packer. A separate minimal `templates/cloud-init/base.yaml` provides commented-out examples for VM launch customization.

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

**Decision**: All build, test, lint, and publish commands run inside Docker containers for reproducibility. Two separate images keep lint fast by excluding heavy QEMU packages.

- `Dockerfile.builder` — Ubuntu 24.04 + Packer, QEMU (x86+arm64+EFI), b2 CLI, xorriso, openssh-client. Used for image builds.
- `Dockerfile.linter` — Ubuntu 24.04 + shellcheck, hadolint, BATS, Packer (for `fmt`), checkmake, PowerShell + py-psscriptanalyzer, yamllint. Used for lint/test.
- `docker/entrypoint.sh` — Creates user matching host uid:gid via `setpriv` (not gosu — gosu doesn't apply supplementary groups, which broke KVM access). Passes `--groups` for KVM device access, drops all capabilities with `--inh-caps=-all`.
- `Makefile` detects `$(id -u):$(id -g)` and passes as `HOST_UID`/`HOST_GID` env vars
- All `make` targets (except `install`) use `docker run -v $PWD:/workdir`
- Lint targets: `lint-bash`, `lint-powershell`, `lint-dockerfile`, `lint-makefile`, `lint-yaml`, `lint-hcl`

**Why setpriv over gosu**: gosu re-execs as the target user but does not apply supplementary groups added via `usermod`. When the builder user needed KVM group membership for QEMU acceleration, gosu silently dropped it, causing "permission denied" on `/dev/kvm`. `setpriv --groups` explicitly passes supplementary group IDs, fixing the issue. setpriv is also a util-linux builtin (no extra install needed).

## Linting Coverage

| File type | Linter | Files |
|---|---|---|
| Bash | shellcheck | `bin/mps`, `lib/*.sh`, `commands/*.sh`, `images/**/*.sh`, `install.sh` |
| PowerShell | py-psscriptanalyzer | `*.ps1` |
| Dockerfile | hadolint | `Dockerfile.builder`, `Dockerfile.linter` |
| Makefile | checkmake | `Makefile` |
| YAML | yamllint | `templates/**/*.yaml`, `images/**/*.yaml` |
| HCL | packer fmt -check | `images/**/*.pkr.hcl` |

**Shellcheck approach**: Command files (`commands/*.sh`) use `# shellcheck disable=SC2154` at file-level because they are sourced at runtime by `bin/mps` which provides color variables from `lib/common.sh`. ShellCheck cannot trace cross-file sourcing chains, so the directive is the correct fix.

## Build System Stamp Files

**Decision**: Use `.stamp-*` files to track Docker image build state in Make.

- `.stamp-builder` depends on `Dockerfile.builder` + `docker/entrypoint.sh` — image build targets use this
- `.stamp-linter` depends on `Dockerfile.linter` + `docker/entrypoint.sh` — lint and test targets use this
- Each stamp is created after its `docker build` succeeds; targets only rebuild when inputs change
- `make clean` removes `.stamp-*` files
- `.stamp-*` is in `.gitignore`

## File Transfer

**Decision**: Colon-prefix convention for guest paths in `mps transfer`.

- `mps transfer` uses `:` prefix to distinguish guest paths from host paths (e.g., `:/home/ubuntu/file.txt`)
- The command auto-resolves the instance name and prepends it to guest paths before calling `multipass transfer`
- Supports host->guest (multiple sources), guest->host (single source only, multipass limitation)
- `mps create --transfer <host-path>:<guest-path>` seeds files after VM creation (always host->guest)
- `--transfer` on create uses first-colon split (host paths cannot start with `:`, guest paths are absolute)
- Transfer specs stored in instance metadata as `MPS_TRANSFER+=<spec>` for reference

## Local Image Support

**Decision**: Explicit import, not auto-discovery. Users run `mps image import <file>` to copy a QCOW2 into `~/.mps/cache/images/`.

- Imported images go to `~/.mps/cache/images/<name>/<tag>/<arch>.img` — same structure as pulled images
- `mps image list` discovers both imported and pulled images with zero additional scan logic
- `.meta` sidecar (KEY=VALUE) written alongside each imported `.img` file, never `source`d — read via `grep`/`cut` only
- Default tag is "local", override with `--tag 1.0.0` for SemVer
- When resolving `--image base` (no explicit tag), highest SemVer wins over "local"; user can pin with `--image base:local`
- `MPS_DEFAULT_IMAGE` in config cascade supports both Ubuntu versions (`24.04`) and mps image names (`base`, `base:1.0.0`)
- `mps_resolve_image()` checks cache first; if no match, passes string through unchanged to `multipass launch`
- Name/arch auto-detected from filename convention (`mps-base-amd64.qcow2` → name=base, arch=amd64)

## SSH Key Management

**Decision**: User-provided SSH keys, injected on-demand via `mps ssh-config`. No sudo required.

- `mps ssh-config` is the **only** command that injects SSH keys into VMs
- Key resolution: `--ssh-key` flag → `MPS_SSH_KEY` config → auto-detect from `~/.ssh/` (ed25519 > ecdsa > rsa)
- Injection is idempotent — checks instance metadata for `MPS_SSH_INJECTED=true` before re-injecting
- Private key path stored in instance metadata as `MPS_SSH_KEY=<path>`
- `mps port forward` requires SSH to be pre-configured — errors with helpful message directing to `mps ssh-config`
- `mp_ssh_info()` now reads from instance metadata instead of OS-specific Multipass key paths
- Removed dependency on root-owned Multipass SSH keys (no more `sudo`)

## Image Disk Sizing

**Decision**: 16G virtual disk size for QCOW2 images. Multipass + cloud-init `growpart` auto-expands at launch.

- 16G < lite profile's 20G disk, so all profiles work without manual resize
- Smaller virtual size means faster downloads and less wasted space in B2
- `qemu-img convert` compaction step in `build.sh` for optimal on-disk size after Packer build

## Cloud-init Template Restructure

**Decision**: Separate full provisioning template (for image builds) from minimal customization template (for VM launch).

- `images/base/cloud-init.yaml` — Full provisioning: Docker, runtimes, tools, blockchain. Used by Packer during image builds.
- `templates/cloud-init/base.yaml` — Minimal: commented-out examples. Used at VM launch from pre-built images.
- Auto-naming convention preserved: `mps-<folder>-base-standard` still uses `base` template
- Packer reference changed from `${var.mps_root}/templates/cloud-init/base.yaml` to `${path.root}/cloud-init.yaml`

## QCOW2 File Extension

**Decision**: `.qcow2.img` extension for build output instead of plain `.qcow2`.

- Multipass expects `.img` extension for custom images
- `.qcow2.img` preserves the format information while being Multipass-compatible
- Applied consistently across Packer, build.sh, Makefile, image import, and publish scripts

## Windows Support

**Decision**: PowerShell parity planned (Phase 7), not yet implemented.

- `bin/mps.ps1` + `commands/*.ps1` + `lib/*.ps1`
- `ConvertFrom-Json` instead of `jq`
- Multipass on Windows uses Hyper-V (Pro/Enterprise) or VirtualBox (Home)
