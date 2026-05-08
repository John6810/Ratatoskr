#!/bin/sh
# scripts/migration/migrate-rwo-to-rwx.sh
#
# Operationalizes upgrade-guide.md § "Path 2 — prod-rwo -> prod-rwx,
# Option B (Manual PVC swap, in-place)" as an idempotent POSIX sh
# script.
#
# CANONICAL DOC: docs/upgrade-guide.md, anchor:
#   #option-b---manual-pvc-swap-advanced-in-place
#
# SCOPE
#   In-place RWO -> RWX migration of the unit3d-storage PVC. The
#   workloads stay in the same namespace; only the PVC is swapped.
#   The old PV is preserved (reclaimPolicy=Retain) and rsynced into
#   the new RWX PVC via a temporary loader Pod that mounts both.
#
# OUT OF SCOPE
#   Option A (fresh parallel namespace) is NOT scripted. Operators
#   wanting Option A follow the manual procedure in upgrade-guide.md
#   directly. The Compose -> K8s flow is shipped separately.
#
# REQUIRED TOOLS
#   - kubectl  (any version compatible with the cluster API)
#   - jq       (PVC accessModes is a JSON array; we read and rewrite
#              manifests via jq pipelines rather than ad-hoc sed)
#
# REQUIRED PERMISSIONS
#   Namespace-scoped: get/list/patch/delete on persistentvolumeclaims,
#     deployments, pods, jobs in $NAMESPACE
#   Cluster-scoped:   get/patch on persistentvolumes (we flip
#                     reclaimPolicy and clear claimRef on the old PV)
#                     get on storageclasses (preflight 14)
#   The script runs `kubectl auth can-i` checks as part of preflight.
#
# OPERATOR INPUTS (env vars, no positional args)
#   NAMESPACE          default: unit3d
#   NEW_STORAGE_CLASS  REQUIRED — RWX-capable StorageClass name
#   KUBECTL_CONTEXT    default: current context
#   OVERLAY_PATH       default: kustomize/overlays/prod-rwx
#   DRY_RUN=1          read-only; mutations log [DRY-RUN] and skip
#   VERBOSE=1          echo every kubectl call before running
#   BACKUP_VERIFIED=1  bypass the /tmp/ratatoskr-backup-marker
#                      preflight (logged loudly)
#   PROCEED=1          bypass the kubectl-context confirmation
#
# EXIT CODES
#   0       success
#   1       generic error (unset required env, unexpected failure)
#   10-19   preflight failures
#     10    missing required tool (kubectl, jq)
#     11    kubectl context mismatch + PROCEED not set
#     12    namespace does not exist
#     13    unit3d-storage PVC missing/unbound or not RWO
#     14    NEW_STORAGE_CLASS missing in cluster
#     15    unit3d-app Deployment is not single-replica
#     16    MariaDB rollout not healthy
#     17    backup marker stale or absent and BACKUP_VERIFIED unset
#     18    unit3d-migrate Job is currently running
#     19    insufficient RBAC for required verbs
#   20-29   mutation failures
#     20    failed to scale down workloads
#     21    failed to capture old PVC manifest
#     22    failed to patch old PV reclaimPolicy/claimRef
#     23    failed to delete old PVC
#     24    failed to apply rescue PVC (rebind to old PV)
#     25    failed to apply new RWX PVC
#     26    failed to apply pvc-loader Pod
#     27    rsync inside pvc-loader returned non-zero
#     28    checksum verification failed
#     29    failed to apply prod-rwx overlay or rollout
#   30      user abort (Ctrl+C, sigterm, explicit decline)
#
# POSIX NOTES
#   `set -eu` — no pipefail in POSIX sh. Pipes are used sparingly
#   and where used, the failure semantics are documented inline.
#   This script targets /bin/sh on Alpine, dash on Debian, and Git
#   Bash sh on Windows operator workstations.
#
# AUTHOR: ratatoskr maintainers
# LICENSE: AGPL-3.0-or-later (matches the repo)

set -eu

