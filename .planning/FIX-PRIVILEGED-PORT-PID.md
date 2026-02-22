# Fix: Privileged Port Forward PID Tracking

## Bug Summary

When forwarding privileged ports (`< 1024`) via `--privileged`, the PID recorded in `.ports.json` is the transient `sudo` wrapper PID instead of the actual `ssh -N -f` daemon PID. This causes `mps port list` to report privileged forwards as `dead` even though the tunnels are actively listening.

## Discovered

2026-02-22, during live verification of the JSON metadata refactor (commit `a259484`).

## Root Cause

`lib/common.sh:1567`:

```bash
pid="$(sudo pgrep -f "ssh.*-L.*${host_port}:localhost:${guest_port}.*${ip}" | tail -1)" || true
```

Classic `pgrep -f` self-match gotcha:

1. `sudo ssh -N -f -L 80:localhost:80 ...` runs → ssh forks into background (PID 77609), sudo exits
2. `sudo pgrep -f "ssh.*-L.*80:localhost:80.*IP" | tail -1` runs
3. `pgrep` excludes its own PID but **not** its parent `sudo` process
4. `sudo`'s command line (`sudo pgrep -f "ssh.*-L.*80:localhost:80..."`) contains the search pattern as a literal string, so the regex matches it
5. `tail -1` picks the highest PID — which is the transient `sudo` wrapper, not the ssh daemon

### Observed PIDs

| Port | Recorded PID (sudo, dead) | Actual SSH PID (alive) |
|------|---------------------------|------------------------|
| 80   | 77611                     | 77609                  |
| 443  | 78257                     | 78255                  |
| 3000 | 77930 (correct)           | 77930                  |

Unprivileged ports (3000) are unaffected — no `sudo` wrapper means no self-match.

## Cross-Platform Impact

**Affects both Linux and macOS identically.** Both Linux `pgrep` (procps) and macOS `pgrep` (BSD):
- Exclude their own PID with `-f`
- Do **not** exclude the parent `sudo` process
- Match against full command line with `-f`

## Downstream Effects

1. **`mps port list`** reports privileged forwards as `dead` (checks recorded PID via `sudo kill -0`)
2. **Duplicate tunnel detection** (`lib/common.sh:1526`) calls `_mps_is_ssh_pid` on the wrong PID — would fail to detect an existing tunnel and could spawn duplicates
3. **`mps port list`** uses `sudo kill -0` for liveness checks on privileged ports (line 1155). If the sudo credential cache has expired, this triggers an **unexpected password prompt during a read-only listing operation**

## Fix

### Primary: PID capture (`lib/common.sh:1566-1570`)

Replace `tail -1` with `head -1` on both the sudo and non-sudo paths:

```bash
# Before (broken)
if [[ "$_use_sudo" == "true" ]]; then
    pid="$(sudo pgrep -f "ssh.*-L.*${host_port}:localhost:${guest_port}.*${ip}" | tail -1)" || true
else
    pid="$(pgrep -f "ssh.*-L.*${host_port}:localhost:${guest_port}.*${ip}" | tail -1)" || true
fi

# After (fixed)
if [[ "$_use_sudo" == "true" ]]; then
    pid="$(sudo pgrep -f "ssh.*-L.*${host_port}:localhost:${guest_port}.*${ip}" | head -1)" || true
else
    pid="$(pgrep -f "ssh.*-L.*${host_port}:localhost:${guest_port}.*${ip}" | head -1)" || true
fi
```

**Why `head -1` works:** The actual `ssh -N -f` daemon is always the oldest (lowest PID) match. Transient processes (`sudo`, `pgrep`, shell wrappers) are spawned after the ssh daemon and always have higher PIDs.

### Secondary: `mps port list` sudo prompt on expired cache

`commands/port.sh:155` uses `sudo kill -0` for liveness checks. If sudo credentials have expired, this prompts for a password during a read-only list operation.

Options (pick one):
- **A)** Use `sudo -n kill -0` (`-n` = non-interactive, fails silently if no cached creds) and treat failure as "unknown" status instead of "dead"
- **B)** Check liveness via `sudo -n ss -tlnp` or `/proc/<pid>/` (Linux-only) instead of `kill -0`
- **C)** Store the ssh process owner in ports.json and use appropriate kill check

Recommended: **Option A** — minimal change, graceful degradation.

```bash
# Before
if sudo kill -0 "$pid" 2>/dev/null; then

# After
if sudo -n kill -0 "$pid" 2>/dev/null; then
```

And display `unknown` (yellow) instead of `dead` (red) when `sudo -n` fails due to expired credentials. Same fix for the duplicate-detection path in `mps_forward_port`.

### Tertiary: Duplicate detection (`lib/common.sh:1526-1537`)

Same PID mismatch affects `_mps_is_ssh_pid` check. After the primary fix, the correct PID will be stored, so this resolves automatically. However, the `sudo kill -0` call at line 1529 should also use `sudo -n` for the same reason.

## Files to Change

| File | Lines | Change |
|------|-------|--------|
| `lib/common.sh` | 1566-1570 | `tail -1` → `head -1` |
| `lib/common.sh` | 1528-1529 | `sudo kill -0` → `sudo -n kill -0` |
| `commands/port.sh` | 155 | `sudo kill -0` → `sudo -n kill -0` + `unknown` status |

## Verification

After fix, rerun the privileged port lifecycle test:

```bash
mps create
mps ssh-config --name <name>
mps port forward --privileged <name> 80:80
mps port forward --privileged <name> 443:443
mps port forward <name> 3000:3000

# Verify PIDs match actual ssh processes
cat ~/.mps/instances/<name>.ports.json | jq '."80".pid'
sudo pgrep -af "ssh.*-L.*80:localhost:80"
# Recorded PID should match the ssh process PID

# Verify port list shows "active" for all three
mps port list

# Verify port list works without sudo creds
sudo -k
mps port list
# Privileged ports should show "unknown" (not prompt for password)

mps down --name <name>
mps destroy --force --name <name>
```
