# Testing Strategy & Coverage

## Framework

- **BATS** (Bash Automated Testing System) v1.13.0
- Tests run inside Docker linter container: `make test`
- Test files: `tests/unit/*.bats` (unit), `tests/integration/*.bats` (integration)
- Shared helper: `tests/test_helper.bash`

## Test Tiers

| Tier | Scope | Runs in | Interpreter | Speed |
|------|-------|---------|-------------|-------|
| **Unit** | Pure functions, no I/O | Docker (linter) | Bash 4+ AND Bash 3.2 | Fast |
| **Integration** | Commands with mocked multipass/network | Docker (linter) | Bash 4+ AND Bash 3.2 | Medium |
| **E2E** | Full VM lifecycle, real multipass + KVM | Native host (CI or local) | Host bash | Slow |

Unit and integration tests exist today. E2E tier is designed but not yet implemented — see [E2E.md](E2E.md).

## Dual-Interpreter Testing

Client scripts (`bin/mps`, `lib/*.sh`, `commands/*.sh`) must work on Bash 3.2+ (macOS default).
The linter image includes a `bash32` binary built from source. All unit and integration tests
run under both Bash 4+ and Bash 3.2 **in parallel** (separate Docker containers, orchestrated
via Makefile). No collisions — each container has its own filesystem and environment.

Test files themselves must also be Bash 3.2-compatible (no associative arrays, no `mapfile`, etc.).

## CI Integration

| Trigger | Tiers | Budget |
|---------|-------|--------|
| PR / push to `main` | Unit + Integration (Bash 4+ with coverage ∥ Bash 3.2) | <20 min wall time |
| `mps/v*` tag (release) | Unit + Integration + E2E | ~2h |
| `images/v*` tag | Image build + potentially E2E | TBD — E2E could run against x86 artifacts while arm64 builds (~75 min free window) |

Runner sizing TBD based on real-world timing data.

### E2E Platform Coverage

- **Linux x86**: Standard GitHub-hosted runners have KVM + `snap install multipass`
- **macOS**: Skipped — CI runners are VMs, no nested virtualization for Multipass. macOS-specific
  surface (path conversion, mount resolution) is small and covered by unit tests + Bash 3.2 compat.
  Revisit if bare-metal Mac CI (MacStadium/Orka) becomes available.

## Mocking Strategy

### Integration: `multipass` binary stub

Mock boundary is the `multipass` binary, not the `mp_*` wrapper functions. A stub script
placed on `PATH` dispatches based on arguments and returns canned JSON/exit codes. This tests
both `lib/multipass.sh` parsing and `commands/*.sh` orchestration in one shot.

Fixtures are captured from real `multipass` output via `make capture-fixtures` (runs
`tests/capture-fixtures.sh` on host). The stub lives at `tests/stubs/multipass` and is
placed on `PATH` ahead of the real binary during tests. Fixture scenarios:
- `running-mounted/` — primary Running+2 mounts, secondary Stopped, foreign Running
- `suspended/` — primary Suspended, secondary Stopped, foreign Running
- `all-stopped/` — primary Stopped, secondary Stopped, foreign Running
- `synthetic/` — derived Starting/Deleted/Unknown states (patched from running-mounted)
- `version.json`, `error-nonexistent.stderr` — standalone fixtures

Stub environment variables control behavior:
- `MOCK_MP_FIXTURES_DIR` — scenario directory
- `MOCK_MP_CALL_LOG` — invocation log for lifecycle assertions
- `MOCK_MP_EXIT_CODE` / `MOCK_MP_<CMD>_EXIT` — configurable exit codes
- `MOCK_MP_EXEC_OUTPUT` / `MOCK_MP_EXEC_EXIT` / `MOCK_MP_DOCKER_VERSION` — exec responses

### Integration: Network functions

For manifest fetches, staleness checks, CLI update checks (`_mps_fetch_manifest`,
`_mps_check_image_staleness`, `_mps_check_cli_update`): a lightweight local HTTP server
(python3 `http.server`) serves fixture files on localhost. This tests real `curl`/`aria2c`
code paths — HTTP status codes, `HEAD` requests, conditional GET (`If-Modified-Since`),
headers — without needing separate binary stubs for each download tool.

Implementation:
- `tests/stubs/http_server.py` — small script using `http.server`, serves a configurable
  fixture directory, supports HEAD + GET + conditional responses, binds to `127.0.0.1:0`
  (OS-assigned port), prints port to stdout on ready
- Tests override `MPS_CDN_BASE_URL` (or equivalent) to `http://127.0.0.1:<port>`
- Setup starts the server in background, captures PID + port; teardown kills PID
- Fixtures: manifest JSON, `.meta.json` sidecars, `mps-release.json` — small files,
  no multi-GB image downloads needed (staleness checks use HTTP HEAD against sidecars)

### E2E: Real everything

No mocking. Real `multipass`, real VMs, real mounts, real port forwards, real SSH tunnels.
Image download testing uses real CDN (acceptable at CI network speeds) or imports local artifacts.

