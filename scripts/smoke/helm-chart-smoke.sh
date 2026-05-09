#!/bin/sh
# scripts/smoke/helm-chart-smoke.sh
#
# End-to-end smoke test for the ratatoskr Helm chart against a real
# Kubernetes cluster. Runs preflight checks, installs the chart with
# generated random secrets, runs nine progressive verifications, then
# tears down the namespace.
#
# CANONICAL DOC: scripts/smoke/README.md
#
# SCOPE
#   Catches what `helm template` + `kubeconform` cannot:
#   - image pull (real registry round-trip)
#   - PVC binding (storage class actually provisions)
#   - init Job ordering (migrate Job vs workload Deployments)
#   - runtime probes (liveness/readiness/startup against real workloads)
#   - end-to-end HTTP through the unit3d-app Service
#
#   Does NOT validate: multi-replica HA, ingress controllers, S3
#   routing, KEDA scaling. Those are overlay-specific and tested
#   separately.
#
# USAGE
#   Run on a node with kubectl + helm + openssl + curl installed and
#   a working kubeconfig pointing at the target cluster. The script
#   itself does NOT install kubectl/helm — it assumes they're present.
#
#   Capture output:
#     ./helm-chart-smoke.sh 2>&1 | tee /tmp/ratatoskr-smoke-$(date +%Y%m%d-%H%M%S).log
#
# REQUIRED TOOLS (preflight 13 verifies presence)
#   kubectl, helm (>= 3.14), openssl, curl
#
# ENV VARS — all optional; defaults shown
#   NAMESPACE          ratatoskr-test
#   RELEASE            ratatoskr
#   CHART_PATH         ./helm/ratatoskr
#   STORAGE_CLASS      csi-rawfile
#   INSTALL_TIMEOUT    10m
#   APP_URL            http://localhost:8080
#   KEEP_NAMESPACE     0 — set 1 to skip cleanup (debug / inspection)
#   APP_KEY            auto-generated via openssl rand if unset
#   MARIADB_ROOT_PW    auto-generated via openssl rand if unset
#   MARIADB_USER_PW    auto-generated via openssl rand if unset
#   REDIS_PW           auto-generated via openssl rand if unset
#   MEILI_KEY          auto-generated via openssl rand if unset
#
# EXIT CODES
#   0       PASS
#   1       generic error (unset required arg, unexpected failure)
#   10-19   preflight failures
#     10    kubectl unreachable
#     11    storage class missing
#     12    K8s server version too old (< 1.30)
#     13    required tool missing (kubectl / helm / openssl / curl)
#     14    chart path missing or `helm lint` failed
#     15    target namespace already exists
#   20-29   install failures
#     20    namespace create failed
#     22    helm install failed or timed out
#   30-39   verification failures
#     30+N  N verification checks failed (e.g. exit 33 = 3 checks failed)
#   40      cleanup phase failed (helm uninstall or namespace delete)
#
# OUTPUT
#   Final line is the grep-able marker: SMOKE_RESULT=PASS or SMOKE_RESULT=FAIL
#
# AUTHOR: ratatoskr maintainers
# LICENSE: AGPL-3.0-or-later

set -eu

# ============================================================================
# Configuration
# ============================================================================
SCRIPT_NAME="helm-chart-smoke.sh"
SCRIPT_VERSION="0.1.0"

NAMESPACE="${NAMESPACE:-ratatoskr-test}"
RELEASE="${RELEASE:-ratatoskr}"
CHART_PATH="${CHART_PATH:-./helm/ratatoskr}"
STORAGE_CLASS="${STORAGE_CLASS:-csi-rawfile}"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-10m}"
APP_URL="${APP_URL:-http://localhost:8080}"
KEEP_NAMESPACE="${KEEP_NAMESPACE:-0}"

# Verification counter
VERIFY_FAILED=0

# Track which phase ran for the EXIT trap
PHASE="preflight"

