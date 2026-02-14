# Architecture Decisions

Decisions made during planning sessions, preserved to avoid re-asking.

## Base Image Dependencies

**Decision**: The base cloud-init template (`images/base/cloud-init.yaml`) installs a comprehensive dev toolchain, not a minimal image. A separate minimal `templates/cloud-init/base.yaml` provides commented-out examples for VM launch customization.

**Docker**: Official apt repo (`docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`). V2 plugin only — no legacy `docker-compose` v1.

**Language Runtimes**:
- Node.js — Latest LTS via `nvm`, plus `pnpm`, `yarn`, `bun`
- Python — System Python 3 + `pip`, `venv`, `uv` (version manager)
- Go — Latest stable from golang.org/dl (direct install to `/usr/local/go`, no version manager)
- Rust — Via `rustup`, per-user (`~ubuntu/.cargo`), plus `just` via apt

**Build Toolchain**: `build-essential`, `pkg-config`, `autoconf`, `automake`, `libtool`, `clang`, `llvm`, `cmake`

**CLI Dev Tools**: `git`, `curl`, `wget`, `jq`, `yq`, `tmux`, `htop`, `tree`, `ripgrep`, `fd-find`, `vim`, `neovim`, `nano`, `shellcheck`, `hadolint`

**Shell**: Bash as default. No zsh/oh-my-zsh.

## Mount Behavior

**Decision**: Auto-mount host CWD by default, path-preserving semantics. See `CLAUDE.md` for full conventions.

Additional: CLI path argument overrides CWD (`mps up /path/to/project`).

## VM Auto-Naming

**Decision**: VMs auto-named from mount path, template, and profile. See `CLAUDE.md` for format and override options.

Additional:
- Folder name sanitized: lowercased, non-alphanumeric replaced with dashes, 4-char md5 hash for truncated names
- Commands on existing instances (down, destroy, shell, exec, status, ssh-config) auto-resolve from CWD + default template + default profile

## Config System

**Decision**: Simple KEY=VALUE env files, no YAML parsing in Bash. See `CLAUDE.md` for cascade order.

## Image Distribution

**Decision**: Backblaze B2 for storage, Cloudflare proxy for public serving.

- `MPS_IMAGE_BASE_URL` — public Cloudflare-proxied URL
- `MPS_B2_BUCKET` / `MPS_B2_BUCKET_PREFIX` — B2 upload settings (for publish scripts)
- Bucket creation and Cloudflare config handled externally
- Manifest: `images/manifest.json` with SemVer versions + `latest` pointer per image
- Architecture-aware: separate `amd64`/`arm64` images per version
- SHA256 checksums verified on pull; local cache at `~/.mps/cache/images/`

## Dockerized Build System

**Decision**: All build, test, lint, and publish commands run inside Docker containers. Two images: builder (heavy, QEMU) and linter (lightweight).

**Why setpriv over gosu**: gosu re-execs as the target user but does not apply supplementary groups added via `usermod`. When the builder user needed KVM group membership for QEMU acceleration, gosu silently dropped it, causing "permission denied" on `/dev/kvm`. `setpriv --groups` explicitly passes supplementary group IDs. setpriv is also a util-linux builtin (no extra install).

## Secure Dependency Installation

**Decision**: Non-OS dependencies installed with integrity verification where possible. No pip packages in builder image.

| Tool | Image | Verification |
|---|---|---|
| Packer | both | GPG-signed HashiCorp apt repo |
| b2 CLI v4.5.1 | builder | SHA256 from `_hashes.txt` sidecar |
| shellcheck v0.11.0 | linter | None (no hashes published) |
| hadolint v2.14.0 | linter | SHA256 from `.sha256` sidecar |
| checkmake v0.3.2 | linter | SHA256 from `checksums.txt` |
| BATS v1.13.0 | linter | None (no hashes published) |
| PowerShell | linter | GPG-signed Microsoft apt repo |
| yamllint, py-psscriptanalyzer | linter | None (pip) |

**b2 standalone binary**: Replaces pip-based `b2[full]`. Eliminates python3/pip/venv from builder image.

**checkmake repo**: Original `mrtazz/checkmake` is archived. Moved to `checkmake/checkmake` (publishes checksums, `v`-prefixed tags).

## Cloud-init Dependency Verification

**Decision**: GitHub release tools in base image cloud-init are SHA-256 verified where publishers provide checksums.

| Tool | Verification |
|---|---|
| yq | SHA-256 from rhash `checksums` file (field $19) |
| hadolint | SHA-256 from `.sha256` sidecar |
| shellcheck | None (no checksums published) |

