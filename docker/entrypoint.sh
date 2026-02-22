#!/bin/bash
set -euo pipefail

# Entrypoint for mps builder container.
# Creates a user matching the host uid:gid, then steps down from root
# using setpriv so that build artifacts are owned by the host user.

HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"
USERNAME="builder"

# Create group if it doesn't exist
if ! getent group "$HOST_GID" &>/dev/null; then
    groupadd -g "$HOST_GID" "$USERNAME"
fi

GROUP_NAME="$(getent group "$HOST_GID" | cut -d: -f1)"

# Create user if it doesn't exist
if ! getent passwd "$HOST_UID" &>/dev/null; then
    useradd -u "$HOST_UID" -g "$HOST_GID" -m -s /bin/bash "$USERNAME"
else
    USERNAME="$(getent passwd "$HOST_UID" | cut -d: -f1)"
fi

# Build supplementary groups list (KVM access when device is available)
SUPP_GROUPS="$HOST_GID"
if [ -e /dev/kvm ]; then
    KVM_GID="$(stat -c '%g' /dev/kvm)"
    SUPP_GROUPS="${SUPP_GROUPS},${KVM_GID}"
fi

# Ensure the user owns their home directory
chown "$HOST_UID:$HOST_GID" "/home/$USERNAME" 2>/dev/null || true

# Step down from root and execute the command
# setpriv properly applies supplementary groups (gosu does not)
# Set HOME so tools (packer, b2, etc.) don't try to use /root
export HOME="/home/$USERNAME"
exec setpriv --reuid="$HOST_UID" --regid="$HOST_GID" --groups="$SUPP_GROUPS" \
    --inh-caps=-all -- "$@"
