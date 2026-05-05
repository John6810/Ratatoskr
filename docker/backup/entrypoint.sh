#!/usr/bin/env bash
# Dispatcher for the ratatoskr-backup image. The first argument selects the
# subcommand; remaining arguments are forwarded. Anything not in the known
# set is treated as a raw command (useful for ad-hoc `restic snapshots`,
# `bash`, etc.).
set -euo pipefail

case "${1:-backup}" in
    backup)       shift || true; exec /usr/local/bin/backup "$@" ;;
    restore)      shift || true; exec /usr/local/bin/restore "$@" ;;
    restore-test) shift || true; exec /usr/local/bin/restore-test "$@" ;;
    sh|bash|shell) exec bash ;;
    *)            exec "$@" ;;
esac
