# E2E Test Implementation Plan

## Overview

End-to-end tests for the `mps` CLI exercising real Multipass VMs, real SSH tunnels, real mounts, real image downloads, and real cloud-init execution. Complements the existing 749 BATS unit/integration tests by covering code paths that can only be reached with a live VM.

Also serves as image validation in the images CI pipeline — built QCOW2 artifacts are imported and tested before publishing.

---

## Configuration

```bash
MPS_E2E_IMAGE        # Default: "base" (pulled from CDN)
                     # File path → imported via mps image import
                     # Arch auto-detected from filename or host

MPS_E2E_INSTALL      # Default: false
                     # true → run install.sh + uninstall.sh bookends
                     # CI sets true (fresh runner); local devs leave false
```

No arch variables — uses `uname -m` throughout. Update checks left **enabled** (real-world conditions, covers `_mps_check_cli_update` and staleness code paths).

---

## Cloud-Init Template Generation

`templates/cloud-init/default.yaml` gets `#:example` / `#:end` markers around every uncommentable block. Markers are comments — no effect on normal usage. The e2e script generates the test template at runtime:

```bash
awk '
  /^#:example/          { uncomment=1; next }
  /^#:end/              { uncomment=0; next }
  uncomment && /^# /    { sub(/^# /, ""); print; next }
  uncomment && /^#\t/   { sub(/^#\t/, "\t"); print; next }
  { print }
' "${MPS_ROOT}/templates/cloud-init/default.yaml" \
  | sed 's/<package>/tree/' \
  > "${E2E_TMPDIR}/cloud-init-e2e.yaml"
```

Single source of truth — template always reflects `default.yaml`. Only fixup: `<package>` placeholder → `tree`.

---

## Script: `tests/e2e.sh`

Plain bash, `set -euo pipefail`, single file. Runs on host (no Docker — Multipass needs KVM).

### Error Model

Assertions counted (pass/fail/skip), don't abort. Fatal prerequisites (install fails, create fails) skip dependent phases. Summary at end, exit 1 if any failures.

### Cleanup

EXIT trap destroys any `mps-e2e-*` VM + removes temp dir. Pre-run stale reaper kills leftover instances from crashed runs.

### Temp Directory

Under `$HOME` (Multipass snap confinement):

```
$HOME/.mps-e2e-<pid>/
├── project/                ← fake project dir (auto-mount + auto-naming source)
│   └── .mps.env            ← MPS_PORTS=19000:9000 + MPS_MOUNTS=...:/mnt/config-mount
├── cloud-init-e2e.yaml     ← generated from default.yaml at runtime
├── mountdir/               ← config mount source (from .mps.env) + adhoc mount tests
│   └── configfile.txt
├── adhocdir/               ← adhoc mount source
│   └── adhocfile.txt
├── upload.txt              ← transfer host→guest
└── download.txt            ← transfer guest→host
```

### Assertion Helpers

```bash
_e2e_pass=0  _e2e_fail=0  _e2e_skip=0

assert_eq()              # label, actual, expected
assert_contains()        # label, haystack, needle
assert_not_contains()    # label, haystack, needle
assert_exit_zero()       # label, command...
assert_exit_nonzero()    # label, command...
assert_file_exists()     # label, path
assert_file_not_exists() # label, path
```

### Phase Structure

```
phase_install              ─┐
phase_smoke                 │  independent
phase_image                ─┘

phase_create               ─┐
phase_exec                  │
phase_cloud_init            │
phase_status                │
phase_ssh                   │
phase_lazy_ports            │  VM-dependent group
phase_transfer              │  (skipped if create fails)
phase_mounts                │
phase_ports                 │
phase_down_up_tunnels       │
phase_destroy              ─┘

phase_image_remove         ─┐  independent
phase_uninstall            ─┘
```

---

## Phase Breakdown

### Phase 0: Install *(when `MPS_E2E_INSTALL=true`)*

```
yes | bash install.sh
assert: mps --version exits 0
assert: multipass version exits 0
assert: jq --version exits 0
assert: ~/.mps/instances/ directory exists
assert: completion file symlinked
```

### Phase 1: CLI Smoke *(no VM, fast)*

```
mps --version                → matches VERSION file content
mps --help                   → contains "Usage"
mps create --help            → exits 0 (repeat for all 13 commands)
mps --debug list 2>&1        → stderr contains "[mps DEBUG]"
```