**Implementation**: `tests/e2e.sh` — plain bash (not BATS), `set -euo pipefail`, single VM.
- ~90 assertions across 16 phases, assertion counters (pass/fail/skip), non-aborting failures
- Fatal gates: install failure skips all phases, create failure skips VM-dependent phases
- Coverage via `BASH_ENV` + `_MPS_COV_PREFIX` (same mechanism as unit/integration)
- Makefile targets: `make test-e2e` (with coverage), `make test-e2e-report` (merge all tiers)
- Env vars: `MPS_E2E_IMAGE` (name or file path), `MPS_E2E_INSTALL` (install/uninstall bookends)
- Stale reaper: destroys leftover `mps-project-cloud-init-e2e` instance before starting
- Temp directory: `$HOME/mps-e2e-<pid>/` (under HOME for snap confinement)

## Code Coverage

Lightweight xtrace-based coverage via `BASH_ENV` + `BASH_XTRACEFD` + grep filter (Bash 4+ only).
No external coverage tool — uses bash's built-in `set -x` with a process substitution pipe to
grep, keeping only trace lines from project source files. Each bash process re-opens its own
FD (close-on-exec prevents inheritance across `exec()`).

- `tests/coverage-trap.sh` — `BASH_ENV` script that sets up the xtrace→grep→hits.log pipe
- `tests/coverage-report.sh` — post-processor generating lcov.info + terminal summary
- `make test` — all tests with coverage: Bash 4+ instrumented + Bash 3.2 compat, then report
- Output: `coverage/lcov.info` (for Codecov/CI), terminal summary table

**Line counting**: Only lines that xtrace can trace are counted as executable. Closing
constructs (`fi`, `done`, `esac`, `}`, `;;`, `else`, `then`, `do`) are excluded — bash
xtrace never fires for them.

**Coverage applies to all tiers**: The `BASH_ENV` mechanism works with any bash process,
not just BATS. E2E scripts get coverage for free by exporting the same env vars.

## Test Isolation

- **Unit/Integration**: Temp directories (`setup_temp_dir`/`teardown_temp_dir`), env cleanup
- **E2E**: Instance naming convention `mps-test-<random>` to prevent collisions between
  parallel runs or crashed previous runs. Aggressive cleanup in teardown. Consider a
  "stale test VM reaper" script for CI that kills `mps-test-*` instances older than N minutes.

---

## Unit Test Coverage: `lib/common.sh`

### Covered

