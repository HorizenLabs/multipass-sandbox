#!/usr/bin/env bash
# tests/ci-check-kvm.sh — Load KVM module if available, warn if not
#
# Attempts to modprobe kvm. KVM accelerates QEMU image builds
# significantly; without it, builds fall back to TCG emulation (slower).
#
# Usage (in CI):
#   bash tests/ci-check-kvm.sh

set -euo pipefail

if [[ ! -e /dev/kvm ]]; then
    sudo modprobe kvm 2>/dev/null || true
fi

if [[ -e /dev/kvm ]]; then
    echo "KVM available"
else
    echo "::warning::KVM not available — builds will use TCG (slower)"
fi