### Phase 2: Image Management

```
If MPS_E2E_IMAGE is a file path:
    mps image import "$MPS_E2E_IMAGE"     → exits 0
    extract image name from filename
Else:
    mps image list --remote               → contains image name
    mps image pull "$MPS_E2E_IMAGE"       → exits 0 (tests aria2c/curl download)
mps image list                            → contains image name
```

### Phase 3: Create *(starts main VM — fatal assertions)*

```
cd $E2E_TMPDIR/project

# .mps.env pre-seeded:
#   MPS_PORTS=19000:9000
#   MPS_MOUNTS=$E2E_TMPDIR/mountdir:/mnt/config-mount

# Pre-populate config mount source
echo "config-mount-content" > $E2E_TMPDIR/mountdir/configfile.txt

# Generate cloud-init template from default.yaml (uncomment all #:example blocks)
<awk script> → $E2E_TMPDIR/cloud-init-e2e.yaml

mps create --profile micro --cloud-init "${E2E_TMPDIR}/cloud-init-e2e.yaml"
# No --name → tests auto-naming from CWD basename "project"
# No --no-mount → tests auto-mount of CWD

derive FULL_NAME, SHORT from mps list output
fatal assert: state == "Running" (via mps status --json)
assert: auto-mount visible in mps mount list with origin "auto"
assert: config mount visible in mps mount list with origin "config"
assert: mps exec -- cat /mnt/config-mount/configfile.txt → "config-mount-content"
assert: metadata file exists at ~/.mps/instances/<short>.json
assert: MPS_PORTS recorded in metadata (port_forwards field)
# Note: port 19000 NOT yet forwarded (ssh: null at create time)
```

### Phase 4: Exec

```
mps exec -- echo hello                    → "hello"
mps exec -- uname -s                      → "Linux"
mps exec -- uname -m                      → matches host arch
mps exec -- pwd                           → matches auto-mount target path
mps exec --workdir /tmp -- pwd            → "/tmp"
mps exec -- sh -c 'exit 42'              → exit code 42
```

### Phase 5: Cloud-Init Validation

```
# ---- Status: zero errors ----
mps exec -- cloud-init status             → contains "done"
mps exec -- jq '.v1.errors | length' /run/cloud-init/result.json  → "0"

# ---- Generic directives ----
mps exec -- dpkg-query -W postgresql-client   → exits 0
mps exec -- dpkg-query -W redis-tools         → exits 0
mps exec -- dpkg-query -W tree                → exits 0
mps exec -- cat /tmp/hello.txt                → "Hello from cloud-init"
mps exec -- cat /home/ubuntu/.env             → contains "DATABASE_URL=postgres://localhost/mydb"
mps exec -- stat -c '%U:%G' /home/ubuntu/.env → "ubuntu:ubuntu"
mps exec -- stat -c '%a' /home/ubuntu/.env    → "600"
mps exec -- hostname                          → "my-sandbox"
mps exec -- timedatectl show -p Timezone --value → "America/New_York"

# ---- Helper: exec as ubuntu with full tool PATH ----
_ubuntu_exec() {
    mps exec -- sudo -u ubuntu bash -c "
        export HOME=/home/ubuntu
        export PATH=\"\$HOME/.claude/bin:\$HOME/.local/bin:\$HOME/.bun/bin:\$PATH\"
        export NVM_DIR=\"\$HOME/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
        $1
    "
}

# ---- HorizenLabs marketplace plugins (active in default.yaml) ----
plugin_list=$(_ubuntu_exec 'claude plugin list')
assert_contains "plugin: zkverify-product-ideation"    "$plugin_list" "zkverify-product-ideation"
assert_contains "plugin: zkverify-product-development" "$plugin_list" "zkverify-product-development"
assert_contains "plugin: context-utils"                "$plugin_list" "context-utils"

# ---- Trail of Bits (spot-check representative plugins) ----
assert_contains "plugin: ask-questions-if-underspecified" "$plugin_list" "ask-questions-if-underspecified"
assert_contains "plugin: building-secure-contracts"      "$plugin_list" "building-secure-contracts"
assert_contains "plugin: static-analysis"                "$plugin_list" "static-analysis"
assert_contains "plugin: variant-analysis"               "$plugin_list" "variant-analysis"

# ---- Superpowers ----
assert_contains "plugin: superpowers" "$plugin_list" "superpowers"

# ---- GSD framework ----
assert_exit_zero "gsd installed"         _ubuntu_exec 'command -v get-shit-done-cc'

# ---- SuperClaude framework ----
assert_exit_zero "superclaude installed" _ubuntu_exec 'command -v superclaude'

# ---- BMAD Method ----
assert_exit_zero "bmad installed"        _ubuntu_exec 'test -d "$HOME/.bmad" || test -d "$HOME/bmm"'

# ---- GitHub Spec Kit ----
assert_exit_zero "spec-kit installed"    _ubuntu_exec 'command -v specify-cli'
```