| Function | Test File | Notes |
|----------|-----------|-------|
| `_mps_parse_size_mb` | `common_parsing.bats` | G/M/bare/invalid inputs |
| `_mps_semver_gt` | `common_parsing.bats` | Greater/equal/less, numeric (10>9) |
| `_mps_is_mps_image` | `common_parsing.bats` | Word names vs numeric Ubuntu versions |
| `mps_log_info` | `common_logging.bats` | Prefix, stderr output |
| `mps_log_warn` | `common_logging.bats` | Prefix |
| `mps_log_error` | `common_logging.bats` | Prefix |
| `mps_log_debug` | `common_logging.bats` | MPS_DEBUG=true/false/unset |
| `mps_die` | `common_logging.bats` | Non-zero exit, error message |
| `_mps_load_env_file` | `common_config.bats` | MPS_* only, comments, quotes, whitespace |
| `_mps_apply_profile` | `common_config.bats` | Sets unset vars, skips overridden, comments |
| `mps_load_config` | `common_config.bats` | Defaults, project override, https validation |
| `mps_validate_resources` | `common_resources.bats` | Valid/invalid CPU/memory/disk, edge cases |
| `_mps_compute_resources` | `common_resources.bats` | Fraction math, min/cap/floor, G vs M format |
| `mps_instance_name` | `common_naming.bats` | Prefix add, no double-prefix, custom prefix |
| `mps_short_name` | `common_naming.bats` | Strip prefix, custom prefix |
| `mps_validate_name` | `common_naming.bats` | Valid chars, rejects dash/dot/space/slash/empty |
| `mps_auto_name` | `common_naming.bats` | Derivation, sanitize, truncate+hash, template strip, custom prefix |
| `mps_resolve_name` | `common_naming.bats` | Priority: explicit > MPS_NAME > auto-name > error |
| `mps_detect_os` | `common_paths.bats` | Returns "linux" in container |
| `mps_detect_arch` | `common_paths.bats` | Returns amd64 or arm64 |
| `mps_host_to_guest_path` | `common_paths.bats` | Identity on Linux |
| `mps_resolve_mount_source` | `common_paths.bats` | CWD fallback, absolute path |
| `mps_resolve_mount` | `common_paths.bats` | Source+target, MPS_NO_AUTOMOUNT, explicit override |
| `_mps_snap_confined` | `common_paths.bats` | Returns false in test env (no snap) |
| `_mps_check_snap_path` | `common_paths.bats` | No-op unconfined, dies on HOME dotdir, allows visible/outside/nested |
| `mps_validate_mount_source` | `common_paths.bats` | HOME check, outside HOME rejection, HOME warn, snap confined hidden path |
| `mps_parse_extra_mounts` | `common_paths.bats` | Empty, absolute pairs, multiple specs |
| `_mps_read_meta_json` | `common_meta.bats` | Read key, missing key, missing file, nested |
| `_mps_write_json` | `common_meta.bats` | Write, permissions (600), atomic overwrite |
| `mps_state_dir` | `common_meta.bats` | Creates dir, correct path |
| `mps_cache_dir` | `common_meta.bats` | Creates dir, correct path |
| `mps_instance_meta` | `common_meta.bats` | Correct path format |
| `mps_resolve_cloud_init` | `common_meta.bats` | Built-in, absolute path, personal, missing, default |
| `_mps_resolve_latest_version` | `common_meta.bats` | Highest semver, arch filter, "local" fallback, empty |
| `mps_check_image_requirements` | `common_meta.bats` | Non-file URL, no meta, CPU/memory/disk warn, profile suggest |
| `mps_ports_file` | `common_ports.bats` | Correct path |
| `mps_port_socket` | `common_ports.bats` | Path format, dir creation |
| `mps_port_forward_count` | `common_ports.bats` | No file (0), counts entries |
| `mps_collect_port_specs` | `common_ports.bats` | Empty, MPS_PORTS, dedup, metadata merge, priority |
| `mps_image_meta` | `common_meta.bats` | Read key, numeric key, missing key, missing file, arch distinction |
| `_mps_read_cached_manifest` | `common_meta.bats` | Read cached, missing returns 1, full content + JSON validation |
| `mps_save_instance_meta` | `common_meta.bats` | Create file, valid JSON, name/full_name, resources, cloud_init, workdir null/value, image object/null, port forwards, transfers, timestamp, permissions (600), ssh null, MPS_DEFAULT fallbacks |
| `mps_resolve_workdir` | `common_meta.bats` | Explicit arg, metadata read, no metadata (empty), no workdir field (empty), null workdir (empty), explicit priority over metadata |
| `mps_resolve_instance_name` | `common_naming.bats` | Prefix explicit, auto-derive from cwd, template override, validation, no double-prefix |
| `mps_cleanup_port_sockets` | `common_ports.bats` | Remove matching, preserve other, no matching, missing dir, multiple sockets |
| `_mps_sha256` | `common_utils.bats` | Hash file, includes filename, stdin, different content, 64 hex chars |
| `_mps_md5` | `common_utils.bats` | Hash file, includes filename, 32 hex chars, different content |
| `mps_require_cmd` | `common_utils.bats` | Existing cmd, silent success, missing cmd, multipass message, jq message, generic message |
| `_mps_download_file` | `network.bats` | aria2c path (3 tests), curl fallback (3 tests), -d/-o flag correctness (1 test) |
| `_mps_remote_is_fresh` | `network.bats` | 304 fresh, 200 stale, missing ref, unreachable server |
| `_mps_remote_fetch` | `network.bats` | First fetch, 304 cache hit, 200 update, network failure ± cache, mkdir |
| `_mps_fetch_manifest` | `network.bats` | Fetch, empty URL, cache file, cached fallback |
| `_mps_check_image_staleness` | `network.bats` | up-to-date, stale, update, 304 fast path, non-SemVer, no meta, manifest fallback |
| `_mps_warn_image_staleness` | `network.bats` | Rebuild warning, update warning, silent cases (up-to-date, opt-out, non-SemVer) |
| `_mps_check_instance_staleness` | `network.bats` | up-to-date, stale, update, stale:manifest, update:manifest, stock, no metadata |
| `_mps_warn_instance_staleness` | `network.bats` | Stale warning, update warning, --skip-manifest, opt-out |
| `_mps_check_cli_update` | `network.bats` | Remote newer, 24h TTL cache, opt-out, non-SemVer, empty URL |
| `_mps_cli_update_warn` | `network.bats` | Update available, force-push detection (temp git repo), missing cache, non-git |
| `mps_check_deps` | Integration | Requires multipass+jq on PATH |
| `mps_require_exists` | Integration | Calls `mp_instance_exists` (mocked multipass) |
| `mps_require_running` | Integration | Calls `mp_instance_state` (mocked multipass) |
| `mps_resolve_image` | Integration | Filesystem + auto-pull + arch detection |
| `_mps_pull_image` | Integration | Network (manifest + download + checksum) |
| `_mps_resolve_project_mounts` | Integration | Metadata + config file parsing |
| `mps_prepare_running_instance` | E2E | require_running + staleness + port forwards |
| `mps_confirm` | Skip | Interactive stdin — not automatable |
| `mps_forward_port` | Integration | SSH stub, validation+happy+failure paths (17 tests) |
| `mps_auto_forward_ports` | Integration | SSH stub, orchestration (6 tests) |
| `mps_kill_port_forwards` | Integration | SSH stub, socket teardown (5 tests) |
| `mps_reset_port_forwards` | Integration | SSH stub, kill+re-establish cycle (5 tests) |

