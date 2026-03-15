# =============================================================================
# Dockerfile — phille06/mythic-framework-docker
# =============================================================================
#
# Build chain (all from source — Phille06 forks of ich777's images):
#
#   Stage 1 — baseimage
#     Replicates: https://github.com/Phille06/docker-debian-baseimage
#     (Fork of ich777/docker-debian-baseimage — credit: ich777, admin@minenet.at)
#
#   Stage 2 — fivemserver
#     Replicates: https://github.com/Phille06/mythic-framework-docker
#     (Fork of ich777/docker-fivem-server — credit: ich777, admin@minenet.at)
#     Adds xz-utils, screen, gotty web console
#     /opt/scripts/start.sh — auto-downloads FXServer from runtime.fivem.net
#
#   Stage 3 — mythic (published image)
#     Adds git, curl, jq, Node.js 22 LTS
#     mythic-entrypoint.sh — first-run Mythic recipe deployment +
#     txAdmin pre-config, then execs ich777 start.sh
#
# Published to Docker Hub as: phille06/mythic-framework-docker
# =============================================================================

# ── Stage 1: Baseimage ────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS baseimage

# bookworm (Debian 12) — replaces buster-slim which reached EOL June 2024
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        wget \
        locales && \
    sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
    locale-gen && \
    rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# ── Stage 2: FiveM server layer ───────────────────────────────────────────────
# Replicates https://github.com/Phille06/mythic-framework-docker
# Original by ich777 (admin@minenet.at) — https://github.com/ich777/docker-fivem-server
FROM baseimage AS fivemserver

# Install dependencies and gotty web console.
# gotty v1.0.1 is amd64-only — skip silently on arm64.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        xz-utils \
        unzip \
        screen && \
    ARCH="$(dpkg --print-architecture)" && \
    if [ "${ARCH}" = "amd64" ]; then \
        wget -q -O /tmp/gotty.tar.gz \
            https://github.com/yudai/gotty/releases/download/v1.0.1/gotty_linux_amd64.tar.gz && \
        tar -C /usr/bin/ -xf /tmp/gotty.tar.gz && \
        rm -f /tmp/gotty.tar.gz; \
    else \
        echo "gotty not available for ${ARCH} — skipping"; \
    fi && \
    rm -rf /var/lib/apt/lists/*

# Copy FXServer start scripts from repo
COPY scripts/ /opt/scripts/
RUN chmod -R 770 /opt/scripts/

# Match ich777 env vars exactly
ENV DATA_DIR="/serverdata"
ENV SERVER_DIR="${DATA_DIR}/serverfiles"
ENV GAME_CONFIG=""
ENV SRV_ADR="https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master/"
ENV MANUAL_UPDATES=""
ENV ENABLE_WEBCONSOLE="true"
ENV GOTTY_PARAMS="-w --title-format FiveM"
ENV UMASK=000
ENV UID=99
ENV GID=100
ENV SERVER_KEY="template"
ENV START_VARS=""
ENV DATA_PERM=770
ENV USER="fivem"

RUN mkdir -p "${DATA_DIR}" "${SERVER_DIR}" && \
    useradd -d "${SERVER_DIR}" -s /bin/bash "${USER}" && \
    chown -R "${USER}" "${DATA_DIR}" && \
    ulimit -n 2048

# ── Stage 3: Mythic layer (final published image) ─────────────────────────────
FROM fivemserver

LABEL org.opencontainers.image.title="mythic-framework-docker"
LABEL org.opencontainers.image.description="FXServer + txAdmin + Mythic Framework — fully automated headless deployment"
LABEL org.opencontainers.image.url="https://hub.docker.com/r/phille06/mythic-framework-docker"
LABEL org.opencontainers.image.source="https://github.com/Phille06/mythic-framework-docker"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.authors="Phille06"
LABEL org.opencontainers.image.vendor="Phille06"
LABEL credits="FiveM Docker image originally by ich777 (admin@minenet.at) — https://github.com/ich777/docker-fivem-server. Forked and extended by Phille06."

USER root

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        curl \
        jq \
        ca-certificates \
        gnupg && \
    mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

COPY mythic-entrypoint.sh /opt/scripts/mythic-entrypoint.sh
RUN chmod 770 /opt/scripts/mythic-entrypoint.sh

VOLUME ["${SERVER_DIR}", "/serverdata/txData"]

# Game traffic
EXPOSE 30120/tcp 30120/udp
# txAdmin web panel
EXPOSE 40120/tcp
# gotty web console
EXPOSE 8080/tcp

ENTRYPOINT ["/opt/scripts/mythic-entrypoint.sh"]