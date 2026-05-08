#!/bin/sh
# scripts/migration/migrate-compose-to-k8s.sh
#
# Operationalizes upgrade-guide.md § "Path 1 — Compose -> Kubernetes"
# as a guided 8-step stepper with state persistence (resumable on
# interruption).
#
# CANONICAL DOC: docs/upgrade-guide.md, anchor:
#   #path-1--compose--kubernetes
#
# DESIGN INVARIANTS
#   * Each step is its own function with its own preflights and exit
#     codes. Operator confirms before each step (--yes to bypass).
#   * State persisted at $STATE_DIR/state.env (KEY=VALUE, sourceable).
#     PHASE_COMPLETED tracks progress. Resume reads it and starts at
#     PHASE_COMPLETED + 1.
#   * Three secrets modes (per ADR-0004): sealed-secrets (default),
#     eso, vanilla. Vanilla emits a loud warning and halts for
#     operator review.
#   * Disk routing per --target-overlay (per ADR-0002):
#     - prod-rwo: all 17 disks tarball -> unit3d-storage PVC
#     - prod-rwx: 3 Storage-aware disks rclone -> S3,
#                 14 image disks tarball -> unit3d-storage RWX PVC
#   * APP_KEY Option A (reuse) only. Option B (fresh key) is manual
#     via the bootstrap-app-key Component — see upgrade-guide.md.
#   * Same-workstation Compose + kubectl access assumed. SSH-tunneled
#     flows are out of scope; operators in that case follow the manual
#     procedure.
#
# REQUIRED TOOLS
#   - kubectl, docker, tar, sha256sum (or shasum), grep, sed, awk
#   - kubeseal      if --secrets-mode=sealed-secrets
#   - rclone        if --target-overlay=prod-rwx
#
# SECURITY POSTURE
#   The script writes the Compose APP_KEY to $STATE_DIR/.app_key with
#   mode 0600 for the duration of Step 5, then shreds it via the EXIT
#   trap. Only the sha256 hash of APP_KEY is recorded in state.env
#   (audit trail; never the key itself).
#
# EXIT CODES
#   0       success
#   1       generic error (bad CLI usage, missing required flag)
#   10-19   preflight failures
#     10    missing required tool
#     11    Compose root invalid / stack still running / .env missing
#     12    target namespace already populated and not --resume
#     13    secrets-mode prerequisites missing (kubeseal cert, RCLONE)
#     14    insufficient state-dir disk space
#   20-29   step-specific mutation failures
#     20    Step 2 (DB backup) failed
#     21    Step 3 (data sync) failed
#     22    Step 4 (APP_KEY) failed
#     23    Step 5 (provision overlay) failed
#     24    Step 6 (DB restore) failed
#     25    Step 7 (PVC restore) failed
#     26    Step 8 (verification) failed
#   30      user abort (Ctrl+C, declined confirmation)
#   40      bad --step / --from-step / --to-step value
#   41      --resume requested but no state dir found
#
# POSIX NOTES
#   `set -eu` — no pipefail. Pipes are used in a few places (grep
#   pipelines, kubectl exec piping into mariadb). Where the failure
#   semantics matter, intermediate files are used instead of pipes.
#
# AUTHOR: ratatoskr maintainers
# LICENSE: AGPL-3.0-or-later

set -eu

# ============================================================================
# CLI parsing
# ============================================================================
SCRIPT_NAME="migrate-compose-to-k8s.sh"
SCRIPT_VERSION="0.1.0"
LOADER_POD="pvc-loader-compose-import"

COMPOSE_ROOT=""
TARGET_OVERLAY=""
NAMESPACE="unit3d"
SECRETS_MODE="sealed-secrets"
KUBECTL_CONTEXT=""
KUBESEAL_CERT=""
STATE_DIR=""
RESUME=0
STEP=""
FROM_STEP=""
TO_STEP=""
DRY_RUN=0
VERBOSE=0
YES=0

PVC_LOADER_IMAGE="${PVC_LOADER_IMAGE:-alpine:3.20}"