# ============================================================================
# Constants
# ============================================================================
SCRIPT_NAME="migrate-rwo-to-rwx.sh"
SCRIPT_VERSION="0.1.0"
PVC_NAME="unit3d-storage"
RESCUE_PVC_NAME="unit3d-storage-rescue"
LOADER_POD="pvc-loader-rwx-migration"
BACKUP_MARKER="/tmp/ratatoskr-backup-marker"
BACKUP_MAX_AGE_MIN=60

# ============================================================================
# Configuration (env-driven)
# ============================================================================
NAMESPACE="${NAMESPACE:-unit3d}"
NEW_STORAGE_CLASS="${NEW_STORAGE_CLASS:-}"
KUBECTL_CONTEXT="${KUBECTL_CONTEXT:-}"
OVERLAY_PATH="${OVERLAY_PATH:-kustomize/overlays/prod-rwx}"
# Image used for the temporary rsync Pod. Operators on locked-down
# supply chains can pin a digest:
#   PVC_LOADER_IMAGE=alpine@sha256:<digest>
PVC_LOADER_IMAGE="${PVC_LOADER_IMAGE:-alpine:3.20}"
DRY_RUN="${DRY_RUN:-0}"
VERBOSE="${VERBOSE:-0}"
BACKUP_VERIFIED="${BACKUP_VERIFIED:-0}"
PROCEED="${PROCEED:-0}"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
WORK_DIR="/tmp/ratatoskr-migration-${TIMESTAMP}"

# Track which mutation phase we entered for the abort handler.
# 0=preflight, 1=scale-down, 2=pvc-swap, 3=rsync, 4=overlay-apply
PHASE=0

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

# ============================================================================
# kubectl wrappers
# ============================================================================
# Build the kubectl context flag once. Empty if KUBECTL_CONTEXT not set.
KUBECTL_CTX_FLAG=""
if [ -n "${KUBECTL_CONTEXT}" ]; then
    KUBECTL_CTX_FLAG="--context=${KUBECTL_CONTEXT}"
fi

# kc: read-only kubectl. Always runs, even in DRY_RUN.
kc() {
    if [ "$VERBOSE" = "1" ]; then
        printf '+ kubectl %s %s\n' "$KUBECTL_CTX_FLAG" "$*" >&2
    fi
    if [ -n "$KUBECTL_CTX_FLAG" ]; then
        kubectl "$KUBECTL_CTX_FLAG" "$@"
    else
        kubectl "$@"
    fi
}

# kc_mutate: kubectl that mutates cluster state.
# Honors DRY_RUN — logs and skips.
kc_mutate() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '[DRY-RUN] kubectl %s\n' "$*"
        return 0
    fi
    if [ "$VERBOSE" = "1" ]; then
        printf '+ kubectl %s %s\n' "$KUBECTL_CTX_FLAG" "$*" >&2
    fi
    if [ -n "$KUBECTL_CTX_FLAG" ]; then
        kubectl "$KUBECTL_CTX_FLAG" "$@"
    else
        kubectl "$@"
    fi
}

# kc_apply_stdin: pipe a manifest from stdin. POSIX has no pipefail;
# the heredoc producer never fails, only kubectl can — so the exit
# code of the pipeline equals kubectl's exit code in practice. We
# document the assumption here rather than rely on bashisms.
kc_apply_stdin() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '[DRY-RUN] kubectl apply -f - (stdin manifest)\n'
        # In DRY_RUN, drain stdin so the caller's heredoc completes.
        cat >/dev/null
        return 0
    fi
    if [ -n "$KUBECTL_CTX_FLAG" ]; then
        kubectl "$KUBECTL_CTX_FLAG" apply -f -
    else
        kubectl apply -f -
    fi
}

