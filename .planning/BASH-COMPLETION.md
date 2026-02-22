# Plan: Self-Describing Bash Completion for `mps` CLI

## Context

The `mps` CLI has 13 commands (some with subcommands) and 40+ flags but no tab-completion support. We want a completion system that is **self-maintaining** — adding or changing commands/flags in command files should automatically be reflected in tab-completion without updating a separate file.

## Approach: Self-Describing CLI via `mps __complete`

Each command file gets a small `_complete_<cmd>()` metadata function that declares its own flags, subcommands, and value completions. A hidden `mps __complete` subcommand queries these at tab-time. The completion script (`completions/mps.bash`) is a thin generic dispatcher that never needs updating.

**Why this works:**
- Source of truth for each command's flags lives in the same file as the command itself
- Adding a new command = creating `commands/foo.sh` with `cmd_foo()` + `_complete_foo()` — completion just works
- The completion script is generic and stable
- `mps __complete` uses a fast path that skips config loading and library sourcing (~5ms)

## Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `completions/mps.bash` | **CREATE** | Thin generic bash completion script (~80 lines) |
| `bin/mps` | **MODIFY** | Add `__complete` fast-path before library sourcing |
| `commands/create.sh` | **MODIFY** | Add `_complete_create()` |
| `commands/up.sh` | **MODIFY** | Add `_complete_up()` |
| `commands/down.sh` | **MODIFY** | Add `_complete_down()` |
| `commands/destroy.sh` | **MODIFY** | Add `_complete_destroy()` |
| `commands/shell.sh` | **MODIFY** | Add `_complete_shell()` |
| `commands/exec.sh` | **MODIFY** | Add `_complete_exec()` |
| `commands/transfer.sh` | **MODIFY** | Add `_complete_transfer()` |
| `commands/list.sh` | **MODIFY** | Add `_complete_list()` |
| `commands/status.sh` | **MODIFY** | Add `_complete_status()` |
| `commands/ssh-config.sh` | **MODIFY** | Add `_complete_ssh_config()` |
| `commands/image.sh` | **MODIFY** | Add `_complete_image()` |
| `commands/mount.sh` | **MODIFY** | Add `_complete_mount()` |
| `commands/port.sh` | **MODIFY** | Add `_complete_port()` |
| `install.sh` | **MODIFY** | Add completion symlink installation |
| `uninstall.sh` | **MODIFY** | Add completion symlink removal |
| `Makefile` | **MODIFY** | Add `completions/` to lint file sets |

## Implementation Details

### 1. `mps __complete` Protocol (in `bin/mps`)

Add a fast-path intercept at the top of `main()`, **before** sourcing `lib/common.sh` and `lib/multipass.sh`:

```bash
# Fast-path: tab-completion (skip config/deps/update check)
if [[ "${1:-}" == "__complete" ]]; then
    shift
    _mps_dispatch_complete "$@"
    exit 0
fi
```

The `_mps_dispatch_complete()` function (defined in `bin/mps` itself) handles these forms:

| Invocation | Output |
|---|---|
| `mps __complete commands` | Newline-separated command names (from `commands/*.sh` basenames) |
| `mps __complete <cmd> flags` | Space-separated flags for the command |
| `mps __complete <cmd> subcmds` | Space-separated subcommands (empty if none) |
| `mps __complete <cmd> flag-values <flag>` | Space-separated values for a flag |
| `mps __complete <cmd> <subcmd> flags` | Flags for a subcommand |
| `mps __complete <cmd> <subcmd> flag-values <flag>` | Values for a subcommand's flag |
| `mps __complete instances` | Dynamic instance short names |
| `mps __complete profiles` | Profile names from `templates/profiles/*.env` |
| `mps __complete images` | Image names from `images/layers/*.yaml` + cached images |
| `mps __complete cloud_init` | Template names from `templates/cloud-init/*.yaml` + `~/.mps/cloud-init/*.yaml` |

For `commands`, `instances`, `profiles`, `images`, and `cloud_init` — the handler resolves these directly from the filesystem (no command file sourcing needed).

For `flags`, `subcmds`, and `flag-values` — the handler sources the specific command file and calls its `_complete_<cmd>()` function. Since command files only define functions (no top-level executable code), sourcing without `lib/common.sh` is safe.

### 2. Completion Metadata Functions (in each `commands/*.sh`)

Each command file gets a `_complete_<cmd>()` function. The function receives an action as `$1` and responds with space-separated words on stdout. Actions:

- `flags` — all flags the command accepts
- `subcmds` — subcommands (for image/mount/port; empty for others)
- `flag-values <flag>` — known values for a specific flag

Magic tokens for dynamic values (resolved by the `__complete` handler):
- `__instances__` — instance short names
- `__profiles__` — profile names
- `__images__` — image flavor names
- `__archs__` — `amd64 arm64`
- `__files__` — file path completion
- `__cloud_init__` — template names (project + personal)

**Example — simple command (`commands/down.sh`):**
```bash
_complete_down() {
    case "${1:-}" in
        flags)       echo "--name -n --force -f --help -h" ;;
        flag-values) case "${2:-}" in --name|-n) echo "__instances__" ;; esac ;;
    esac
}
```