### Covered: `lib/multipass.sh` (Stub Smoke Tests)

Integration tests using the mock `multipass` stub and captured JSON fixtures.

| Function | Test File | Notes |
|----------|-----------|-------|
| `mp_list_all` | `stub_smoke.bats` | Filters to mps-prefixed instances (excludes `fixture-foreign`) |
| `mp_state` | `stub_smoke.bats` | Running and Stopped states from fixture |
| `mp_instance_exists` | `stub_smoke.bats` | Known instance (exit 0), unknown (exit non-zero) |
| `mp_get_mounts` | `stub_smoke.bats` | Mounted instance (2 mounts), unmounted (empty) |
| `mp_ipv4` | `stub_smoke.bats` | Returns valid IP from fixture |

### Covered: `lib/multipass.sh` (Lifecycle, Execution, Mount, Transfer)

Integration tests using the mock `multipass` stub with call-log assertions and configurable exit codes.

| Function | Test File | Notes |
|----------|-----------|-------|
| `mp_info` | `mp_lifecycle.bats` | Full JSON for known instance; dies on unknown |
| `mp_info_field` | `mp_lifecycle.bats` | Field extraction (state, image_release); empty for missing |
| `mp_instance_state` | `mp_lifecycle.bats` | Returns state for existing; "nonexistent" for unknown |
| `mp_launch` | `mp_lifecycle.bats` | Arg construction via call log, defaults, cloud-init, extras, failure |
| `mp_start` | `mp_lifecycle.bats` | Call log, success message, dies on failure |
| `mp_stop` | `mp_lifecycle.bats` | No --force by default, --force when true, dies on failure |
| `mp_delete` | `mp_lifecycle.bats` | --purge by default, omit when false, dies on failure |
| `mp_exec` | `mp_lifecycle.bats` | -- separator, --working-directory, output forwarding, exit code |
| `mp_shell` | `mp_lifecycle.bats` | `multipass shell` without workdir; `exec bash -c cd` with workdir |
| `mp_mount` | `mp_lifecycle.bats` | source instance:target format; returns 1 on failure (not die) |
| `mp_umount` | `mp_lifecycle.bats` | instance:target format; swallows failure silently |
| `mp_transfer` | `mp_lifecycle.bats` | Correct args, multiple sources, <2 args dies, failure dies |
| `mp_wait_cloud_init` | `mp_lifecycle.bats` | cloud-init status --wait; warns but doesn't die on failure |
| `mp_docker_status` | `mp_lifecycle.bats` | Version string when available; "not running" when unavailable |

### Covered: `lib/common.sh` Network Functions

Integration tests using a local Python3 HTTP server (`tests/stubs/http_server.py`) serving
fixture files on localhost. Tests both aria2c and curl download paths, HTTP conditional GET
(`If-Modified-Since`/304), manifest fetching, staleness detection, and CLI update checks.

| Function | Test File | Notes |
|----------|-----------|-------|
| `_mps_remote_is_fresh` | `network.bats` | 304 fresh, 200 stale, missing ref, unreachable |
| `_mps_remote_fetch` | `network.bats` | First fetch, 304 cache, 200 update, failure ± cache, mkdir |
| `_mps_download_file` | `network.bats` | aria2c (3), curl fallback (3), `-d`/`-o` flag (1) |
| `_mps_fetch_manifest` | `network.bats` | Fetch, empty URL, cache, cached fallback |
| `_mps_check_image_staleness` | `network.bats` | up-to-date, stale, update, 304 fast, non-SemVer, no meta, manifest fallback |
| `_mps_warn_image_staleness` | `network.bats` | Rebuild, update, silent (fresh/opt-out/non-SemVer) |
| `_mps_check_instance_staleness` | `network.bats` | up-to-date, stale, update, stale:manifest, update:manifest, stock, no metadata |
| `_mps_warn_instance_staleness` | `network.bats` | Stale, update, --skip-manifest, opt-out |
| `_mps_check_cli_update` | `network.bats` | Newer version, 24h TTL, opt-out, non-SemVer, empty URL |
| `_mps_cli_update_warn` | `network.bats` | Update available, force-push (temp git repo), missing cache, non-git |

### Covered: Bash Completion (`_complete_*()` + `__complete` dispatcher)

All 13 command files export a `_complete_<cmd>()` metadata function for tab-completion.
These are pure functions (no I/O, no external deps) — unit-tested by sourcing and calling.

