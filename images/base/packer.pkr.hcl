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

source "qemu" "base" {
  iso_url          = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
  iso_checksum     = "none"
  disk_image       = true
  output_directory = var.output_dir
  vm_name          = "mps-base.qcow2"
  disk_size        = "50G"
  format           = "qcow2"
  accelerator      = "kvm"
  memory           = 4096
  cpus             = 4
  ssh_username     = "ubuntu"
  ssh_timeout      = "20m"
  shutdown_command  = "sudo shutdown -P now"
  headless         = true

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
