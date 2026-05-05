# syntax=docker/dockerfile:1.7

# ratatoskr-backup — MariaDB hot backups via mariadb-backup, encrypted at
# rest with restic. Built on the same MariaDB image as the server so the
# backup tool is exact-version matched (upstream MariaDB requires this).
#
# Build context MUST be the repo root so `COPY scripts/...` resolves:
#   docker build -f docker/backup/Dockerfile -t ratatoskr-backup:dev .

ARG MARIADB_VERSION=11.8

FROM mariadb:${MARIADB_VERSION}

# Pinned restic upstream binary. SHA256 hashes from
# https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/SHA256SUMS
ARG RESTIC_VERSION=0.18.1
ARG RESTIC_SHA256_AMD64=680838f19d67151adba227e1570cdd8af12c19cf1735783ed1ba928bc41f363d
ARG RESTIC_SHA256_ARM64=87f53fddde38764095e9c058a3b31834052c37e5826d2acf34e18923c006bd45

# TARGETARCH is set automatically by buildx for multi-arch builds. Defaults
# to amd64 so plain `docker build` still works on a single-host machine.
ARG TARGETARCH=amd64

LABEL org.opencontainers.image.source="https://github.com/john6810/ratatoskr" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      org.opencontainers.image.title="ratatoskr-backup" \
      org.opencontainers.image.description="MariaDB hot backups via mariadb-backup, encrypted with restic" \
      org.opencontainers.image.version="${MARIADB_VERSION}-restic${RESTIC_VERSION}"

ENV DEBIAN_FRONTEND=noninteractive

# - bash: scripts use [[ and pipefail
# - bzip2: decompress restic upstream tarball at build time
# - ca-certificates: TLS to B2/S3/etc.
# - curl: download restic at build time
# - tini: PID 1 for clean signal handling
# - zstd: streaming compression for the mariadb-backup pipe
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        bzip2 \
        ca-certificates \
        curl \
        tini \
        zstd \
    && rm -rf /var/lib/apt/lists/*

# Install restic from the upstream GitHub release. Architecture detected
# from $TARGETARCH; SHA256 verified against the pinned hashes above.
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) sha256="${RESTIC_SHA256_AMD64}"; arch="linux_amd64" ;; \
        arm64) sha256="${RESTIC_SHA256_ARM64}"; arch="linux_arm64" ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}"; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/restic.bz2 \
        "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_${arch}.bz2"; \
    echo "${sha256}  /tmp/restic.bz2" | sha256sum -c -; \
    bunzip2 /tmp/restic.bz2; \
    install -m 0755 /tmp/restic /usr/local/bin/restic; \
    rm -f /tmp/restic; \
    /usr/local/bin/restic version

# Drop build-only deps. Keep bash, ca-certificates, tini, zstd.
RUN apt-get purge -y --auto-remove curl bzip2 \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Scripts on PATH so operators can run them directly:
#   docker compose --profile backup run --rm unit3d-backup restore latest
COPY --chmod=0755 scripts/backup.sh /usr/local/bin/backup
COPY --chmod=0755 scripts/restore.sh /usr/local/bin/restore
COPY --chmod=0755 scripts/restore-test.sh /usr/local/bin/restore-test
COPY --chmod=0755 docker/backup/entrypoint.sh /usr/local/bin/entrypoint

# Run as the existing `mysql` user (UID 999 in the base image). Sharing the
# UID with the mariadb data volume keeps file ownership consistent when the
# backup container reads /var/lib/mysql.
USER mysql

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint"]
CMD ["backup"]