### Phase 6: Status & List

```
mps status                → contains instance name, "Running", IPv4 address
mps status --json         → valid JSON, jq '.info[].state' == "Running"
mps list                  → contains short name
```

### Phase 7: SSH Config

```
mps ssh-config --print                 → contains "Host $SHORT"
mps ssh-config --append                → file exists at ~/.ssh/config.d/mps-$FULL_NAME
ssh -o ConnectTimeout=5 -o BatchMode=yes $SHORT echo ssh-ok  → "ssh-ok"
mps ssh-config --print                 → same output (key injection idempotent)
```

### Phase 8: Lazy Port Init

SSH is now injected. The next call to `mps_prepare_running_instance()` triggers `mps_auto_forward_ports()`, which lazily establishes the `MPS_PORTS` tunnels from `.mps.env`.

```
mps exec -- echo trigger-lazy-ports
mps port list $SHORT                   → 19000 shows "active" (MPS_PORTS from .mps.env)
```

**Background**: `mps_forward_port()` requires `ssh.injected == true` in instance metadata. At create time, metadata has `ssh: null`, so `mps_auto_forward_ports()` silently skips. After `mps ssh-config` injects the key, the next command's `mps_prepare_running_instance()` call succeeds.

### Phase 9: Transfer

```
# Host → guest (temp files under $HOME for snap confinement)
echo "host-payload" > $E2E_TMPDIR/upload.txt
mps transfer $E2E_TMPDIR/upload.txt :/tmp/upload.txt
mps exec -- cat /tmp/upload.txt        → "host-payload"

# Guest → host
mps exec -- sh -c 'echo guest-payload > /tmp/download.txt'
mps transfer :/tmp/download.txt $E2E_TMPDIR/download.txt
cat $E2E_TMPDIR/download.txt           → "guest-payload"
```

### Phase 10: Mounts

Tests all three mount origins: auto (from CWD at create), config (from `MPS_MOUNTS` in `.mps.env`), adhoc (from `mps mount add`).

```
# Config mount already present from create (via .mps.env MPS_MOUNTS)
mps mount list                                → /mnt/config-mount origin "config"

# Add adhoc mount to a different target
mkdir $E2E_TMPDIR/adhocdir
echo "adhoc-content" > $E2E_TMPDIR/adhocdir/adhocfile.txt
mps mount add $E2E_TMPDIR/adhocdir:/mnt/adhoc
mps exec -- cat /mnt/adhoc/adhocfile.txt      → "adhoc-content"

# Bidirectional: guest writes to adhoc mount, host reads
mps exec -- sh -c 'echo from-guest > /mnt/adhoc/guestfile.txt'
cat $E2E_TMPDIR/adhocdir/guestfile.txt        → "from-guest"

# Three origins visible
mps mount list                                → auto, config, adhoc all present

# Remove adhoc mount
mps mount remove /mnt/adhoc
mps mount list                                → does not contain /mnt/adhoc
```

### Phase 11: Port Forwarding

```
# Start service in VM
mps exec -- sh -c 'nohup python3 -m http.server 8111 &>/dev/null &'
sleep 2

# Unprivileged forward
mps port forward $SHORT 18111:8111
curl -sf --max-time 5 http://localhost:18111/  → non-empty response
mps port list $SHORT                           → 18111 "active"

# Privileged forward (passwordless sudo on CI + dev host)
mps port forward --privileged $SHORT 80:8111
curl -sf --max-time 5 http://localhost:80/     → non-empty response
mps port list $SHORT                           → 80 "active"
```

### Phase 12: Down/Up + Tunnel Lifecycle