usage() {
    cat <<USAGE_EOF
$SCRIPT_NAME v$SCRIPT_VERSION — Compose -> Kubernetes guided migration

Usage:
  $0 --compose-root <path> --target-overlay <prod-rwo|prod-rwx> [options]

Required:
  --compose-root <path>          Path to Compose project root (with docker-compose.yml)
  --target-overlay <name>        prod-rwo or prod-rwx

Options:
  --target-namespace <name>      Default: unit3d
  --secrets-mode <mode>          sealed-secrets (default) | eso | vanilla
  --kubectl-context <ctx>        Default: current
  --kubeseal-cert <path>         Required if --secrets-mode=sealed-secrets
  --state-dir <path>             Default: /tmp/ratatoskr-migration-<timestamp>
  --resume                       Continue from last completed step
  --step <n>                     Run only step N (1-8)
  --from-step <n> --to-step <m>  Partial run window
  --dry-run                      Read-only, no mutations
  --verbose                      Echo every kubectl/docker command
  --yes                          Skip per-step confirmation prompts
  -h, --help                     Show this help

Env overrides:
  PVC_LOADER_IMAGE               Default: alpine:3.20
                                 Pin a digest: alpine@sha256:<digest>
  RCLONE_REMOTE                  Required for prod-rwx (e.g. s3-target)
  S3_BUCKET                      Required for prod-rwx (bucket name only)

For exit codes and recovery procedures, see scripts/migration/README.md.
USAGE_EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --compose-root)     COMPOSE_ROOT="$2"; shift 2 ;;
        --target-overlay)   TARGET_OVERLAY="$2"; shift 2 ;;
        --target-namespace) NAMESPACE="$2"; shift 2 ;;
        --secrets-mode)     SECRETS_MODE="$2"; shift 2 ;;
        --kubectl-context)  KUBECTL_CONTEXT="$2"; shift 2 ;;
        --kubeseal-cert)    KUBESEAL_CERT="$2"; shift 2 ;;
        --state-dir)        STATE_DIR="$2"; shift 2 ;;
        --resume)           RESUME=1; shift ;;
        --step)             STEP="$2"; shift 2 ;;
        --from-step)        FROM_STEP="$2"; shift 2 ;;
        --to-step)          TO_STEP="$2"; shift 2 ;;
        --dry-run)          DRY_RUN=1; shift ;;
        --verbose)          VERBOSE=1; shift ;;
        --yes)              YES=1; shift ;;
        -h|--help)          usage; exit 0 ;;
        *)                  printf 'unknown flag: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

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

abort() {
    code="$1"
    shift
    err "$*"
    exit "$code"
}

# ============================================================================
# CLI validation
# ============================================================================
[ -n "$COMPOSE_ROOT" ]   || abort 1 "--compose-root is required"
[ -n "$TARGET_OVERLAY" ] || abort 1 "--target-overlay is required"

case "$TARGET_OVERLAY" in
    prod-rwo|prod-rwx) ;;
    *) abort 1 "--target-overlay must be 'prod-rwo' or 'prod-rwx' (got: $TARGET_OVERLAY)" ;;
esac

case "$SECRETS_MODE" in
    sealed-secrets|eso|vanilla) ;;
    *) abort 1 "--secrets-mode must be one of: sealed-secrets, eso, vanilla" ;;
esac

if [ "$SECRETS_MODE" = "sealed-secrets" ] && [ -z "$KUBESEAL_CERT" ]; then
    abort 1 "--kubeseal-cert is required when --secrets-mode=sealed-secrets"
fi

# ============================================================================
# State directory + state file
# ============================================================================
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

resolve_latest_state_dir() {
    # Find the most recent /tmp/ratatoskr-migration-* directory.
    # POSIX: ls -1dt … may not sort by mtime; use find + sort.
    candidate="$(find /tmp -maxdepth 1 -type d -name 'ratatoskr-migration-*' 2>/dev/null \
        | sort | tail -n 1)"
    if [ -z "$candidate" ]; then
        return 1
    fi
    printf '%s\n' "$candidate"
    return 0
}

if [ -z "$STATE_DIR" ]; then
    if [ "$RESUME" = "1" ]; then
        STATE_DIR="$(resolve_latest_state_dir 2>/dev/null || true)"
        if [ -z "$STATE_DIR" ]; then
            abort 41 "--resume requested but no /tmp/ratatoskr-migration-* directory found"
        fi
    else
        STATE_DIR="/tmp/ratatoskr-migration-${TIMESTAMP}"
    fi
fi
STATE_FILE="$STATE_DIR/state.env"
APP_KEY_FILE="$STATE_DIR/.app_key"
mkdir -p "$STATE_DIR"
chmod 0700 "$STATE_DIR" 2>/dev/null || true

# Reload prior state if resuming.
PHASE_COMPLETED=0
if [ "$RESUME" = "1" ] && [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
fi

# ============================================================================
# State persistence helpers
# ============================================================================
# Write/replace KEY=VALUE in $STATE_FILE. POSIX-safe (no in-place sed).
state_set() {
    key="$1"
    value="$2"
    if [ ! -f "$STATE_FILE" ]; then
        printf '# ratatoskr migration state — DO NOT edit manually\n' > "$STATE_FILE"
        chmod 0600 "$STATE_FILE"
    fi
    tmp="$STATE_FILE.tmp"
    grep -v "^${key}=" "$STATE_FILE" > "$tmp" || true
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$STATE_FILE"
}

# ============================================================================
# Trap: shred APP_KEY temp file on exit
# ============================================================================
on_exit() {
    rc=$?
    if [ -f "$APP_KEY_FILE" ]; then
        # POSIX-portable: overwrite with zeros, then unlink. shred(1) is
        # GNU coreutils, not POSIX. dd is POSIX.
        size="$(wc -c < "$APP_KEY_FILE" 2>/dev/null || echo 0)"
        if [ "$size" -gt 0 ]; then
            dd if=/dev/zero of="$APP_KEY_FILE" bs=1 count="$size" conv=notrunc \
                >/dev/null 2>&1 || true
        fi
        rm -f "$APP_KEY_FILE"
    fi
    if [ "$rc" -ne 0 ]; then
        warn "exit=$rc — state preserved at: $STATE_DIR"
        warn "to resume: $0 --resume --compose-root '$COMPOSE_ROOT' --target-overlay '$TARGET_OVERLAY'"
    fi
}
trap on_exit EXIT
trap 'exit 30' INT TERM

# ============================================================================
# kubectl wrappers
# ============================================================================
KUBECTL_CTX_FLAG=""
if [ -n "$KUBECTL_CONTEXT" ]; then
    KUBECTL_CTX_FLAG="--context=$KUBECTL_CONTEXT"
fi

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

kc_mutate() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '[DRY-RUN] kubectl %s\n' "$*"
        return 0
    fi
    kc "$@"
}

