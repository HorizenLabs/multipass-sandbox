# Architecture Decisions

Decisions made during planning sessions, preserved to avoid re-asking.

## Image Layer Contents

**Decision**: Cloud-init layers in `images/layers/` are merged at build time to produce the toolchain for each flavor. A separate minimal `templates/cloud-init/base.yaml` provides commented-out examples for VM launch customization.

**base layer** (all flavors):
- Docker: Official apt repo (`docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`). V2 plugin only.
- Node.js: Latest LTS via `nvm`, plus `pnpm`, `yarn`, `bun`
- Python: System Python 3 + `pip`, `venv`, `uv`
- CLI dev tools: `git`, `curl`, `wget`, `jq`, `yq`, `tmux`, `htop`, `tree`, `ripgrep`, `fd-find`, `vim`, `neovim`, `nano`, `shellcheck`, `hadolint`, `pv`, `p7zip-full`, `screen`
- AI coding assistants: Claude Code, Crush, OpenCode, Gemini CLI, Codex CLI
- Shell: Bash default, zsh installed but not default. `just` via apt.

**protocol-dev layer** (protocol-dev and above):
- Build toolchain: `build-essential`, `pkg-config`, `autoconf`, `automake`, `libtool`, `clang`, `llvm`, `libclang-dev`, `lld`, `cmake`
- SSL/crypto/dev libs: `libssl-dev`, `libffi-dev`, `zlib1g-dev`, `libbz2-dev`, `libreadline-dev`, `libsqlite3-dev`, `libncurses-dev`, `libxml2-dev`, `libxmlsec1-dev`, `liblzma-dev`, `libzstd-dev`, `libsquashfs-dev`, `libudev-dev`, `protobuf-compiler`, `libprotobuf-dev`
- Go: Latest stable from golang.org/dl (direct install to `/usr/local/go`)
- Rust: Via `rustup`, per-user (`~ubuntu/.cargo`), plus `cargo-audit`

**smart-contract-dev layer** (smart-contract-dev and above):
- Solana CLI + Anchor (via cargo/avm)
- Foundry (forge, cast, anvil, chisel)
- Hardhat + Solhint (via bun)

**smart-contract-audit layer** (smart-contract-audit only):
- cosign (sigstore verification)
- Slither, solc-select, Mythril, Halmos (via uv)
- Aderyn (Cyfrin installer)
- Echidna (sigstore-verified binary)
- Medusa (via go install)

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
| yq v4.45.1 | builder | SHA256 from rhash `checksums` file (field $19) |

**b2 standalone binary**: Replaces pip-based `b2[full]`. Eliminates python3/pip/venv from builder image.

**checkmake repo**: Original `mrtazz/checkmake` is archived. Moved to `checkmake/checkmake` (publishes checksums, `v`-prefixed tags).

## Cloud-init Dependency Verification

**Decision**: GitHub release tools in base image cloud-init are SHA-256 verified where publishers provide checksums.

| Tool | Verification |
|---|---|
| yq | SHA-256 from rhash `checksums` file (field $19) |
| hadolint | SHA-256 from `.sha256` sidecar |
| shellcheck | None (no checksums published) |
| cosign | SHA-256 from `cosign_checksums.txt` |
| Echidna | Sigstore bundle verified via cosign |

## Python Version Management

**Decision**: `uv` only — `pyenv` removed. uv manages Python versions directly (`uv python install 3.12`).

## Just (Command Runner)

**Decision**: Installed via apt (Ubuntu 24.04 universe repo) instead of `cargo install`. Faster, no Rust build cache bloat.

## Cargo Build Cache Cleanup

**Decision**: Clear `~/.cargo/registry`, `~/.cargo/git`, `~/.cargo/.package-cache` in post-provisioning. Binaries in `~/.cargo/bin/` preserved. Reduces image size from Anchor/AVM source builds.

## Image Flavors

**Decision**: Composable cloud-init layers merged at build time with `yq eval-all '. as $item ireduce ({}; . *+ $item)'`. Each layer is a standalone `#cloud-config` file.

**Layers** (cumulative — each flavor includes all preceding layers):

| Flavor | Layers | Use case |
|---|---|---|
| `base` | base | General dev (Docker, Node.js, Python, AI tools) |
| `protocol-dev` | base + protocol-dev | Systems/protocol dev (+ C/C++, Go, Rust) |
| `smart-contract-dev` | base + protocol-dev + smart-contract-dev | Smart contract dev (+ Solana, Foundry, Hardhat) |
| `smart-contract-audit` | all four layers | Full auditing toolkit (+ Slither, Echidna, Medusa) |

**yq merge strategy**: `*+` (deep merge with array append). `packages` lists merge additively, `runcmd` lists append in layer order, scalar keys (like `final_message`) are overwritten by later layers.

