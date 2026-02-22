# Refactor: SSH Port Forward Lifecycle — Control Sockets

## Context

Port forwarding uses `ssh -N -f -L` tunnels tracked by PID in `.ports.json`. This has several problems:

1. **Wrong PID captured for privileged ports** — `pgrep -f ... | tail -1` picks the transient `sudo` wrapper PID instead of the `ssh` daemon PID
2. **`sudo` prompts in read-only operations** — `mps port list` calls `sudo kill -0` for privileged forwards, can prompt for password when sudo cache expires
3. **Fragile dedup** — relies on `pgrep` regex matching against process command lines, `ps -o comm=` introspection, and `kill -0` liveness checks across privilege boundaries

All three issues stem from the same root cause: tracking tunnels by PID. Replace the entire PID-based tracking with SSH control sockets (`-M -S`), which provide a reliable, cross-platform mechanism for liveness checks, dedup, and clean shutdown — no PID tracking, no `pgrep`, no `kill -0`, no `sudo` for status checks.

**Approach:** One control socket per tunnel (Option A from design discussion). Each `mps port forward` creates an independent SSH master with its own socket file. Dedup = socket exists + `ssh -O check` succeeds. Cleanup = `ssh -O exit` per socket.

---

## Step 1: Add socket directory helper

**File:** `lib/common.sh` — after `mps_ports_file()` (line 1411)

Add helper to return the control socket path for a given instance + host port:

```bash
mps_port_socket() {
    local short_name="$1" host_port="$2"
    local dir="${HOME}/.mps/sockets"
    mkdir -p "$dir"
    echo "${dir}/${short_name}-${host_port}.sock"
}
```

Sockets go in `~/.mps/sockets/` (separate from `~/.mps/instances/` metadata). Socket filenames encode the instance and host port: `<short_name>-<host_port>.sock`.

---

## Step 2: Rewrite `mps_forward_port()` — control socket tunnel

**File:** `lib/common.sh` — `mps_forward_port()` (lines 1457-1588)

### 2a. Return code convention

Change `mps_forward_port()` to use distinct return codes:

- **return 0** — tunnel newly established
- **return 2** — already active (dedup skip)
- **return 1** — error

Callers handle accordingly:
- `_port_forward()` (explicit `mps port forward`): on return 2, warn: "Port localhost:<host_port> is already forwarded to <instance>:<guest_port>"
- `mps_auto_forward_ports()`: on return 2, log debug (silent), don't increment the forwarded count

### 2b. Replace dedup block (lines 1515-1539)

Remove the entire PID-based dedup (read `.ports.json`, `_mps_is_ssh_pid`, `kill -0`). Replace with:

```
socket_path = mps_port_socket(short_name, host_port)
if socket exists AND ssh -O check -S <socket> succeeds:
    return 2
```

For privileged sockets (owned by root), use `sudo ssh -O check`. Use `sudo -n` to avoid password prompts — if sudo cache expired, treat as "not forwarded" and re-establish (the actual `sudo ssh` forward command will prompt if needed, which is acceptable for a write operation).

### 2c. Add `-M -S` to SSH command (lines 1542-1551)

Add control socket flags to the SSH command array:

```
ssh -M -S <socket_path> -N -f -L ...
```

### 2d. Replace PID capture + JSON write (lines 1565-1586)

Remove the entire `pgrep` + `.ports.json` write block. Replace with:

```
Verify tunnel is up: ssh -O check -S <socket_path>
Write .ports.json entry with socket path instead of PID:
  { "guest_port": N, "socket": "<path>", "sudo": true/false }
```

The `.ports.json` schema changes from:
```json
{"3000": {"guest_port": 8080, "pid": 12345, "sudo": false}}
```
to:
```json
{"3000": {"guest_port": 8080, "socket": "/home/user/.mps/sockets/foo-3000.sock", "sudo": false}}
```

---

## Step 3: Update callers for return code 2

**File:** `commands/port.sh` — `_port_forward()` (line 103)

Current code:
```bash
if ! mps_forward_port "$instance_name" "$name" "${host_port}:${guest_port}" "$privileged"; then
    mps_die "Failed to establish port forward"
fi
mps_log_info "Port forward active: localhost:${host_port} → ${instance_name}:${guest_port}"
```

