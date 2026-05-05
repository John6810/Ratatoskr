#!/usr/bin/env bash
# Restore drill — verify the latest snapshot is restorable end-to-end and
# that the resulting datadir starts a working MariaDB. Runs in an ephemeral
# directory; no impact on production data.
#
# This is the truth check for the backup pipeline. If it fails, backups are
# theatrical and the operator must investigate before relying on them.
#
# Exit 0 = drill passed.
# Exit 1 = drill failed (snapshot unreadable, prepare failed, mariadbd refused
#          to start, or row-count sentinels not met).
#
# Required env:
#   RESTIC_REPOSITORY, RESTIC_PASSWORD (or RESTIC_PASSWORD_FILE)
#
# Optional:
#   BACKUP_TAG          default ratatoskr-mariadb
#   DRILL_DB_NAME       default unit3d
#   DRILL_MIN_USERS     minimum row count in users table (default 1 — bootstrap admin)
#   DRILL_TIMEOUT       seconds to wait for mariadbd to accept queries (default 30)
#   BACKUP_HOSTNAME     restrict snapshot selection to a specific source host

set -euo pipefail

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is required}"
if [[ -z "${RESTIC_PASSWORD:-}" && -z "${RESTIC_PASSWORD_FILE:-}" ]]; then
    echo "RESTIC_PASSWORD or RESTIC_PASSWORD_FILE is required" >&2
    exit 1
fi

BACKUP_TAG="${BACKUP_TAG:-ratatoskr-mariadb}"
DRILL_DB_NAME="${DRILL_DB_NAME:-unit3d}"
DRILL_MIN_USERS="${DRILL_MIN_USERS:-1}"
DRILL_TIMEOUT="${DRILL_TIMEOUT:-30}"

DRILL_DIR="$(mktemp -d -t ratatoskr-drill-XXXXXX)"
DATADIR="${DRILL_DIR}/data"
SOCKET="${DRILL_DIR}/mysql.sock"
PIDFILE="${DRILL_DIR}/mysql.pid"

# Tear down the spawned mariadbd and wipe scratch dir on exit, regardless of
# whether the drill passed or failed.
cleanup() {
    if [[ -f "${PIDFILE}" ]]; then
        local pid
        pid="$(cat "${PIDFILE}" 2>/dev/null || true)"
        if [[ -n "${pid}" ]]; then
            kill "${pid}" 2>/dev/null || true
            sleep 2
            kill -9 "${pid}" 2>/dev/null || true
        fi
    fi
    rm -rf "${DRILL_DIR}"
}
trap cleanup EXIT

mkdir -p "${DATADIR}"

HOST_FLAG=()
if [[ -n "${BACKUP_HOSTNAME:-}" ]]; then
    HOST_FLAG=(--host "${BACKUP_HOSTNAME}")
fi

echo "[drill] streaming latest snapshot to ${DATADIR}"
restic dump --tag "${BACKUP_TAG}" "${HOST_FLAG[@]}" latest /mariadb.xbstream.zst \
| zstd -d \
| mbstream -x -C "${DATADIR}"

echo "[drill] preparing backup"
mariadb-backup --prepare --target-dir="${DATADIR}"

echo "[drill] starting ephemeral mariadbd on socket ${SOCKET}"
# --skip-networking: no TCP listener (drill is local-only via unix socket)
# --skip-grant-tables: no auth needed for read-only sanity queries
mariadbd \
    --datadir="${DATADIR}" \
    --socket="${SOCKET}" \
    --pid-file="${PIDFILE}" \
    --skip-networking \
    --skip-grant-tables \
    --user=mysql \
    >"${DRILL_DIR}/mariadbd.log" 2>&1 &

# Wait up to DRILL_TIMEOUT seconds for the server to accept queries.
for _ in $(seq 1 "${DRILL_TIMEOUT}"); do
    if mariadb --socket="${SOCKET}" -e 'SELECT 1' >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if ! mariadb --socket="${SOCKET}" -e 'SELECT 1' >/dev/null 2>&1; then
    echo "[drill] FAIL: mariadbd never accepted connections within ${DRILL_TIMEOUT}s" >&2
    echo "[drill] mariadbd log tail:" >&2
    tail -n 50 "${DRILL_DIR}/mariadbd.log" >&2 || true
    exit 1
fi

echo "[drill] running sanity queries on database ${DRILL_DB_NAME}"
USERS_COUNT="$(mariadb --socket="${SOCKET}" -N -B -e \
    "SELECT COUNT(*) FROM \`${DRILL_DB_NAME}\`.users")"
TORRENTS_COUNT="$(mariadb --socket="${SOCKET}" -N -B -e \
    "SELECT COUNT(*) FROM \`${DRILL_DB_NAME}\`.torrents")"

echo "[drill]   users    = ${USERS_COUNT}"
echo "[drill]   torrents = ${TORRENTS_COUNT}"

# Sentinel: at minimum the bootstrap admin from DEFAULT_OWNER_* must exist.
# UNIT3D's UserSeeder seeds three rows (System, Bot, owner), so even a fresh
# install passes >=1 unless the seeder never ran.
if (( USERS_COUNT < DRILL_MIN_USERS )); then
    echo "[drill] FAIL: users table has ${USERS_COUNT} rows, expected >=${DRILL_MIN_USERS}" >&2
    exit 1
fi

# torrents table is allowed to be 0 (fresh deployment with no uploads yet),
# but the table must exist — covered implicitly by the COUNT(*) succeeding.

echo "[drill] PASS"
