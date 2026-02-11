# Multi Pass Sandbox (mps)

Internal CLI tool for spinning up isolated VM-based development environments using Canonical Multipass. Provides stronger isolation than Docker containers alone — full VMs with Docker daemons running inside.

## Tech Stack

- **CLI**: Bash (macOS/Linux), PowerShell planned (Windows)
- **VM Engine**: Canonical Multipass
- **Config**: KEY=VALUE .env files (no YAML parsing in Bash)
- **Dependencies**: `multipass`, `jq`
- **Image builds**: Packer (QCOW2)
- **Tests**: BATS (planned)

## Project Structure

- `bin/mps` — Main entry point, subcommand dispatch
- `lib/common.sh` — Logging, config cascade, path conversion, mount resolution, validation
- `lib/multipass.sh` — Thin wrappers around `multipass` CLI with `--format json` + `jq`
- `commands/*.sh` — One file per subcommand, each exports `cmd_<name>()` function
- `templates/cloud-init/` — Cloud-init YAML templates (base, blockchain, ai-agent)
- `templates/profiles/` — Resource profiles (lite, standard, heavy)
- `config/defaults.env` — Shipped defaults
- `images/` — Packer build scripts for pre-built VM images

## Key Conventions

- All instance names prefixed with `mps-` (configurable via `MPS_INSTANCE_PREFIX`)
- Config cascade: `config/defaults.env` → `~/.mps/config` → `.mps.env` → CLI flags
- Default mount: host CWD → guest at same absolute path (read-write)
- Windows path conversion: `C:\foo\bar` → `/c/foo/bar`
- `MPS_MOUNTS` is additive (on top of auto-mount), `MPS_NO_AUTOMOUNT=true` to opt out
- `mps shell`/`mps exec` auto-set workdir to the mounted project path
- Commands use `while/case/shift` arg parsing, private `_<cmd>_usage()` helpers
- Color output uses `$'\033[...]'` ANSI-C quoting (not double-quoted `\033`)

## Planning & Status

- Full implementation plan: `.planning/PLAN.md`
- Architecture decisions: `.planning/DECISIONS.md`
- Implementation status: `.planning/STATUS.md`
