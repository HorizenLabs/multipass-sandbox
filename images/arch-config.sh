#!/usr/bin/env bash
# images/arch-config.sh — Resolve architecture-specific Packer variables
# Source this file after optionally setting TARGET_ARCH (default: host arch)

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
    x86_64)  HOST_ARCH="amd64" ;;
    aarch64) HOST_ARCH="arm64" ;;
esac

TARGET_ARCH="${TARGET_ARCH:-$HOST_ARCH}"

case "$TARGET_ARCH" in
    amd64)
        PACKER_ARCH_VARS=(
            -var "target_arch=amd64"
            -var "qemu_binary=qemu-system-x86_64"
            -var "machine_type=pc"
            -var "efi_boot=false"
            -var "efi_firmware_code="
            -var "efi_firmware_vars="
        )
        ;;
    arm64)
        PACKER_ARCH_VARS=(
            -var "target_arch=arm64"
            -var "qemu_binary=qemu-system-aarch64"
            -var "machine_type=virt"
            -var "efi_boot=true"
            -var "efi_firmware_code=/usr/share/qemu-efi-aarch64/QEMU_EFI.fd"
            -var "efi_firmware_vars=/usr/share/qemu-efi-aarch64/QEMU_VARS.fd"
        )
        ;;
    *)
        echo "ERROR: Unsupported architecture: $TARGET_ARCH (expected: amd64 or arm64)"
        exit 1
        ;;
esac

# KVM when native, TCG when cross-compiling
if [ "$TARGET_ARCH" = "$HOST_ARCH" ] && [ -e /dev/kvm ]; then
    PACKER_ARCH_VARS+=( -var "accelerator=kvm" -var "cpu_type=host" )
    echo "Accelerator: KVM (native)"
else
    PACKER_ARCH_VARS+=( -var "accelerator=tcg" )
    case "$TARGET_ARCH" in
        amd64) PACKER_ARCH_VARS+=( -var "cpu_type=qemu64" ) ;;
        arm64) PACKER_ARCH_VARS+=( -var "cpu_type=cortex-a72" ) ;;
    esac
    echo "Accelerator: TCG (emulation — this will be slow)"
fi

echo "Host: $HOST_ARCH → Target: $TARGET_ARCH"
