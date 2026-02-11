# Implementation Status

## Phase 1 — MVP Core: DONE

- [x] `config/defaults.env` — Default configuration values
- [x] `lib/common.sh` — Logging, config cascade, path conversion, mount resolution, validation
- [x] `lib/multipass.sh` — Multipass CLI wrappers with JSON parsing
- [x] `bin/mps` — Main entry point with subcommand dispatch
- [x] `templates/cloud-init/base.yaml` — Base cloud-init (Docker, Node.js, Python, Go, Rust, dev tools)
- [x] `templates/cloud-init/blockchain.yaml` — Blockchain dev template (Solana, Foundry, Hardhat)
- [x] `templates/cloud-init/ai-agent.yaml` — AI agent template (auditd, AppArmor, nftables)
- [x] `templates/profiles/lite.env` — 2 CPU, 2GB RAM, 20GB disk
- [x] `templates/profiles/standard.env` — 4 CPU, 4GB RAM, 50GB disk
- [x] `templates/profiles/heavy.env` — 8 CPU, 8GB RAM, 100GB disk
- [x] `commands/create.sh` — Create sandbox with mount, cloud-init, profile support
- [x] `commands/up.sh` — Create-or-start sandbox
- [x] `commands/down.sh` — Stop sandbox (with --force)
- [x] `commands/destroy.sh` — Remove sandbox (with confirmation)
- [x] `commands/shell.sh` — Interactive shell with auto-workdir
- [x] `commands/exec.sh` — Execute command with auto-workdir
- [x] `commands/list.sh` — List sandboxes (table + --json)
- [x] `commands/status.sh` — Detailed status (resources, mounts, Docker health)
- [x] `commands/ssh-config.sh` — VS Code SSH integration (--print, --append)

## Phase 2 — Image System: DONE (scaffolding)

- [x] `commands/image.sh` — `image list` (local + --remote) and `image pull` (with SHA256 verification)
- [x] `images/base/build.sh` + `packer.pkr.hcl` + `scripts/setup-base.sh`
- [x] `images/blockchain/build.sh` + `packer.pkr.hcl` + `scripts/install-{rust,solana,foundry}.sh`
- [ ] Actual S3 bucket / CDN setup for hosting images
- [ ] CI pipeline (GitHub Actions) for automated image builds

## Phase 3 — Port Forwarding: DONE (scaffolding)

- [x] `commands/port.sh` — `port forward` (SSH tunnel) and `port list` (PID tracking)
- [ ] Auto-forwarding from `MPS_PORTS` on `mps up` (rules stored in metadata, not yet applied)
- [ ] Port forward cleanup on `mps down`

## Phase 4 — PowerShell Parity (Windows): NOT STARTED

- [ ] `bin/mps.ps1`
- [ ] `lib/common.ps1`
- [ ] `lib/multipass.ps1`
- [ ] `commands/*.ps1`
- [x] `install.ps1` — Windows installer (created, basic)

## Phase 5 — Polish & CI: PARTIAL

- [x] `install.sh` — Installer (symlink + dep check)
- [x] `Makefile` — install, test, lint, image-base, image-blockchain targets
- [x] `.gitignore`
- [x] `README.md`
- [ ] BATS test suite
- [ ] shellcheck clean pass (scripts written to be clean, but not yet verified with shellcheck binary)
- [ ] CI pipeline (GitHub Actions)

## Known Issues / TODO

- Port auto-forwarding from `MPS_PORTS` config not wired into `mps up` post-start hooks
- Port forward cleanup not triggered on `mps down`/`mps destroy`
- No `.ports` file cleanup when destroying instances
- Profile application in `lib/common.sh` uses `MPS_PROFILE_*` prefix convention that profiles don't fully match (profiles use `MPS_PROFILE_CPUS` but commands look for `MPS_CPUS`)
- Cloud-init templates duplicate the full base setup (blockchain/ai-agent copy all of base) — could be refactored to use includes or a build-time merge
