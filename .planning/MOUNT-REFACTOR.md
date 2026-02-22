# Mount System Refactor

## Context

VMs are treated as cattle, not pets — frequent `destroy + up` cycles are expected as images update. The current mount system stores all mount info in instance metadata, making it the source of truth. This refactor makes `.mps.env` the durable config for persistent mounts and Multipass the source of truth for current mount state. Instance metadata is simplified to just a `workdir` field. A new `mps mount` subcommand enables runtime mount management with clear persistent vs session-only semantics.

**Design decisions (from discussion):**
- Persistent mounts = CWD auto-mount + `MPS_MOUNTS` in config. Restored on every `mps up`.
- Session-only mounts = `mps mount add` on running instances. Removed on `mps down`.
- No `--persist` flag — help text directs users to `.mps.env` for persistence.
- Metadata stores only `workdir` (for `shell`/`exec`). No mount array.
- Mount origins derived at runtime: Multipass mounts matched against workdir (auto), `MPS_MOUNTS` (config), remainder (adhoc).

---

## Step 1: Simplify instance metadata schema

**File:** `lib/common.sh` — `mps_save_instance_meta()` (~line 1015)

Change third parameter from `mounts_json` (JSON array) to `workdir` (plain string):

```
Before: mps_save_instance_meta(name, image_json, mounts_json, port_forwards_json, transfers_json)
After:  mps_save_instance_meta(name, image_json, workdir, port_forwards_json, transfers_json)
```

In the jq template:
- Replace `--argjson mounts "$mounts_json"` with `--arg workdir "$workdir"`
- Replace `mounts: $mounts,` with `workdir: (if $workdir == "" then null else $workdir end),`

**File:** `lib/common.sh` — `mps_resolve_workdir()` (~line 444)

Read `.workdir` field directly. No backward-compat fallback needed (no external users yet).

---

## Step 2: Update `mps create` to pass workdir

**File:** `commands/create.sh` (~lines 236-276)

- Remove the entire `mounts_json` building block (lines 236-260) — the loops that build `[{"source":..., "target":..., "auto": true/false}]`
- Replace with: `local workdir="${MPS_MOUNT_TARGET:-}"`
- Update the `mps_save_instance_meta` call to pass `"$workdir"` as third arg

The multipass launch mount logic (lines 164-192) stays unchanged — auto-mount, `--mount` flags, and `MPS_MOUNTS` are still passed to `mp_launch` via `extra_args`.

Note: `--mount` flags on `mps create` still work but behave as session mounts. They're passed to Multipass at launch, cleaned up on `mps down`, and not restored on `mps up`. Help text should note: "For persistent mounts, use MPS_MOUNTS in .mps.env."

---

## Step 3: Rewrite `_up_restore_mounts()` to restore all persistent mounts

**File:** `commands/up.sh` — `_up_restore_mounts()` (~lines 139-164)

Current: only restores CWD auto-mount.
New: restores auto-mount AND `MPS_MOUNTS` from config cascade.

Logic:
1. Query Multipass for existing mounts (single `mp_info` call)
2. If not `--no-mount`: resolve auto-mount, mount if not already present
3. Parse `MPS_MOUNTS` via `mps_parse_extra_mounts()`, mount each if not already present
4. For each, check Multipass mounts by guest-path key to avoid duplicates

Reuses existing helpers: `mps_resolve_mount()`, `mps_parse_extra_mounts()`, `mp_mount()`.

---

## Step 4: Add adhoc mount cleanup to `mps down`

**File:** `commands/down.sh` — insert before `mp_stop()` (line 71)

