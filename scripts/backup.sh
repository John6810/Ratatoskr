#!/usr/bin/env bash
# ratatoskr backup — mariadb-backup hot backup, streamed and zstd-compressed,
# pushed to a restic repository (encryption + dedup).
#
# Required env:
#   MARIADB_HOST                  hostname of the MariaDB server (e.g. mariadb)
#   MARIADB_USER                  backup user (RELOAD, PROCESS, LOCK TABLES, BACKUP_ADMIN)
#   MARIADB_PASSWORD              or MARIADB_PASSWORD_FILE
#   RESTIC_REPOSITORY             e.g. b2:my-bucket:/ratatoskr
#   RESTIC_PASSWORD               or RESTIC_PASSWORD_FILE
#
# Backend-specific (B2):
#   B2_ACCOUNT_ID, B2_ACCOUNT_KEY
#
# Optional:
#   BACKUP_HOSTNAME               tag attached to each snapshot, default $(hostname)
#   BACKUP_TAG                    extra restic tag, default ratatoskr-mariadb
#   MARIABACKUP_PARALLEL          --parallel for mariadb-backup, default 4
#   ZSTD_LEVEL                    1..19, default 3
#   BACKUP_PRUNE                  true|false, default true (forget+prune after backup)
#   BACKUP_RETENTION_DAILY        --keep-daily, default 30
#
# Exit 0 on success. Exit non-zero on any pipeline stage failure (pipefail).

set -euo pipefail

: "${MARIADB_HOST:?MARIADB_HOST is required}"
: "${MARIADB_USER:?MARIADB_USER is required}"
: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is required}"

# Resolve secrets from *_FILE env vars when set (Docker/K8s secret pattern).
# We deliberately do NOT export MARIADB_PASSWORD — exporting leaks it into
# /proc/<pid>/environ of every child process. Instead the password is passed
# only to mariadb-backup, via MYSQL_PWD on the command line below (read by
# mariadb tools natively, never visible in `ps aux` argv).
if [[ -n "${MARIADB_PASSWORD_FILE:-}" ]]; then
    MARIADB_PASSWORD="$(< "${MARIADB_PASSWORD_FILE}")"
fi
: "${MARIADB_PASSWORD:?MARIADB_PASSWORD or MARIADB_PASSWORD_FILE is required}"

if [[ -z "${RESTIC_PASSWORD:-}" && -z "${RESTIC_PASSWORD_FILE:-}" ]]; then
    echo "RESTIC_PASSWORD or RESTIC_PASSWORD_FILE is required" >&2
    exit 1
fi

BACKUP_HOSTNAME="${BACKUP_HOSTNAME:-$(hostname)}"
BACKUP_TAG="${BACKUP_TAG:-ratatoskr-mariadb}"
MARIABACKUP_PARALLEL="${MARIABACKUP_PARALLEL:-4}"
ZSTD_LEVEL="${ZSTD_LEVEL:-3}"
BACKUP_PRUNE="${BACKUP_PRUNE:-true}"
BACKUP_RETENTION_DAILY="${BACKUP_RETENTION_DAILY:-30}"

# Initialize the restic repo on first run. `restic cat config` exits 0 only
# when the repo is initialized, so it doubles as an existence probe.
if ! restic cat config >/dev/null 2>&1; then
    echo "[backup] initializing restic repository: ${RESTIC_REPOSITORY}"
    restic init
fi

echo "[backup] streaming mariadb-backup -> zstd -${ZSTD_LEVEL} -> restic"
echo "[backup]   host=${MARIADB_HOST} user=${MARIADB_USER} parallel=${MARIABACKUP_PARALLEL} tag=${BACKUP_TAG}"

# pipefail (set above) propagates a non-zero exit from any stage.
# mariadb-backup writes the xbstream archive to stdout; zstd compresses;
# restic reads stdin and pushes a single binary blob into the repository.
#
# MYSQL_PWD is consumed natively by mariadb-backup. It is set inline so the
# variable propagates only to that one process — not to zstd, not to restic.
# `--password=` on argv would expose the secret in `ps aux`; we avoid it.
MYSQL_PWD="${MARIADB_PASSWORD}" mariadb-backup --backup \
    --stream=xbstream \
    --user="${MARIADB_USER}" \
    --host="${MARIADB_HOST}" \
    --parallel="${MARIABACKUP_PARALLEL}" \
| zstd "-${ZSTD_LEVEL}" --threads=0 \
| restic backup \
    --stdin \
    --stdin-filename="mariadb.xbstream.zst" \
    --tag "${BACKUP_TAG}" \
    --host "${BACKUP_HOSTNAME}"

echo "[backup] snapshot stored"

if [[ "${BACKUP_PRUNE}" == "true" ]]; then
    echo "[backup] enforcing retention: keep-daily=${BACKUP_RETENTION_DAILY}"
    restic forget \
        --tag "${BACKUP_TAG}" \
        --host "${BACKUP_HOSTNAME}" \
        --keep-daily "${BACKUP_RETENTION_DAILY}" \
        --prune
else
    echo "[backup] BACKUP_PRUNE=false — skipping forget+prune (operator runs it separately)"
fi

echo "[backup] done"
