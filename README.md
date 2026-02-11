# Multi Pass Sandbox (mps)

Isolated VM-based development environments powered by [Multipass](https://multipass.run/). Spin up full Linux VMs with Docker, language runtimes, and dev tools pre-configured — stronger isolation than containers alone.

## Quick Start

```bash
# Install
./install.sh

# Create and start a sandbox (mounts current directory)
mps up

# Open a shell
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
| `mps create [name] [path]` | Create a new sandbox |
| `mps up [name] [path]` | Create (if needed) and start a sandbox |
| `mps down [name]` | Stop a sandbox |
| `mps destroy [name]` | Remove a sandbox permanently |
| `mps shell [name]` | Open an interactive shell |
| `mps exec [name] -- <cmd>` | Execute a command in a sandbox |
| `mps list` | List all sandboxes |
| `mps status [name]` | Show detailed sandbox status |
| `mps ssh-config [name]` | Generate SSH config for VS Code |
| `mps image list\|pull` | Manage sandbox images |
| `mps port forward\|list` | Manage port forwarding |

## Mounting

By default, `mps` mounts your current working directory into the VM at the **same absolute path**:

```bash
# On host: /home/user/projects/myapp
mps up
# Inside VM: cd /home/user/projects/myapp — same files!
```

On Windows, drive letters are converted: `C:\Users\dev\project` → `/c/Users/dev/project`.

Override with a path argument:

```bash
mps up myvm /path/to/project    # Mount specific directory instead of CWD
mps create myvm --no-mount      # No automatic mount
```

Extra mounts from `.mps.env` are additive (added on top of the auto-mount).

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
MPS_CLOUD_INIT=blockchain
MPS_PROFILE=heavy
MPS_PORTS="8899:8899 8900:8900 3000:3000"
MPS_MOUNTS="./data:~/extra-data"
```

## Profiles

| Profile | CPUs | RAM | Disk |
|---------|------|-----|------|
| `lite` | 2 | 2GB | 20GB |
| `standard` | 4 | 4GB | 50GB |
| `heavy` | 8 | 8GB | 100GB |

```bash
mps create dev --profile heavy
```

## Cloud-init Templates

| Template | Includes |
|----------|----------|
| `base` | Docker (official), Node.js (nvm), Python (pip/venv/uv), Go, Rust (rustup), build tools, CLI tools |
| `blockchain` | Base + Solana CLI, Anchor, Foundry, Hardhat |
| `ai-agent` | Base + audit/monitoring, AppArmor, resource limits, network logging |

```bash
mps create dev --cloud-init blockchain
```

## VS Code Integration

Generate an SSH config for VS Code Remote-SSH:

```bash
# Print to stdout
mps ssh-config myvm

# Write to ~/.ssh/config.d/
mps ssh-config myvm --append
```

Then in VS Code: Remote-SSH → Connect to Host → `mps-myvm`.

## Port Forwarding

```bash
# Forward host:3000 → VM:3000
mps port forward myvm 3000:3000

# List active forwards
mps port list

# Auto-forward via .mps.env
# MPS_PORTS="8899:8899 3000:3000"
```

## Building Images

Pre-built images skip cloud-init provisioning for faster startup:

```bash
make image-base          # Build base QCOW2 image with Packer
make image-blockchain    # Build blockchain image

mps image list --remote  # Browse available images
mps image pull base:latest
```

## Development

```bash
make lint    # shellcheck all scripts
make test    # Run BATS tests
make help    # Show all targets
```

## License

Internal use.
