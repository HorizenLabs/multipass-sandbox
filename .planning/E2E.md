# E2E Test Design

## Why not BATS

BATS is designed for fast, isolated, repeatable tests — each `@test` is a subshell with per-test setup/teardown and no shared state. E2E VM lifecycle tests are inherently sequential and stateful: create VM → wait for cloud-init → mount → exec → port forward → transfer → destroy. Using BATS would require fighting the framework:

- **Shared state**: No clean way to pass VM name/IP between tests (temp file hacks, `setup_file` globals)
- **Timeouts**: `mp_wait_cloud_init` takes minutes; BATS has no per-test timeout
- **Failure cleanup**: A mid-sequence failure leaves a VM running with no teardown path
- **Parallelism**: Counterproductive — one VM, sequential steps

## Architecture

Plain bash scripts orchestrated through Makefile targets — same pattern as all other CI operations except these run on the **host** (not in Docker, since Multipass needs KVM).

```
make test-e2e              ← runs tests/e2e.sh on host (not Docker)
make test-e2e-report       ← merges e2e coverage with unit/integration

GH Actions workflow (self-hosted runner with Multipass + KVM)
  └── job: e2e
        ├── step: make test-e2e 2>&1 | tee /tmp/mps-e2e.log
        ├── step: make test-e2e-report
        └── step: upload coverage artifact
```

Developer runs the same `make test-e2e` locally. Only difference from other targets: no `$(DOCKER_RUN)` wrapper.

## Test script design

`tests/e2e.sh` — sequential bash with `set -e`, assertion helpers, EXIT trap for cleanup.

```bash
#!/usr/bin/env bash
set -euo pipefail

# Unique name to avoid collisions
VM_NAME="mps-e2e-$(date +%s)-$$"
PROFILE="micro"

cleanup() { bin/mps destroy --name "$VM_NAME" --force 2>/dev/null || true; }
trap cleanup EXIT

assert_eq()   { [[ "$1" == "$2" ]] || { echo "FAIL: expected '$2', got '$1'" >&2; exit 1; }; }
assert_contains() { [[ "$1" == *"$2"* ]] || { echo "FAIL: '$1' does not contain '$2'" >&2; exit 1; }; }

# --- Test sequence ---
echo "==> Create"
bin/mps create --name "$VM_NAME" --profile "$PROFILE" --no-mount
assert_eq "$(bin/mps status --name "$VM_NAME" --json | jq -r .state)" "Running"

echo "==> Exec"
result=$(bin/mps exec --name "$VM_NAME" -- echo hello)
assert_eq "$result" "hello"

echo "==> Down / Up"
bin/mps down --name "$VM_NAME"
assert_eq "$(bin/mps status --name "$VM_NAME" --json | jq -r .state)" "Stopped"
bin/mps up --name "$VM_NAME"
assert_eq "$(bin/mps status --name "$VM_NAME" --json | jq -r .state)" "Running"

echo "==> Transfer"
echo "test-content" > /tmp/mps-e2e-file.txt
bin/mps transfer --name "$VM_NAME" /tmp/mps-e2e-file.txt :/tmp/mps-e2e-file.txt
result=$(bin/mps exec --name "$VM_NAME" -- cat /tmp/mps-e2e-file.txt)
assert_eq "$result" "test-content"

echo "==> Destroy"
bin/mps destroy --name "$VM_NAME" --force
trap - EXIT  # cleanup no longer needed

echo "All e2e tests passed."
```

## Coverage capture

The xtrace coverage mechanism (`BASH_ENV` + `BASH_XTRACEFD` + grep filter) works on any bash process, not just BATS. E2e scripts get coverage for free:

```makefile
test-e2e:
	export _MPS_COV_DIR=coverage/e2e && \
	export BASH_ENV=$(CURDIR)/tests/coverage-trap.sh && \
	bash tests/e2e.sh

test-e2e-report:
	bash tests/coverage-report.sh coverage/ coverage/unit coverage/integration coverage/e2e
```

This captures traces from `bin/mps`, all sourced libraries, and command files — exactly the code paths that unit/integration tests can't reach (real multipass calls, real SSH, real mounts).

## CI runner requirements

- **Linux x86** GitHub-hosted runner (standard runners have KVM)
- `snap install multipass`
- `jq` installed
- Network access (for image pulls if testing `mps image pull`)

## Test isolation

- Instance naming: `mps-e2e-<timestamp>-<pid>` prevents collisions
- EXIT trap ensures cleanup on failure
- Consider a stale VM reaper for CI: kill `mps-e2e-*` instances older than N minutes
- Use `--profile micro` to minimize resource usage (1 CPU, ~256M memory)

## What e2e covers that unit/integration cannot

These are the code paths currently at 0% coverage that e2e would exercise:

- **Real multipass operations**: `mp_launch`, `mp_start`, `mp_stop`, `mp_delete` with actual VMs
- **Cloud-init**: Real `mp_wait_cloud_init` completion
- **Mounts**: Real `mp_mount`/`mp_umount` with host filesystem
- **SSH**: Real SSH key injection, `ssh-config` generation, port forwarding tunnels
- **Networking**: Real IP resolution, port connectivity
- **Image pulls**: Real CDN download (optional, slow — may skip in CI unless release-triggered)

## Phasing

1. **Minimal**: create → exec → destroy (validates core lifecycle)
2. **Mounts**: create with auto-mount → exec with workdir → verify file access
3. **Port forwarding**: forward → verify connectivity → cleanup
4. **SSH config**: generate → verify SSH connectivity
5. **Transfer**: host↔guest file copy round-trip
6. **Image**: pull → create from pulled image (release-triggered only)
