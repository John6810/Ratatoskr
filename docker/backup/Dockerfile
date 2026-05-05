# syntax=docker/dockerfile:1.7

# ratatoskr-backup — MariaDB hot backups via mariadb-backup, encrypted at
# rest with restic. Built on the same MariaDB image as the server so the
# backup tool is exact-version matched (upstream MariaDB requires this).
#
# Build context MUST be the repo root so `COPY scripts/...` resolves:
#   docker build -f docker/backup/Dockerfile -t ratatoskr-backup:dev .
#
# Restic is compiled from source against a pinned upstream commit using a
# current Go toolchain, so the binary's vendored runtime is fixed against
# Go stdlib CVEs that the upstream-published binary has not yet been
# rebuilt to address. The supply-chain assurance is equivalent — pinned
# git tag + commit SHA verified at clone time, instead of a binary checksum.

# Global build args — declared before the first FROM so BuildKit substitutes
# them in every stage's `FROM` line. Re-declared (without a default) inside
# each stage that needs them via `ARG` so the value flows into RUN/LABEL too.
ARG GO_VERSION=1.26-bookworm
ARG MARIADB_VERSION=11.8

# =============================================================================
# Stage 1 — restic-builder: compile restic from upstream source.
# Runs on the BUILDPLATFORM (the runner's native arch) and cross-compiles
# to TARGETARCH/TARGETOS, which is faster than QEMU-emulating Go on arm64.
# =============================================================================

FROM --platform=$BUILDPLATFORM golang:${GO_VERSION} AS restic-builder

# restic v0.18.1 — annotated tag at upstream commit
# 7d0aa7f2e30546fba7c8f1c0bae4d6704e3d8423 as of 2026-05-05.
# The clone is verified against this commit so a moved tag (or a CDN cache
# poisoning a different commit under the same name) fails the build.
ARG RESTIC_GIT_TAG=v0.18.1
ARG RESTIC_GIT_COMMIT=7d0aa7f2e30546fba7c8f1c0bae4d6704e3d8423

ARG TARGETOS=linux
ARG TARGETARCH=amd64

# CGO_ENABLED=0 produces a fully static binary that does not depend on the
# runtime image's libc — robust across any glibc version drift in the
# mariadb base image. GOOS/GOARCH cross-compile from the build host arch.
ENV CGO_ENABLED=0 \
    GOOS=${TARGETOS} \
    GOARCH=${TARGETARCH}

WORKDIR /src

RUN set -eux; \
    git clone --depth 1 --branch "${RESTIC_GIT_TAG}" https://github.com/restic/restic.git .; \
    actual=$(git rev-parse HEAD); \
    if [ "${actual}" != "${RESTIC_GIT_COMMIT}" ]; then \
        echo "FATAL: ${RESTIC_GIT_TAG} resolved to ${actual}, expected ${RESTIC_GIT_COMMIT}" >&2; \
        exit 1; \
    fi

# -trimpath strips host filesystem paths from the binary (reproducibility).
# -s -w drops the symbol table and DWARF debug info (smaller binary).
# -X main.version stamps the displayed version so `restic version` shows
# the pinned tag, not "unknown" or the build-time commit ID.
RUN go build \
        -trimpath \
        -ldflags="-s -w -X main.version=${RESTIC_GIT_TAG}" \
        -o /out/restic \
        ./cmd/restic

# Smoke test the just-built binary on the build host (only meaningful when
# BUILDPLATFORM == TARGETPLATFORM — buildx skips this RUN's effects when
# they diverge, but `go build` already did the cross-arch validation).
RUN /out/restic version || true

# =============================================================================
# Stage 2 — runtime: mariadb base + scripts + the compiled restic binary.
# =============================================================================

FROM mariadb:${MARIADB_VERSION} AS runtime

# Carry the build args forward into this stage's LABEL block so the OCI
# version label reflects the actual restic source pin.
ARG RESTIC_GIT_TAG=v0.18.1
ARG MARIADB_VERSION

LABEL org.opencontainers.image.source="https://github.com/john6810/ratatoskr" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      org.opencontainers.image.title="ratatoskr-backup" \
      org.opencontainers.image.description="MariaDB hot backups via mariadb-backup, encrypted with restic (compiled from source)" \
      org.opencontainers.image.version="${MARIADB_VERSION}-restic${RESTIC_GIT_TAG}-fromsource"

ENV DEBIAN_FRONTEND=noninteractive

# Runtime apt set:
# - bash: scripts use [[ and pipefail
# - ca-certificates: TLS to B2/S3/SFTP/etc. from restic and mariadb-backup
# - tini: PID 1 for clean signal handling
# - zstd: streaming compression for the mariadb-backup pipe
#
# Note: bzip2 and curl are no longer installed. The previous Dockerfile
# pulled the upstream restic binary tarball at build time and needed both;
# the from-source build path inherits everything it needs from the
# golang:${GO_VERSION} stage.
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        tini \
        zstd \
    && rm -rf /var/lib/apt/lists/*

# Compiled restic from the builder stage. Static binary, no runtime deps.
COPY --from=restic-builder --chmod=0755 /out/restic /usr/local/bin/restic
RUN /usr/local/bin/restic version

# gosu ships in the mariadb base image for its own docker-entrypoint to
# drop privileges from root. ratatoskr-backup bypasses that entrypoint
# entirely (tini -> /usr/local/bin/entrypoint, USER mysql), so gosu is
# never invoked. Removing it drops 9 unfixable Trivy findings (1 CRITICAL
# + 8 HIGH) that come from gosu's vendored Go stdlib.
RUN rm -f /usr/local/bin/gosu

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
