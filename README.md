# Multi Pass Sandbox (mps)

Isolated VM-based development environments powered by [Multipass](https://multipass.run/). Spin up full Linux VMs with Docker, language runtimes, and dev tools pre-configured — stronger isolation than containers alone.

## Quick Start

```bash
# Install
./install.sh

# Create and start a sandbox (auto-names from CWD, mounts current directory)
mps up

# Open a shell (auto-resolves sandbox from CWD)
mps shell

# Run a command
mps exec -- docker ps

# List sandboxes
mps list

# Stop
mps down

# Destroy
mps destroy --force
```

## Requirements

- [Multipass](https://multipass.run/) — VM engine (snap, brew, or Windows installer)
- [jq](https://jqlang.github.io/jq/) — JSON processing (Linux/macOS only; Windows uses `ConvertFrom-Json`)

## Commands

| Command | Description |
|---------|-------------|
| `mps create [path] [flags]` | Create a new sandbox |
| `mps up [path] [flags]` | Create (if needed) and start a sandbox |
| `mps down [--name <name>]` | Stop a sandbox |
| `mps destroy [--name <name>]` | Remove a sandbox permanently |
| `mps shell [--name <name>]` | Open an interactive shell |
| `mps exec [--name <name>] -- <cmd>` | Execute a command in a sandbox |
| `mps transfer <src...> <dst>` | Transfer files between host and sandbox |
| `mps list` | List all sandboxes |
| `mps status [--name <name>]` | Show detailed sandbox status |
| `mps ssh-config [--name <name>]` | Generate SSH config for VS Code |
| `mps image list\|pull` | Manage sandbox images |
| `mps port forward\|list` | Manage port forwarding |

## Auto-Naming

VMs are automatically named based on your project directory, cloud-init template, and profile:

```
mps-<folder>-<template>-<profile>
```

For example, running `mps up` from `~/projects/myapp` produces `mps-myapp-base-standard`.

- Override with `--name <name>` flag or `MPS_NAME` in `.mps.env`
- Long names (>40 chars) are truncated with a short hash suffix for uniqueness
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

On Windows, drive letters are converted: `C:\Users\dev\project` -> `/c/Users/dev/project`.

```bash
mps up ~/code/project           # Mount specific directory instead of CWD
mps create --no-mount --name scratch   # No automatic mount (requires --name)
mps create --mount ./data:/home/ubuntu/data  # Extra mount (repeatable)
```

Extra mounts from `MPS_MOUNTS` in `.mps.env` are additive (on top of the auto-mount). Set `MPS_NO_AUTOMOUNT=true` to disable the CWD auto-mount.

## File Transfer

Transfer files between host and sandbox using the `:` prefix convention for guest paths:

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
2. `~/.mps/config` — user global overrides
3. `.mps.env` — per-project (in your repo)
4. CLI flags — highest priority

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

## Profiles

| Profile | CPUs | RAM | Disk |
|---------|------|-----|------|
| `lite` | 2 | 2GB | 20GB |
| `standard` (default) | 4 | 4GB | 50GB |
| `heavy` | 8 | 8GB | 100GB |

```bash
mps create --profile heavy
mps create --profile lite --cpus 1 --memory 1G   # Profile + overrides
```

## Cloud-init Templates

| Template | Location | Purpose |
|----------|----------|---------|
| `base` | `templates/cloud-init/base.yaml` | Minimal customization template (commented-out examples). Used at VM launch from pre-built images. |
| (build) | `images/base/cloud-init.yaml` | Full provisioning template baked into images via Packer. Docker, Node.js, Python, Go, Rust, build tools, Solana, Anchor, Foundry, Hardhat. |

## Port Forwarding

Ports are forwarded via SSH tunnels. Forward on create/up, or manage individually:

```bash
# Forward host:3000 -> VM:3000
mps port forward 3000:3000

# Forward during creation
mps create --port 3000:3000 --port 8080:8080

# List active forwards
mps port list

# Auto-forward via .mps.env
# MPS_PORTS="8899:8899 3000:3000"
```

Ports are automatically cleaned up on `mps down` and `mps destroy`.

## VS Code Integration

Generate an SSH config for VS Code Remote-SSH. This resolves your SSH key, injects it into the VM, and generates the config — no `sudo` required.

```bash
# Auto-detect key, inject, print config
mps ssh-config --name dev

# Use a specific key
mps ssh-config --ssh-key ~/.ssh/id_ed25519 --name dev

# Append to ~/.ssh/config.d/
mps ssh-config --append --name dev
```

SSH key resolution order: `--ssh-key` flag > `MPS_SSH_KEY` config > auto-detect from `~/.ssh/` (ed25519 > ecdsa > rsa).

Then in VS Code: Remote-SSH -> Connect to Host -> `mps-<name>`.

**Note:** Port forwarding requires SSH to be configured first. Run `mps ssh-config` before `mps port forward`.

## Pre-built Images

Pre-built QCOW2 images skip cloud-init provisioning for faster startup. Images are distributed via Backblaze B2 with Cloudflare proxy, versioned with SemVer, and verified with SHA256 checksums.

```bash
# Browse available images
mps image list --remote

# Pull an image
mps image pull base:latest
mps image pull base:1.0.0

# Build locally with Packer (runs inside Docker, outputs .qcow2.img)
make image-base                     # Native architecture
make image-base ARCH=arm64          # Cross-architecture
```

## Development

All build, lint, and test commands run inside Docker containers for reproducibility. The Makefile auto-builds the container images when their Dockerfiles change.

```bash
make linter          # Build the linter image
make builder         # Build the builder image (Packer, QEMU, b2)
make lint            # Run all linters (shellcheck, hadolint, yamllint, checkmake, packer fmt, py-psscriptanalyzer)
make test            # Run BATS tests
make image-base      # Build base VM image with Packer
make publish-base VERSION=1.0.0   # Publish to Backblaze B2
make help            # Show all targets
```

### Linters

| File type | Linter |
|-----------|--------|
| Bash | shellcheck |
| PowerShell | py-psscriptanalyzer |
| Dockerfile | hadolint |
| Makefile | checkmake |
| YAML | yamllint |
| HCL/Packer | packer fmt |

## License

Internal use.