Add `_down_cleanup_adhoc_mounts()` that:
1. Queries Multipass for current mounts
2. Reads `workdir` from metadata (auto-mount target)
3. Resolves `MPS_MOUNTS`: if already set by config cascade, use it; otherwise read from `${workdir}/.mps.env` and `~/.mps/config` via grep (don't source — avoid side effects). This handles `mps down --name foo` from a non-project directory where the cascade didn't load the project's `.mps.env`. Works because `workdir` equals the host project path on Linux/macOS (identity mapping in `mps_host_to_guest_path()`).
4. Unmounts anything that doesn't match auto or config (= adhoc)

This is necessary because Multipass natively persists all mounts across stop/start. Without cleanup, session-only mounts would survive `mps down && mps up`.

The function returns early (no-op) if no mounts or all mounts are persistent.

---

## Step 5: Create `commands/mount.sh`

**New file**, following `commands/port.sh` dispatch pattern.

### `cmd_mount()` — dispatcher
Extracts first arg as subcommand, dispatches to `_mount_add`, `_mount_remove`, `_mount_list`.

### `_mount_add <src:dst> [--name <name>]`
- Requires running instance (`mps_require_running`)
- Validates `src:dst` format, resolves relative source to absolute
- Mount source validation (see below)
- Checks Multipass for existing mount at target (skip if present)
- Calls `mp_mount()`
- Logs: "Mounted ... (session-only, removed on 'mps down')"

### `_mount_remove <guest_path> [--name <name>]`
- Requires running instance
- Verifies mount exists in Multipass
- Calls `mp_umount()`
- If removed mount matches workdir or config: warns it will return on next `mps up` and directs user to edit `MPS_MOUNTS` in `.mps.env` for permanent removal

### `_mount_list [--name <name>]`
- Requires running instance
- Queries Multipass for current mounts
- Resolves `MPS_MOUNTS` via cascade or project `.mps.env` (same pattern as Step 4)
- Derives origin for each: match workdir = `auto`, match `MPS_MOUNTS` = `config`, else `adhoc`
- Displays table: `SOURCE  TARGET  ORIGIN`

### `_mount_usage()`
- Documents all three subcommands
- Includes persistence guidance: "For persistent mounts, add MPS_MOUNTS to .mps.env"

### Mount source validation

Add a shared helper `mps_validate_mount_source()` in `lib/common.sh` that enforces security rules on mount source paths. Called after resolving to absolute path.

**Rule 1 — Block mounts outside $HOME (error, hard block):**
On macOS and deb-based Linux installs, Multipass can mount any path including root-owned directories. Snap confinement on Ubuntu limits this to `$HOME`, which is desirable. Enforce this restriction universally in mps:
- If resolved source path is not under `$HOME`, die with: "Mount source must be within your home directory ($HOME)."
- This prevents mounting system directories (`/etc`, `/var`, `/usr`) into the VM.

**Rule 2 — Warn on mounting $HOME directly (warn, allow):**
If the resolved source path equals `$HOME` exactly:
- Log warning: "Mounting your entire home directory exposes dotfiles (.ssh, .gnupg, etc.) inside the VM. Consider mounting a project subdirectory instead, or use --no-mount."
- Do NOT block — user may have a legitimate reason.

**Rule 3 — Warn on hidden paths on Linux (warn, allow):**
On Linux (Snap installs), mounting hidden top-level paths (e.g. `~/.ssh`) is blocked by Snap confinement. Non-hidden parents containing hidden children work fine.
- If `mps_detect_os` = `linux` and resolved source path's basename starts with `.`:
- Log warning: "Snap may block mounting hidden paths directly. Consider mounting the parent directory instead."
- Do NOT block — let `multipass mount` fail with its own error if applicable.

**Where to call:**
- `_mount_add()` — after resolving source path
- `commands/create.sh` — when processing `--mount` CLI flags and `MPS_MOUNTS` config entries (before passing to `mp_launch`)
- `_up_restore_mounts()` — when mounting config mounts

The CWD auto-mount doesn't need rule 1/3 checks (CWD is virtually always a non-hidden project dir under $HOME), but should get the rule 2 check (user could `cd ~ && mps create`).

Also add notes in `_mount_usage()` help text about these restrictions.

---

## Step 6: Update help text and mount display

**File:** `bin/mps` (~line 56) — add `mount` to command list in `mps_usage()`.

**File:** `commands/status.sh` (~lines 150-166) — enhance mount display with origin annotations (`auto`, `config`, `adhoc`) when instance is running. Same derivation logic as `_mount_list` (resolve `MPS_MOUNTS` via cascade or project `.mps.env`).

---

## Step 7: Lint and update testing plan

Run `make lint` (shellcheck + lint-bash32 + all other linters). Fix all errors before proceeding.

Review `.planning/MOUNT-REFACTOR-TESTS.md` — add, remove, or adjust test cases based on:
- What was actually implemented (APIs, flags, output formats)
- Edge cases discovered during implementation
- Behaviors that changed from the original plan

---

## Files modified

| File | Change |
|------|--------|
| `lib/common.sh` | `mps_save_instance_meta()` signature, `mps_resolve_workdir()`, new `mps_validate_mount_source()`, new `_mps_resolve_project_mounts()` helper |
| `commands/create.sh` | Remove `mounts_json` building, pass `workdir` to metadata, mount source validation |
| `commands/up.sh` | Rewrite `_up_restore_mounts()` for auto + config mounts |
| `commands/down.sh` | Add `_down_cleanup_adhoc_mounts()` before stop |
| `commands/mount.sh` | **New file**: `cmd_mount()` with add/remove/list |
| `commands/status.sh` | Origin annotations in mount display |
| `bin/mps` | Add `mount` to help text |

## Existing helpers reused (no changes needed)

- `mps_resolve_mount()`, `mps_resolve_mount_source()`, `mps_host_to_guest_path()` — `lib/common.sh`
- `mps_parse_extra_mounts()` — `lib/common.sh`
- `mp_mount()`, `mp_umount()` — `lib/multipass.sh`
- `mps_require_running()`, `mps_resolve_instance_name()`, `mps_short_name()` — `lib/common.sh`
- `_mps_read_meta_json()` — `lib/common.sh`