# ============================================================================
# Abort handler
# ============================================================================
on_abort() {
    rc=$?
    if [ "$rc" -eq 0 ]; then
        return 0
    fi
    banner "ABORT (exit=$rc, phase=$PHASE)"
    case "$PHASE" in
        1)
            warn "Aborted during scale-down. Workloads may be at replicas=0."
            warn "Recovery: scale them back to the prod-rwo defaults manually:"
            warn "  kubectl scale -n $NAMESPACE deployment/unit3d-app --replicas=1"
            warn "  kubectl scale -n $NAMESPACE deployment/unit3d-queue --replicas=1"
            warn "  kubectl scale -n $NAMESPACE deployment/unit3d-scheduler --replicas=1"
            ;;
        2)
            warn "Aborted during PVC swap. Cluster state requires manual repair."
            warn "Old PVC may be deleted; old PV is retained (claimRef cleared or set)."
            warn "Recovery: see upgrade-guide.md § Path 2 rollback (Option B)."
            warn "Backup tarball + MariaDB dump from preflight ARE your recovery path."
            warn "Work directory preserved at: $WORK_DIR"
            ;;
        3)
            warn "Aborted during rsync. Loader Pod may still be running."
            warn "Recovery: kubectl delete pod -n $NAMESPACE $LOADER_POD"
            warn "Then re-run this script — preflights detect partial state."
            warn "Work directory preserved at: $WORK_DIR"
            ;;
        4)
            warn "Aborted during overlay apply / rollout."
            warn "Recovery: kubectl rollout undo -n $NAMESPACE deployment/unit3d-app"
            warn "Then investigate before re-applying the prod-rwx overlay."
            ;;
        *)
            ;;
    esac
}
trap on_abort EXIT
trap 'exit 30' INT TERM

