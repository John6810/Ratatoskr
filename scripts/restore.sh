#!/usr/bin/env bash
# ratatoskr restore — pull a snapshot from restic, decompress, prepare with
# mariadb-backup, and copy back to a target datadir.
#
# DESTRUCTIVE — wipes the target datadir before copy-back. Run only on a
# stopped MariaDB. Operators must `docker compose stop mariadb` (or equivalent)
# before invoking this script.
#
# Usage:
#   restore [SNAPSHOT_ID]
#
# Defaults:
#   SNAPSHOT_ID = latest snapshot tagged with $BACKUP_TAG
#   TARGET_DIR  = /var/lib/mysql (mounted from the mariadb-data volume)
#
# Required env:
#   RESTIC_REPOSITORY, RESTIC_PASSWORD (or RESTIC_PASSWORD_FILE)
#
# Optional:
#   TARGET_DIR        default /var/lib/mysql
#   BACKUP_TAG        default ratatoskr-mariadb
#   RESTORE_FORCE     true to wipe a non-empty TARGET_DIR (default false)
#   BACKUP_HOSTNAME   restrict snapshot selection to a specific source host

set -euo pipefail

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is required}"
if [[ -z "${RESTIC_PASSWORD:-}" && -z "${RESTIC_PASSWORD_FILE:-}" ]]; then
    echo "RESTIC_PASSWORD or RESTIC_PASSWORD_FILE is required" >&2
    exit 1
fi

SNAPSHOT_ID="${1:-latest}"
TARGET_DIR="${TARGET_DIR:-/var/lib/mysql}"
BACKUP_TAG="${BACKUP_TAG:-ratatoskr-mariadb}"

# Refuse to overwrite a non-empty datadir unless explicitly forced. This is
# the safety net: an operator who runs `restore` against a live datadir
# would otherwise destroy the running database.
if [[ -d "${TARGET_DIR}" && -n "$(ls -A "${TARGET_DIR}" 2>/dev/null)" ]]; then
    if [[ "${RESTORE_FORCE:-false}" != "true" ]]; then
        cat <<EOF >&2
ERROR: ${TARGET_DIR} is not empty.

The restore overwrites the target datadir. To proceed:
  1. Stop MariaDB: docker compose stop mariadb
  2. Re-run with RESTORE_FORCE=true
EOF
        exit 1
    fi
    echo "[restore] RESTORE_FORCE=true — wiping ${TARGET_DIR}"
    rm -rf "${TARGET_DIR:?}"/*
fi

mkdir -p "${TARGET_DIR}"

WORK_DIR="$(mktemp -d -t ratatoskr-restore-XXXXXX)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# Optional host filter — restoring on host-A from a snapshot taken on host-B
# requires the operator to set BACKUP_HOSTNAME=host-B.
HOST_FLAG=()
if [[ -n "${BACKUP_HOSTNAME:-}" ]]; then
    HOST_FLAG=(--host "${BACKUP_HOSTNAME}")
fi

echo "[restore] streaming snapshot ${SNAPSHOT_ID} (tag=${BACKUP_TAG}) -> zstd -d -> mbstream -> ${WORK_DIR}"
restic dump --tag "${BACKUP_TAG}" "${HOST_FLAG[@]}" "${SNAPSHOT_ID}" /mariadb.xbstream.zst \
| zstd -d \
| mbstream -x -C "${WORK_DIR}"

echo "[restore] preparing backup with mariadb-backup --prepare"
mariadb-backup --prepare --target-dir="${WORK_DIR}"

echo "[restore] copying back to ${TARGET_DIR}"
mariadb-backup --copy-back --target-dir="${WORK_DIR}" --datadir="${TARGET_DIR}"

# Best-effort ownership fix. mariadb-backup --copy-back writes files as the
# running user; if that's already mysql (UID 999), this is a no-op. If we
# are running as a different uid (e.g. root in a sidecar) chown completes
# the alignment. Failures are logged loudly — silently ignoring a chown
# failure can leave the datadir partially unreadable by mysqld at boot,
# and the operator deserves to see that before they hit a startup crash.
if ! chown -R mysql:mysql "${TARGET_DIR}" 2>/dev/null; then
    echo "[restore] WARNING: chown to mysql:mysql failed on ${TARGET_DIR}" >&2
    echo "[restore]          Verify ownership manually before starting MariaDB:" >&2
    echo "[restore]            stat -c '%U:%G %n' ${TARGET_DIR}" >&2
fi

echo "[restore] done. Start MariaDB: docker compose up -d mariadb"