| Scope | Test File | Notes |
|-------|-----------|-------|
| Smoke: each `_complete_*` responds to `flags` (non-empty, includes `--help`) | `completion.bats` | 13 commands — one test per command |
| Subcommand routing: `image`, `mount`, `port` return correct `subcmds` list | `completion.bats` | 3 tests |
| Per-subcommand flags: subcommand-aware commands route flags by subcommand | `completion.bats` | e.g., `_complete_image flags pull` includes `--force` |
| `flag-values` magic tokens: `--profile` → `__profiles__`, `--image` → `__images__`, etc. | `completion.bats` | 8 tests — verify routing, not exhaustive per-flag |
| `__complete` dispatcher: commands/profiles/images/cloud_init token collection | `completion.bats` | Temp dirs for HOME-based paths, real repo for project paths |
| `__complete` dispatcher: command-level routing + edge cases | `completion.bats` | Subprocess invocation, hyphen normalization, unknown cmd |
| `__complete instances` | `completion_instances.bats` | Integration: subprocess, multipass stub, prefix filtering, missing tools, custom prefix |

### Covered: `__complete instances` (Integration)

Subprocess tests invoking `bin/mps __complete instances`. The `__complete` early-exit path never
sources `lib/common.sh`, so setup is minimal — multipass stub + fixtures only.

| Scope | Test File | Notes |
|-------|-----------|-------|
| Returns short names for mps-prefixed instances | `completion_instances.bats` | Strips `mps-` prefix from fixture names |
| Excludes non-mps-prefixed instances | `completion_instances.bats` | `fixture-foreign` not in output |
| One name per line, correct count | `completion_instances.bats` | 2 lines for 2 mps-prefixed instances |
| Empty instance list → empty output | `completion_instances.bats` | `{"list":[]}` fixture, exit 0 |
| Missing multipass → graceful empty | `completion_instances.bats` | Restricted PATH, exit 0 |
| Missing jq → graceful empty | `completion_instances.bats` | Restricted PATH, exit 0 |
| Custom `MPS_INSTANCE_PREFIX` | `completion_instances.bats` | `fixture` prefix → returns `foreign` |
| Call log contains `list --format json` | `completion_instances.bats` | Verifies stub invocation |

### Covered: `_mps_completions()` Driver (Integration)

In-process tests sourcing `completions/mps.bash`, stubbing `mps` as a bash function, simulating
tab completions via `COMP_WORDS`/`COMP_CWORD`, and asserting on `COMPREPLY` contents.

| Scope | Test File | Notes |
|-------|-----------|-------|
| Top-level completion (commands + global flags) | `completion_driver.bats` | Empty word, prefix filter, `--` filter |
| Global flag skipping (`--debug`, `--help`) | `completion_driver.bats` | Flag consumed, next word completes commands/flags |
| Command-level flag completion | `completion_driver.bats` | create, list, down — `--` prefix, all flags |
| Flag-value resolution (`--name`, `--profile`, `--image`, `--cloud-init`) | `completion_driver.bats` | Magic tokens, short aliases (`-n`), prefix filtering |
| Subcommand routing (image, mount, port) | `completion_driver.bats` | Subcmd list, prefix filter, `--` filter |
| Subcommand flag completion | `completion_driver.bats` | `image pull --force`, `port forward --privileged` |
| Subcommand flag-value resolution | `completion_driver.bats` | `image import --arch`, `mount add --name` |
| `--` separator stops completion | `completion_driver.bats` | exec with and without `--name` |
| File completion (`__files__` token) | `completion_driver.bats` | `ssh-config --ssh-key` triggers `compgen -f` |
| Edge cases | `completion_driver.bats` | Unknown cmd, extra positional, flag-like non-subcmd, multi flag-value |
| `_init_completion` integration | `completion_driver.bats` | Uses readline helper when available |
| `complete -p` registration | `completion_driver.bats` | Verifies `_mps_completions` bound to `mps` |

### Covered: `bin/mps` Entry Point (`main()` dispatch)

Subprocess tests invoking `bin/mps` directly. Full path: `lib/common.sh` sourced, `mps_load_config`
called. `MPS_CHECK_UPDATES=false` prevents network access; multipass stub on PATH for `mps_check_deps`.

| Scope | Test File | Notes |
|-------|-----------|-------|
| `--help` / `-h` shows usage | `entry_point.bats` | Exit 0, contains `Usage:` and `Commands:` |
| `--version` / `-v` shows version | `entry_point.bats` | Exit 0, matches VERSION file content |
| No args → exit 1 with usage | `entry_point.bats` | Global dispatch, not command-level |
| `--debug` enables debug logging | `entry_point.bats` | Stderr contains `[mps DEBUG]` |
| Path traversal rejected (`../etc`) | `entry_point.bats` | Regex validation `^[a-z][-a-z]*$` |
| Uppercase rejected (`Create`) | `entry_point.bats` | Same regex |
| Dot-prefix rejected (`.hidden`) | `entry_point.bats` | Same regex |
| Unknown valid-format command | `entry_point.bats` | `nonexistent-cmd` → exit 1, usage |
| Command-specific `--help` dispatches | `entry_point.bats` | `list --help` → `--json` in output |

### Covered: `commands/*.sh` Argument Parsing

