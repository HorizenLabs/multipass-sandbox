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
  default = "22.04"
}

variable "output_dir" {
  type    = string
  default = "output-base"
}

variable "iso_url" {
  type = string
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

source "qemu" "base" {
  iso_url           = var.iso_url
  iso_checksum      = "none"
  disk_image        = true
  output_directory  = var.output_dir
  vm_name           = "mps-base.qcow2"
  disk_size         = "50G"
  format            = "qcow2"
  qemu_binary       = var.qemu_binary
  machine_type      = var.machine_type
  accelerator       = var.accelerator
  cpu_model         = var.cpu_type
  efi_boot          = var.efi_boot
  efi_firmware_code = var.efi_firmware_code
  efi_firmware_vars = var.efi_firmware_vars
  memory            = 4096
  cpus              = 4
  ssh_username      = "ubuntu"
  ssh_timeout       = "20m"
  shutdown_command   = "sudo shutdown -P now"
  headless          = true

  cd_content = {
    "meta-data" = ""
    "user-data" = file("${var.mps_root}/templates/cloud-init/base.yaml")
  }
  cd_label = "cidata"
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
