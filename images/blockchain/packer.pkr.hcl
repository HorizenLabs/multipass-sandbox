# Multi Pass Sandbox — Blockchain Image Packer Template
# Builds a QCOW2 image with Solana, Foundry, Hardhat pre-installed.

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

variable "output_dir" {
  type    = string
  default = "output-blockchain"
}

source "qemu" "blockchain" {
  iso_url          = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
  iso_checksum     = "none"
  disk_image       = true
  output_directory = var.output_dir
  vm_name          = "mps-blockchain.qcow2"
  disk_size        = "100G"
  format           = "qcow2"
  accelerator      = "kvm"
  memory           = 8192
  cpus             = 4
  ssh_username     = "ubuntu"
  ssh_timeout      = "30m"
  shutdown_command  = "sudo shutdown -P now"
  headless         = true

  cd_content = {
    "meta-data" = ""
    "user-data" = file("${var.mps_root}/templates/cloud-init/blockchain.yaml")
  }
  cd_label = "cidata"
}

build {
  sources = ["source.qemu.blockchain"]

  provisioner "shell" {
    scripts = [
      "scripts/install-rust.sh",
      "scripts/install-solana.sh",
      "scripts/install-foundry.sh",
    ]
    execute_command = "chmod +x {{ .Path }}; sudo -u ubuntu {{ .Path }}"
  }

  post-processor "checksum" {
    checksum_types = ["sha256"]
    output         = "${var.output_dir}/mps-blockchain.qcow2.sha256"
  }
}
