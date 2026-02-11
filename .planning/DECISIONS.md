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
- CLI path argument overrides CWD: `mps up myvm /path/to/project`
- `MPS_MOUNTS` in `.mps.env` is additive (extra mounts on top of auto-mount)
- `MPS_NO_AUTOMOUNT=true` disables CWD auto-mount

## Config System

**Decision**: Simple KEY=VALUE env files. No YAML parsing in Bash.

Cascade (later wins): `config/defaults.env` → `~/.mps/config` → `.mps.env` → CLI flags

## Image Distribution

**Decision**: HTTP/S3 for MVP. OCI registry planned for later.

- Manifest-based: `manifest.json` hosted on S3 with SHA256 checksums
- Architecture-aware: separate `amd64`/`arm64` images
- Local cache at `~/.mps/cache/images/`

## Windows Support

**Decision**: PowerShell parity planned (Phase 4), not yet implemented.

- `bin/mps.ps1` + `commands/*.ps1` + `lib/*.ps1`
- `ConvertFrom-Json` instead of `jq`
- Multipass on Windows uses Hyper-V (Pro/Enterprise) or VirtualBox (Home)
