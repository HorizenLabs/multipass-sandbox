# Implementation Status

## Phase 1 — MVP Core: DONE

- [x] `config/defaults.env` — Default configuration values (updated for B2)
- [x] `lib/common.sh` — Logging, config cascade, path conversion, mount resolution, auto-naming, validation
- [x] `lib/multipass.sh` — Multipass CLI wrappers with JSON parsing
- [x] `bin/mps` — Main entry point with subcommand dispatch
- [x] `templates/cloud-init/base.yaml` — Base cloud-init (Docker, Node.js, Python, Go, Rust, dev tools)
- [x] `templates/cloud-init/blockchain.yaml` — Blockchain dev template (Solana, Foundry, Hardhat)
- [x] `templates/cloud-init/ai-agent.yaml` — AI agent template (auditd, AppArmor, nftables)
- [x] `templates/profiles/lite.env` — 2 CPU, 2GB RAM, 20GB disk
- [x] `templates/profiles/standard.env` — 4 CPU, 4GB RAM, 50GB disk
- [x] `templates/profiles/heavy.env` — 8 CPU, 8GB RAM, 100GB disk
- [x] `commands/create.sh` — Create sandbox with auto-naming, mount, cloud-init, profile
- [x] `commands/up.sh` — Create-or-start sandbox
- [x] `commands/down.sh` — Stop sandbox (with --force)
- [x] `commands/destroy.sh` — Remove sandbox (with confirmation)
- [x] `commands/shell.sh` — Interactive shell with auto-workdir
- [x] `commands/exec.sh` — Execute command with auto-workdir
- [x] `commands/list.sh` — List sandboxes (table + --json)
- [x] `commands/status.sh` — Detailed status (resources, mounts, Docker health)
- [x] `commands/ssh-config.sh` — VS Code SSH integration (--print, --append)

## Phase 2 — Image System: DONE

- [x] `commands/image.sh` — `image list` (local + --remote) and `image pull` (SemVer + latest resolution, SHA256 verify)
- [x] `images/manifest.json` — Manifest template with SemVer versions + latest pointer
- [x] `images/publish.sh` — Publish images to Backblaze B2 via `b2` CLI, update manifest
- [x] `images/base/build.sh` + `packer.pkr.hcl` + `scripts/setup-base.sh`
- [x] `images/blockchain/build.sh` + `packer.pkr.hcl` + `scripts/install-{rust,solana,foundry}.sh`
- [ ] Actual Backblaze B2 bucket + Cloudflare proxy setup (handled externally)
- [ ] CI pipeline (GitHub Actions) for automated image builds

## Phase 3 — Port Forwarding: DONE (scaffolding)

- [x] `commands/port.sh` — `port forward` (SSH tunnel) and `port list` (PID tracking)
- [ ] Auto-forwarding from `MPS_PORTS` on `mps up`
- [ ] Port forward cleanup on `mps down`/`mps destroy`

## Phase 4 — PowerShell Parity (Windows): NOT STARTED

- [ ] `bin/mps.ps1`
- [ ] `lib/common.ps1`
- [ ] `lib/multipass.ps1`
- [ ] `commands/*.ps1`
- [x] `install.ps1` — Windows installer (basic)

## Phase 5 — Polish & CI: DONE (build system)

- [x] `Dockerfile.builder` — Builder image with packer, shellcheck, hadolint, bats, b2, yamllint, checkmake, py-psscriptanalyzer, gosu
- [x] `docker/entrypoint.sh` — uid:gid matching entrypoint
- [x] `Makefile` — Dockerized: builder, lint (6 sub-targets), test, image-base, image-blockchain, publish-base, publish-blockchain
- [x] `install.sh` — Installer (symlink + dep check)
- [x] `.gitignore`
- [x] `README.md`
- [ ] BATS test suite
- [ ] GitHub Actions CI pipeline

## File Transfer: DONE

- [x] `lib/multipass.sh` — Updated `mp_transfer()` to variadic with error handling
- [x] `commands/transfer.sh` — Standalone `mps transfer` command with `:` prefix guest path convention
- [x] `commands/create.sh` — `--transfer` flag for seeding files into new VMs after creation
- [x] `commands/up.sh` — `--transfer` passthrough to `cmd_create`
- [x] `bin/mps` — Updated help text with transfer command and `--name` flag pattern

## Known Issues / TODO

- Port auto-forwarding from `MPS_PORTS` not wired into `mps up` post-start hooks
- Port forward cleanup not triggered on `mps down`/`mps destroy`
- No `.ports` file cleanup when destroying instances
- Cloud-init templates duplicate the full base setup (blockchain/ai-agent copy all of base) — could refactor to merge at build time
- README.md needs updating to reflect auto-naming, --name flag, B2 image system, dockerized build, and `mps transfer` command