Change to capture return code and handle 0/1/2:
```
rc = mps_forward_port(...)
if rc == 1: die "Failed to establish port forward"
if rc == 2: warn "Port localhost:<host_port> is already forwarded to <instance>:<guest_port>"
if rc == 0: info "Port forward active: ..."
```

**File:** `lib/common.sh` — `mps_auto_forward_ports()` (line 1603)

Current code counts any successful return. Change to only increment count on return 0 (newly established), ignore return 2 (already active):
```
rc = mps_forward_port(...)
if rc == 0: count++
# rc == 2: silent skip (already active)
# rc == 1: already logged by mps_forward_port
```

---

## Step 4: Rewrite `mps_kill_port_forwards()` — socket-based cleanup

**File:** `lib/common.sh` — `mps_kill_port_forwards()` (lines 1617-1656)

Replace PID-based kill loop with:

```
For each entry in .ports.json:
    read socket path and sudo flag
    if sudo: sudo ssh -O exit -S <socket>
    else: ssh -O exit -S <socket>
    rm -f <socket> (cleanup stale socket file)
```

No need for `_mps_is_ssh_pid()` or `kill -0` — `ssh -O exit` is a no-op on dead sockets (fails silently).

---

## Step 5: Update `_port_list()` — socket-based liveness

**File:** `commands/port.sh` — `_port_list()` (lines 112-174)

Replace PID-based liveness checks (lines 153-164) with:

```
Read socket path and sudo flag from .ports.json entry
if sudo: sudo -n ssh -O check -S <socket>
else: ssh -O check -S <socket>
alive → "active" (green)
dead → "dead" (red)
sudo -n failed (expired cache) → "unknown" (yellow)
```

Update display columns: replace `PID` with `STATUS` only (PID is no longer tracked). Or keep the column but show `—` since we don't store PIDs anymore.

---

## Step 6: Remove `_mps_is_ssh_pid()`

**File:** `lib/common.sh` — lines 1396-1405

Delete entirely. No callers remain after Steps 2-4. The function existed solely to guard against stale PIDs — control sockets make this unnecessary.

---

## Step 7: Update `mps_reset_port_forwards()`

**File:** `lib/common.sh` — `mps_reset_port_forwards()` (lines 1659-1670)

Add socket file cleanup after killing forwards and removing `.ports.json`. Glob `~/.mps/sockets/<short_name>-*.sock` and remove any remaining socket files (catches edge case where `.ports.json` was deleted but sockets remain):

```bash
local sock
for sock in "${HOME}/.mps/sockets/${short_name}-"*.sock; do
    [[ -e "$sock" ]] && rm -f "$sock"
done
```

---

## Step 8: Update `commands/destroy.sh` — socket cleanup

**File:** `commands/destroy.sh` — lines 75-81

After `mps_kill_port_forwards` and removing `.ports.json`, also clean up socket files:

```bash
local sock
for sock in "${HOME}/.mps/sockets/${short_name}-"*.sock; do
    [[ -e "$sock" ]] && rm -f "$sock"
done
```

Consider extracting a shared helper `mps_cleanup_port_sockets()` if this pattern repeats.

---

## Step 9: Lint and update testing plan

Run `make lint` (shellcheck + lint-bash32 + all other linters). Fix all errors before proceeding.

Review `.planning/FIX-PRIVILEGED-PORT-PID-TESTS.md` — add, remove, or adjust test cases based on:
- What was actually implemented (socket paths, output format changes)
- Edge cases discovered during implementation
- Behaviors that changed from the original plan

---

## Files modified

| File | Change |
|------|--------|
| `lib/common.sh` | New `mps_port_socket()`, rewrite `mps_forward_port()` (socket dedup + launch + tracking + return codes), rewrite `mps_kill_port_forwards()` (socket exit), update `mps_auto_forward_ports()` (handle return 2), update `mps_reset_port_forwards()` (socket cleanup), remove `_mps_is_ssh_pid()` |
| `commands/port.sh` | Update `_port_forward()` (handle return 2 — warn on already-mapped), rewrite `_port_list()` liveness checks (socket-based) |
| `commands/destroy.sh` | Add socket file cleanup |

## Functions unchanged

- `mps_ports_file()` — still returns `.ports.json` path
- `mps_collect_port_specs()` — collects specs from config/metadata, unchanged
- Port forward calls in `commands/create.sh`, `commands/up.sh`, `commands/down.sh` — unchanged (they call `mps_auto_forward_ports` / `mps_reset_port_forwards`)
