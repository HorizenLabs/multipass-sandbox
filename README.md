# Multipass Sandbox

<p align="center">
  <img src="assets/mps.png" alt="Multipass Sandbox" width="1000">
</p>

Isolated VM-based development environments powered by [Multipass](https://multipass.run/). Spin up full Linux VMs with Docker, language runtimes, and dev tools pre-configured — stronger isolation than containers alone.

---

[Quick Start](#quick-start) | [Requirements](#requirements) | [Installation](#installation) | [Commands](#commands) | [Auto-Naming](#auto-naming) | [Mounting](#mounting) | [File Transfer](#file-transfer) | [Configuration](#configuration) | [Profiles](#profiles) | [Cloud-init Templates](#cloud-init-templates) | [Image Flavors](#image-flavors) | [SSH & Port Forwarding](#advanced-ssh--port-forwarding) | [Pre-built Images](#pre-built-images) | [Development](#development)

---

## Quick Start

```bash
# Install
./install.sh

# Create and start a sandbox (auto-names from CWD, mounts current directory)
mps up

# Or seed it with your Claude config
mps up --transfer ~/.claude:/home/ubuntu/.claude

# Open a shell (auto-resolves sandbox from CWD)
mps shell

# Run a command
mps exec -- docker ps

# List sandboxes
mps list

# Stop (prevents auto-restart on host reboot)
mps down

# Destroy
mps destroy --force
```

**Note:** Multipass automatically restarts running VMs on host reboot. Use `mps down` to stop sandboxes you don't want restarting.

## Requirements

- [Multipass](https://multipass.run/) — VM engine (snap or brew)
- [jq](https://jqlang.github.io/jq/) — JSON processing

## Installation

```bash
# Install (symlinks bin/mps to ~/.local/bin/)
./install.sh

# Or via make
make install
```

The installer checks for `multipass` and `jq`, creates `~/mps/` directories, symlinks `mps` onto your PATH, and offers to update your shell profile if needed. Override the install directory with `MPS_INSTALL_DIR`.

**WSL2 (Windows Subsystem for Linux):** Use the dedicated WSL2 installer, which handles systemd, snapd, and multipass setup before delegating to `install.sh`:

```bash
./install-wsl.sh
```

The script checks that systemd is enabled (required for snap/multipass on WSL2), installs snapd and multipass if missing, then runs the standard installer. If systemd is not enabled, it prints instructions to configure `/etc/wsl.conf` and restart WSL.

> **Snap Confinement (Ubuntu):** Multipass installed via snap cannot access hidden directories (dotdirs) directly under `$HOME` — this is an AppArmor restriction of the snap `home` interface. MPS uses `~/mps/` (not `~/.mps/`) to avoid this. If you provide paths under a hidden directory (e.g., `~/.secret/project` as a mount source, transfer path, or cloud-init file), MPS will detect active snap confinement and refuse the operation with a clear error. Workaround: move files to a non-hidden path or copy them to a staging directory.

### Uninstall

```bash
# Remove symlink, VMs, caches, and configs
./uninstall.sh

# Or via make
make uninstall
```

## Commands

| Command | Description |
|---------|-------------|
| `mps create [path] [flags]` | Create a new sandbox |
| `mps up [path] [flags]` | Create (if needed) and start a sandbox; restores mounts and port forwards on restart |
| `mps down [-f] [-n <name>]` | Stop a sandbox; cleans up port forwards and session-only mounts |
| `mps destroy [-f] [-n <name>]` | Remove a sandbox permanently (`--force` skips confirmation) |
| `mps shell [-n <name>] [-w <path>]` | Open an interactive shell |
| `mps exec [-n <name>] [-w <path>] -- <cmd>` | Execute a command in a sandbox |
| `mps transfer [-n <name>] <src...> <dst>` | Transfer files or directories between host and sandbox |
| `mps list [--json]` | List all sandboxes |
| `mps status [-n <name>] [--json]` | Show detailed status (resources, image staleness, mounts, Docker) |
| `mps ssh-config [-n <name>]` | Configure SSH access (inject key, generate config) |
| `mps image <list\|pull\|import\|remove>` | Manage sandbox images |
| `mps mount <add\|remove\|list>` | Manage mounts at runtime (origin tracking: auto/config/adhoc) |
| `mps port <forward\|list>` | Manage port forwarding |

Common flags across commands: `-n` (`--name`), `-f` (`--force`), `-w` (`--workdir`), `--mem` (`--memory`). `create`/`up` also accept `--transfer <src:dst>` (repeatable). Run `mps <command> --help` for detailed usage on any command.

## Auto-Naming

Sandboxes are automatically named based on your project directory and cloud-init template:

```
<folder>-<template>
```

For example, running `mps up` from `~/projects/myapp` produces `myapp-default`.

- Override with `--name <name>` flag or `MPS_NAME` in `.mps.env`
- Long names are truncated with a short hash suffix for uniqueness
- Commands that operate on existing instances auto-resolve the name from CWD

```bash
mps up                          # Auto-named from CWD
mps up --name mydev             # Explicit name
mps shell                       # Auto-resolves sandbox for CWD
mps shell --name mydev          # Explicit name
```

## Mounting

By default, `mps` mounts your current working directory into the VM at the **same absolute path**:

```bash
# On host: /home/user/projects/myapp
mps up
# Inside VM: cd /home/user/projects/myapp — same files!
```

```bash
mps up ~/code/project           # Mount specific directory instead of CWD
mps create --no-mount --name scratch   # No automatic mount (requires --name)
mps create --mount ./data:/home/ubuntu/data  # Extra mount (repeatable)
```

Extra mounts from `MPS_MOUNTS` in `.mps.env` are additive (on top of the auto-mount). Set `MPS_NO_AUTOMOUNT=true` to disable the CWD auto-mount.

### Runtime mount management

Add or remove mounts on a running sandbox with `mps mount`. Each mount is tracked by origin:

- **auto** — the CWD auto-mount (from `mps up`)
- **config** — persistent mounts from `MPS_MOUNTS` in `.mps.env`
- **adhoc** — session-only mounts added at runtime (removed automatically on `mps down`)

```bash
mps mount add ./data:/home/ubuntu/data       # Add a session-only mount
mps mount list                                # Show mounts with origin
mps mount remove /home/ubuntu/data            # Unmount
```

Persistent mounts (auto and config) are automatically restored when restarting a stopped sandbox with `mps up`.

## File Transfer

Transfer files or directories between host and sandbox using the `:` prefix convention for guest paths:

```bash
# Host -> guest
mps transfer ./config.json :/home/ubuntu/config.json
mps transfer file1.txt file2.txt :/home/ubuntu/

# Guest -> host
mps transfer :/home/ubuntu/output.log ./output.log

# With explicit sandbox name
mps transfer --name mydev ./script.sh :/tmp/script.sh

# Seed files during creation
mps create --transfer ./setup.sh:/home/ubuntu/setup.sh
```

## Configuration

Configuration is loaded in cascade (later values win):

1. `config/defaults.env` — shipped defaults
2. `~/mps/config` — user global overrides
3. `.mps.env` — per-project (in your repo)
4. Profile — resource fractions from `templates/profiles/<name>.env`
5. Auto-scaling — vCPU/memory computed from host hardware fractions
6. CLI flags — highest priority

### Example `.mps.env`

```bash
MPS_NAME=myproject-dev
MPS_CPUS=8
MPS_MEMORY=16G
MPS_DISK=100G
MPS_PROFILE=heavy
MPS_PORTS="8899:8899 8900:8900 3000:3000"
MPS_MOUNTS="./data:~/extra-data"
MPS_NO_AUTOMOUNT=false
```

### Configuration Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `MPS_NAME` | (auto) | Override auto-generated sandbox name |
| `MPS_IMAGE` | | Per-project image override (takes precedence over `MPS_DEFAULT_IMAGE`) |
| `MPS_DEFAULT_IMAGE` | `base` | Default image (`base`, `base:1.0.0`, or Ubuntu version like `24.04`) |
| `MPS_PROFILE` | | Per-project profile override (takes precedence over `MPS_DEFAULT_PROFILE`) |
| `MPS_DEFAULT_PROFILE` | `lite` | Default resource profile (`micro`, `lite`, `standard`, `heavy`) |
| `MPS_CLOUD_INIT` | | Per-project cloud-init override (takes precedence over `MPS_DEFAULT_CLOUD_INIT`) |
| `MPS_DEFAULT_CLOUD_INIT` | `default` | Cloud-init template name or file path |
| `MPS_CPUS` | (from profile) | vCPUs (host threads) |
| `MPS_MEMORY` | (from profile) | Memory with unit (e.g., `4G`) |
| `MPS_DISK` | (from profile) | Disk with unit (e.g., `40G`) |
| `MPS_PORTS` | (empty) | Space-separated `host:guest` port pairs, auto-forwarded on create/up |
| `MPS_MOUNTS` | (empty) | Extra mounts (`src:dst`), additive on top of auto-mount |
| `MPS_NO_AUTOMOUNT` | `false` | Disable automatic CWD mount |
| `MPS_SSH_KEY` | (auto-detect) | SSH key path (auto-detect: ed25519 > ecdsa > rsa) |
| `MPS_IMAGE_BASE_URL` | `https://mpsandbox.horizenlabs.io` | Image registry URL |
| `MPS_IMAGE_CHECK_UPDATES` | `true` | Check for image and instance staleness updates |
| `MPS_INSTANCE_PREFIX` | `mps` | Prefix for auto-generated instance names |
| `MPS_CHECK_UPDATES` | `true` | Check for CLI version updates (at most once per 24h) |
| `MPS_DEBUG` | `false` | Enable debug logging (`--debug` flag) |

## Profiles

Profiles define resource allocation as **fractions of host hardware**, with minimum floors and maximum caps. A `lite` profile on a 16-thread machine allocates more resources than on a 4-thread machine.

| Profile | vCPU Fraction | vCPU Min | Mem Fraction | Mem Min | Mem Cap | Disk |
|---------|-------------|---------|--------------|---------|---------|------|
| `micro` | 1/8 | 1 | 1/16 | 1G | 2G | 10G |
| `lite` **(default)** | 1/4 | 2 | 1/6 | 2G | 8G | 20G |
| `standard` | 1/3 | 4 | 1/4 | 4G | 16G | 40G |
| `heavy` | 1/2 | 6 | 1/3 | 6G | 64G | 75G |

Example resolved values on a 16-thread / 64GB host:

| Profile | vCPUs | Memory | Disk |
|---------|------|--------|------|
| `micro` | 2 | 4G | 10G |
| `lite` | 4 | 8G | 20G |
| `standard` | 5 | 16G | 40G |
| `heavy` | 8 | 21G | 75G |

Disk sizes are upper limits — Multipass creates thin-provisioned (sparse) virtual disks that start at the size of the source image and grow on demand up to the configured maximum.

```bash
mps create --profile heavy
mps create --profile lite --cpus 4 --memory 4G   # Profile + overrides
```

## Cloud-init Templates

Cloud-init templates customize VMs **at launch time**, on top of pre-built images. This is how you install extra packages, enable plugins, write config files, or run setup scripts without rebuilding an image.

Sandboxes are designed to be disposable — image staleness checks will regularly flag them for rebuild to pick up security patches and tool updates. Rather than manually installing dependencies inside a running sandbox (e.g., `mps shell` then `apt-get install ...`), define your project's setup in a cloud-init template or `.mps.env`. This way, `mps destroy && mps up` always gives you a fresh, correctly configured environment — and teammates get the same setup automatically.

### Using templates

```bash
# Use the default template (enabled plugins, commented-out examples)
mps create

# Use a named template from templates/cloud-init/ or ~/mps/cloud-init/
mps create --cloud-init mytemplate

# Use any file path directly
mps create --cloud-init ./my-cloud-init.yaml

# Set a per-project default in .mps.env (name flows into auto-naming)
MPS_CLOUD_INIT=.mps/dev.yaml

# Set a personal default in ~/mps/config
MPS_DEFAULT_CLOUD_INIT=personal
```

Named templates are resolved in order: `templates/cloud-init/` (project), then `~/mps/cloud-init/` (personal).

### The default template

The shipped `default` template (`templates/cloud-init/default.yaml`) enables HorizenLabs Claude Code marketplace plugins (`hl-product-ideation`, `zkverify-product-development`, `context-utils`) and includes commented-out examples for:

- **Packages**: Install additional apt packages (`packages:` block)
- **Run commands**: Execute scripts on first boot (`runcmd:` block)
- **Write files**: Drop config files into the VM (`write_files:` block)
- **Hostname / timezone**: Set VM hostname and timezone
- **Claude Code plugins**: Commented-out examples for Trail of Bits, GSD, SuperClaude, Superpowers, BMAD, GitHub Spec Kit (uncomment to enable)

### Creating custom templates

Create a `#cloud-config` YAML file and place it in one of these locations:

1. **Project-shared** (`<project>/.mps/<name>.yaml`): Checked into git, shared by the team. Set `MPS_CLOUD_INIT=.mps/<name>.yaml` in `.mps.env`. Use a descriptive name — it flows into auto-naming (e.g., `dev.yaml` → `myproject-dev`). The `.mps/` directory keeps MPS config out of the project root.
2. **Personal** (`~/mps/cloud-init/<name>.yaml`): Personal defaults, not in any repo. Reference by name (e.g., `--cloud-init personal`) or set `MPS_DEFAULT_CLOUD_INIT=<name>` in `~/mps/config`.
3. **MPS built-in** (`templates/cloud-init/<name>.yaml`): For templates shipped with MPS itself.
4. **Any file path** (e.g., `--cloud-init ~/configs/dev-setup.yaml`)

```yaml
#cloud-config
packages:
  - postgresql-client
  - redis-tools

runcmd:
  - echo "Hello from cloud-init" > /tmp/hello.txt
  - sudo -u ubuntu bash -c 'pip install my-tool'

write_files:
  - path: /home/ubuntu/.env
    content: |
      DATABASE_URL=postgres://localhost/mydb
    owner: ubuntu:ubuntu
    permissions: '0600'

timezone: America/New_York
```

These templates run on top of whatever image you're using. For the image build-time layers (what packages come pre-installed), see `images/layers/*.yaml`.

### Creating templates with Claude Code

The `/init-template` skill guides you through creating a cloud-init template interactively. It reads the default template, knows what's pre-installed in each image flavor, and generates valid YAML with the right config wiring.

```bash
# In Claude Code (from the mps repo), run:
/init-template
```

The skill walks you through: scope (personal vs project), target image flavor, which plugins/frameworks to enable, extra packages, custom commands, and sandbox settings (`.mps.env`). It writes the template and config files for you.

## Image Flavors

Pre-built images come in four flavors. Each builds on the previous, adding specialized tooling:

| Flavor | Builds On | Description | Min Profile |
|--------|-----------|-------------|-------------|
| `base` | — | Ubuntu 24.04 + Docker + Node.js + Python + dev tools + AI assistants | micro |
| `protocol-dev` | base | + C/C++ toolchain + Go + Rust | lite |
| `smart-contract-dev` | protocol-dev | + Solana/Anchor (amd64) + Foundry + Hardhat | lite |
| `smart-contract-audit` | smart-contract-dev | + Slither + Mythril (amd64) + Echidna + Medusa + Halmos (amd64) | standard |

<details>
<summary>What's in each flavor</summary>

**base**: Docker (CE + Compose + Buildx), Node.js (LTS via nvm), pnpm, yarn, Bun, Python 3 + uv, git, curl, jq, yq, tmux, ripgrep, fd, Neovim, shellcheck, hadolint, zsh. AI assistants: Claude Code, Crush, OpenCode, Gemini CLI, Codex CLI.

**protocol-dev** adds: build-essential, clang, LLVM, lld, cmake, Go (latest stable), Rust (stable via rustup + cargo-audit), protobuf, SSL/crypto dev libraries.

**smart-contract-dev** adds: Solana CLI + Anchor (amd64-only, via avm), Foundry (forge, cast, anvil, chisel), Hardhat, Solhint.

**smart-contract-audit** adds: Slither, solc-select, Mythril + Halmos (amd64-only, via uv), Aderyn, Echidna (sigstore-verified), Medusa, cosign.

</details>

Images warn (but do not block) when your profile is below the minimum. For example, launching `smart-contract-audit` with `micro` triggers a warning since it requires `standard`.

```bash
mps create --image protocol-dev --profile standard
mps create --image smart-contract-audit --profile heavy
```

## Advanced: SSH & Port Forwarding

SSH and port forwarding require explicit setup — by design, `mps` does not automatically inject SSH keys or open tunnels.

### SSH Setup

Configure SSH access with `mps ssh-config`. This resolves your SSH key, injects it into the VM, and generates an SSH config entry — no `sudo` required.

```bash
# Auto-detect key, inject, print config to stdout
mps ssh-config

# Use a specific key
mps ssh-config --ssh-key ~/.ssh/id_ed25519

# Write config to ~/.ssh/config.d/ (for VS Code)
mps ssh-config --append
```

SSH key resolution order: `--ssh-key` flag > `MPS_SSH_KEY` config > auto-detect from `~/.ssh/` (ed25519 > ecdsa > rsa).

### VS Code Remote-SSH

The primary use case for `mps ssh-config` is connecting to sandboxes from VS Code via the [Remote-SSH](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-ssh) extension.

```bash
# 1. Write SSH config for your sandbox
mps ssh-config --append

# 2. Ensure ~/.ssh/config includes the config.d directory
#    Add this line at the TOP of the file (before any Host blocks):
#    Include config.d/*

# 3. In VS Code: Cmd/Ctrl+Shift+P -> "Remote-SSH: Connect to Host" -> select <name>
```

The `--append` flag writes to `~/.ssh/config.d/<instance-name>`, which VS Code picks up automatically when your `~/.ssh/config` includes `config.d/*`. Use `--print` (the default) if you prefer to manage SSH config manually.

### Port Forwarding

Ports are forwarded via SSH tunnels, so `mps ssh-config` must be run first. The `--port` flag on create stores forwarding rules in instance metadata but does not activate them until SSH is configured.

```bash
# 1. Create with port rules (stored, not yet active)
mps create --port 3000:3000 --port 8080:8080

# 2. Configure SSH (required before any forwarding)
mps ssh-config

# 3. Forward ports (uses stored rules, or specify manually)
mps port forward mydev 3000:3000

# List active forwards
mps port list

# Auto-forward via .mps.env (activated on next mps up after ssh-config)
# MPS_PORTS="8899:8899 3000:3000"
```

Forwards bind to `localhost` only — they are not exposed on external network interfaces. Privileged ports (< 1024) require the `--privileged` flag, which elevates the SSH tunnel via `sudo`:

```bash
mps port forward --privileged mydev 80:80
```

> **Note:** Auto-forwarding (via `MPS_PORTS` or `--port` metadata) skips privileged ports for safety — it never triggers a `sudo` prompt automatically. If you have privileged ports configured, `mps up` will warn and print the exact `mps port forward --privileged` command to run manually.

Ports are automatically cleaned up on `mps down` and `mps destroy`.

## Pre-built Images

Pre-built QCOW2 images come with tools pre-installed, so cloud-init has far less to do at startup. Images are distributed via Backblaze B2 with Cloudflare proxy, versioned with SemVer, and verified with SHA256 checksums.

```bash
# Browse cached images (shows update status)
mps image list

# Browse remote registry
mps image list --remote

# Pull an image (auto-detects host architecture)
mps image pull base
mps image pull base:1.0.0
mps image pull base --force      # Re-download even if up to date

# Import a locally built image
mps image import images/artifacts/mps-base-amd64.qcow2.img

# Remove cached images
mps image remove base:1.0.0
mps image remove --all
```

Images are checked for updates automatically on `mps create` and `mps up`. Running sandboxes are also checked for staleness (rebuilt image pulled, or newer version available locally) on `mps up`, `mps shell`, `mps exec`, `mps status`, `mps transfer`, and `mps ssh-config`. Disable all image/instance update checks with `MPS_IMAGE_CHECK_UPDATES=false`.

### Building Images Locally

Image builds run inside Docker via Packer + QEMU. Flavors chain from their parent — building `smart-contract-audit` automatically builds the full chain.

```bash
make image-base                     # Both architectures (parallel)
make image-base-amd64               # Single architecture
make image-protocol-dev             # Chains from base
make image-smart-contract-dev       # Chains from protocol-dev
make image-smart-contract-audit     # Full chain: base → protocol-dev → sc-dev → sc-audit
make import-base                    # Import host-arch image into local mps cache
```

## Development

All build, lint, and test commands run inside Docker containers for reproducibility. The Makefile auto-builds the container images when their Dockerfiles change.

```bash
# Docker images (auto-built on first use)
make build-docker-linter      # Linter/test image
make build-docker-builder     # Builder image (Packer, QEMU)
make build-docker-publisher   # Publisher image (b2, jq, yq)

# Lint and test
make lint                     # Run all linters
make lint-actions             # Lint GitHub Actions workflows
make test                     # Run BATS tests

# Publish (requires B2_APPLICATION_KEY_ID and B2_APPLICATION_KEY)
make publish-base VERSION=1.0.0        # Upload + manifest (both archs)
make upload-base-amd64 VERSION=1.0.0   # CI: upload only (no manifest)
make update-manifest VERSION=1.0.0     # CI fan-in: single manifest write

make help                     # Show all targets
```

### Linters

| File type | Linter |
|-----------|--------|
| Bash | shellcheck |
| Bash 3.2 compat | lint-bash32-compat.sh |
| PowerShell | py-psscriptanalyzer |
| Dockerfile | hadolint |
| Makefile | checkmake |
| YAML | yamllint |
| HCL/Packer | packer fmt |
| GitHub Actions | actionlint |

## License

Proprietary — internal use only. All rights reserved.
