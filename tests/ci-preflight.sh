#!/usr/bin/env bash
# tests/ci-preflight.sh — Snap confinement preflight for CI runners
#
# Fail-fast check ensuring the runner has strict snap confinement.
# Run early in both images.yml and release.yml before substantive work.
#
# Checks:
#   1. AppArmor kernel module enabled
#   2. snap debug confinement == strict
#   3. sudo snap wait system seed.loaded (prevents snap install hangs)

set -euo pipefail

_preflight_pass=0
_preflight_fail=0

_log() { echo "[preflight] $*"; }

_pass() {
    _preflight_pass=$((_preflight_pass + 1))
    echo "  PASS: $1"
}

_fail() {
    _preflight_fail=$((_preflight_fail + 1))
    echo "  FAIL: $1" >&2
    if [ -n "${2:-}" ]; then
        echo "        $2" >&2
    fi
}

# --- Check 1: AppArmor kernel module ---
_log "Checking AppArmor kernel module..."
APPARMOR_ENABLED="/sys/module/apparmor/parameters/enabled"
if [ -f "$APPARMOR_ENABLED" ]; then
    aa_val="$(cat "$APPARMOR_ENABLED")"
    if [ "$aa_val" = "Y" ]; then
        _pass "AppArmor kernel module enabled"
    else
        _fail "AppArmor kernel module not enabled" "value=$aa_val (expected Y)"
    fi
else
    _fail "AppArmor sysfs not found" "$APPARMOR_ENABLED does not exist"
fi

# --- Check 2: Snap strict confinement ---
_log "Checking snap confinement mode..."
if command -v snap >/dev/null 2>&1; then
    confinement="$(snap debug confinement 2>/dev/null)" || confinement="unknown"
    if [ "$confinement" = "strict" ]; then
        _pass "Snap confinement is strict"
    else
        _fail "Snap confinement is not strict" "mode=$confinement (expected strict)"
    fi
else
    _fail "snap not found on PATH"
fi

# --- Check 3: Snap seed loaded ---
_log "Waiting for snap seed..."
if command -v snap >/dev/null 2>&1; then
    if sudo snap wait system seed.loaded 2>/dev/null; then
        _pass "Snap seed loaded"
    else
        _fail "snap wait system seed.loaded failed"
    fi
else
    _fail "snap not found on PATH (skipping seed wait)"
fi

# --- Summary ---
echo ""
echo "Preflight: ${_preflight_pass} passed, ${_preflight_fail} failed"

if [ "$_preflight_fail" -gt 0 ]; then
    echo "::error::Snap confinement preflight failed — runner lacks strict confinement"
    exit 1
fi