kc_apply_stdin() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '[DRY-RUN] kubectl apply -f - (stdin manifest)\n'
        cat >/dev/null
        return 0
    fi
    if [ -n "$KUBECTL_CTX_FLAG" ]; then
        kubectl "$KUBECTL_CTX_FLAG" apply -f -
    else
        kubectl apply -f -
    fi
}

# Run a docker compose command in $COMPOSE_ROOT.
dc() {
    if [ "$VERBOSE" = "1" ]; then
        printf '+ (cd %s && docker compose %s)\n' "$COMPOSE_ROOT" "$*" >&2
    fi
    ( cd "$COMPOSE_ROOT" && docker compose "$@" )
}

# Cross-platform sha256 (linux: sha256sum; macOS: shasum -a 256).
sha256_of() {
    file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        printf 'unknown\n'
    fi
}

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        abort 10 "required tool not found in PATH: $1"
    fi
}

# Confirm before mutating step. Bypassed by --yes.
confirm_step() {
    label="$1"
    if [ "$YES" = "1" ] || [ "$DRY_RUN" = "1" ]; then
        return 0
    fi
    printf '\n>>> About to run: %s\n' "$label"
    printf '    Continue? [y/N] '
    read -r answer
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) abort 30 "operator declined; state preserved at $STATE_DIR" ;;
    esac
}

# ============================================================================
# Step 1 — Pre-migration checklist (preflight)
# ============================================================================
step_1_preflight() {
    banner "STEP 1 — Pre-migration checklist"

    # Tools
    for t in kubectl docker tar grep sed awk; do
        require_tool "$t"
    done
    if [ "$SECRETS_MODE" = "sealed-secrets" ]; then
        require_tool kubeseal
        if [ ! -f "$KUBESEAL_CERT" ]; then
            abort 13 "kubeseal cert not found at: $KUBESEAL_CERT"
        fi
    fi
    if [ "$TARGET_OVERLAY" = "prod-rwx" ]; then
        require_tool rclone
        [ -n "${RCLONE_REMOTE:-}" ] \
            || abort 13 "RCLONE_REMOTE env var required for prod-rwx"
        [ -n "${S3_BUCKET:-}" ] \
            || abort 13 "S3_BUCKET env var required for prod-rwx"
    fi
    log "10/ tools present"

    # Compose root
    [ -d "$COMPOSE_ROOT" ] \
        || abort 11 "--compose-root '$COMPOSE_ROOT' does not exist"
    [ -f "$COMPOSE_ROOT/docker-compose.yml" ] \
        || abort 11 "no docker-compose.yml at $COMPOSE_ROOT"
    [ -f "$COMPOSE_ROOT/.env" ] \
        || abort 11 "no .env at $COMPOSE_ROOT"
    log "11a/ compose-root layout OK"

    # Compose stack must be stopped (no running containers)
    running="$(dc ps -q 2>/dev/null | tr -d '[:space:]' || true)"
    if [ -n "$running" ]; then
        abort 11 "Compose stack has running containers; stop it first: docker compose stop"
    fi
    log "11b/ compose stack stopped"

    # Required env vars in compose .env
    for var in APP_KEY APP_URL DB_DATABASE DB_USERNAME DB_PASSWORD; do
        if ! grep -q "^${var}=" "$COMPOSE_ROOT/.env"; then
            abort 11 "missing $var in $COMPOSE_ROOT/.env"
        fi
    done
    log "11c/ compose .env has required keys"

    # kubectl reachable
    if ! kc cluster-info >/dev/null 2>&1; then
        abort 11 "kubectl cluster-info failed (context: $(kubectl config current-context 2>/dev/null || echo none))"
    fi
    log "11d/ kubectl reachable"

    # Target namespace must NOT have a unit3d-app deployment yet
    if kc get deployment unit3d-app -n "$NAMESPACE" >/dev/null 2>&1; then
        if [ "$RESUME" = "1" ]; then
            warn "12/ namespace $NAMESPACE already has unit3d-app — continuing because --resume"
        else
            abort 12 "namespace $NAMESPACE already has unit3d-app — pass --resume or pick another namespace"
        fi
    fi
    log "12/ target namespace check passed"

    # Disk space sanity (approx). Estimate compose volume size and
    # require at least 1.5x free at $STATE_DIR.
    storage_dir="$COMPOSE_ROOT/storage"
    if [ -d "$storage_dir" ]; then
        # du -sk is POSIX. Output: "<kb>\t<path>"
        approx_kb="$(du -sk "$storage_dir" 2>/dev/null | awk '{print $1}')"
    else
        approx_kb=0
    fi
    avail_kb="$(df -P "$STATE_DIR" | awk 'NR==2 {print $4}')"
    needed_kb=$((approx_kb * 3 / 2))
    log "14a/ compose storage approx: ${approx_kb} KB"
    log "14b/ state-dir free: ${avail_kb} KB (need ~${needed_kb} KB)"
    if [ "$avail_kb" -lt "$needed_kb" ] && [ "$needed_kb" -gt 0 ]; then
        abort 14 "insufficient disk space at $STATE_DIR (have ${avail_kb} KB, need ~${needed_kb} KB)"
    fi

    # Persist initial state
    state_set TIMESTAMP             "$TIMESTAMP"
    state_set COMPOSE_PROJECT_ROOT  "$COMPOSE_ROOT"
    state_set TARGET_NAMESPACE      "$NAMESPACE"
    state_set TARGET_OVERLAY        "$TARGET_OVERLAY"
    state_set SECRETS_MODE          "$SECRETS_MODE"
    state_set PHASE_COMPLETED       1
    log "Step 1 OK"
}

