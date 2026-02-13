#!/usr/bin/env bash
set -euo pipefail

# Post-provisioning script for base image
# Runs after cloud-init has completed during Packer build.
# Cleans up and prepares the image for distribution.

echo "=== MPS Base Image: Post-provisioning ==="

# Wait for cloud-init to finish (should already be done, but be safe)
cloud-init status --wait || true

# Remove build-time password (Multipass injects its own SSH keys)
passwd -l ubuntu
# Remove build-time sshd override and disable SSH password authentication
rm -f /etc/ssh/sshd_config.d/50-packer-build.conf
sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config

# Remove old kernel (replaced by HWE edge kernel)
apt-get remove -y linux-virtual linux-headers-virtual linux-image-virtual 2>/dev/null || true
apt-get autoremove --purge -y

# Clean up apt cache
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