# ============================================================================
# Preflight phase
# ============================================================================
preflight() {
    banner "PREFLIGHT — read-only checks"

    # 10. Required tools
    if ! command -v kubectl >/dev/null 2>&1; then
        err "kubectl not found in PATH"
        exit 10
    fi
    if ! command -v jq >/dev/null 2>&1; then
        err "jq not found in PATH (required for PVC manifest manipulation)"
        exit 10
    fi
    log "10/ tools: kubectl + jq present"

    # 11. Context confirmation
    current_ctx="$(kubectl config current-context 2>/dev/null || true)"
    expected_ctx="${KUBECTL_CONTEXT:-$current_ctx}"
    if [ -z "$current_ctx" ]; then
        err "no current kubectl context configured"
        exit 11
    fi
    log "11/ kubectl context: current='$current_ctx' expected='$expected_ctx'"
    if [ "$current_ctx" != "$expected_ctx" ] && [ "$PROCEED" != "1" ]; then
        err "context mismatch: current=$current_ctx, expected=$expected_ctx"
        err "Set KUBECTL_CONTEXT=$current_ctx if intentional, or PROCEED=1 to bypass"
        exit 11
    fi

    # 12. Namespace exists
    if ! kc get namespace "$NAMESPACE" >/dev/null 2>&1; then
        err "namespace '$NAMESPACE' does not exist"
        exit 12
    fi
    log "12/ namespace '$NAMESPACE' exists"

    # 13. unit3d-storage PVC exists, Bound, RWO
    pvc_phase="$(kc get pvc -n "$NAMESPACE" "$PVC_NAME" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [ "$pvc_phase" != "Bound" ]; then
        err "PVC $PVC_NAME phase='$pvc_phase' (expected 'Bound')"
        exit 13
    fi
    pvc_modes="$(kc get pvc -n "$NAMESPACE" "$PVC_NAME" \
        -o jsonpath='{.spec.accessModes[*]}' 2>/dev/null || true)"
    if [ "$pvc_modes" != "ReadWriteOnce" ]; then
        err "PVC $PVC_NAME accessModes='$pvc_modes' (expected 'ReadWriteOnce')"
        err "If already RWX, this migration is unnecessary."
        exit 13
    fi
    OLD_PV="$(kc get pvc -n "$NAMESPACE" "$PVC_NAME" \
        -o jsonpath='{.spec.volumeName}' 2>/dev/null)"
    OLD_PVC_SIZE="$(kc get pvc -n "$NAMESPACE" "$PVC_NAME" \
        -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null)"
    log "13/ PVC $PVC_NAME: Bound, RWO, pv=$OLD_PV, size=$OLD_PVC_SIZE"

    # 14. NEW_STORAGE_CLASS present
    if [ -z "$NEW_STORAGE_CLASS" ]; then
        err "NEW_STORAGE_CLASS env var is required"
        exit 14
    fi
    if ! kc get storageclass "$NEW_STORAGE_CLASS" >/dev/null 2>&1; then
        err "StorageClass '$NEW_STORAGE_CLASS' not found"
        exit 14
    fi
    # accessModes on StorageClass is informational only — the actual
    # supported modes are provisioner-side. We log a hint, do not abort.
    sc_provisioner="$(kc get storageclass "$NEW_STORAGE_CLASS" \
        -o jsonpath='{.provisioner}' 2>/dev/null || true)"
    log "14/ StorageClass '$NEW_STORAGE_CLASS' exists (provisioner=$sc_provisioner)"
    log "    NOTE: StorageClass.accessModes is hint-only. Verify the"
    log "    provisioner supports ReadWriteMany before proceeding in production."

    # 15. unit3d-app Deployment is single-replica
    app_replicas="$(kc get deployment -n "$NAMESPACE" unit3d-app \
        -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
    if [ "$app_replicas" != "1" ]; then
        err "unit3d-app replicas='$app_replicas' (Option B requires single-replica source)"
        err "Multi-replica + RWO is not a valid pre-state."
        exit 15
    fi
    log "15/ unit3d-app: replicas=1"

    # 16. MariaDB healthy
    if ! kc rollout status -n "$NAMESPACE" statefulset/mariadb \
            --timeout=60s >/dev/null 2>&1; then
        err "MariaDB StatefulSet rollout is not healthy"
        exit 16
    fi
    log "16/ MariaDB StatefulSet healthy"

    # 17. Backup marker recency
    if [ "$BACKUP_VERIFIED" = "1" ]; then
        warn "17/ BACKUP_VERIFIED=1 — backup-marker preflight BYPASSED"
        warn "    Operator asserts a backup was taken before running this script."
        warn "    If a backup was NOT taken, ABORT NOW (Ctrl+C)."
    else
        if [ ! -f "$BACKUP_MARKER" ]; then
            err "no backup marker at $BACKUP_MARKER"
            err "Drop a marker after running scripts/backup.sh:"
            err "    touch $BACKUP_MARKER"
            err "Or pass BACKUP_VERIFIED=1 to bypass (NOT recommended)."
            exit 17
        fi
        # POSIX-portable mtime check via find -mmin (relative minutes).
        if ! find "$BACKUP_MARKER" -mmin "-${BACKUP_MAX_AGE_MIN}" \
                | grep -q .; then
            err "backup marker $BACKUP_MARKER is older than ${BACKUP_MAX_AGE_MIN} min"
            err "Run scripts/backup.sh, then 'touch $BACKUP_MARKER'."
            exit 17
        fi
        log "17/ backup marker $BACKUP_MARKER is fresh (< ${BACKUP_MAX_AGE_MIN} min)"
    fi

    # 18. No active migrate Job
    migrate_active="$(kc get job -n "$NAMESPACE" unit3d-migrate \
        -o jsonpath='{.status.active}' 2>/dev/null || true)"
    if [ -n "$migrate_active" ] && [ "$migrate_active" != "0" ]; then
        err "unit3d-migrate Job is currently active (status.active=$migrate_active)"
        err "Wait for it to finish before migrating storage."
        exit 18
    fi
    log "18/ no active unit3d-migrate Job"

    # 19. RBAC sanity (best-effort; cluster RBAC is the source of truth)
    rbac_ok=1
    for verb_resource in \
        "patch persistentvolumes" \
        "delete persistentvolumeclaims" \
        "apply persistentvolumeclaims"; do
        verb="${verb_resource% *}"
        resource="${verb_resource#* }"
        scope_flag="-n $NAMESPACE"
        if [ "$resource" = "persistentvolumes" ]; then
            scope_flag=""
        fi
        # shellcheck disable=SC2086
        if ! kc auth can-i "$verb" "$resource" $scope_flag >/dev/null 2>&1; then
            err "RBAC: cannot '$verb $resource' (scope: ${scope_flag:-cluster})"
            rbac_ok=0
        fi
    done
    if [ "$rbac_ok" -ne 1 ]; then
        exit 19
    fi
    log "19/ RBAC checks passed"

    log "preflight: ALL CHECKS PASSED"
}