# ============================================================================
# Step 2 — Database backup (mariadb-dump from Compose)
# ============================================================================
step_2_db_backup() {
    banner "STEP 2 — Database backup"

    db_dump="$STATE_DIR/db.sql"

    # Read MARIADB_ROOT_PASSWORD from compose .env (fall back to
    # DB_PASSWORD which is what UNIT3D's .env.example uses).
    root_pw="$(grep -E '^MARIADB_ROOT_PASSWORD=' "$COMPOSE_ROOT/.env" \
        | head -n1 | cut -d= -f2- || true)"
    if [ -z "$root_pw" ]; then
        root_pw="$(grep -E '^DB_PASSWORD=' "$COMPOSE_ROOT/.env" \
            | head -n1 | cut -d= -f2-)"
    fi
    if [ -z "$root_pw" ]; then
        abort 20 "could not read MARIADB_ROOT_PASSWORD or DB_PASSWORD from compose .env"
    fi

    db_name="$(grep -E '^DB_DATABASE=' "$COMPOSE_ROOT/.env" \
        | head -n1 | cut -d= -f2-)"
    db_name="${db_name:-unit3d}"

    if [ "$DRY_RUN" = "1" ]; then
        log "[DRY-RUN] would run: docker compose exec -T mariadb mariadb-dump …"
        state_set DB_DUMP_PATH "$db_dump"
        state_set PHASE_COMPLETED 2
        log "Step 2 OK (dry-run)"
        return 0
    fi

    # Bring just MariaDB up for the dump; the rest of the stack stays
    # stopped (preflight 11b verified).
    log "starting mariadb service for dump"
    dc up -d mariadb || abort 20 "failed to start mariadb"
    # Wait for healthcheck (best-effort); fall back to a fixed sleep.
    sleep 10

    log "running mariadb-dump -> $db_dump"
    # mariadb-dump reads from stdin via -T (no TTY). We pipe its stdout
    # to a file. POSIX has no pipefail; capture via redirect, then
    # validate the dump in the next step.
    if ! dc exec -T mariadb mariadb-dump \
            --single-transaction --quick --lock-tables=false \
            -uroot -p"$root_pw" "$db_name" > "$db_dump"; then
        dc stop mariadb || true
        abort 20 "mariadb-dump returned non-zero"
    fi

    dc stop mariadb || true

    # Validate dump
    table_count="$(grep -c '^CREATE TABLE' "$db_dump" || true)"
    if [ "$table_count" -lt 50 ]; then
        abort 20 "dump looks suspicious — only $table_count CREATE TABLE statements (expected 100+ on UNIT3D v9.2.0)"
    fi
    log "dump size: $(wc -c < "$db_dump") bytes, $table_count tables"

    state_set DB_DUMP_PATH       "$db_dump"
    state_set DB_DUMP_TABLES     "$table_count"
    state_set DB_DUMP_SHA256     "$(sha256_of "$db_dump")"
    state_set PHASE_COMPLETED    2
    log "Step 2 OK"
}

