# Mount System Refactor — Automated Verification

Functional tests for the mount refactor (`.planning/MOUNT-REFACTOR.md`). All tests are executed via `mps` commands on the host — multipass and jq are available. This test list is preliminary and will be refined by implementation Step 7.

---

## Test 1: Metadata schema — workdir field, no mounts array

`mps create`, then inspect instance metadata JSON.
- Assert: `.workdir` field exists and equals the expected mount target path
- Assert: `.mounts` key does not exist

## Test 2: Mount list — auto-mount origin

`mps mount list` on a freshly created instance.
- Assert: CWD auto-mount appears with `auto` origin

## Test 3: Adhoc mount add

`mps mount add <src>:<dst>` on a running instance.
- Assert: mount succeeds (exit code 0)
- Assert: `mps mount list` shows the new mount with `adhoc` origin

## Test 4: Mount list — mixed origins

After adding an adhoc mount to an instance with auto-mount:
- Assert: `mps mount list` shows both mounts with correct origins (`auto`, `adhoc`)

## Test 5: Down/up cycle — adhoc removed, auto restored

`mps down && mps up` after adding an adhoc mount.
- Assert: adhoc mount is gone
- Assert: auto-mount is restored

## Test 6: Config mount persistence

Set `MPS_MOUNTS="<src>:<dst>"` in `.mps.env`, then `mps down && mps up`.
- Assert: both auto-mount and config mount are present
- Assert: config mount shows `config` origin in `mps mount list`

## Test 7: Mount remove + persistence warning

`mps mount remove <guest_path>` for a persistent mount (auto or config).
- Assert: mount is removed (not in `mps mount list`)
- Assert: output warns that mount will return on next `mps up`

## Test 8: Shell workdir

`mps shell -c pwd` after create.
- Assert: output matches the expected workdir from metadata

## Test 9: Status display — mount origins

`mps status` on a running instance with mounts.
- Assert: mount display includes origin annotations (`auto`, `config`, `adhoc`)

## Test 10: Block mount outside $HOME

`mps mount add /etc:/mnt/etc` (source outside $HOME).
- Assert: command fails (non-zero exit code)
- Assert: error message contains "home directory"

## Test 11: Warn on mounting $HOME directly

Create an instance from `$HOME` (e.g., `cd ~ && mps create --name test`).
- Assert: warning output mentions "home directory" or "dotfiles"
- Assert: command still succeeds (warning, not error)

## Test 12: (Linux only) Hidden path warning

`mps mount add ~/.ssh:/mnt/ssh` on a Linux host.
- Assert: warning output mentions "hidden" or "Snap"
- Assert: command is not blocked (warning only)