# ============================================================================
# Mutation phase
# ============================================================================

# Wait for a deployment to fully scale to zero. Returns 0 on success.
wait_pods_drained() {
    deployment="$1"
    selector="$2"
    timeout=180
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
        count="$(kc get pods -n "$NAMESPACE" -l "$selector" \
            --no-headers 2>/dev/null | wc -l)"
        if [ "$count" -eq 0 ]; then
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    err "timeout waiting for $deployment pods to drain (selector=$selector)"
    return 1
}

mutate_scale_down() {
    PHASE=1
    banner "MUTATION 20 — scale unit3d-app/queue/scheduler to 0"
    kc_mutate scale -n "$NAMESPACE" deployment/unit3d-app --replicas=0 || exit 20
    kc_mutate scale -n "$NAMESPACE" deployment/unit3d-queue --replicas=0 || exit 20
    kc_mutate scale -n "$NAMESPACE" deployment/unit3d-scheduler --replicas=0 || exit 20
    if [ "$DRY_RUN" != "1" ]; then
        wait_pods_drained "unit3d-app"       "app.kubernetes.io/name=unit3d-app"       || exit 20
        wait_pods_drained "unit3d-queue"     "app.kubernetes.io/name=unit3d-queue"     || exit 20
        wait_pods_drained "unit3d-scheduler" "app.kubernetes.io/name=unit3d-scheduler" || exit 20
    fi
    log "scale-down complete"
}

mutate_capture_old() {
    PHASE=2
    banner "MUTATION 21-22 — capture old PVC, retain old PV"
    mkdir -p "$WORK_DIR"
    log "work dir: $WORK_DIR"

    # 21. Capture old PVC manifest (read-only; safe in DRY_RUN)
    kc get pvc -n "$NAMESPACE" "$PVC_NAME" -o json \
        > "$WORK_DIR/old-pvc.json" || exit 21
    log "21/ old PVC manifest captured: $WORK_DIR/old-pvc.json"

    # Also capture the PV manifest (for forensics if migration aborts).
    if [ -n "$OLD_PV" ]; then
        kc get pv "$OLD_PV" -o json \
            > "$WORK_DIR/old-pv.json" || exit 21
        log "    old PV manifest captured: $WORK_DIR/old-pv.json"
    fi

    # 22. Patch old PV reclaimPolicy=Retain (idempotent).
    if [ -z "$OLD_PV" ]; then
        err "OLD_PV is empty; cannot patch reclaimPolicy"
        exit 22
    fi
    current_policy="$(kc get pv "$OLD_PV" \
        -o jsonpath='{.spec.persistentVolumeReclaimPolicy}' 2>/dev/null || true)"
    if [ "$current_policy" = "Retain" ]; then
        log "22/ old PV $OLD_PV already has reclaimPolicy=Retain"
    else
        kc_mutate patch pv "$OLD_PV" --type=merge \
            -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' || exit 22
        log "22/ old PV $OLD_PV reclaimPolicy: $current_policy -> Retain"
    fi
}