| Scope | Test File | Notes |
|-------|-----------|-------|
| `--help` / `-h` returns 0 with usage text | `cmd_parsing.bats` | All 14 commands (including subcommands) |
| Unknown flags rejected | `cmd_parsing.bats` | 9 commands (subcommand commands tested via routing) |
| Unexpected positional args rejected | `cmd_parsing.bats` | 6 commands that reject positionals |
| Missing flag values die | `cmd_parsing.bats` | 19 flag+command combos (all `${2:?}` patterns) |
| Short flag aliases (`-n`, `-f`, `-w`, `--mem`) | `cmd_parsing.bats` | 5 alias tests |
| `exec`: `--` separator, no-command validation | `cmd_parsing.bats` | 4 tests |
| `transfer`: direction validation (guest-to-guest, mixed, multi-guest) | `cmd_parsing.bats` | 6 tests |
| `image`: subcommand routing, import/pull/remove validation | `cmd_parsing.bats` | 16 tests |
| `mount`: subcommand routing, add/remove/list validation | `cmd_parsing.bats` | 9 tests |
| `port`: subcommand routing, numeric port validation, `--privileged` | `cmd_parsing.bats` | 11 tests |
| `list --json`: returns raw JSON | `cmd_parsing.bats` | 1 test |
| `create --profile`: valid/invalid profile, `--no-mount` | `cmd_parsing.bats` | 4 tests |

Multipass-dependent functions are stubbed at file scope (`mp_*`, `mps_require_*`, etc.)
so tests exercise only parsing and validation logic.

### Covered: `commands/*.sh` Orchestration Logic (Batch 1)

Integration tests that let most functions flow through to real code backed by the multipass
stub + fixture data. Only network, SSH, and interactive functions are stubbed. Tests verify
the full wiring: argument resolution → state checks → `mp_*` calls → metadata I/O → output.

| Command | Test File | Tests | Notes |
|---------|-----------|-------|-------|
| `cmd_list` | `cmd_query.bats` | 7 | Formatted table, state text, IP, `--json`, empty list, call log, image column |
| `cmd_status` | `cmd_query.bats` | 8 | Detailed info, `--json`, image hash, staleness, mount origins, docker, stopped skip, nonexistent |
| `cmd_down` | `cmd_lifecycle.bats` | 7 | Stop, `--force`, already-stopped, nonexistent, port reset, adhoc mount cleanup, success message |
| `cmd_destroy` | `cmd_lifecycle.bats` | 7 | Purge, metadata removal, ports file, SSH config, nonexistent, `--force`, success message |
| `cmd_create` | `cmd_lifecycle.bats` | 10 | Launch+cloud-init+meta, call log args, metadata JSON, explicit name, `--no-mount`, `--profile`, already-exists, summary, auto-mount, sidecar extraction |
| `cmd_up` | `cmd_lifecycle.bats` | 8 | Nonexistent→create, stopped→start, running→noop, suspended→start, mount restore, IP output, instance name, unexpected state |
| `cmd_shell` | `cmd_exec.bats` | 5 | Call log, `--workdir`, metadata workdir, nonexistent, not running |
| `cmd_exec` | `cmd_exec.bats` | 5 | `--` separator, `--workdir`, metadata workdir, exit code forwarding, not running |
| `cmd_transfer` | `cmd_exec.bats` | 5 | Host→guest, guest→host, not-running error, direction message, prepare check |
| `cmd_mount` | `cmd_exec.bats` | 6 | List with origins, no mounts, add, already-mounted, remove, nonexistent mount |

**Stub strategy**: Unlike `cmd_parsing.bats` (which stubs ALL `mp_*`/`mps_*` to isolate parsing),
orchestration tests let most functions flow through backed by the multipass stub. Only network,
SSH, and interactive functions are stubbed: `mps_resolve_image`, `mps_auto_forward_ports`,
`mps_forward_port`, `mps_reset_port_forwards`, `mps_kill_port_forwards`,
`mps_cleanup_port_sockets`, `mps_confirm`, `mps_check_image_requirements`,
`_mps_fetch_manifest`, `_mps_warn_image_staleness`, `_mps_warn_instance_staleness`,
`_mps_check_instance_staleness`.

### Covered: `commands/*.sh` Orchestration Logic (Batch 2)

Commands requiring additional setup: SSH tooling (`openssh-client` in linter image), keypair
fixtures (real `ssh-keygen`), cache filesystem, and multipass stub extension (`mktemp` pattern).

