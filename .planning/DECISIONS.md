# Architecture Decisions

Decisions made during planning sessions, preserved to avoid re-asking. For conventions and project structure, see `CLAUDE.md`.

## Image Layer Contents

Cloud-init layers in `images/layers/` are merged at build time to produce the toolchain for each flavor. A separate minimal `templates/cloud-init/default.yaml` provides commented-out examples for VM launch customization.

**base layer** (all flavors):
- Docker: Official apt repo (`docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`). V2 plugin only.
- Node.js: Latest LTS via `nvm`, plus `pnpm`, `yarn`, `bun`
- Python: System Python 3 + `venv`, `uv` (also manages Python versions — no pyenv)
- CLI dev tools: `git`, `curl`, `wget`, `jq`, `yq`, `tmux`, `htop`, `tree`, `ripgrep`, `fd-find`, `vim`, `neovim`, `nano`, `shellcheck`, `hadolint`, `pv`, `p7zip-full`, `screen`
- AI coding assistants: Claude Code, Crush, OpenCode, Gemini CLI, Codex CLI
- Shell: Bash default, zsh installed but not default. `just` via apt.

**protocol-dev layer** (protocol-dev and above):
- Build toolchain: `build-essential`, `python3-pip`, `pkg-config`, `autoconf`, `automake`, `libtool`, `clang`, `llvm`, `libclang-dev`, `lld`, `cmake`
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
- Aderyn (Cyfrin installer), Echidna (sigstore-verified binary), Medusa (via go install)

## Image Flavors

Composable cloud-init layers merged at build time with `yq eval-all '. as $item ireduce ({}; . *+ $item)'` (`*+` = deep merge with array append).

| Flavor | Layers | Use case |
|---|---|---|
| `base` | base | General dev (Docker, Node.js, Python, AI tools) |
| `protocol-dev` | base + protocol-dev | Systems/protocol dev (+ C/C++, Go, Rust) |
| `smart-contract-dev` | base + protocol-dev + smart-contract-dev | Smart contract dev (+ Solana, Foundry, Hardhat) |
| `smart-contract-audit` | all four layers | Full auditing toolkit (+ Slither, Echidna, Medusa) |

Build artifacts: `images/artifacts/mps-<flavor>-<arch>.qcow2.img` (`.qcow2.img` = format info + Multipass-compatible `.img`).

## Image Distribution

Backblaze B2 for storage, Cloudflare proxy for public serving. Files at bucket root (no path prefix).

- `MPS_IMAGE_BASE_URL` — public Cloudflare-proxied URL (maps 1:1 to bucket root)
- `MPS_B2_BUCKET` — B2 bucket name (for publish scripts)
- Manifest: `images/manifest.json` with SemVer versions + `latest` pointer per image
- Architecture-aware: separate `amd64`/`arm64` images per version
- SHA256 checksums verified on pull; local cache at `~/.mps/cache/images/`
- `file_size` (bytes) stored in manifest arch entries for autoindex display
- Static `index.html` pages generated from manifest after every publish (root, per-flavor, per-version)

## Image Flavor Metadata

Each layer YAML contains an `x-mps:` top-level block (cloud-init silently ignores unknown keys).

**Fields**: `disk_size`, `min_profile`, `min_disk`, `min_memory`, `min_cpus`

**Data flow**: layer YAML → `build.sh` (disk_size for Packer) → `publish.sh` (inject into manifest) → `image.sh` (write to `.meta` sidecar) → `create.sh` (compare against resolved resources, warn only)

| Flavor | Disk Size | Actual Usage |
|---|---|---|
| base | 7G | 4.6 GiB |
| protocol-dev | 10G | 7.2 GiB |
| smart-contract-dev | 11G | 8.3 GiB |
| smart-contract-audit | 13G | 9.8 GiB |

## Secure Dependency Installation

Non-OS dependencies installed with integrity verification where possible.

| Tool | Image | Verification |
|---|---|---|
| Packer | builder, linter | GPG-signed HashiCorp apt repo |
| b2 CLI | publisher | SHA256 from `_hashes.txt` sidecar |
| shellcheck | linter | None (no hashes published) |
| hadolint | linter | SHA256 from `.sha256` sidecar |
| checkmake | linter | SHA256 from `checksums.txt` |
| BATS | linter | None (no hashes published) |
| PowerShell | linter | SHA256 from `hashes.sha256` sidecar |
| actionlint | linter | SHA256 from `checksums.txt` |
| yamllint, py-psscriptanalyzer | linter | None (pip) |
| yq | builder, publisher | SHA256 from rhash `checksums` file |

Cloud-init layers: yq (rhash checksums), hadolint (.sha256 sidecar), cosign (cosign_checksums.txt), Echidna (sigstore bundle via cosign), shellcheck (no checksums published).

## Linting Notes

Linter-to-file mapping is in CLAUDE.md "Workflow" section. Additional note: command files use `# shellcheck disable=SC2154` at file-level — they're sourced by `bin/mps` which provides color variables from `lib/common.sh`.

## Build System Stamp Files

`.stamps/` directory tracks Docker image build state in Make.

- `.stamps/{builder,linter,publisher}` depend on respective Dockerfile + `docker/entrypoint.sh`
- `.stamps/image-<flavor>-{amd64,arm64}` — depend on builder stamp + common image deps + per-flavor layer file + parent flavor stamp (non-base only)
- `make clean` removes stamp files; `.stamps/` is in `.gitignore`

## File Transfer

Colon-prefix convention for guest paths in `mps transfer` (`:` prefix = guest path). Supports host→guest (multiple sources), guest→host (single source — multipass limitation). `--transfer` on `mps create` seeds files after VM creation.

## Local Image Support

Explicit import via `mps image import <file>`. Cache at `~/.mps/cache/images/<name>/<tag>/<arch>.img` with `.meta` sidecar (KEY=VALUE, read via `grep`/`cut`, never `source`d). Name/arch auto-detected from filename. `mps_resolve_image()` checks cache first, falls through to `multipass launch` for Ubuntu versions.

## SSH Key Management

`mps ssh-config` is the **only** command that injects SSH keys. Key resolution: `--ssh-key` flag → `MPS_SSH_KEY` config → auto-detect from `~/.ssh/` (ed25519 > ecdsa > rsa). Injection is idempotent (`MPS_SSH_INJECTED=true` metadata). `mps port forward` requires SSH pre-configured.

## Git Tagging Strategy

Prefixed tags for independent artifact versioning. All image flavors share a single version.

| Tag pattern | Artifact | Example |
|---|---|---|
| `mps/v*` | Tool release | `mps/v0.1.0` |
| `images/v*` | All image flavors | `images/v1.0.0` |

Tool version tracked in `VERSION` file (plain SemVer, no `v` prefix). `mps/v*` tag must match — CI validates.

## Claude Code Plugin Marketplaces

Two marketplaces registered at image build time via Packer `shell` provisioner (not cloud-init):

| Marketplace | Source | Access |
|---|---|---|
| `hl-claude-marketplace` | Git submodule at `vendor/hl-claude-marketplace` (relative URL) | Private (HorizenLabs) |
| `trailofbits/skills` | GitHub shorthand (cloned at build time) | Public |

Private marketplace uses relative URL (`../hl-claude-marketplace.git`) — resolves against parent repo remote. Files copied via Packer `file` provisioner, registered with `claude plugin marketplace add /local/path`.