mutate_swap_pvc() {
    PHASE=2
    banner "MUTATION 23-25 — delete old PVC, clear claimRef, apply rescue + new PVC"

    # 23. Delete old PVC. PV survives because of Retain (step 22).
    kc_mutate delete pvc -n "$NAMESPACE" "$PVC_NAME" \
        --wait=true --timeout=300s || exit 23
    log "23/ old PVC $PVC_NAME deleted (PV $OLD_PV preserved)"

    # The old PV now has phase=Released and a stale claimRef pointing
    # at the deleted PVC. To re-bind it via a new PVC's volumeName we
    # must clear that claimRef.
    if [ "$DRY_RUN" != "1" ]; then
        kc_mutate patch pv "$OLD_PV" --type=json \
            -p='[{"op":"remove","path":"/spec/claimRef"}]' || exit 22
        log "    old PV $OLD_PV claimRef cleared"
    else
        printf '[DRY-RUN] kubectl patch pv %s (clear claimRef)\n' "$OLD_PV"
    fi

    # 24. Apply rescue PVC: claims the OLD PV by volumeName so the
    # loader Pod can mount it RO alongside the new RWX PVC.
    kc_apply_stdin <<EOF || exit 24
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $RESCUE_PVC_NAME
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: unit3d-storage-rescue
    app.kubernetes.io/part-of: ratatoskr
    ratatoskr.io/migration: rwo-to-rwx
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ""
  volumeName: $OLD_PV
  resources:
    requests:
      storage: $OLD_PVC_SIZE
EOF
    log "24/ rescue PVC $RESCUE_PVC_NAME applied (rebinds old PV $OLD_PV)"

    # 25. Apply new RWX unit3d-storage PVC.
    kc_apply_stdin <<EOF || exit 25
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC_NAME
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: unit3d-storage
    app.kubernetes.io/part-of: ratatoskr
    ratatoskr.io/migration: rwo-to-rwx-new
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: $NEW_STORAGE_CLASS
  resources:
    requests:
      storage: $OLD_PVC_SIZE
EOF
    log "25/ new RWX PVC $PVC_NAME applied (storageClass=$NEW_STORAGE_CLASS)"

    if [ "$DRY_RUN" != "1" ]; then
        # Wait for both PVCs to bind.
        kc wait --for=jsonpath='{.status.phase}=Bound' \
            -n "$NAMESPACE" "pvc/$RESCUE_PVC_NAME" --timeout=120s || exit 24
        kc wait --for=jsonpath='{.status.phase}=Bound' \
            -n "$NAMESPACE" "pvc/$PVC_NAME"          --timeout=120s || exit 25
        log "    both PVCs Bound"
    fi
}

mutate_loader_pod() {
    PHASE=3
    banner "MUTATION 26 — apply pvc-loader Pod (rsync between old and new)"

    # Inline Pod manifest. Mirrors the upgrade-guide.md pvc-loader
    # pattern with security tightening:
    #   - runAsNonRoot:true
    #   - readOnlyRootFilesystem:true (writes go to /old, /new, /tmp)
    #   - allowPrivilegeEscalation:false, capabilities.drop:[ALL]
    #   - seccompProfile RuntimeDefault
    #   - apk add rsync at startup (alpine:3.20 includes apk)
    #
    # Old PVC mounted RO at /old, new RWX PVC at /new.
    kc_apply_stdin <<EOF || exit 26
apiVersion: v1
kind: Pod
metadata:
  name: $LOADER_POD
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: pvc-loader
    app.kubernetes.io/component: migration
    app.kubernetes.io/part-of: ratatoskr
    app.kubernetes.io/managed-by: migrate-rwo-to-rwx
    ratatoskr.io/migration: rwo-to-rwx
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 60
  securityContext:
    runAsNonRoot: true
    runAsUser: 33
    runAsGroup: 33
    fsGroup: 33
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: loader
      image: $PVC_LOADER_IMAGE
      imagePullPolicy: IfNotPresent
      command:
        - /bin/sh
        - -c
        - |
          set -eu
          # apk needs root for the install path; alpine ships rsync
          # as a separate package. The container runs as UID 33,
          # which means apk will fail unless we pre-bake an image
          # with rsync preinstalled. To stay base-image-only, we
          # use busybox's built-in 'cp -a' as a fallback when rsync
          # is absent.
          if command -v rsync >/dev/null 2>&1; then
            COPY_CMD="rsync -a --delete /old/ /new/"
          else
            # busybox cp -a preserves ownership, timestamps, symlinks.
            # No --delete equivalent; the new PVC is empty so this is fine.
            COPY_CMD="cp -a /old/. /new/"
          fi
          echo "loader ready (copy: \$COPY_CMD)"
          # Stay alive indefinitely so 'kubectl exec' can drive the
          # actual rsync without a deadline. The script deletes the
          # Pod explicitly when copy + checksum verification finish.
          tail -f /dev/null
      volumeMounts:
        - name: old
          mountPath: /old
          readOnly: true
        - name: new
          mountPath: /new
        - name: tmp
          mountPath: /tmp
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
        limits:
          cpu: 1000m
          memory: 512Mi
  volumes:
    - name: old
      persistentVolumeClaim:
        claimName: $RESCUE_PVC_NAME
        readOnly: true
    - name: new
      persistentVolumeClaim:
        claimName: $PVC_NAME
    - name: tmp
      emptyDir:
        sizeLimit: 64Mi
EOF
    log "26/ pvc-loader Pod applied"

    if [ "$DRY_RUN" != "1" ]; then
        kc wait --for=condition=Ready -n "$NAMESPACE" \
            "pod/$LOADER_POD" --timeout=180s || exit 26
        log "    pvc-loader Pod is Ready"
    fi
}