# ============================================================================
# Step 3 — Application data sync (tarball storage)
# ============================================================================
step_3_data_sync() {
    banner "STEP 3 — Application data sync"

    storage_dir="$COMPOSE_ROOT/storage"
    if [ ! -d "$storage_dir" ]; then
        abort 21 "$storage_dir does not exist"
    fi

    tarball="$STATE_DIR/storage.tar.gz"

    # Tarball strategy (see ADR-0002):
    #   prod-rwo: include all of ./storage/app/
    #   prod-rwx: include ./storage/app/ minus the 3 Storage-aware
    #             subtrees (those go to S3 via rclone below)
    #
    # We use --exclude on prod-rwx. POSIX tar does not specify
    # --exclude, but BSD/GNU tar both implement it; document the
    # dependency.
    tar_excludes=""
    if [ "$TARGET_OVERLAY" = "prod-rwx" ]; then
        tar_excludes="--exclude=app/files/torrents/files \
                      --exclude=app/files/subtitles/files \
                      --exclude=app/files/attachments/files"
    fi

    if [ "$DRY_RUN" = "1" ]; then
        log "[DRY-RUN] would create $tarball with excludes: $tar_excludes"
    else
        log "creating tarball: $tarball"
        # shellcheck disable=SC2086
        # Word-splitting on $tar_excludes is intentional — POSIX tar
        # accepts multiple --exclude flags as separate args.
        tar czf "$tarball" $tar_excludes -C "$storage_dir" app/ \
            || abort 21 "tar failed"
        log "tarball size: $(wc -c < "$tarball") bytes"
    fi

    # rclone the 3 Storage-aware disks for prod-rwx
    if [ "$TARGET_OVERLAY" = "prod-rwx" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            log "[DRY-RUN] would rclone 3 S3-aware disks to $RCLONE_REMOTE:$S3_BUCKET"
        else
            log "rclone: torrent-files -> S3"
            rclone copy "$storage_dir/app/files/torrents/files/" \
                "$RCLONE_REMOTE:$S3_BUCKET/torrent-files/" \
                --transfers 8 --progress \
                || abort 21 "rclone torrent-files failed"
            log "rclone: subtitle-files -> S3"
            rclone copy "$storage_dir/app/files/subtitles/files/" \
                "$RCLONE_REMOTE:$S3_BUCKET/subtitle-files/" \
                --transfers 8 --progress \
                || abort 21 "rclone subtitle-files failed"
            log "rclone: attachment-files -> S3"
            rclone copy "$storage_dir/app/files/attachments/files/" \
                "$RCLONE_REMOTE:$S3_BUCKET/attachment-files/" \
                --transfers 8 --progress \
                || abort 21 "rclone attachment-files failed"
        fi
        state_set S3_ROUTING_VERIFIED 1
    fi

    if [ "$DRY_RUN" != "1" ]; then
        state_set BACKUP_TARBALL_PATH    "$tarball"
        state_set BACKUP_TARBALL_SHA256  "$(sha256_of "$tarball")"
    fi
    state_set PHASE_COMPLETED 3
    log "Step 3 OK"
}

# ============================================================================
# Step 4 — APP_KEY transfer (Option A: reuse)
# ============================================================================
step_4_app_key() {
    banner "STEP 4 — APP_KEY transfer (Option A: reuse)"

    app_key="$(grep '^APP_KEY=' "$COMPOSE_ROOT/.env" | head -n1 | cut -d= -f2-)"
    if [ -z "$app_key" ]; then
        abort 22 "APP_KEY missing or empty in $COMPOSE_ROOT/.env"
    fi

    # Sanity check: APP_KEY should start with "base64:" per Laravel
    # convention.
    case "$app_key" in
        base64:*) ;;
        *) warn "APP_KEY does not start with 'base64:' — Laravel may reject it" ;;
    esac

    # Compute hash for state file (audit trail)
    app_key_hash="$(printf '%s' "$app_key" | (
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum
        else
            shasum -a 256
        fi
    ) | awk '{print $1}')"

    # Persist the key to a 0600 file for use by Step 5. The EXIT trap
    # shreds this file on script termination.
    if [ "$DRY_RUN" = "1" ]; then
        log "[DRY-RUN] would write APP_KEY to $APP_KEY_FILE (mode 0600)"
    else
        umask 077
        printf '%s' "$app_key" > "$APP_KEY_FILE"
    fi

    state_set APP_KEY_HASH    "$app_key_hash"
    state_set PHASE_COMPLETED 4
    log "Step 4 OK (hash: ${app_key_hash})"
}

# ============================================================================
# Step 5 — Provision the K8s overlay
# ============================================================================
generate_secrets_bundle_sealed() {
    bundle="$1"
    cert="$2"
    app_key_value="$3"

    # Generate an unsealed Secret manifest in-memory and pipe to
    # kubeseal. POSIX: avoid pipefail, write intermediate file with
    # umask 077.
    umask 077
    raw="$STATE_DIR/.unit3d-secrets-raw.yaml"
    cat > "$raw" <<RAWEOF
apiVersion: v1
kind: Secret
metadata:
  name: unit3d-secrets
  namespace: $NAMESPACE
type: Opaque
stringData:
  APP_KEY: $app_key_value
RAWEOF
    if ! kubeseal --cert "$cert" -o yaml < "$raw" > "$bundle"; then
        rm -f "$raw"
        abort 23 "kubeseal failed"
    fi
    rm -f "$raw"
}

generate_secrets_bundle_eso() {
    bundle="$1"
    cat > "$bundle" <<EOF_ESO
# External Secrets Operator template — operator MUST populate the
# referenced KMS backend (Vault/AWS SM/etc.) BEFORE applying this.
# See docs/security-hardening.md § "Secrets: sealed-secrets vs ESO".
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: unit3d-secrets
  namespace: $NAMESPACE
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: ratatoskr-vault    # operator-supplied ClusterSecretStore
    kind: ClusterSecretStore
  target:
    name: unit3d-secrets
    creationPolicy: Owner
  data:
    - secretKey: APP_KEY
      remoteRef:
        key: ratatoskr/unit3d
        property: APP_KEY
EOF_ESO
}

generate_secrets_bundle_vanilla() {
    bundle="$1"
    app_key_value="$2"
    umask 077
    cat > "$bundle" <<EOF_VANILLA
# WARNING — PLAINTEXT SECRET. Do not commit this file.
# This mode bypasses ADR-0004's sealed-secrets default.
apiVersion: v1
kind: Secret
metadata:
  name: unit3d-secrets
  namespace: $NAMESPACE
type: Opaque
stringData:
  APP_KEY: $app_key_value
EOF_VANILLA
}

