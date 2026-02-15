#cloud-config
# Packer build-time overrides (cleaned up in post-provisioning)
output: {all: '| tee -a /dev/ttyS0'}
chpasswd:
  list: |
    ubuntu:ubuntu
  expire: false
ssh_pwauth: true

# Override 60-cloudimg-settings.conf which forces PasswordAuthentication no
write_files:
  - path: /etc/ssh/sshd_config.d/50-packer-build.conf
    content: |
      PasswordAuthentication yes
    permissions: '0644'

${base_config}
