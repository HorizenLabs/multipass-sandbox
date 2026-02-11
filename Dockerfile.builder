# Multi Pass Sandbox (mps) — Builder Image
# Contains all tools needed for testing, linting, building, and publishing.
#
# Build:  docker build -f Dockerfile.builder -t mps-builder .
# Usage:  docker run --rm -v "$PWD:/workdir" -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) mps-builder <command>

FROM ubuntu:24.04

ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive

# ---------- System packages ----------
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
    && rm -rf /var/lib/apt/lists/*

# ---------- gosu (step down from root) ----------
RUN set -eux; \
    GOSU_VERSION="1.17"; \
    dpkgArch="$(dpkg --print-architecture)"; \
    curl -fsSL "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-${dpkgArch}" -o /usr/local/bin/gosu; \
    chmod +x /usr/local/bin/gosu; \
    gosu --version; \
    gosu nobody true

# ---------- shellcheck ----------
RUN set -eux; \
    SC_VERSION="v0.10.0"; \
    ARCH="$(uname -m)"; \
    curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/${SC_VERSION}/shellcheck-${SC_VERSION}.linux.${ARCH}.tar.xz" \
        | tar -xJf - --strip-components=1 -C /usr/local/bin "shellcheck-${SC_VERSION}/shellcheck"; \
    shellcheck --version

# ---------- hadolint ----------
RUN set -eux; \
    HL_VERSION="v2.12.0"; \
    ARCH="$(dpkg --print-architecture)"; \
    if [ "$ARCH" = "amd64" ]; then HL_ARCH="x86_64"; else HL_ARCH="arm64"; fi; \
    curl -fsSL "https://github.com/hadolint/hadolint/releases/download/${HL_VERSION}/hadolint-Linux-${HL_ARCH}" \
        -o /usr/local/bin/hadolint; \
    chmod +x /usr/local/bin/hadolint; \
    hadolint --version

# ---------- BATS (Bash Automated Testing System) ----------
RUN set -eux; \
    BATS_VERSION="1.11.0"; \
    curl -fsSL "https://github.com/bats-core/bats-core/archive/refs/tags/v${BATS_VERSION}.tar.gz" \
        | tar -xzf - -C /opt; \
    /opt/bats-core-${BATS_VERSION}/install.sh /usr/local; \
    bats --version

# ---------- Packer ----------
RUN set -eux; \
    PACKER_VERSION="1.11.2"; \
    ARCH="$(dpkg --print-architecture)"; \
    curl -fsSL "https://releases.hashicorp.com/packer/${PACKER_VERSION}/packer_${PACKER_VERSION}_linux_${ARCH}.zip" \
        -o /tmp/packer.zip; \
    unzip /tmp/packer.zip -d /usr/local/bin; \
    rm /tmp/packer.zip; \
    packer --version

# ---------- checkmake (Makefile linter) ----------
RUN set -eux; \
    CHECKMAKE_VERSION="0.2.2"; \
    ARCH="$(dpkg --print-architecture)"; \
    curl -fsSL "https://github.com/mrtazz/checkmake/releases/download/${CHECKMAKE_VERSION}/checkmake-${CHECKMAKE_VERSION}.linux.${ARCH}" \
        -o /usr/local/bin/checkmake; \
    chmod +x /usr/local/bin/checkmake; \
    checkmake --version || true

# ---------- Python tools: yamllint, b2 CLI, py-psscriptanalyzer ----------
RUN pip3 install --no-cache-dir --break-system-packages \
        yamllint \
        b2[full] \
        py-psscriptanalyzer \
    && yamllint --version \
    && b2 version \
    && py-psscriptanalyzer --help >/dev/null 2>&1 || true

# ---------- Entrypoint ----------
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workdir
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