# ============================================================================
# Logging
# ============================================================================
log() {
    printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

warn() {
    printf '[%s] WARN: %s\n' "$(date +%H:%M:%S)" "$*" >&2
}

err() {
    printf '[%s] ERR:  %s\n' "$(date +%H:%M:%S)" "$*" >&2
}

banner() {
    printf '\n========================================================================\n'
    printf '%s\n' "$*"
    printf '========================================================================\n'
}

pass() {
    printf '  PASS: %s\n' "$*"
}

fail() {
    printf '  FAIL: %s\n' "$*"
    VERIFY_FAILED=$((VERIFY_FAILED + 1))
}

# ============================================================================
# Cleanup trap — runs on every exit, idempotent, gated by KEEP_NAMESPACE
# ============================================================================
cleanup() {
    rc=$?

    if [ "$KEEP_NAMESPACE" = "1" ]; then
        warn "KEEP_NAMESPACE=1 — skipping cleanup (exit_phase=$PHASE rc=$rc)"
        warn "Manual teardown:"
        warn "  helm uninstall $RELEASE -n $NAMESPACE --wait --timeout=5m || true"
        warn "  kubectl delete namespace $NAMESPACE --wait=true --timeout=5m"
        return "$rc"
    fi

    # Only run cleanup if the namespace actually exists.
    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        return "$rc"
    fi

    banner "CLEANUP — helm uninstall + namespace delete (exit_phase=$PHASE rc=$rc)"

    cleanup_failed=0

    # helm uninstall — best-effort. If the release was never created
    # (preflight aborted before install), `helm uninstall` returns
    # non-zero with "release: not found" — not a real failure.
    if helm status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
        if ! helm uninstall "$RELEASE" -n "$NAMESPACE" --wait --timeout=5m; then
            warn "helm uninstall returned non-zero — proceeding to namespace delete"
            cleanup_failed=1
        fi
    fi

    if ! kubectl delete namespace "$NAMESPACE" --wait=true --timeout=5m; then
        err "kubectl delete namespace failed or timed out"
        cleanup_failed=1
    fi

    if [ "$cleanup_failed" -ne 0 ] && [ "$rc" -eq 0 ]; then
        # Successful smoke but cleanup hiccuped → exit 40
        rc=40
    fi

    log "cleanup complete (rc=$rc)"
    return "$rc"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

# ============================================================================
# Helpers
# ============================================================================
require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "required tool not found in PATH: $1"
        exit 13
    fi
}

# Generate a hex secret of N bytes if the named env var is empty.
# Usage: gen_if_empty VAR_NAME 24
gen_if_empty() {
    name="$1"
    bytes="$2"
    eval "current=\${$name:-}"
    if [ -z "$current" ]; then
        # shellcheck disable=SC2034
        # `value` is consumed by the eval below — shellcheck can't
        # see through string-name reassignment.
        value="$(openssl rand -hex "$bytes")"
        eval "$name=\$value"
    fi
}

# ============================================================================
# Phase 1 — Preflight
# ============================================================================
preflight() {
    PHASE="preflight"
    banner "PREFLIGHT — read-only checks"

    # 13: tools first (the other checks depend on kubectl/helm)
    for t in kubectl helm openssl curl; do
        require_tool "$t"
    done
    log "13/ tools present (kubectl, helm, openssl, curl)"

    # 10: kubectl reachable
    if ! kubectl version --request-timeout=10s >/dev/null 2>&1; then
        err "kubectl cannot reach the cluster API server"
        exit 10
    fi
    server_version="$(kubectl version -o json 2>/dev/null \
        | grep -o '"gitVersion": *"[^"]*"' \
        | head -2 | tail -1 \
        | sed 's/.*"v\([^"]*\)".*/\1/')"
    log "10/ kubectl reachable (server v$server_version)"

    # 11: storage class
    if ! kubectl get storageclass "$STORAGE_CLASS" >/dev/null 2>&1; then
        err "storage class '$STORAGE_CLASS' not found"
        err "Available:"
        kubectl get storageclass 2>&1 | sed 's/^/    /' >&2
        exit 11
    fi
    log "11/ storage class '$STORAGE_CLASS' exists"

    # 12: K8s version >= 1.30. Parse "1.30.5" → major*100 + minor.
    major="$(printf '%s' "$server_version" | cut -d. -f1)"
    minor="$(printf '%s' "$server_version" | cut -d. -f2)"
    score=$((major * 100 + minor))
    if [ "$score" -lt 130 ]; then
        err "K8s server version $server_version is below the chart's minimum (1.30)"
        exit 12
    fi
    log "12/ K8s server version $server_version >= 1.30"

    # 13b: helm version >= 3.14
    helm_version="$(helm version --short 2>/dev/null | sed 's/^v//; s/+.*$//')"
    helm_major="$(printf '%s' "$helm_version" | cut -d. -f1)"
    helm_minor="$(printf '%s' "$helm_version" | cut -d. -f2)"
    helm_score=$((helm_major * 100 + helm_minor))
    if [ "$helm_score" -lt 314 ]; then
        err "helm version $helm_version is below the required minimum (3.14)"
        exit 13
    fi
    log "13b/ helm version $helm_version >= 3.14"

    # 14: chart path + lint
    if [ ! -d "$CHART_PATH" ]; then
        err "chart path not found: $CHART_PATH"
        exit 14
    fi
    if [ ! -f "$CHART_PATH/Chart.yaml" ]; then
        err "no Chart.yaml at $CHART_PATH"
        exit 14
    fi
    log "14a/ chart path: $CHART_PATH"

    # Lint with the bundled CI test values to satisfy required-field
    # constraints. If ci/test-values.yaml is absent, lint without it
    # — the in-script generated secrets will satisfy schema at install.
    lint_args=""
    if [ -f "$CHART_PATH/ci/test-values.yaml" ]; then
        lint_args="-f $CHART_PATH/ci/test-values.yaml"
    fi
    # shellcheck disable=SC2086
    # Word-splitting on $lint_args is intentional — helm lint accepts
    # `-f <path>` as separate args.
    if ! helm lint "$CHART_PATH" $lint_args >/dev/null 2>&1; then
        err "helm lint failed on $CHART_PATH"
        helm lint "$CHART_PATH" $lint_args >&2
        exit 14
    fi
    log "14b/ helm lint clean"

    # 15: target namespace must not exist (avoid clobbering)
    if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        err "namespace '$NAMESPACE' already exists"
        err "Delete it first or pick a different NAMESPACE env var:"
        err "  kubectl delete namespace $NAMESPACE"
        exit 15
    fi
    log "15/ namespace '$NAMESPACE' does not exist (clean slate)"

    log "preflight: ALL CHECKS PASSED"
}