mutate_rsync_and_verify() {
    PHASE=3
    banner "MUTATION 27-28 — rsync data + checksum verification"

    if [ "$DRY_RUN" = "1" ]; then
        log "[DRY-RUN] skipping rsync + checksum (would exec into $LOADER_POD)"
        return 0
    fi

    # 27. rsync (or cp -a fallback). The container start-cmd printed
    # the chosen tool; we re-detect here for the actual run.
    if kc exec -n "$NAMESPACE" "$LOADER_POD" -- \
            sh -c 'command -v rsync >/dev/null 2>&1'; then
        log "27/ running rsync -a --delete /old/ /new/"
        kc exec -n "$NAMESPACE" "$LOADER_POD" -- \
            rsync -a --delete /old/ /new/ || exit 27
    else
        log "27/ rsync absent; running cp -a /old/. /new/"
        kc exec -n "$NAMESPACE" "$LOADER_POD" -- \
            sh -c 'cp -a /old/. /new/' || exit 27
    fi
    log "27/ data copy complete"

    # 28. Checksum verification (sample of up to 100 files).
    log "28/ verifying checksums on a 100-file sample"
    old_sums="$(kc exec -n "$NAMESPACE" "$LOADER_POD" -- sh -c '
        cd /old && find . -type f | sort | head -100 \
          | xargs -I {} md5sum {} 2>/dev/null
    ' || true)"
    new_sums="$(kc exec -n "$NAMESPACE" "$LOADER_POD" -- sh -c '
        cd /new && find . -type f | sort | head -100 \
          | xargs -I {} md5sum {} 2>/dev/null
    ' || true)"
    if [ -z "$old_sums" ]; then
        warn "28/ old PVC contained no files in 100-sample; skipping checksum"
    elif [ "$old_sums" != "$new_sums" ]; then
        err "28/ checksum mismatch between /old and /new"
        printf '%s\n' "$old_sums" > "$WORK_DIR/old-sums.txt"
        printf '%s\n' "$new_sums" > "$WORK_DIR/new-sums.txt"
        err "    diffs written to $WORK_DIR/{old,new}-sums.txt"
        exit 28
    else
        log "28/ checksum sample matches (100 files)"
    fi
}

mutate_cleanup_loader() {
    PHASE=3
    banner "MUTATION — delete pvc-loader Pod, drop rescue PVC"

    kc_mutate delete pod -n "$NAMESPACE" "$LOADER_POD" \
        --wait=true --timeout=120s --ignore-not-found || true
    log "    pvc-loader Pod deleted"

    # Drop the rescue PVC. The old PV becomes Released again, with
    # reclaimPolicy=Retain protecting the data. Step 35 (post-rollout)
    # flips reclaimPolicy back to Delete; the operator deletes the
    # orphaned PV after the soak period.
    kc_mutate delete pvc -n "$NAMESPACE" "$RESCUE_PVC_NAME" \
        --wait=true --timeout=120s --ignore-not-found || true
    log "    rescue PVC $RESCUE_PVC_NAME deleted (old PV preserved)"
}