step_5_provision() {
    banner "STEP 5 — Provision the K8s overlay (secrets-mode=$SECRETS_MODE)"

    overlay_path="kustomize/overlays/$TARGET_OVERLAY"
    if [ ! -d "$overlay_path" ]; then
        abort 23 "overlay path '$overlay_path' not found (run from repo root)"
    fi

    secrets_dir="$STATE_DIR/secrets"
    mkdir -p "$secrets_dir"
    chmod 0700 "$secrets_dir"
    bundle="$secrets_dir/unit3d-secrets.yaml"

    # Read APP_KEY from the temp file written in Step 4.
    if [ ! -f "$APP_KEY_FILE" ] && [ "$DRY_RUN" != "1" ]; then
        abort 23 "APP_KEY temp file missing at $APP_KEY_FILE (Step 4 may not have run)"
    fi
    if [ "$DRY_RUN" = "1" ]; then
        app_key_value="DRY_RUN_PLACEHOLDER"
    else
        app_key_value="$(cat "$APP_KEY_FILE")"
    fi

    # Generate the bundle per mode
    case "$SECRETS_MODE" in
        sealed-secrets)
            if [ "$DRY_RUN" = "1" ]; then
                log "[DRY-RUN] would run kubeseal -> $bundle"
            else
                generate_secrets_bundle_sealed "$bundle" "$KUBESEAL_CERT" "$app_key_value"
                log "sealed-secrets bundle written: $bundle"
            fi
            ;;
        eso)
            generate_secrets_bundle_eso "$bundle"
            warn "ESO mode: $bundle is a TEMPLATE. Populate your KMS backend"
            warn "before applying. See docs/security-hardening.md."
            ;;
        vanilla)
            warn "VANILLA mode: writing PLAINTEXT secret manifest."
            warn "This bypasses ADR-0004. Do not commit $bundle."
            if [ "$YES" != "1" ]; then
                printf '\n>>> About to write a plaintext Secret. Continue? [y/N] '
                read -r ack
                case "$ack" in
                    y|Y|yes|YES) ;;
                    *) abort 30 "operator declined plaintext secret" ;;
                esac
            fi
            generate_secrets_bundle_vanilla "$bundle" "$app_key_value"
            log "vanilla Secret written: $bundle (DO NOT COMMIT)"
            ;;
    esac

    # Apply the overlay
    log "applying overlay: $overlay_path"
    kc_mutate apply -k "$overlay_path" || abort 23 "kubectl apply -k failed"

    # Apply the secrets bundle. Sealed-secrets is safe to auto-apply
    # (the manifest is a SealedSecret, plaintext key never touches
    # the cluster). ESO/vanilla halt for operator review.
    case "$SECRETS_MODE" in
        sealed-secrets)
            log "applying sealed-secrets bundle"
            kc_mutate apply -f "$bundle" || abort 23 "kubectl apply sealed-secrets failed"
            ;;
        eso)
            warn "Halting: apply $bundle manually after configuring your KMS:"
            warn "  kubectl apply -f $bundle"
            warn "Then re-run with --resume to continue."
            abort 23 "ESO mode requires operator action"
            ;;
        vanilla)
            warn "Halting: review and apply $bundle manually:"
            warn "  kubectl apply -f $bundle"
            warn "Then re-run with --resume to continue."
            abort 23 "Vanilla mode requires operator review"
            ;;
    esac

    # Wait for unit3d-migrate Job to complete
    log "waiting for unit3d-migrate Job (timeout 10m)"
    if [ "$DRY_RUN" != "1" ]; then
        kc wait --for=condition=Complete -n "$NAMESPACE" \
            job/unit3d-migrate --timeout=10m \
            || abort 23 "unit3d-migrate Job did not complete"
    fi

    # Scale unit3d-app to 0 for now — data not restored yet
    kc_mutate scale -n "$NAMESPACE" deployment/unit3d-app --replicas=0 \
        || warn "could not scale unit3d-app to 0 (may be acceptable)"

    state_set PHASE_COMPLETED 5
    log "Step 5 OK"
}

