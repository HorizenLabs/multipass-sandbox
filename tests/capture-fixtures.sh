#!/usr/bin/env bash
# tests/capture-fixtures.sh — Capture real multipass JSON into test fixtures
#
# Requires: multipass, jq on host.  NOT intended to run in Docker.
#
# Creates three VMs with minimal resources, drives them through lifecycle
# states, and captures multipass list/info JSON at each stage.  Synthetic
# fixtures are derived by patching the state field in captured JSON.
#
# Output: tests/fixtures/multipass/
#   running-mounted/   — primary Running+mounts, secondary Stopped, foreign Running
#   suspended/         — primary Suspended, secondary Stopped, foreign Running
#   all-stopped/       — primary Stopped, secondary Stopped, foreign Running
#   synthetic/         — derived: Starting, Deleted, Unknown states
#   version.json       — multipass version output
#   error-nonexistent.stderr — stderr from info on non-existent instance

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="${SCRIPT_DIR}/fixtures/multipass"

# VM names
PRIMARY="mps-fixture-primary"
SECONDARY="mps-fixture-secondary"
FOREIGN="fixture-foreign"
ALL_VMS=("$PRIMARY" "$SECONDARY" "$FOREIGN")

# Minimal resources
CPUS=1
MEMORY="512M"
DISK="5G"

# Mount directories (must be under HOME for snap confinement)
MOUNT_A="${HOME}/mps-fixture-mount-a"
MOUNT_B="${HOME}/mps-fixture-mount-b"

# ---------- Helpers ----------

log() { echo "[capture] $*"; }

die() { echo "[capture] ERROR: $*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed"
}

cleanup() {
    log "Cleaning up..."
    for vm in ${ALL_VMS[@]+"${ALL_VMS[@]}"}; do
        multipass delete "$vm" --purge 2>/dev/null || true
    done
    rm -rf "${MOUNT_A}" "${MOUNT_B}"
    log "Cleanup complete."
}

# Capture a scenario: list + info for each VM
capture_scenario() {
    local scenario="$1"
    local dir="${FIXTURES_DIR}/${scenario}"
    mkdir -p "$dir"
    log "Capturing scenario: ${scenario}"

    multipass list --format json | jq . > "${dir}/list.json"
    for vm in ${ALL_VMS[@]+"${ALL_VMS[@]}"}; do
        local state
        state="$(multipass info "$vm" --format json | jq -r ".info[\"${vm}\"].state")"
        log "  ${vm}: ${state}"
        multipass info "$vm" --format json | jq . > "${dir}/info-${vm}.json"
    done
}

# ---------- Preflight ----------

require_cmd multipass
require_cmd jq

# Detect and clean up leftover VMs from failed runs
for vm in ${ALL_VMS[@]+"${ALL_VMS[@]}"}; do
    if multipass info "$vm" --format json &>/dev/null; then
        log "Found leftover VM '${vm}', cleaning up..."
        multipass delete "$vm" --purge 2>/dev/null || true
    fi
done

# Register cleanup trap
trap cleanup EXIT

# ---------- Create fixtures directory ----------

rm -rf "${FIXTURES_DIR:?}"
mkdir -p "$FIXTURES_DIR"

# ---------- Launch VMs ----------

log "Launching VMs (this takes a few minutes)..."

multipass launch --name "$PRIMARY" --cpus "$CPUS" --memory "$MEMORY" --disk "$DISK"
multipass launch --name "$SECONDARY" --cpus "$CPUS" --memory "$MEMORY" --disk "$DISK"
multipass launch --name "$FOREIGN" --cpus "$CPUS" --memory "$MEMORY" --disk "$DISK"

log "All VMs launched."

# ---------- Stop secondary ----------

log "Stopping secondary..."
multipass stop "$SECONDARY"

# ---------- Mount directories on primary ----------

log "Creating mount directories..."
mkdir -p "$MOUNT_A" "$MOUNT_B"

log "Mounting on primary..."
multipass mount "$MOUNT_A" "${PRIMARY}:/mnt/test-a"
multipass mount "$MOUNT_B" "${PRIMARY}:/mnt/test-b"

# ---------- Scenario 1: running-mounted ----------

capture_scenario "running-mounted"

# ---------- Suspend primary ----------

log "Suspending primary..."
multipass suspend "$PRIMARY"

# ---------- Scenario 2: suspended ----------

capture_scenario "suspended"

# ---------- Stop primary ----------

log "Stopping primary (from Suspended)..."
multipass stop --force "$PRIMARY"

# ---------- Scenario 3: all-stopped ----------

capture_scenario "all-stopped"

# ---------- Version fixture ----------

log "Capturing version..."
multipass version --format json | jq . > "${FIXTURES_DIR}/version.json"

# ---------- Error fixture ----------

log "Capturing error for non-existent instance..."
multipass info "nonexistent-instance-xyz" --format json 2> "${FIXTURES_DIR}/error-nonexistent.stderr" || true

# ---------- Synthetic fixtures ----------

log "Generating synthetic fixtures..."
mkdir -p "${FIXTURES_DIR}/synthetic"

# Copy list.json from running-mounted as the base for synthetic
cp "${FIXTURES_DIR}/running-mounted/list.json" "${FIXTURES_DIR}/synthetic/list.json"

# Derive synthetic info files by patching the state field on primary
for state_pair in "Starting:info-starting.json" "Deleted:info-deleted.json" "Unknown:info-unknown.json"; do
    state="${state_pair%%:*}"
    filename="${state_pair#*:}"
    jq ".info[\"${PRIMARY}\"].state = \"${state}\"" \
        "${FIXTURES_DIR}/running-mounted/info-${PRIMARY}.json" \
        > "${FIXTURES_DIR}/synthetic/${filename}"
    log "  Generated synthetic/${filename} (state=${state})"
done

# Copy other info files into synthetic for completeness
cp "${FIXTURES_DIR}/running-mounted/info-${SECONDARY}.json" "${FIXTURES_DIR}/synthetic/"
cp "${FIXTURES_DIR}/running-mounted/info-${FOREIGN}.json" "${FIXTURES_DIR}/synthetic/"

# ---------- Summary ----------

log ""
log "Fixtures captured successfully:"
find "$FIXTURES_DIR" -type f | sort | while IFS= read -r f; do
    log "  ${f#"${SCRIPT_DIR}/"}"
done
log ""
log "Commit these fixtures to the repo."
