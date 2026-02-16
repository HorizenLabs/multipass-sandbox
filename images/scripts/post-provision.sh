#!/usr/bin/env bash
set -euo pipefail

# Post-provisioning script for MPS images (all flavors)
# Runs after cloud-init has completed during Packer build.
# Cleans up and prepares the image for distribution.

echo "=== MPS Image: Post-provisioning ==="

# Wait for cloud-init to finish (should already be done, but be safe)
cloud-init status --wait || true

# Ensure ubuntu owns its entire home directory
# (must run after all layers — Go, Rust, Solana etc. create files as ubuntu)
chown -R ubuntu:ubuntu /home/ubuntu

# Remove build-time password (Multipass injects its own SSH keys)
passwd -l ubuntu
# Remove build-time sshd override and disable SSH password authentication
rm -f /etc/ssh/sshd_config.d/50-packer-build.conf
sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config

# Remove old (non-HWE) kernel if present.  In chained builds (protocol-dev
# etc.) the base image already has only the HWE kernel, so this is a no-op.
if dpkg -l linux-image-virtual 2>/dev/null | grep -q '^ii'; then
  # Derive version from the metapackage, e.g. "6.8.0.50.52" → "6.8.0"
  OLD_KVER="$(dpkg-query -W -f='${Version}' linux-image-virtual | cut -d. -f1-3)"
  # Allow removing the running kernel — this is a Packer build; the VM will
  # be shut down and captured as an image.  The kernel prerm calls
  # linux-check-removal which normally aborts on running-kernel removal.
  # DEBIAN_FRONTEND=noninteractive makes it quietly succeed (per manpage).
  # As belt-and-suspenders, also swap in a no-op script in case the
  # noninteractive path isn't honoured (see https://askubuntu.com/a/1313030).
  export DEBIAN_FRONTEND=noninteractive
  if [ -f /usr/bin/linux-check-removal ]; then
    mv /usr/bin/linux-check-removal /usr/bin/linux-check-removal.orig
    printf '#!/bin/sh\nexit 0\n' > /usr/bin/linux-check-removal
    chmod +x /usr/bin/linux-check-removal
  fi
  apt-get purge -y linux-virtual linux-headers-virtual linux-image-virtual
  # Purge every versioned package whose NAME contains the old version.
  # Shared packages (linux-libc-dev, linux-tools-common) only carry the
  # version in dpkg's VERSION column, not their name, so they're safe.
  # shellcheck disable=SC2046
  dpkg -l 'linux-*' 2>/dev/null \
    | awk -v ver="$OLD_KVER" '/^ii/ && $2 ~ ver {print $2}' \
    | xargs -r apt-get purge -y
  # Restore original script (linux-base may already be purged at this point)
  if [ -f /usr/bin/linux-check-removal.orig ]; then
    mv /usr/bin/linux-check-removal.orig /usr/bin/linux-check-removal
  fi
fi
apt-get autoremove --purge -y

# Clean up apt cache
apt-get clean
rm -rf /var/lib/apt/lists/*

# Clean up Rust/Cargo build caches (binaries in ~/.cargo/bin are preserved)
# No-op if Rust isn't installed (rm -rf on non-existent dirs is fine)
rm -rf /home/ubuntu/.cargo/registry \
       /home/ubuntu/.cargo/git \
       /home/ubuntu/.cargo/.package-cache

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
