# Refactor: SSH Port Forward Lifecycle — Automated Verification

Functional tests for the control socket refactor (see `FIX-PRIVILEGED-PORT-PID.md`). All tests executed via `mps` commands on the host — multipass, jq, and sudo are available. This test list is preliminary and will be refined by implementation Step 8.

---

## Test 1: Unprivileged forward — socket created

`mps port forward <name> 3000:3000` on a running instance with SSH configured.
- Assert: exit code 0
- Assert: socket file exists at `~/.mps/sockets/<name>-3000.sock`
- Assert: `ssh -O check -S <socket>` succeeds (master running)
- Assert: `.ports.json` entry has `socket` field (not `pid`)

## Test 2: Privileged forward — socket created

`mps port forward --privileged <name> 80:80` on a running instance.
- Assert: exit code 0
- Assert: socket file exists at `~/.mps/sockets/<name>-80.sock`
- Assert: `sudo ssh -O check -S <socket>` succeeds
- Assert: `.ports.json` entry has `sudo: true` and `socket` field

## Test 3: Dedup — explicit user forward warns on already-mapped

Run `mps port forward <name> 3000:3000` twice.
- Assert: second call exits successfully (no crash)
- Assert: second call output contains "already forwarded" (warn-level message)
- Assert: only one SSH master process exists (single socket)

## Test 4: Dedup — privileged repeated forward warns

Run `mps port forward --privileged <name> 80:80` twice.
- Assert: second call output contains "already forwarded"
- Assert: single socket, single SSH master

## Test 5: Dedup — auto-forward is silent on already-active

Forward a port, then `mps down && mps up` (which auto-forwards).
- Assert: `mps up` output does NOT contain "already forwarded" warnings
- Assert: tunnel is active after up

## Test 6: Port list — active status

After forwarding ports 3000 (unprivileged) and 80 (privileged):
- Assert: `mps port list` shows both as `active`
- Assert: no sudo password prompt during list

## Test 7: Port list — graceful degradation without sudo cache

```bash
sudo -k
mps port list
```
- Assert: unprivileged forwards show `active`
- Assert: privileged forwards show `unknown` (not `dead`, no password prompt)

## Test 8: Down — tunnels killed, sockets cleaned

`mps down <name>` after establishing forwards.
- Assert: all sockets for instance removed from `~/.mps/sockets/`
- Assert: `.ports.json` removed
- Assert: `ssh -O check` on old socket paths fails

## Test 9: Up — auto-forward re-establishes tunnels

`mps up <name>` after down (with `MPS_PORTS` configured).
- Assert: new socket files created
- Assert: `mps port list` shows forwards as `active`

## Test 10: Destroy — full cleanup

`mps destroy --force <name>` after establishing forwards.
- Assert: all sockets for instance removed
- Assert: `.ports.json` removed
- Assert: no orphaned SSH processes for the instance IP

## Test 11: Mixed privilege forwards

Forward both privileged and unprivileged ports on the same instance:
```bash
mps port forward <name> 3000:3000
mps port forward --privileged <name> 80:80
mps port forward --privileged <name> 443:443
```
- Assert: three separate socket files exist
- Assert: `mps port list` shows all three as `active`
- Assert: `mps down` cleans up all three

## Test 12: Stale socket recovery

Manually kill an SSH master (`ssh -O exit`), then re-forward:
```bash
ssh -O exit -S ~/.mps/sockets/<name>-3000.sock dummy
mps port forward <name> 3000:3000
```
- Assert: dedup detects dead socket, re-establishes tunnel
- Assert: new socket is functional