# ============================================================================
# Phase 2 — Install
# ============================================================================
install() {
    PHASE="install"
    banner "INSTALL — namespace + helm install (timeout $INSTALL_TIMEOUT)"

    # 20: namespace
    if ! kubectl create namespace "$NAMESPACE" >/dev/null; then
        err "kubectl create namespace failed"
        exit 20
    fi
    log "20/ namespace '$NAMESPACE' created"

    # 21: secrets — generate if not provided
    gen_if_empty MARIADB_ROOT_PW 24
    gen_if_empty MARIADB_USER_PW 24
    gen_if_empty REDIS_PW 24
    gen_if_empty MEILI_KEY 16

    # APP_KEY needs the Laravel "base64:" prefix.
    if [ -z "${APP_KEY:-}" ]; then
        APP_KEY="base64:$(openssl rand -base64 32)"
    fi
    log "21/ secrets generated (sha256 hashes only logged below)"
    log "    APP_KEY hash:        $(printf '%s' "$APP_KEY" | openssl sha256 | awk '{print $2}')"
    log "    MARIADB_ROOT_PW hash: $(printf '%s' "$MARIADB_ROOT_PW" | openssl sha256 | awk '{print $2}')"
    log "    MARIADB_USER_PW hash: $(printf '%s' "$MARIADB_USER_PW" | openssl sha256 | awk '{print $2}')"
    log "    REDIS_PW hash:       $(printf '%s' "$REDIS_PW" | openssl sha256 | awk '{print $2}')"
    log "    MEILI_KEY hash:      $(printf '%s' "$MEILI_KEY" | openssl sha256 | awk '{print $2}')"

    # 22: helm install
    log "22/ helm install $RELEASE -n $NAMESPACE --wait --timeout=$INSTALL_TIMEOUT"
    if ! helm install "$RELEASE" "$CHART_PATH" \
            -n "$NAMESPACE" \
            --wait --timeout="$INSTALL_TIMEOUT" \
            --set "unit3d.appKey=$APP_KEY" \
            --set "unit3d.appUrl=$APP_URL" \
            --set "mariadb.auth.rootPassword=$MARIADB_ROOT_PW" \
            --set "mariadb.auth.password=$MARIADB_USER_PW" \
            --set "redis.auth.password=$REDIS_PW" \
            --set "meilisearch.masterKey=$MEILI_KEY" \
            --set "global.storageClass=$STORAGE_CLASS" \
            --set "ingress.enabled=false"; then
        err "helm install failed or timed out"
        err "--- pods at failure ---"
        kubectl -n "$NAMESPACE" get pods 2>&1 | sed 's/^/    /' >&2
        err "--- recent events at failure ---"
        kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp 2>&1 \
            | tail -30 | sed 's/^/    /' >&2
        exit 22
    fi
    log "install complete"
}