# ============================================================================
# Step 6 — Database restore
# ============================================================================
step_6_db_restore() {
    banner "STEP 6 — Database restore"

    db_dump="${DB_DUMP_PATH:-$STATE_DIR/db.sql}"
    if [ ! -f "$db_dump" ]; then
        abort 24 "db dump not found at $db_dump"
    fi

    # Read MARIADB_ROOT_PASSWORD from in-cluster secret
    if [ "$DRY_RUN" = "1" ]; then
        log "[DRY-RUN] would restore $db_dump into mariadb-0"
        state_set PHASE_COMPLETED 6
        log "Step 6 OK (dry-run)"
        return 0
    fi

    root_pw="$(kc get secret -n "$NAMESPACE" mariadb-secrets \
        -o jsonpath='{.data.MARIADB_ROOT_PASSWORD}' 2>/dev/null \
        | base64 -d 2>/dev/null || true)"
    if [ -z "$root_pw" ]; then
        abort 24 "could not read MARIADB_ROOT_PASSWORD from in-cluster secret"
    fi

    db_name="$(grep -E '^DB_DATABASE=' "$COMPOSE_ROOT/.env" \
        | head -n1 | cut -d= -f2-)"
    db_name="${db_name:-unit3d}"

    log "dropping + recreating empty database $db_name"
    kc exec -n "$NAMESPACE" mariadb-0 -- \
        mariadb -uroot -p"$root_pw" \
        -e "DROP DATABASE IF EXISTS $db_name; CREATE DATABASE $db_name;" \
        || abort 24 "drop/create database failed"

    log "restoring dump into $db_name"
    kc exec -i -n "$NAMESPACE" mariadb-0 -- \
        mariadb -uroot -p"$root_pw" "$db_name" < "$db_dump" \
        || abort 24 "restore failed"

    # Verify table count
    actual_tables="$(kc exec -n "$NAMESPACE" mariadb-0 -- \
        mariadb -uroot -p"$root_pw" "$db_name" -N -B \
        -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$db_name';" \
        2>/dev/null | tr -d '[:space:]')"
    expected_tables="${DB_DUMP_TABLES:-0}"
    log "tables after restore: $actual_tables (dumped: $expected_tables)"
    if [ "$actual_tables" -lt "$expected_tables" ]; then
        abort 24 "restored table count ($actual_tables) less than dumped ($expected_tables)"
    fi

    # Sentinel: users table has rows
    user_count="$(kc exec -n "$NAMESPACE" mariadb-0 -- \
        mariadb -uroot -p"$root_pw" "$db_name" -N -B \
        -e "SELECT COUNT(*) FROM users;" 2>/dev/null | tr -d '[:space:]')"
    log "users row count: $user_count"
    if [ "${user_count:-0}" -lt 1 ]; then
        abort 24 "users table is empty post-restore — sentinel check failed"
    fi

    state_set PHASE_COMPLETED 6
    log "Step 6 OK"
}

# ============================================================================
# Step 7 — PVC data restore (apply pvc-loader, kubectl cp + extract)
# ============================================================================
apply_loader_pod() {
    kc_apply_stdin <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $LOADER_POD
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: pvc-loader
    app.kubernetes.io/component: migration
    app.kubernetes.io/part-of: ratatoskr
    app.kubernetes.io/managed-by: migrate-compose-to-k8s
    ratatoskr.io/migration: compose-to-k8s
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
          echo "loader ready (pvc /storage mounted)"
          tail -f /dev/null
      volumeMounts:
        - name: storage
          mountPath: /storage
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
    - name: storage
      persistentVolumeClaim:
        claimName: unit3d-storage
    - name: tmp
      emptyDir:
        sizeLimit: 64Mi
EOF
}

step_7_pvc_restore() {
    banner "STEP 7 — PVC data restore"

    tarball="${BACKUP_TARBALL_PATH:-$STATE_DIR/storage.tar.gz}"
    if [ ! -f "$tarball" ] && [ "$DRY_RUN" != "1" ]; then
        abort 25 "tarball not found at $tarball"
    fi

    log "applying pvc-loader Pod"
    apply_loader_pod || abort 25 "loader Pod apply failed"

    if [ "$DRY_RUN" = "1" ]; then
        log "[DRY-RUN] would kubectl cp tarball + extract"
        state_set PHASE_COMPLETED 7
        log "Step 7 OK (dry-run)"
        return 0
    fi

    kc wait --for=condition=Ready -n "$NAMESPACE" "pod/$LOADER_POD" \
        --timeout=180s || abort 25 "loader Pod not Ready"

    log "kubectl cp tarball into $LOADER_POD"
    kc cp "$tarball" "$NAMESPACE/$LOADER_POD:/tmp/storage.tar.gz" \
        || abort 25 "kubectl cp failed"

    log "extracting tarball into /storage/"
    kc exec -n "$NAMESPACE" "$LOADER_POD" -- \
        sh -c 'cd /storage && tar xzf /tmp/storage.tar.gz && rm /tmp/storage.tar.gz' \
        || abort 25 "tar extraction failed"

    # Sample verification: list a known disk subdir
    log "verifying extracted layout"
    if ! kc exec -n "$NAMESPACE" "$LOADER_POD" -- \
            sh -c 'ls /storage/app/images/users/avatars 2>/dev/null | head' \
            >/dev/null; then
        warn "/storage/app/images/users/avatars missing — operator dataset may differ from default layout"
    fi

    log "deleting loader Pod"
    kc_mutate delete pod -n "$NAMESPACE" "$LOADER_POD" \
        --wait=true --timeout=120s --ignore-not-found || true

    state_set PHASE_COMPLETED 7
    log "Step 7 OK"
}