## Python Version Management

**Decision**: `uv` only — `pyenv` removed. uv manages Python versions directly (`uv python install 3.12`).

## Just (Command Runner)

**Decision**: Installed via apt (Ubuntu 24.04 universe repo) instead of `cargo install`. Faster, no Rust build cache bloat.

## Cargo Build Cache Cleanup

**Decision**: Clear `~/.cargo/registry`, `~/.cargo/git`, `~/.cargo/.package-cache` in post-provisioning. Binaries in `~/.cargo/bin/` preserved. Reduces image size from Anchor/AVM source builds.

## Image Flavors

**Decision**: Single `base` image. Blockchain tools (Solana, Anchor, Foundry, Hardhat) included in base — no separate `blockchain` flavor.

## Linting Coverage

| File type | Linter | Files |
|---|---|---|
| Bash | shellcheck | `bin/mps`, `lib/*.sh`, `commands/*.sh`, `images/**/*.sh`, `install.sh` |
| PowerShell | py-psscriptanalyzer | `*.ps1` |
| Dockerfile | hadolint | `Dockerfile.builder`, `Dockerfile.linter` |
| Makefile | checkmake | `Makefile` |
| YAML | yamllint | `templates/**/*.yaml`, `images/**/*.yaml` |
| HCL | packer fmt -check | `images/**/*.pkr.hcl` |

**Shellcheck**: Command files use `# shellcheck disable=SC2154` at file-level — they're sourced by `bin/mps` which provides color variables from `lib/common.sh`. ShellCheck can't trace cross-file sourcing.

## Build System Stamp Files

**Decision**: `.stamp-*` files track Docker image build state in Make.

- `.stamp-builder` depends on `Dockerfile.builder` + `docker/entrypoint.sh`
- `.stamp-linter` depends on `Dockerfile.linter` + `docker/entrypoint.sh`
- `.stamp-image-base-{amd64,arm64}` — per-arch, depend on builder stamp + Packer/cloud-init sources
- `make clean` removes `.stamp-*`; `.stamp-*` is in `.gitignore`

## File Transfer

**Decision**: Colon-prefix convention for guest paths in `mps transfer`.

- `:` prefix distinguishes guest paths (e.g., `:/home/ubuntu/file.txt`)
- Supports host->guest (multiple sources), guest->host (single source — multipass limitation)
- `--transfer` on `mps create` seeds files after VM creation (first-colon split)
- Transfer specs stored in instance metadata as `MPS_TRANSFER+=<spec>`

## Local Image Support

**Decision**: Explicit import, not auto-discovery. `mps image import <file>` copies QCOW2 into `~/.mps/cache/images/`.

- Cache path: `~/.mps/cache/images/<name>/<tag>/<arch>.img`
- `.meta` sidecar (KEY=VALUE), read via `grep`/`cut` only (never `source`d)
- Default tag "local", override with `--tag`; highest SemVer wins over "local" for resolution
- Name/arch auto-detected from filename convention (`mps-base-amd64.qcow2` -> name=base, arch=amd64)
- `mps_resolve_image()` checks cache first, falls through to `multipass launch` for Ubuntu versions

## SSH Key Management

**Decision**: User-provided SSH keys, injected on-demand via `mps ssh-config`. No sudo required.

- `mps ssh-config` is the **only** command that injects SSH keys
- Key resolution: `--ssh-key` flag -> `MPS_SSH_KEY` config -> auto-detect from `~/.ssh/` (ed25519 > ecdsa > rsa)
- Injection is idempotent (checks `MPS_SSH_INJECTED=true` metadata)
- `mps port forward` requires SSH pre-configured — errors with helpful message

## Image Disk Sizing

**Decision**: 10G virtual disk for QCOW2 images. Multipass + cloud-init `growpart` auto-expands at launch.

- 10G < lite profile's 20G, so all profiles work
- Actual usage: ~6.7G (67%), ~3G headroom
- `qemu-img convert` compaction in `build.sh` for optimal on-disk size

## Cloud-init Template Restructure

**Decision**: Separate full provisioning (image builds) from minimal customization (VM launch). See `CLAUDE.md` Project Structure for paths.

## QCOW2 File Extension

**Decision**: `.qcow2.img` — preserves format info while being Multipass-compatible (requires `.img`).

## Windows Support

**Decision**: PowerShell parity planned (Phase 7). `ConvertFrom-Json` instead of `jq`. Multipass uses Hyper-V (Pro/Enterprise) or VirtualBox (Home).