# ============================================================================
# Phase 3 — Verification (9 progressive checks)
# ============================================================================
verify() {
    PHASE="verify"
    banner "VERIFY — 9 progressive checks"

    # 30: all pods Ready, no Pending or CrashLoopBackOff
    log "30/ pods Ready / no Pending / no CrashLoop"
    not_running="$(kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null \
        | awk '$3 != "Running" && $3 != "Completed" {print}')"
    if [ -n "$not_running" ]; then
        fail "some pods not Running/Completed:"
        printf '%s\n' "$not_running" | sed 's/^/    /'
    else
        pass "all pods Running/Completed"
    fi

    # 31: 3 StatefulSets stable
    log "31/ StatefulSets stable (mariadb, redis, meilisearch)"
    sts_ok=1
    for sts in "$RELEASE-mariadb" "$RELEASE-redis" "$RELEASE-meilisearch"; do
        ready="$(kubectl -n "$NAMESPACE" get statefulset "$sts" \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
        replicas="$(kubectl -n "$NAMESPACE" get statefulset "$sts" \
            -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
        if [ "$ready" = "$replicas" ] && [ "${ready:-0}" -ge 1 ]; then
            log "    $sts: $ready/$replicas"
        else
            fail "$sts: ready=$ready/$replicas"
            sts_ok=0
        fi
    done
    [ "$sts_ok" -eq 1 ] && pass "3 StatefulSets stable"

    # 32: 3 Deployments available
    log "32/ Deployments available (app, queue, scheduler)"
    dep_ok=1
    for dep in "$RELEASE-unit3d-app" "$RELEASE-unit3d-queue" "$RELEASE-unit3d-scheduler"; do
        avail="$(kubectl -n "$NAMESPACE" get deployment "$dep" \
            -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
        replicas="$(kubectl -n "$NAMESPACE" get deployment "$dep" \
            -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
        if [ "$avail" = "$replicas" ] && [ "${avail:-0}" -ge 1 ]; then
            log "    $dep: $avail/$replicas"
        else
            fail "$dep: available=$avail/$replicas"
            dep_ok=0
        fi
    done
    [ "$dep_ok" -eq 1 ] && pass "3 Deployments available"

    # 33: migrate Job Complete + log shows migrations ran
    log "33/ migrate Job Complete + log inspection"
    job_status="$(kubectl -n "$NAMESPACE" get job "$RELEASE-unit3d-migrate" \
        -o jsonpath='{.status.succeeded}' 2>/dev/null || echo 0)"
    if [ "${job_status:-0}" -ge 1 ]; then
        # Check the log contains migration evidence
        if kubectl -n "$NAMESPACE" logs "job/$RELEASE-unit3d-migrate" 2>/dev/null \
                | grep -q -i "migrat"; then
            pass "migrate Job Complete (logs show migration activity)"
        else
            fail "migrate Job Complete but logs lack migration evidence"
        fi
    else
        fail "migrate Job not Complete (succeeded=$job_status)"
        kubectl -n "$NAMESPACE" logs "job/$RELEASE-unit3d-migrate" 2>&1 \
            | tail -20 | sed 's/^/    /'
    fi

    # 34: migrate:status from app pod
    log "34/ migrate:status from unit3d-app"
    if kubectl -n "$NAMESPACE" exec "deploy/$RELEASE-unit3d-app" -- \
            php /app/artisan migrate:status >/tmp/migrate-status.txt 2>&1; then
        ran_count="$(grep -c -E 'Ran|Yes' /tmp/migrate-status.txt || true)"
        if [ "${ran_count:-0}" -ge 1 ]; then
            pass "migrate:status reports $ran_count migrations applied"
        else
            fail "migrate:status returned no Ran/Yes entries"
            tail -5 /tmp/migrate-status.txt | sed 's/^/    /'
        fi
    else
        fail "migrate:status exec failed"
        tail -5 /tmp/migrate-status.txt 2>/dev/null | sed 's/^/    /'
    fi
    rm -f /tmp/migrate-status.txt

    # 35: redis ping
    log "35/ redis-cli ping (auth-aware)"
    if kubectl -n "$NAMESPACE" exec "statefulset/$RELEASE-redis" -- \
            redis-cli -a "$REDIS_PW" --no-auth-warning ping 2>/dev/null \
            | grep -q PONG; then
        pass "redis PONG"
    else
        fail "redis ping did not return PONG"
    fi

    # 36: meilisearch /health
    log "36/ meilisearch /health from app pod"
    health="$(kubectl -n "$NAMESPACE" exec "deploy/$RELEASE-unit3d-app" -- \
        sh -c "wget -qO- http://$RELEASE-meilisearch:7700/health 2>/dev/null \
               || curl -s http://$RELEASE-meilisearch:7700/health" 2>/dev/null \
        || echo "")"
    if printf '%s' "$health" | grep -q '"status".*"available"'; then
        pass "meilisearch reports status:available"
    else
        fail "meilisearch /health unexpected: $health"
    fi

    # 37: HTTP probe via port-forward
    log "37/ HTTP probe unit3d-app via port-forward"
    pf_log=/tmp/smoke-pf.log
    kubectl -n "$NAMESPACE" port-forward "svc/$RELEASE-unit3d-app" 18080:80 \
        >"$pf_log" 2>&1 &
    pf_pid=$!
    # Wait for port-forward to bind
    sleep 5
    code="$(curl -s -o /dev/null -w '%{http_code}' \
        --max-time 10 http://127.0.0.1:18080 || echo 000)"
    kill "$pf_pid" 2>/dev/null || true
    wait "$pf_pid" 2>/dev/null || true
    rm -f "$pf_log"
    case "$code" in
        200|302)
            pass "unit3d-app returned HTTP $code"
            ;;
        *)
            fail "unit3d-app HTTP probe got $code (expected 200 or 302)"
            ;;
    esac

    # 38: zero pod restarts
    log "38/ pod restart counter"
    restarts="$(kubectl -n "$NAMESPACE" get pods \
        -o jsonpath='{range .items[*]}{.metadata.name} {.status.containerStatuses[*].restartCount}{"\n"}{end}' \
        2>/dev/null || true)"
    bad="$(printf '%s' "$restarts" | awk '$2 != "" && $2 != "0" {print}')"
    if [ -z "$bad" ]; then
        pass "all pods report 0 restarts"
    else
        fail "pods with non-zero restart count:"
        printf '%s\n' "$bad" | sed 's/^/    /'
    fi

    # Aggregate
    if [ "$VERIFY_FAILED" -eq 0 ]; then
        log "verify: all 9 checks PASSED"
    else
        err "verify: $VERIFY_FAILED check(s) FAILED"
        exit $((30 + VERIFY_FAILED))
    fi
}

# ============================================================================
# Main
# ============================================================================
main() {
    started_at="$(date +%s)"

    banner "$SCRIPT_NAME v$SCRIPT_VERSION"
    log "namespace=$NAMESPACE release=$RELEASE chart=$CHART_PATH"
    log "storage_class=$STORAGE_CLASS install_timeout=$INSTALL_TIMEOUT"
    log "keep_namespace=$KEEP_NAMESPACE"

    preflight
    install
    verify

    elapsed=$(( $(date +%s) - started_at ))

    banner "SMOKE TEST RESULT"
    if [ "$VERIFY_FAILED" -eq 0 ]; then
        log "PASS — all 9 verifications green (elapsed ${elapsed}s)"
        printf 'SMOKE_RESULT=PASS\n'
    else
        err "FAIL — $VERIFY_FAILED check(s) failed (elapsed ${elapsed}s)"
        printf 'SMOKE_RESULT=FAIL\n'
    fi
    # cleanup runs via EXIT trap regardless
}

main "$@"
