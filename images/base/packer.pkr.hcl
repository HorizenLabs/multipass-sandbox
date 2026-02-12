# Multi Pass Sandbox — Base Image Packer Template
# Builds a QCOW2 image with Docker and core dev tools pre-installed.

packer {
  required_plugins {
    qemu = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "mps_root" {
  type    = string
  default = "../.."
}

variable "ubuntu_version" {
  type    = string
  default = "jammy"
}

variable "output_dir" {
  type    = string
  default = "output-base"
}

variable "target_arch" {
  type    = string
  default = "amd64"
}

variable "qemu_binary" {
  type    = string
  default = "qemu-system-x86_64"
}

variable "machine_type" {
  type    = string
  default = "pc"
}

variable "accelerator" {
  type    = string
  default = "kvm"
}

variable "cpu_type" {
  type    = string
  default = "host"
}

variable "efi_boot" {
  type    = bool
  default = false
}

variable "efi_firmware_code" {
  type    = string
  default = ""
}

variable "efi_firmware_vars" {
  type    = string
  default = ""
}

locals {
  base_cloud_init = trimprefix(
    file("${var.mps_root}/templates/cloud-init/base.yaml"),
    "#cloud-config\n"
  )
}

source "qemu" "base" {
  iso_url           = "https://cloud-images.ubuntu.com/${var.ubuntu_version}/current/${var.ubuntu_version}-server-cloudimg-${var.target_arch}.img"
  iso_checksum      = "file:https://cloud-images.ubuntu.com/${var.ubuntu_version}/current/SHA256SUMS"
  disk_image        = true
  output_directory  = var.output_dir
  vm_name           = "mps-base.qcow2"
  disk_size         = "100G"
  format            = "qcow2"
  qemu_binary       = var.qemu_binary
  machine_type      = var.machine_type
  accelerator       = var.accelerator
  cpu_model         = var.cpu_type
  efi_boot          = var.efi_boot
  efi_firmware_code = var.efi_firmware_code
  efi_firmware_vars = var.efi_firmware_vars
  memory            = 8192
  cpus              = 4
  ssh_username      = "ubuntu"
  ssh_password      = "ubuntu"
  ssh_timeout       = "30m"
  shutdown_command  = "echo 'ubuntu' | sudo -S shutdown -P now"
  headless          = true

  cd_content = {
    "meta-data" = ""
    "user-data" = templatefile("${path.root}/packer-user-data.pkrtpl.hcl", {
      base_config = local.base_cloud_init
    })
  }
  cd_label = "cidata"

  qemuargs = [
    ["-serial", "mon:stdio"],
  ]
}

build {
  sources = ["source.qemu.base"]

  provisioner "shell" {
    scripts = [
      "scripts/setup-base.sh",
    ]
    execute_command = "chmod +x {{ .Path }}; sudo {{ .Path }}"
  }

  post-processor "checksum" {
    checksum_types = ["sha256"]
    output         = "${var.output_dir}/mps-base.qcow2.sha256"
  }
}