Tests tunnel death on stop, `mps_require_running` guard on stopped VMs, lazy tunnel re-establishment after restart, mount persistence distinction, and process loss on full shutdown (not suspend).

```
# --- Verify tunnels alive before down ---
mps port list $SHORT                     → 18111, 80, 19000 all "active"

# --- Down: tunnels die, VM stops ---
mps down
mps status --json                        → state == "Stopped"
mps port list $SHORT                     → all ports "dead"

# --- Error behavior on stopped VM (mps_require_running guard) ---
mps exec -- echo hello                   → exit != 0, stderr contains "not running"
mps port forward $SHORT 29000:9000       → exit != 0, stderr contains "not running"

# --- Up: VM restarts (full shutdown — processes killed) ---
mps up
mps status --json                        → state == "Running"

# --- Mount restoration ---
# Auto-mount restored
mps exec -- cat <auto-mounted-file>      → content matches

# Config mount restored (defined in .mps.env MPS_MOUNTS)
mps exec -- cat /mnt/config-mount/configfile.txt → "config-mount-content"
mps mount list                           → /mnt/config-mount origin "config"

# Adhoc mount NOT restored (session-only, lost on down)
mps mount list                           → does not contain /mnt/adhoc

# --- Lazy tunnel re-establishment via first exec ---
mps exec -- echo alive                   → "alive"
mps port list $SHORT                     → 19000 "active" (re-established from MPS_PORTS)

# --- Explicit forwards need manual re-forward ---
mps port forward $SHORT 18111:8111
mps port forward --privileged $SHORT 80:8111
mps port list $SHORT                     → 18111, 80, 19000 all "active"

# --- Restart service (killed by full shutdown) and verify end-to-end ---
mps exec -- sh -c 'nohup python3 -m http.server 8111 &>/dev/null &'
sleep 2
curl -sf --max-time 5 http://localhost:18111/  → response
curl -sf --max-time 5 http://localhost:80/     → response
```

### Phase 13: Destroy + Cleanup Verification

```
mps destroy --force
mps list                                 → does not contain instance
assert: ~/.mps/instances/<short>.json removed
assert: ~/.mps/sockets/<short>-*.sock removed
assert: ~/.ssh/config.d/mps-$FULL_NAME removed
```

### Phase 14: Image Remove

```
mps image remove $IMAGE_NAME --force
mps image list                           → does not contain image
```

### Phase 15: Uninstall *(when `MPS_E2E_INSTALL=true`)*

```
yes | bash uninstall.sh
assert: command -v mps fails
assert: completion file removed
assert: ~/.mps/instances/ empty or gone
```

---

## Coverage Path-Awareness

The existing `coverage-trap.sh` and `coverage-report.sh` are hardcoded to `/workdir/` paths (Docker container layout). E2E runs on the **host**, so xtrace lines have real host paths. Both scripts need a configurable prefix.

### `coverage-trap.sh` changes

Add `_MPS_COV_PREFIX` env var (defaults to `/workdir` for backward compat). Replace the hardcoded grep pattern:

```bash
# Before (line 31):
exec {BASH_XTRACEFD}> >("$_cov_grep" --line-buffered -E '^\++ /workdir/(bin/mps|lib/|commands/|...)' ...

# After:
_cov_prefix="${_MPS_COV_PREFIX:-/workdir}"
exec {BASH_XTRACEFD}> >("$_cov_grep" --line-buffered -E "^\++ ${_cov_prefix}/(bin/mps|lib/|commands/|completions/|install\.sh|uninstall\.sh)" ...
```

Existing `make test` (Docker) continues to work unchanged — `_MPS_COV_PREFIX` is unset, defaults to `/workdir`.

### `coverage-report.sh` changes

Replace hardcoded `WORKDIR="/workdir"` with a configurable prefix:

```bash
# Before (line 26):
WORKDIR="/workdir"

# After:
WORKDIR="${_MPS_COV_PREFIX:-/workdir}"
```

The `find bin/ lib/ commands/...` on line 58 uses relative paths from CWD, so it works in both Docker (`/workdir/`) and host (project root) — no change needed there, but the `test-e2e-report` target must run from the project root.

## Makefile Targets

