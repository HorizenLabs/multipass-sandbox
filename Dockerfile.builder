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
        python3 \
        python3-pip \
        python3-venv \
        software-properties-common \
        unzip \
        wget \
        xz-utils \
        qemu-system-x86 \
        qemu-utils \
        qemu-system-arm \
        openssh-client \
        qemu-efi-aarch64 \
        xorriso \
    && rm -rf /var/lib/apt/lists/*

# ---------- Packer ----------
RUN set -eux; \
    PACKER_VERSION="1.11.2"; \
    ARCH="$(dpkg --print-architecture)"; \
    curl -fsSL "https://releases.hashicorp.com/packer/${PACKER_VERSION}/packer_${PACKER_VERSION}_linux_${ARCH}.zip" \
        -o /tmp/packer.zip; \
    unzip /tmp/packer.zip -d /usr/local/bin; \
    rm /tmp/packer.zip; \
    packer --version

# ---------- Python tools: b2 CLI ----------
# hadolint ignore=DL3013
RUN pip3 install --no-cache-dir --break-system-packages \
        "b2[full]" \
    && b2 version

# ---------- Entrypoint ----------
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workdir
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