| Command | Test File | Tests | Notes |
|---------|-----------|-------|-------|
| `cmd_port forward` | `cmd_port.bats` | 8 | Happy path, already-forwarded (rc=2), not running, nonexistent, missing spec, `--privileged`, success message, missing args |
| `cmd_port list` | `cmd_port.bats` | 7 | Header columns, entries from `.ports.json`, filter by name, no forwards, dead socket, multiple sandboxes, re-establish dead |
| `_ssh_config_resolve_pubkey` | `cmd_ssh_config.bats` | 5 | Auto-detect ed25519, prefer ed25519 over rsa, explicit path (private→.pub), missing key, explicit .pub |
| `_ssh_config_inject_key` | `cmd_ssh_config.bats` | 3 | Call log (mktemp+transfer+bash -c), metadata update, skip if already injected |
| `cmd_ssh_config` | `cmd_ssh_config.bats` | 5 | Config block content, `--append` file, `--print --append`, file permissions (600), not running |
| `cmd_image list` | `cmd_image.bats` | 5 | Columns, empty cache, STATUS with manifest, no STATUS without manifest, pulled vs imported |
| `cmd_image import` | `cmd_image.bats` | 9 | Cache path, auto-detect name, auto-detect arch, `.meta.json` SHA256, `.sha256` sidecar verify, checksum mismatch, `--name/--tag/--arch` overrides, file not found, summary output |
| `cmd_image pull` | `cmd_image.bats` | 3 | Calls `_mps_pull_image`, up-to-date skip, `--force` bypass |
| `cmd_image remove` | `cmd_image.bats` | 8 | Specific version, `--arch` only, `--all`, empty parent cleanup, `--force`, not found, all versions, preview |

**Stub strategy**: Same base stubs as batch 1. Additional setup: `openssh-client` installed in
linter Docker image provides real `ssh-keygen` for keypair generation and real `ssh -O check` for
socket probing. `_mps_fetch_manifest` returns fixture manifest JSON (not fail). `_mps_pull_image`
and `_mps_check_image_staleness` stubbed. Multipass stub extended with `mktemp` pattern for
ssh-config key injection flow.

### Covered: Port Forwarding Pipeline (Unit A)

Integration tests exercising the full port forwarding orchestration with SSH/sudo stubs on PATH.
No real SSH server — the `ssh` stub simulates control socket behavior via marker files (`-M -S`
create, `-O check -S` alive check, `-O exit -S` teardown). The `sudo` stub strips `sudo`/`-n`
and executes remaining args.

| Function | Test File | Tests | Notes |
|----------|-----------|-------|-------|
| `mps_forward_port` (validation) | `port_forwarding.bats` | 8 | Empty spec, non-numeric, port 0, >65535, privileged reject, no IP, no SSH config, missing key |
| `mps_forward_port` (happy path) | `port_forwarding.bats` | 6 | Tunnel establish, `.ports.json` record, dedup (rc=2), stale socket, sudo/privileged, SSH options |
| `mps_forward_port` (failure) | `port_forwarding.bats` | 3 | SSH fail, post-verify fail, append to existing |
| `mps_auto_forward_ports` | `port_forwarding.bats` | 6 | No ports, multi-port, count logging, dedup skip, error continue, custom verb |
| `mps_kill_port_forwards` | `port_forwarding.bats` | 5 | No file, exit commands, socket cleanup, sudo entries, null socket |
| `mps_reset_port_forwards` | `port_forwarding.bats` | 5 | Full cleanup, no re-establish, `--auto-forward`, missing file, kill+create cycle |

**Stub scripts**: `tests/stubs/ssh` (SSH control socket mock), `tests/stubs/sudo` (privilege strip).
**Helper**: `setup_ssh_stub()` in `tests/test_helper.bash`.

Env vars controlling SSH stub: `MOCK_SSH_CALL_LOG`, `MOCK_SSH_TUNNEL_EXIT`,
`MOCK_SSH_TUNNEL_NO_SOCKET`, `MOCK_SSH_STALE_SOCKETS`.

### Covered: `install.sh` (Installer)

Integration tests with two modes: sourced function tests (guard prevents execution, call
functions directly with overridden globals) and subprocess tests (run `bash install.sh` with
`HOME`/`PATH` isolation). Stubs for `snap`, `brew`, `apt-get`, `uname`, `mps`, `multipass`, `sudo`.

| Scope | Test File | Tests | Notes |
|-------|-----------|-------|-------|
| `detect_os` | `install.bats` | 3 | Linux, Darwin, unknown via uname stub |
| `confirm` | `install.bats` | 4 | y, Yes, n, empty |
| `install_dependency` | `install.bats` | 8 | Found, missing+snap, missing+brew, missing+apt, decline, unknown platform |
| Directory structure | `install.bats` | 2 | `~/mps/*`, `~/.ssh/config.d`, `INSTALL_DIR` |
| Symlink | `install.bats` | 4 | Create, replace, non-symlink error, `MPS_INSTALL_DIR` override |
| Bash completion | `install.bats` | 4 | Linux, macOS+brew, fallback, zsh hint |
| PATH check | `install.bats` | 4 | Already on PATH, accept→bashrc, zsh→.zshrc, decline |
| Missing deps + verify | `install.bats` | 2 | Warns but continues, "Installation complete" |

### Covered: `uninstall.sh` (Uninstaller)