```makefile
test-e2e:
	rm -rf $(COVERAGE_DIR)/e2e
	_MPS_COV_DIR=$(CURDIR)/$(COVERAGE_DIR)/e2e \
	_MPS_COV_PREFIX=$(CURDIR) \
	BASH_ENV=$(CURDIR)/tests/coverage-trap.sh \
	bash tests/e2e.sh

test-e2e-report:
	_MPS_COV_PREFIX=$(CURDIR) \
	bash tests/coverage-report.sh coverage/ coverage/unit coverage/integration coverage/e2e
```

`_MPS_COV_PREFIX=$(CURDIR)` makes xtrace grep match real host paths and makes the report strip the correct prefix. Always with coverage. Not wired into `make test` — e2e is slow, requires multipass, separate CI job.

---

## Images Pipeline Integration

```yaml
# images.yml — validation job after build, before publish
validate:
  needs: [build-amd64]
  runs-on: warp-ubuntu-latest-x64-4x
  steps:
    - uses: actions/checkout@v4
    - uses: actions/download-artifact@v4
      with: { name: "mps-base-amd64", path: /tmp/artifacts/ }
    - run: |
        MPS_E2E_INSTALL=true \
        MPS_E2E_IMAGE=/tmp/artifacts/mps-base-amd64.qcow2.img \
        make test-e2e 2>&1 | tee /tmp/mps-e2e.log
```

Regular CI: `MPS_E2E_INSTALL=true make test-e2e` (pulls default `base` from CDN).

---

## Changes to Existing Files

| File | Change |
|------|--------|
| `templates/cloud-init/default.yaml` | Add `#:example` / `#:end` markers around uncommentable blocks |
| `tests/coverage-trap.sh` | Add `_MPS_COV_PREFIX` env var (default `/workdir`) to make grep pattern configurable for host-native runs |
| `tests/coverage-report.sh` | Replace hardcoded `WORKDIR="/workdir"` with `_MPS_COV_PREFIX` env var (default `/workdir`) |
| `Makefile` | Add `test-e2e` and `test-e2e-report` targets (host-native, no Docker, with `_MPS_COV_PREFIX`) |
| `.planning/STATUS.md` | Update e2e checkbox |
| `.planning/TESTING.md` | Update E2E section with implementation details |

## New Files

| File | Description |
|------|-------------|
| `tests/e2e.sh` | Main e2e test script (~400-500 lines) |

---

## Key Design Decisions

### Why plain bash, not BATS
BATS runs each `@test` in a subshell with per-test setup/teardown. E2E VM lifecycle is inherently sequential and stateful: create → configure → test → destroy. Shared VM state across phases is intentional.

### Why single VM for the main flow
One VM exercises all code paths. Creating/destroying between phases would add minutes per cycle with no additional coverage. The coupling is intentional — we're testing a real developer workflow.

### Why coverage by default
Unit/integration tests with stubs cannot reach many code paths (real multipass calls, real SSH, real mounts, real downloads). E2e is the only way to achieve higher overall coverage. Always-on coverage avoids maintaining separate targets.

### Why $HOME-based temp dirs
Multipass is installed as a snap, which restricts file access to the user's home directory. Paths under `/tmp` would fail for mounts and transfers.

### Why SSH config before port forwarding
`mps_forward_port()` requires `ssh.injected == true` in instance metadata. At create time, metadata has `ssh: null`, so `MPS_PORTS` auto-forwarding silently skips. SSH must be configured first, then the next command's `mps_prepare_running_instance()` lazily establishes the tunnels.

### Why `multipass stop` kills processes
`multipass stop` is a full VM shutdown (like poweroff), not suspend. Guest processes are terminated. After `mps up`, services must be restarted. This was confirmed experimentally. The `mps_require_running()` guard in `mps_prepare_running_instance()` protects against commands on stopped VMs — multipass itself would auto-start them, but our guard rejects first.

### Why test three mount origins
Mounts have three persistence tiers: auto (CWD at create, restored on up), config (`MPS_MOUNTS` in `.mps.env`, restored on up), adhoc (`mps mount add`, session-only — lost on down). Testing all three validates the mount lifecycle model.

---

## Not in Scope

- `mps shell` — inherently interactive, `mps exec` covers the same multipass path
- Multi-instance tests — one VM validates all code paths
- CI workflow YAML — separate follow-up after the script works locally
- Windows/PowerShell — Phase 12 of the project