**Example — command with subcommands (`commands/image.sh`):**
```bash
_complete_image() {
    case "${1:-}" in
        subcmds) echo "list pull import remove" ;;
        flags)
            case "${2:-}" in
                list)   echo "--remote --help -h" ;;
                pull)   echo "--force -f --help -h" ;;
                import) echo "--name --tag --arch --help -h" ;;
                remove) echo "--arch --all --force -f --help -h" ;;
                *)      echo "--help -h" ;;
            esac ;;
        flag-values)
            case "${3:-}" in
                --arch) echo "__archs__" ;;
            esac ;;
    esac
}
```

**Example — complex command (`commands/create.sh`):**
```bash
_complete_create() {
    case "${1:-}" in
        flags) echo "--name -n --image --cpus --memory --mem --disk --cloud-init --profile --mount --port --transfer --no-mount --help -h" ;;
        flag-values)
            case "${2:-}" in
                --name|-n)    echo "__instances__" ;;
                --profile)    echo "__profiles__" ;;
                --image)      echo "__images__" ;;
                --cloud-init) echo "__cloud_init__" ;;
            esac ;;
    esac
}
```

### 3. `completions/mps.bash` (Thin Completion Script)

Self-contained, Bash 3.2+ compatible, no `set -euo pipefail`. Structure:

```bash
# mps(1) bash completion — delegates to `mps __complete`
command -v complete &>/dev/null || return 0

_mps_completions() {
    local cur prev cmd subcmd
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # 1. Find command word (first non-flag word after "mps")
    # 2. Find subcommand word (second non-flag word, for image/mount/port)
    # 3. Detect if past "--" separator

    # Dispatch to mps __complete based on context:
    # - Value completion: mps __complete <cmd> [<subcmd>] flag-values <prev>
    # - Flag completion: mps __complete <cmd> [<subcmd>] flags
    # - Subcommand completion: mps __complete <cmd> subcmds
    # - Command completion: mps __complete commands

    # Handle magic tokens in output:
    # __instances__ → call mps __complete instances
    # __profiles__ → call mps __complete profiles
    # __images__ → call mps __complete images
    # __files__ → use compgen -f
    # __archs__ → "amd64 arm64"
    # __cloud_init__ → call mps __complete cloud_init

    COMPREPLY=($(compgen -W "$words" -- "$cur"))
}

complete -o default -F _mps_completions mps
```

The `-o default` ensures file path completion works as fallback (e.g., after `--` in exec).

### 4. `install.sh` — Completion Installation

New section after symlink installation, before PATH check:

```
# ---------- Bash Completion ----------
```

Logic:
1. Linux: symlink to `~/.local/share/bash-completion/completions/mps` (create dir if needed)
2. macOS: symlink to `$(brew --prefix 2>/dev/null)/etc/bash_completion.d/mps` if it exists; otherwise print `source` instruction
3. If user's shell is zsh: print `bashcompinit` hint
4. Handle existing symlink gracefully (remove + recreate)

### 5. `uninstall.sh` — Completion Removal

New section after symlink removal (between current sections 1 and 2):

Check known completion locations for our symlink, remove if found, add to `removed` array.

### 6. `Makefile` — Lint Integration (line 42-43)

Add `completions/` to both `BASH_SCRIPTS` and `CLIENT_SCRIPTS` find paths:

```makefile
BASH_SCRIPTS    := $(shell find bin/ lib/ commands/ images/ completions/ -name '*.sh' -o -name '*.bash' -o -name 'mps' 2>/dev/null | grep -v '.ps1') install.sh uninstall.sh
CLIENT_SCRIPTS  := $(shell find bin/ lib/ commands/ completions/ -name '*.sh' -o -name '*.bash' -o -name 'mps' 2>/dev/null | grep -v '.ps1') install.sh uninstall.sh
```

## Performance

The `__complete` fast path:
- Resolves `MPS_ROOT` (~1ms — already happens before library sourcing)
- Skips: `lib/common.sh`, `lib/multipass.sh`, config cascade, dep check, update check
- For static completions (flags/subcmds): sources one command file, calls one function (~5ms total)
- For dynamic completions (instances): `multipass list --format json | jq` (~50-100ms)
- Well within acceptable tab-completion latency

## Verification

1. `make lint` — shellcheck + bash32 compat pass on all modified files
2. Interactive testing after sourcing the completion:
   ```bash
   source completions/mps.bash
   mps <TAB>                          # → all commands
   mps create --<TAB>                 # → create flags
   mps create --profile <TAB>         # → micro, lite, standard, heavy
   mps image <TAB>                    # → list, pull, import, remove
   mps image pull <TAB>               # → image flavor names
   mps --<TAB>                        # → global flags (--help, --version, --debug)
   mps exec --name foo -- <TAB>       # → default file completion
   mps down --name <TAB>              # → instance names (dynamic)
   ```
3. Verify `mps __complete` outputs directly:
   ```bash
   mps __complete commands
   mps __complete create flags
   mps __complete create flag-values --profile
   mps __complete image subcmds
   mps __complete image pull flags
   mps __complete instances
   mps __complete profiles
   ```

## Out of Scope

- Zsh native completion (future `completions/_mps` or `completions/mps.zsh`)
- Fish completion
- CLAUDE.md project structure update
