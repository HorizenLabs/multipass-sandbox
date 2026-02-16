# Multi Pass Sandbox (mps) — Builder Image
# Contains tools needed for building VM images (Packer, QEMU, yq).
# Publishing uses the separate mps-publisher image for credential isolation.
# For lint/test tools, see Dockerfile.linter.
#
# Build:  docker build -f Dockerfile.builder -t mps-builder .
# Usage:  docker run --rm -v "$PWD:/workdir" -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) mps-builder <command>

FROM ubuntu:25.10

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
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com plucky main" \
        > /etc/apt/sources.list.d/hashicorp.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends packer \
    && rm -rf /var/lib/apt/lists/* \
    && packer --version

# ---------- yq (YAML merge tool, SHA256-verified) ----------
RUN set -eux; \
    ARCH="$(dpkg --print-architecture)"; \
    YQ_VERSION="v4.45.1"; \
    YQ_FILE="yq_linux_${ARCH}"; \
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_FILE}" \
        -o /tmp/"${YQ_FILE}"; \
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/checksums" \
        -o /tmp/yq_checksums; \
    EXPECTED=$(awk "/^${YQ_FILE} /{print \$19}" /tmp/yq_checksums); \
    echo "${EXPECTED}  /tmp/${YQ_FILE}" | sha256sum -c -; \
    install -m 755 /tmp/"${YQ_FILE}" /usr/local/bin/yq; \
    rm /tmp/"${YQ_FILE}" /tmp/yq_checksums; \
    yq --version

# ---------- Entrypoint ----------
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workdir
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
