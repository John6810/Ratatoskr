#!/bin/sh
# ratatoskr-entrypoint.sh
#
# Wraps the dunglas/frankenphp base image entrypoint with a
# cgroup-aware GOMEMLIMIT calculation, ensuring Go's GC behaves
# correctly under Kubernetes pod memory limits.
#
# Without explicit GOMEMLIMIT, Go's GC calibrates against host
# memory rather than the pod's cgroup limit — under pressure this
# leads to OOMKilled events with no useful diagnostic.
#
# We set GOMEMLIMIT to 90% of the cgroup memory limit, leaving 10%
# headroom for non-Go memory (PHP runtime, kernel buffers, libraries).
# Operator override: set GOMEMLIMIT explicitly in pod spec; auto-calc
# is skipped if the env var is already set.

set -e

if [ -z "${GOMEMLIMIT:-}" ]; then
    mem_max=""

    # cgroup v2
    if [ -f /sys/fs/cgroup/memory.max ]; then
        mem_max=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo "max")
        if [ "$mem_max" = "max" ] || [ -z "$mem_max" ]; then
            mem_max=""
        fi
    # cgroup v1
    elif [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        mem_max=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
        # cgroup v1 reports max int64 when no limit set
        if [ -z "$mem_max" ] || [ "$mem_max" -gt 9000000000000000000 ]; then
            mem_max=""
        fi
    fi

    if [ -n "$mem_max" ]; then
        GOMEMLIMIT="$(( mem_max * 90 / 100 / 1048576 ))MiB"
        export GOMEMLIMIT
        echo "[ratatoskr-entrypoint] GOMEMLIMIT auto-set to ${GOMEMLIMIT} (90% of cgroup limit)" >&2
    fi
fi

# Pass through to the base image entrypoint with all args.
# dunglas/frankenphp's docker-php-entrypoint handles PHP setup
# and exec's frankenphp run with the CMD args.
exec docker-php-entrypoint "$@"