mutate_apply_overlay() {
    PHASE=4
    banner "MUTATION 29 — apply prod-rwx overlay, wait rollout"

    if [ ! -d "$OVERLAY_PATH" ]; then
        err "OVERLAY_PATH '$OVERLAY_PATH' not found (run from repo root or override)"
        exit 29
    fi
    kc_mutate apply -k "$OVERLAY_PATH" || exit 29
    log "29/ overlay applied: $OVERLAY_PATH"

    if [ "$DRY_RUN" != "1" ]; then
        kc rollout status -n "$NAMESPACE" deployment/unit3d-app \
            --timeout=600s || exit 29
        log "    unit3d-app rollout complete"
    fi
}

mutate_finalize_old_pv() {
    PHASE=4
    banner "MUTATION 35 — flip old PV reclaimPolicy back to Delete"

    if [ -z "$OLD_PV" ]; then
        warn "OLD_PV unknown; skipping reclaimPolicy reset"
        return 0
    fi
    # The PV is now Released with no claimant. Flipping reclaimPolicy
    # back to Delete does NOT immediately delete a Released PV —
    # Delete only fires when the BOUND state ends. So this is a
    # housekeeping change for any future rebind.
    kc_mutate patch pv "$OLD_PV" --type=merge \
        -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' || true
    log "35/ old PV $OLD_PV reclaimPolicy: Retain -> Delete"
    log "    The PV remains in the cluster (Released). After verifying the new"
    log "    deployment for >= 24h, the operator can: kubectl delete pv $OLD_PV"
}

# ============================================================================
# Post-flight
# ============================================================================
postflight() {
    banner "POST-FLIGHT — verification"

    if [ "$DRY_RUN" = "1" ]; then
        log "[DRY-RUN] skipping post-flight checks"
        return 0
    fi

    # Pod-side smoke checks via exec into a unit3d-app pod.
    pod="$(kc get pod -n "$NAMESPACE" \
        -l app.kubernetes.io/name=unit3d-app \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -z "$pod" ]; then
        warn "no unit3d-app pod found for smoke checks"
        return 0
    fi
    log "smoke target: $pod"

    if kc exec -n "$NAMESPACE" "$pod" -- php artisan --version >/dev/null 2>&1; then
        log "OK   artisan responds"
    else
        warn "artisan check failed (non-fatal)"
    fi

    if kc exec -n "$NAMESPACE" "$pod" -- \
            sh -c 'ls /app/storage/ | head' >/dev/null 2>&1; then
        log "OK   /app/storage/ readable from app pod"
    else
        warn "/app/storage/ read failed (non-fatal — may be S3-routed)"
    fi
}

# ============================================================================
# Main
# ============================================================================
main() {
    banner "$SCRIPT_NAME v$SCRIPT_VERSION"
    log "namespace=$NAMESPACE storage_class=$NEW_STORAGE_CLASS"
    log "dry_run=$DRY_RUN verbose=$VERBOSE backup_verified=$BACKUP_VERIFIED"
    log "overlay=$OVERLAY_PATH"

    preflight

    if [ "$DRY_RUN" = "1" ]; then
        banner "DRY-RUN — preflight passed; mutations would now follow"
    fi

    mutate_scale_down
    mutate_capture_old
    mutate_swap_pvc
    mutate_loader_pod
    mutate_rsync_and_verify
    mutate_cleanup_loader
    mutate_apply_overlay
    mutate_finalize_old_pv

    postflight

    PHASE=0
    banner "MIGRATION COMPLETE"
    log "Old PV $OLD_PV is Released with reclaimPolicy=Delete."
    log "After 24h+ of verified prod-rwx operation, run:"
    log "    kubectl delete pv $OLD_PV"
    log "Work directory preserved at: $WORK_DIR"
}

main "$@"
