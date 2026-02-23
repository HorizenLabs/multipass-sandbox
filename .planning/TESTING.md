# Testing Strategy & Coverage

## Framework

- **BATS** (Bash Automated Testing System) v1.13.0
- Tests run inside Docker linter container: `make test`
- Test files: `tests/*.bats`, shared helper: `tests/test_helper.bash`

## Test Tiers

| Tier | Scope | Runs in | Interpreter | Speed |
|------|-------|---------|-------------|-------|
| **Unit** | Pure functions, no I/O | Docker (linter) | Bash 4+ AND Bash 3.2 | Fast |
| **Integration** | Commands with mocked multipass/network | Docker (linter) | Bash 4+ AND Bash 3.2 | Medium |
| **E2E** | Full VM lifecycle, real multipass + KVM | Native host (CI or local) | Host bash | Slow |

Only **Unit** tests exist today. Integration and E2E tiers are planned.

## Dual-Interpreter Testing

Client scripts (`bin/mps`, `lib/*.sh`, `commands/*.sh`) must work on Bash 3.2+ (macOS default).
The linter image includes a `bash32` binary built from source. All unit and integration tests
run under both Bash 4+ and Bash 3.2 **in parallel** (separate Docker containers, orchestrated
via Makefile). No collisions — each container has its own filesystem and environment.

Test files themselves must also be Bash 3.2-compatible (no associative arrays, no `mapfile`, etc.).

## CI Integration

| Trigger | Tiers | Budget |
|---------|-------|--------|
| PR / push to `main` | Unit + Integration (Bash 4 ∥ Bash 3.2) | <20 min wall time |
| `mps/v*` tag (release) | Unit + Integration + E2E | ~2h |
| `images/v*` tag | Image build + potentially E2E | TBD — E2E could run against x86 artifacts while arm64 builds (~75 min free window) |

Runner sizing TBD based on real-world timing data.

### E2E Platform Coverage

- **Linux x86**: Solvable — CI runners with KVM (same type as Packer builds) + `snap install multipass`
- **macOS**: Skipped — CI runners are VMs, no nested virtualization for Multipass. macOS-specific
  surface (path conversion, mount resolution) is small and covered by unit tests + Bash 3.2 compat.
  Revisit if bare-metal Mac CI (MacStadium/Orka) becomes available.

## Mocking Strategy

### Integration: `multipass` binary stub

Mock boundary is the `multipass` binary, not the `mp_*` wrapper functions. A stub script
placed on `PATH` dispatches based on arguments and returns canned JSON/exit codes. This tests
both `lib/multipass.sh` parsing and `commands/*.sh` orchestration in one shot.

Fixtures should be captured from real `multipass` output:
- `multipass list --format json` — include both mps-prefixed and non-mps VMs to test filtering
- `multipass info <name> --format json` — various states (Running, Stopped, Deleted)
- `multipass mount`, `multipass exec` — exit codes and error messages

### Integration: Network functions

For manifest fetches, staleness checks, CLI update checks (`_mps_fetch_manifest`,
`_mps_check_image_staleness`, `_mps_check_cli_update`):
- Option A: Stub `curl`/`aria2c` the same way as `multipass`
- Option B: Local HTTP server (python3 one-liner) serving fixture files — more realistic

Staleness checks are HTTP HEAD requests against small `.meta.json` sidecars, not full image
downloads. No need to download multi-GB images for integration tests.

### E2E: Real everything

No mocking. Real `multipass`, real VMs, real mounts, real port forwards.
Image download testing (if included) uses real CDN — acceptable at CI network speeds.

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
| `mps_validate_mount_source` | `common_paths.bats` | HOME check, outside HOME rejection, HOME warn |
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
| `_mps_download_file` | Integration | Calls aria2c/curl — mock or local HTTP server |
| `mps_check_deps` | Integration | Requires multipass+jq on PATH |
| `mps_require_exists` | Integration | Calls `mp_instance_exists` (mocked multipass) |
| `mps_require_running` | Integration | Calls `mp_instance_state` (mocked multipass) |
| `mps_resolve_image` | Integration | Filesystem + auto-pull + arch detection |
| `_mps_pull_image` | Integration | Network (manifest + download + checksum) |
| `_mps_remote_is_fresh` | Integration | HTTP HEAD — mock curl or local server |
| `_mps_remote_fetch` | Integration | HTTP conditional GET |
| `_mps_fetch_manifest` | Integration | Network wrapper |
| `_mps_check_image_staleness` | Integration | Manifest + meta files + possibly network |
| `_mps_warn_image_staleness` | Integration | Wrapper over staleness check |
| `_mps_check_instance_staleness` | Integration | Instance + image metadata |
| `_mps_warn_instance_staleness` | Integration | Wrapper |
| `_mps_check_cli_update` | Integration | Network (mps-release.json) + git |
| `_mps_cli_update_warn` | Integration | JSON + git merge-base |
| `_mps_resolve_project_mounts` | Integration | Metadata + config file parsing |
| `mps_prepare_running_instance` | E2E | require_running + staleness + port forwards |
| `mps_confirm` | Skip | Interactive stdin — not automatable |
| `mps_forward_port` | E2E | SSH tunnel setup |
| `mps_auto_forward_ports` | E2E | Wrapper over forward_port |
| `mps_kill_port_forwards` | E2E | SSH socket teardown |
| `mps_reset_port_forwards` | E2E | Wrapper |

### Not Yet Covered: `lib/multipass.sh`

All functions are thin wrappers around the `multipass` CLI.

| Function | Suggested Tier | Notes |
|----------|---------------|-------|
| `mp_info`, `mp_info_field`, `mp_state`, `mp_ipv4` | Integration | Mock JSON responses |
| `mp_list_all` | Integration | Mock JSON — test mps-prefix filtering |
| `mp_instance_exists`, `mp_instance_state` | Integration | Mock exit codes + JSON |
| `mp_launch` | E2E | |
| `mp_start`, `mp_stop`, `mp_delete` | E2E | |
| `mp_exec`, `mp_shell` | E2E | |
| `mp_mount`, `mp_umount`, `mp_get_mounts` | E2E | |
| `mp_transfer` | E2E | |
| `mp_wait_cloud_init` | E2E | |
| `mp_docker_status` | E2E | |

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
| `__complete instances` | Integration | Requires live multipass — deferred to integration tier |

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

### Not Yet Covered: `commands/*.sh`

Remaining command-level test tiers:
- **Orchestration logic** — integration-testable with multipass stub
- **Full workflows** — E2E only

---

## Test Counts

| File | Tests |
|------|-------|
| `cmd_parsing.bats` | 105 |
| `common_parsing.bats` | 21 |
| `common_naming.bats` | 38 |
| `common_logging.bats` | 8 |
| `common_config.bats` | 12 |
| `common_resources.bats` | 17 |
| `common_paths.bats` | 15 |
| `common_meta.bats` | 56 |
| `common_ports.bats` | 15 |
| `common_utils.bats` | 15 |
| `completion.bats` | 44 |
| **Total** | **346** |

*Last updated: 2026-02-23*