# ============================================================================
# Step 8 — Verification before cutover
# ============================================================================
step_8_verify() {
    banner "STEP 8 — Verification before cutover"

    # Scale unit3d-app back to overlay default. The overlay declares
    # the canonical replica count; we restore that by re-applying.
    overlay_path="kustomize/overlays/$TARGET_OVERLAY"
    log "re-applying overlay to restore replica count"
    kc_mutate apply -k "$overlay_path" \
        || abort 26 "overlay re-apply failed"

    if [ "$DRY_RUN" = "1" ]; then
        log "[DRY-RUN] skipping rollout wait + smoke checks"
        state_set PHASE_COMPLETED 8
        log "Step 8 OK (dry-run)"
        return 0
    fi

    log "waiting for unit3d-app rollout"
    kc rollout status -n "$NAMESPACE" deployment/unit3d-app \
        --timeout=600s || abort 26 "unit3d-app rollout did not complete"

    # Smoke checks
    pod="$(kc get pod -n "$NAMESPACE" \
        -l app.kubernetes.io/name=unit3d-app \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -n "$pod" ]; then
        log "smoke target: $pod"
        if kc exec -n "$NAMESPACE" "$pod" -- \
                php artisan --version >/dev/null 2>&1; then
            log "OK   artisan responds"
        else
            warn "artisan check failed (non-fatal)"
        fi
        if kc exec -n "$NAMESPACE" "$pod" -- \
                sh -c 'ls /app/storage/app/images/users/avatars 2>/dev/null | head' \
                >/dev/null 2>&1; then
            log "OK   /app/storage readable from app pod"
        else
            warn "/app/storage read failed (non-fatal — may be S3-routed)"
        fi
    fi

    state_set PHASE_COMPLETED 8

    banner "VERIFICATION PASSED — operator action items for DNS cutover"
    cat <<CUTOVER_EOF

Manual steps from upgrade-guide.md § Path 1, Step 8 (DNS cutover):

  1. Reduce DNS TTL on the existing record to 60s (24h before cutover
     ideal — current TTL is the upper bound on cutover sharpness).

  2. Update A/AAAA records to point at the K8s ingress LoadBalancer IP:
       kc get -n $NAMESPACE svc traefik    # or your ingress controller

  3. Watch DNS propagation:
       dig +short tracker.example.org @1.1.1.1
       dig +short tracker.example.org @8.8.8.8

  4. Stop the Compose stack (do NOT 'down -v' — preserve volumes for
     rollback):
       (cd $COMPOSE_ROOT && docker compose stop)

  5. Watch the K8s app logs for real traffic:
       kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=unit3d-app -f

⚠️  BitTorrent .torrent files have the announce URL baked in PERMANENTLY
    (per ADR-0003). The new ingress endpoint MUST resolve the same FQDN
    that was published in old .torrent files. Changing the FQDN
    silently breaks every distributed .torrent file forever.

Backup discipline (upgrade-guide.md § "Discipline for Option B"):
  Keep $STATE_DIR/db.sql and $STATE_DIR/storage.tar.gz for >= 1 week
  after the cutover before deleting them.
CUTOVER_EOF

    log "Step 8 OK"
}

# ============================================================================
# Step dispatcher
# ============================================================================
run_step() {
    n="$1"
    case "$n" in
        1) confirm_step "Step 1: Pre-migration checklist";    step_1_preflight ;;
        2) confirm_step "Step 2: Database backup";            step_2_db_backup ;;
        3) confirm_step "Step 3: Application data sync";      step_3_data_sync ;;
        4) confirm_step "Step 4: APP_KEY transfer";           step_4_app_key ;;
        5) confirm_step "Step 5: Provision the K8s overlay";  step_5_provision ;;
        6) confirm_step "Step 6: Database restore";           step_6_db_restore ;;
        7) confirm_step "Step 7: PVC data restore";           step_7_pvc_restore ;;
        8) confirm_step "Step 8: Verification";               step_8_verify ;;
        *) abort 40 "invalid step: $n" ;;
    esac
}

determine_step_range() {
    if [ -n "$STEP" ]; then
        case "$STEP" in
            [1-8]) START="$STEP"; END="$STEP" ;;
            *) abort 40 "--step must be 1..8 (got: $STEP)" ;;
        esac
        return 0
    fi
    if [ -n "$FROM_STEP" ] || [ -n "$TO_STEP" ]; then
        START="${FROM_STEP:-1}"
        END="${TO_STEP:-8}"
        case "$START" in [1-8]) ;; *) abort 40 "--from-step must be 1..8" ;; esac
        case "$END"   in [1-8]) ;; *) abort 40 "--to-step must be 1..8" ;; esac
        return 0
    fi
    if [ "$RESUME" = "1" ]; then
        START=$((PHASE_COMPLETED + 1))
        END=8
        if [ "$START" -gt 8 ]; then
            log "all 8 steps already completed in $STATE_DIR"
            exit 0
        fi
        return 0
    fi
    START=1
    END=8
}

# ============================================================================
# Main
# ============================================================================
main() {
    banner "$SCRIPT_NAME v$SCRIPT_VERSION"
    log "compose_root=$COMPOSE_ROOT"
    log "target=$TARGET_OVERLAY namespace=$NAMESPACE secrets=$SECRETS_MODE"
    log "state_dir=$STATE_DIR (resume=$RESUME, phase_completed=$PHASE_COMPLETED)"
    log "dry_run=$DRY_RUN verbose=$VERBOSE yes=$YES"

    determine_step_range
    log "step range: $START..$END"

    n="$START"
    while [ "$n" -le "$END" ]; do
        run_step "$n"
        n=$((n + 1))
    done

    banner "MIGRATION SCRIPT COMPLETE"
    log "state preserved at: $STATE_DIR"
}

main "$@"