**Build artifacts**: All flavors output to `images/artifacts/mps-<flavor>-<arch>.qcow2.img`. Generated `cloud-init.yaml` is cleaned up after build.

**chown moved to post-provision**: `chown -R ubuntu:ubuntu /home/ubuntu` runs in `post-provision.sh` instead of as the last runcmd entry. This ensures it always runs after all layers' runcmd blocks regardless of merge order.

## Linting Coverage

| File type | Linter | Files |
|---|---|---|
| Bash | shellcheck | `bin/mps`, `lib/*.sh`, `commands/*.sh`, `images/**/*.sh`, `install.sh` |
| PowerShell | py-psscriptanalyzer | `*.ps1` |
| Dockerfile | hadolint | `Dockerfile.builder`, `Dockerfile.linter` |
| Makefile | checkmake | `Makefile` |
| YAML | yamllint | `templates/**/*.yaml`, `images/layers/*.yaml` |
| HCL | packer fmt -check | `images/**/*.pkr.hcl` |

**Shellcheck**: Command files use `# shellcheck disable=SC2154` at file-level — they're sourced by `bin/mps` which provides color variables from `lib/common.sh`. ShellCheck can't trace cross-file sourcing.

## Build System Stamp Files

**Decision**: `.stamp-*` files track Docker image build state in Make.

- `.stamp-builder` depends on `Dockerfile.builder` + `docker/entrypoint.sh`
- `.stamp-linter` depends on `Dockerfile.linter` + `docker/entrypoint.sh`
- `.stamp-image-<flavor>-{amd64,arm64}` — per-flavor per-arch, depend on builder stamp + shared image deps (packer.pkr.hcl, build.sh, all layers)
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

**Decision**: 15G virtual disk for QCOW2 images. Multipass + cloud-init `growpart` auto-expands at launch.

- 15G < lite profile's 20G, so all profiles work
- Increased from 10G after adding AI coding assistants (ENOSPC during build)
- `qemu-img convert` compaction in `build.sh` for optimal on-disk size

## Cloud-init Template Restructure

**Decision**: Separate full provisioning (image builds) from minimal customization (VM launch). See `CLAUDE.md` Project Structure for paths.

## QCOW2 File Extension

**Decision**: `.qcow2.img` — preserves format info while being Multipass-compatible (requires `.img`).

## Solidity Security Tools

**Decision**: Comprehensive Solidity auditing toolkit in the `smart-contract-audit` layer.

| Tool | Category | Install Method |
|---|---|---|
| Slither | Static analysis | `uv tool install slither-analyzer` |
| solc-select | Compiler management | `uv tool install solc-select` |
| Mythril | Symbolic execution | `uv tool install mythril` |
| Halmos | Symbolic testing (Foundry) | `uv tool install halmos` |
| Solhint | Linter | `bun install -g solhint` |
| Aderyn | Static analysis | Cyfrin installer script |
| Echidna | Fuzzer | Binary from GitHub releases |
| Medusa | Fuzzer | `go install` |

**Excluded**: Manticore (archived), Certora (commercial), Vyper tools (not needed).

## AI Coding Assistants

**Decision**: Pre-install agentic CLI/TUI coding assistants in the base layer (included in all flavors). Users bring their own API keys.

| Tool | Install Method | Runtime Deps |
|---|---|---|
| Claude Code | Native binary installer (`curl \| bash`) | None |
| Crush | bun (`@charmland/crush`) | Node.js (via bun) |
| OpenCode | bun (`opencode-ai`) | Node.js (via bun) |
| Gemini CLI | bun (`@google/gemini-cli`) | Node.js (via bun) |
| Codex CLI | bun (`@openai/codex`) | Node.js (via bun) |

**Selection criteria**: CLI/TUI agentic tools with large communities, primarily free to use, open source preferred. Excluded: IDE-only plugins, paid-only tools, small/niche projects.

**Claude Code Plugin Marketplaces**: Two marketplaces registered at image build time:

| Marketplace | Source | Access |
|---|---|---|
| `hl-claude-marketplace` | Git submodule at `vendor/hl-claude-marketplace` | Private (HorizenLabs) |
| `trailofbits/skills` | GitHub shorthand (cloned at build time) | Public |

**Private marketplace strategy**: Git submodule with relative URL (`../hl-claude-marketplace.git`). Resolves against parent repo remote, automatically using the same protocol (HTTPS or SSH). No credentials needed inside the Packer VM — files are copied via Packer `file` provisioner, then registered with `claude plugin marketplace add /local/path`. Build script verifies submodule is initialized before starting.

## Windows Support

**Decision**: PowerShell parity planned (Phase 7). `ConvertFrom-Json` instead of `jq`. Multipass uses Hyper-V (Pro/Enterprise) or VirtualBox (Home).
