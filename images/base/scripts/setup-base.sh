#!/usr/bin/env bash
set -euo pipefail

# Post-provisioning script for base image
# Runs after cloud-init has completed during Packer build.
# Cleans up and prepares the image for distribution.

echo "=== MPS Base Image: Post-provisioning ==="

# Wait for cloud-init to finish (should already be done, but be safe)
cloud-init status --wait || true

# Clean up apt cache
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/*

# Clean up cloud-init for re-initialization on first boot
cloud-init clean --logs

# Clear machine-id (will be regenerated on first boot)
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id

# Clear tmp
rm -rf /tmp/* /var/tmp/*

# Clear bash history
: > /home/ubuntu/.bash_history
: > /root/.bash_history

# Zero free space for better compression
dd if=/dev/zero of=/EMPTY bs=1M 2>/dev/null || true
rm -f /EMPTY

echo "=== Post-provisioning complete ==="