All subprocess tests running `bash uninstall.sh` with fully installed state under fake HOME.
Multipass stub for VM discovery, `du` stub, `brew` stub, stdin piping for interactive prompts.

| Scope | Test File | Tests | Notes |
|-------|-----------|-------|-------|
| Symlink removal | `uninstall.bats` | 4 | Correct target, wrong target, non-symlink, missing |
| Bash completion | `uninstall.bats` | 3 | Linux, brew, no files |
| VM cleanup | `uninstall.bats` | 4 | Confirm delete, decline, no VMs, multipass unavailable |
| SSH config | `uninstall.bats` | 2 | Removes mps-*, preserves others |
| Instance metadata | `uninstall.bats` | 2 | Removes .json/.env/.ports.json, preserves non-matching |
| Cache | `uninstall.bats` | 2 | Confirm remove, decline preserve |
| User config | `uninstall.bats` | 3 | Confirm remove, decline preserve, missing |
| Directory cleanup | `uninstall.bats` | 2 | Empty ~/mps removed, non-empty preserved |
| Summary + misc | `uninstall.bats` | 4 | Lists removed, nothing removed, MPS_INSTALL_DIR override, source dir |

### Not Yet Covered: Full Workflows

- **Full workflows** — E2E only (real VMs, real mounts, real port forwards)

---

## Test Counts

| File | Tests | Tier | Directory |
|------|-------|------|-----------|
| `cmd_parsing.bats` | 105 | Unit | `tests/unit/` |
| `common_parsing.bats` | 21 | Unit | `tests/unit/` |
| `common_naming.bats` | 38 | Unit | `tests/unit/` |
| `common_logging.bats` | 8 | Unit | `tests/unit/` |
| `common_config.bats` | 23 | Unit | `tests/unit/` |
| `common_resources.bats` | 19 | Unit | `tests/unit/` |
| `common_paths.bats` | 30 | Unit | `tests/unit/` |
| `common_meta.bats` | 56 | Unit | `tests/unit/` |
| `common_ports.bats` | 15 | Unit | `tests/unit/` |
| `common_updates.bats` | 19 | Unit | `tests/unit/` |
| `common_utils.bats` | 23 | Unit | `tests/unit/` |
| `completion.bats` | 69 | Unit | `tests/unit/` |
| `stub_smoke.bats` | 20 | Integration | `tests/integration/` |
| `mp_lifecycle.bats` | 40 | Integration | `tests/integration/` |
| `network.bats` | 65 | Integration | `tests/integration/` |
| `cmd_query.bats` | 21 | Integration | `tests/integration/` |
| `cmd_lifecycle.bats` | 67 | Integration | `tests/integration/` |
| `cmd_exec.bats` | 27 | Integration | `tests/integration/` |
| `cmd_port.bats` | 20 | Integration | `tests/integration/` |
| `cmd_ssh_config.bats` | 19 | Integration | `tests/integration/` |
| `cmd_image.bats` | 50 | Integration | `tests/integration/` |
| `resolve_image.bats` | 15 | Integration | `tests/integration/` |
| `port_forwarding.bats` | 33 | Integration | `tests/integration/` |
| `completion_driver.bats` | 36 | Integration | `tests/integration/` |
| `completion_instances.bats` | 8 | Integration | `tests/integration/` |
| `entry_point.bats` | 11 | Integration | `tests/integration/` |
| `install.bats` | 37 | Integration | `tests/integration/` |
| `uninstall.bats` | 26 | Integration | `tests/integration/` |
| **Total** | **921** | | |

*Last updated: 2026-02-26*

### E2E Test Coverage Map

| Phase | Name | Tests | Key Assertions |
|-------|------|-------|----------------|
| 0 | Install | 5 | install.sh, mps --version, deps, dirs, completion |
| 1 | Smoke | 16 | --version, --help, all 13 cmd --help, --debug |
| 2 | Image | 3 | import/pull, image list |
| 3 | Create | 7 | create, state Running, auto-mount, config mount, content, metadata |
| 4 | Exec | 6 | echo, uname, arch, pwd, --workdir, exit code |
| 5 | Cloud-Init | 20 | status, errors, packages, files, perms, hostname, tz, plugins |
| 6 | Status | 5 | status text, --json, list |
| 7 | SSH | 4 | --print, --append, SSH connectivity, idempotent |
| 8 | Lazy Ports | 2 | trigger, port list 19000 active |
| 9 | Transfer | 2 | host->guest, guest->host |
| 10 | Mounts | 7 | config present, adhoc add, bidirectional, 3 origins, remove |
| 11 | Ports | 4 | unprivileged forward, privileged forward, port list |
| 12 | Down/Up | 14 | tunnels alive, down state, ports dead, exec error, up state, mount restore, lazy re-establish, re-forward, service restart |
| 13 | Destroy | 3 | not in list, metadata removed, SSH config removed |
| 14 | Image Remove | 1 | image not in list |
| 15 | Uninstall | 2 | mps not found, completion removed |
| **Total** | | **~90** | |
