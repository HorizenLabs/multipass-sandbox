# Multi Pass Sandbox (mps) — Builder Image
# Contains tools needed for building VM images and publishing.
# For lint/test tools, see Dockerfile.linter.
#
# Build:  docker build -f Dockerfile.builder -t mps-builder .
# Usage:  docker run --rm -v "$PWD:/workdir" -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) mps-builder <command>

FROM ubuntu:24.04

ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ---------- System packages ----------
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        gnupg \
        jq \
        make \
        software-properties-common \
        unzip \
        xz-utils \
        qemu-system-x86 \
        qemu-utils \
        qemu-system-arm \
        openssh-client \
        qemu-efi-aarch64 \
        xorriso \
    && rm -rf /var/lib/apt/lists/*

# ---------- Packer (HashiCorp apt repo, GPG-verified) ----------
# hadolint ignore=DL3008
RUN curl -fsSL https://apt.releases.hashicorp.com/gpg \
        | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" \
        > /etc/apt/sources.list.d/hashicorp.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends packer \
    && rm -rf /var/lib/apt/lists/* \
    && packer --version

# ---------- b2 CLI (standalone binary from GitHub, SHA256-verified) ----------
RUN set -eux; \
    B2_VERSION="4.5.1"; \
    ARCH="$(dpkg --print-architecture)"; \
    if [ "$ARCH" = "amd64" ]; then B2_BIN="b2v4-linux"; else B2_BIN="b2v4-linux-aarch64"; fi; \
    curl -fsSL "https://github.com/Backblaze/B2_Command_Line_Tool/releases/download/v${B2_VERSION}/${B2_BIN}" \
        -o /tmp/"${B2_BIN}"; \
    curl -fsSL "https://github.com/Backblaze/B2_Command_Line_Tool/releases/download/v${B2_VERSION}/${B2_BIN}_hashes.txt" \
        -o /tmp/"${B2_BIN}_hashes.txt"; \
    EXPECTED=$(grep '^sha256 ' /tmp/"${B2_BIN}_hashes.txt" | awk '{print $2}'); \
    echo "${EXPECTED}  /tmp/${B2_BIN}" | sha256sum -c -; \
    install -m 755 /tmp/"${B2_BIN}" /usr/local/bin/b2; \
    rm /tmp/"${B2_BIN}" /tmp/"${B2_BIN}_hashes.txt"; \
    b2 version

# ---------- Entrypoint ----------
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workdir
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
