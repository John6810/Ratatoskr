# Upgrade guide

Deployment commands below run from the repository root and require Python 3
with PyYAML plus an explicit `KUBECONFIG` (or `KUBECTL_CONTEXT`). The apply helper
resolves the API Service and endpoint IPs before applying restrictive egress;
rendered Secrets stay in memory. For offline GitOps, patch the
`unit3d-migration-api` NetworkPolicy with those exact CIDRs yourself. Its default
loopback placeholder deliberately blocks API access. See the
[security guide](./security-hardening.md).

Operator-facing procedures for migrating an existing ratatoskr deployment to a newer version or a different deployment mode. Three paths covered: Compose → Kubernetes (Path 1), prod-rwo → prod-rwx (Path 2), and UNIT3D version bumps within a Kubernetes deployment (Path 3).

> **Manual procedures only at v0.3.** The unified migration tool ROADMAP'd for v0.4 will automate the data-transfer portions of Paths 1 and 2 (PVC migration, MariaDB restore orchestration, S3 sync). This guide will be amended with the automated path when v0.4 ships. Until then, the steps below are the canonical procedures — well-trodden but operator-driven.

## Common prerequisites

Before any of the three paths:

- **Backup of the current deployment.** A full MariaDB dump (mysqldump or mariabackup), application volumes (storage tree as a tarball, or S3 snapshot if already routed), and the operator's `.env` file (Compose) or sealed-secrets bundle (Kubernetes). Backup retention: keep until the new deployment is verified stable for at least 1 week.
- **Maintenance window planned.** Paths 1 and 2 require downtime (~30 min – 2 h depending on dataset size). Path 3 is rolling on prod-rwx (zero-downtime), brief on prod-rwo (Recreate strategy).
- **`kubectl` access to the target cluster.** With sufficient RBAC to apply manifests, exec into pods, and create/delete PVCs in the target namespace.
- **DNS access.** Required for Path 1 (cutover from Compose host to K8s ingress IP) and sometimes Path 2 (if changing the cluster's exposed endpoint).

## Path 1 — Compose → Kubernetes

Existing v0.2 Compose deployers moving to a Kubernetes cluster (typically because the Compose stack outgrew its single-VPS footprint or because the operator wants HA from prod-rwx). Expected downtime: 30 min – 2 h depending on dataset size, dominated by the database dump/restore and the application data transfer.

High-level flow: dump MariaDB → sync application volumes → provision the K8s overlay with operator-supplied secrets → restore data into the new cluster → verify with port-forward → DNS cutover.

### Pre-migration checklist

- **Identify the storage volumes used in Compose.** `compose/docker-compose.yml` lists the bind mounts and named volumes. The ratatoskr Compose stack mounts `./storage` (Laravel's writable tree, holds all 17 disks), `./bootstrap/cache` (compiled config, regenerable), and the `mariadb-data` named volume (DB data files, NOT a bind mount).
- **Note the current UNIT3D version.** Read `compose/.env` (or the image tag in `docker-compose.yml`). The K8s deployment must use the same major.minor version for the schema to match — Laravel migrations are not always idempotent across major versions.
- **Decide on the target overlay.** `prod-rwo` is the closer fit semantically (single-replica + persistent volume, mirrors the Compose single-host model). `prod-rwx` is for operators who need HA *now* and have an RWX storage class — but it adds the S3 routing wrinkle (3 of 17 disks move off-PVC). Beginners migrating from Compose typically pick `prod-rwo` first, then move to `prod-rwx` later via Path 2 once the K8s deployment is stable.

### Step 1 — Database backup

Use `mysqldump` for portability — works across MariaDB versions and produces a self-contained SQL file. For datasets above ~10 GiB, `mariabackup` is faster (physical hot backup) but requires the source and target MariaDB versions to match exactly.

```bash
# From the Compose host:
docker compose exec -T mariadb mysqldump \
  --single-transaction --quick --lock-tables=false \
  -uroot -p"${MARIADB_ROOT_PASSWORD}" \
  unit3d > unit3d-backup-$(date +%Y%m%d-%H%M%S).sql

# Verify the dump is well-formed (non-empty, contains schema):
grep -c "^CREATE TABLE" unit3d-backup-*.sql
# Expect: 100+ tables on UNIT3D v9.2.0
```

`--single-transaction` gives a consistent snapshot of InnoDB tables without taking locks; `--quick` streams row-by-row so memory usage stays bounded; `--lock-tables=false` skips the MyISAM-era global lock (UNIT3D is InnoDB, locking is unnecessary).

For very large datasets where downtime cost matters, prefer the v0.2 backup pipeline ([`docs/backup-restore.md`](./backup-restore.md)) — `mariabackup` + Restic gives a physical hot backup that restores in a fraction of the `mysqldump` reload time.

### Step 2 — Application data sync

Compose stores user-uploaded content under `./storage/` (17 Laravel filesystem disks per ADR-0002). The transfer strategy depends on the target overlay:

- **Target prod-rwo**: all 17 disks go to a single `unit3d-storage` PVC (RWO). Bundle them into a tarball; restore in Step 6.
- **Target prod-rwx**: 3 Storage-aware disks (`torrent-files`, `subtitle-files`, `attachment-files`) sync directly to the S3-compatible bucket; the 14 PVC-bound disks (8 UNIT3D content disks + 6 Laravel-default disks per ADR-0002) bundle into a tarball.

```bash
# Tarball the PVC-bound disks (used by both prod-rwo and prod-rwx targets;
# prod-rwx omits the three S3-aware disks since they go to S3 instead).
tar czf unit3d-pvc-data-$(date +%Y%m%d).tar.gz \
  -C ./storage \
  app/images/articles \
  app/images/users/avatars \
  app/images/users/icons \
  app/images/categories \
  app/images/playlists \
  app/images/torrents/banners \
  app/images/torrents/covers \
  app/tmp/nfos
```

For prod-rwx S3 sync, install `rclone` and configure the operator's S3 endpoint (`rclone config` interactive, or env-driven for automation). The example below assumes a remote named `s3-target`:

```bash
# Sync the 3 Storage-aware disks to the S3 bucket.
# Use --transfers 8 for parallelism; tune based on bandwidth and S3 rate limits.
rclone copy ./storage/app/files/torrents/files/ \
  s3-target:bucket-name/torrent-files/ --progress --transfers 8
rclone copy ./storage/app/files/subtitles/files/ \
  s3-target:bucket-name/subtitle-files/ --progress --transfers 8
rclone copy ./storage/app/files/attachments/files/ \
  s3-target:bucket-name/attachment-files/ --progress --transfers 8
```

### Step 3 — APP_KEY transfer

Two options, operator's choice:

- **Option A — Reuse the existing APP_KEY** (preserves signed cookie / token / encrypted-column compatibility). Read `APP_KEY` from `compose/.env`, copy verbatim into a new sealed-secret targeting the K8s cluster. Existing user sessions and remember-me tokens continue to work post-cutover. This is the operator-friendlier path.
- **Option B — Generate a new APP_KEY** (forces all sessions to re-auth on cutover). The opt-in `bootstrap-app-key` Component generates one in-cluster on first deploy. All existing sessions invalidate, password-reset tokens in flight will fail. Acceptable if you want a clean session reset as part of the migration; otherwise prefer Option A.

For Option A:

```bash
# Read the existing APP_KEY from Compose
APP_KEY_VALUE=$(grep '^APP_KEY=' compose/.env | cut -d= -f2-)

# Fill the secret template, seal it, drop in the target overlay's secrets/
sed "s|CHANGEME|${APP_KEY_VALUE}|" \
  kustomize/base/secrets-templates/unit3d-secrets.yaml \
  | kubeseal --format yaml \
  > kustomize/overlays/prod-rwo/secrets/unit3d-secrets-sealed.yaml

# Repeat for the other 4 secrets (mariadb-secrets, redis-secrets,
# meilisearch-secrets, and unit3d-storage-secrets if prod-rwx target).
# See the per-overlay secrets/README.md for the full kubeseal recipe.
```

### Step 4 — Provision the K8s overlay

```bash
# In the operator's ratatoskr fork
cd kustomize/overlays/<target>  # prod-rwo or prod-rwx

# Edit values.env (APP_URL, TRUSTED_PROXIES, FILESYSTEM_<DISK> if prod-rwx)
$EDITOR values.env

# Generate the rest of the sealed-secrets (Step 3 covered unit3d-secrets;
# repeat the kubeseal pattern for each *-secrets.yaml under
# kustomize/base/secrets-templates/).

# Uncomment the matching - secrets/*-sealed.yaml lines in
# kustomization.yaml's resources: block.

# Apply the overlay
python3 scripts/security/apply-kustomize.py kustomize/overlays/<target>
```

Wait for the `unit3d-migrate` Job to complete. The migrate Job runs initial Laravel migrations on the still-empty database, ensuring the schema is at the correct version for the target image tag — these will be overwritten by the dump restore in Step 5, but the schema check is the safety net:

```bash
kubectl wait --for=condition=Complete job/unit3d-migrate -n unit3d \
  --timeout=10m
```

If the Job fails, inspect logs (`kubectl logs -n unit3d job/unit3d-migrate`) — most failures at this stage are env or DB-credential mismatches between `values.env` and the sealed-secrets.

### Step 5 — Database restore

Once the cluster is healthy but BEFORE traffic cutover, drop the migrate-Job-populated empty database and restore the dump:

```bash
# Sanity-check the mariadb pod is running
kubectl get pods -n unit3d -l app.kubernetes.io/name=mariadb

# Read MARIADB_ROOT_PASSWORD from the in-cluster secret (avoids retyping)
ROOT_PW=$(kubectl get secret -n unit3d mariadb-secrets \
  -o jsonpath='{.data.MARIADB_ROOT_PASSWORD}' | base64 -d)

# Drop + recreate the empty database
kubectl exec -n unit3d mariadb-0 -- \
  mariadb -uroot -p"${ROOT_PW}" \
  -e "DROP DATABASE unit3d; CREATE DATABASE unit3d;"

# Restore the dump
kubectl exec -i -n unit3d mariadb-0 -- \
  mariadb -uroot -p"${ROOT_PW}" unit3d \
  < unit3d-backup-YYYYMMDD-HHMMSS.sql

# Verify counts match the source
kubectl exec -n unit3d mariadb-0 -- \
  mariadb -uroot -p"${ROOT_PW}" unit3d \
  -e "SELECT COUNT(*) AS users FROM users;
      SELECT COUNT(*) AS torrents FROM torrents;"
```

Compare the user/torrent counts against the Compose source (`docker compose exec mariadb mariadb ...` with the same query). They must match.

### Step 6 — PVC data restore

Copy the application data tarball into the `unit3d-storage` PVC. The cluster doesn't expose the PVC directly to the operator — use a temporary pod that mounts it:

```bash
# Manifest for a temporary "loader" pod that mounts unit3d-storage:
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pvc-loader
  namespace: unit3d
spec:
  restartPolicy: Never
  securityContext:
    runAsUser: 33     # www-data, matches base/unit3d-app/deployment.yaml
    runAsGroup: 33
    fsGroup: 33
  containers:
    - name: loader
      image: alpine:3
      command: ["sleep", "3600"]
      volumeMounts:
        - name: storage
          mountPath: /storage
  volumes:
    - name: storage
      persistentVolumeClaim:
        claimName: unit3d-storage
EOF

kubectl wait --for=condition=Ready pod/pvc-loader -n unit3d --timeout=2m

# Copy the tarball into the pod, extract into /storage
kubectl cp unit3d-pvc-data-YYYYMMDD.tar.gz \
  unit3d/pvc-loader:/storage/migration.tar.gz
kubectl exec -n unit3d pvc-loader -- \
  sh -c "cd /storage && tar xzf migration.tar.gz && rm migration.tar.gz"

# Verify a sample directory (count files in a known disk)
kubectl exec -n unit3d pvc-loader -- \
  find /storage/app/images/users/avatars -type f | wc -l

# Cleanup
kubectl delete pod -n unit3d pvc-loader
```

For the prod-rwx S3 path, no PVC restore is needed for the 3 Storage-aware disks — they were synced to S3 in Step 2 and the running app reads them directly from S3 once the FILESYSTEM_<DISK>=s3 env vars are honored.

### Step 7 — Verification before cutover

Port-forward the unit3d-app Service to localhost without touching DNS:

```bash
kubectl port-forward -n unit3d svc/unit3d-app 8080:80
# Browser: http://localhost:8080
```

Verification checklist:

- Login as an existing user (uses the migrated password hash from Step 5)
- Browse the torrent listing (exercises MariaDB read path)
- Open a torrent detail page (exercises image disks: covers, banners)
- Download a `.torrent` file (exercises Storage-aware disk: torrent-files; on prod-rwx this hits S3)
- View a user profile with avatar (exercises user-avatars PVC disk)
- Submit a search query (exercises Meilisearch — should return results immediately if `scout:sync-index-settings` ran cleanly during the migrate Job)

Any verification failure → don't cut over. Investigate, fix, re-verify. Common failures: DNS-dependent URLs in emails (Laravel uses `APP_URL`; verify it's set correctly in `values.env`), TLS cert not yet issued by cert-manager (wait or check the Certificate resource), Meilisearch not reachable from the app (NetworkPolicy issue, check `unit3d-to-infra-egress`).

### Step 8 — DNS cutover

Once verification passes:

1. Update DNS A/AAAA records to point at the K8s ingress LoadBalancer IP. Reduce TTL ahead of time (24h before cutover, lower TTL to 60s) so the cutover is sharp.
2. Wait for DNS propagation. Monitor `dig +short tracker.example.org` from a few external resolvers.
3. **Stop the Compose deployment** to prevent split-brain writes during the TTL window:
   ```bash
   docker compose stop
   # Don't `down` yet — keep the volumes for rollback.
   ```
4. Watch the K8s app logs for incoming traffic; confirm real users are arriving (not just port-forward tests).

### Path 1 rollback

If verification fails or post-cutover issues surface within the maintenance window:

1. Revert DNS records to the Compose host's IP.
2. Wait for TTL expiry.
3. Restart Compose: `docker compose up -d`.
4. Investigate the K8s deployment offline — its data is unaffected. The Compose deployment has been the canonical source throughout; the K8s deployment was a parallel restore that did not feed back to Compose.

Retain both deployments running (Compose live, K8s investigated offline) until the K8s issues are resolved and a second cutover succeeds.

## Path 2 — prod-rwo → prod-rwx

Existing v0.3 prod-rwo deployment moving to prod-rwx (multi-replica `unit3d-app`/`unit3d-queue`, RWX storage, S3 routing for the 3 Storage-aware disks). Expected downtime: 15-60 min depending on dataset size.

High-level flow: cannot in-place flip because PVC `accessModes` is immutable post-create. Two operator-grade options below.

### The PVC `accessModes` constraint

Critical Kubernetes invariant: `PersistentVolumeClaim.spec.accessModes` is **immutable** after the PVC is created. The base `unit3d-storage` PVC ships with `[ReadWriteOnce]`; prod-rwo uses it as-is, prod-rwx patches the field to `[ReadWriteMany]`. `kubectl apply -k kustomize/overlays/prod-rwx` against an existing prod-rwo cluster does NOT flip the field — the API server silently no-ops the immutable field, the PVC stays RWO, and multi-replica scheduling fails because the volume can't be multi-attached.

Two operator paths from this point.

### Option A — Fresh deploy in a new namespace (recommended)

Provision prod-rwx in a parallel namespace (e.g., `unit3d-rwx` if the existing one is `unit3d`, or rely on the ApplicationSet's per-overlay namespace template). Restore data, verify, swap ingress, retire the old namespace.

Steps mirror Path 1 Steps 4-8, with the source now being the existing prod-rwo cluster instead of Compose:

- **Step A1** (substitute for Path 1 Step 1): take the MariaDB dump from the live prod-rwo cluster:
  ```bash
  ROOT_PW=$(kubectl get secret -n unit3d mariadb-secrets \
    -o jsonpath='{.data.MARIADB_ROOT_PASSWORD}' | base64 -d)
  kubectl exec -n unit3d mariadb-0 -- \
    mariadb-dump --single-transaction --quick --lock-tables=false \
    -uroot -p"${ROOT_PW}" unit3d \
    > unit3d-backup-$(date +%Y%m%d-%H%M%S).sql
  ```
- **Step A2** (substitute for Path 1 Step 2): tarball the existing PVC contents via a debug pod (same `pvc-loader` pattern as Path 1 Step 6, but reading instead of writing):
  ```bash
  kubectl cp unit3d/pvc-loader:/storage ./prod-rwo-storage-snapshot
  tar czf prod-rwo-snapshot-$(date +%Y%m%d).tar.gz prod-rwo-storage-snapshot/
  ```
  For the 3 Storage-aware disks that will move to S3 in prod-rwx, sync them directly to the target S3 bucket via `rclone copy` from inside the pod, OR include them in the tarball and sync after extracting — either works.
- **Step A3-A6**: identical to Path 1 Steps 3-6, but the target namespace is the new one (e.g., `unit3d-rwx`).
- **Step A7-A8** (verification + cutover): port-forward to verify, then swap ingress to the new namespace's `unit3d-app` Service. The DNS doesn't change (same domain); only the IngressRoute or Ingress backend Service reference changes. Update the operator's ingress config in their fork, apply, watch the rollout.
- **Cleanup**: keep the old `unit3d` namespace running until prod-rwx is verified stable for at least 1 week. Then `kubectl delete namespace unit3d`.

This option is recommended because the rollback path is trivial — the old namespace is intact, swap ingress back, no data loss.

### Option B — Manual PVC swap (advanced, in-place)

This path stops the application while the storage is copied. Use the guarded
[migration script](../scripts/migration/README.md), which preserves the original
PV and verifies the copy before restarting workloads.

1. Take and verify a MariaDB backup and an archive of `storage/`. Keep them through
   the rollback window. Pause any GitOps reconciler that would restore replicas
   while the migration is running.
2. Set `NAMESPACE`, `NEW_STORAGE_CLASS`, and `OVERLAY_PATH`. The target overlay must
   explicitly declare the same namespace, `ReadWriteMany`, the selected
   `storageClassName`, and the original PVC's requested capacity. Perform any
   capacity expansion separately. Include the production secrets, ingress CRDs,
   and storage settings required by that overlay.
3. Run the read-only preflight, then the migration:

   ```bash
   DRY_RUN=1 sh scripts/migration/migrate-rwo-to-rwx.sh
   sh scripts/migration/migrate-rwo-to-rwx.sh
   ```

   The backup marker must be fresh; see the script guide. The script stops all
   three consumers, removes the inactive migration Job, retains the old PV,
   swaps PVCs, copies and checksums the data, and only then applies the target
   overlay. A completed migration Pod must be removed before deleting its PVC.
4. Verify application, queue, scheduler, authenticated search, and representative
   files on different nodes. Re-enable GitOps only after its desired PVC matches
   the live class and capacity. Keep the original PV on `Retain` during the
   rollback window.

### Path 2 rollback

- **Option A:** point ingress back to the original namespace after checking that
  it has the data needed to resume service.
- **Option B:** the old PVC is gone, but its PV is retained. Stop all application
  consumers and remove the migration Job and loader Pod. Record the new RWX PV
  and set it to `Retain` before removing its claim. Remove the rescue claim if it
  still exists, then clear the original PV's stale `claimRef`. Recreate the
  original RWO PVC with its original StorageClass, capacity, and `volumeName`
  pointing to the retained PV. The migration work directory contains the original
  PVC/PV JSON. Strip server-generated metadata, finalizers, status, and the old
  last-applied annotation before using `kubectl create`. Reapply the original RWO
  overlay, recreate its migration Job, and wait for all workloads to become ready.

The original PV contains the data from the time of the copy. Reconcile any writes
accepted on RWX before switching back; retaining the new PV preserves those writes
for recovery. Storage rollback does not undo database schema changes. Restore a
verified DB backup if the application's schema compatibility requires it.

The executable rehearsal is [`scripts/tests/rwx-migration.sh`](../scripts/tests/rwx-migration.sh).
It checks the original files, APP_KEY, and a database sentinel after the return to
RWO. Its namespace and data are disposable; do not run this test against production.

Keep the backups until the replacement has been verified stable for at least one
week. Reclaiming a retained PV is an explicit final cleanup operation.

## Path 3 — UNIT3D version bumps

Updating the ratatoskr-built image tag (e.g., from `v9.2.0` to `v9.3.0` when upstream UNIT3D releases a new minor version). Near-zero downtime on prod-rwx via the RollingUpdate strategy; brief Recreate-strategy downtime on prod-rwo. Helm creates a migration Job per revision. Kustomize requires explicitly replacing
its static Job before each application upgrade, as described below.

### Step 1 — Pre-bump checklist

- **Read the upstream UNIT3D release notes** for breaking changes (config defaults, deprecated env vars, schema changes that affect existing installations). Major version bumps (e.g., `v9.x` → `v10.x`) frequently include irreversible schema migrations.
- **Backup MariaDB.** Even though Laravel migrations are usually safe to forward-roll, schema changes are not always reversible without a backup. Use the v0.2 backup pipeline ([`docs/backup-restore.md`](./backup-restore.md)) or `mariadb-dump` (Step 1 of Path 1).
- **Verify the new image tag exists** in the operator's image registry:
  ```bash
  docker manifest inspect ghcr.io/<operator>/unit3d:v9.3.0
  ```

### Step 2 — Image tag bump

In the operator's fork:

```bash
cd kustomize/base

# Option A: edit deployment.yaml directly
$EDITOR unit3d-app/deployment.yaml
$EDITOR unit3d-queue/deployment.yaml
$EDITOR unit3d-scheduler/deployment.yaml
$EDITOR unit3d-migrate/job.yaml
# Change image: ghcr.io/<operator>/unit3d:v9.2.0 -> v9.3.0 in each.

# Option B: update the web and migration image together
kustomize edit set image \
  ghcr.io/<operator>/unit3d=ghcr.io/<operator>/unit3d:v9.3.0 \
  ghcr.io/<operator>/unit3d-migrate=ghcr.io/<operator>/unit3d-migrate:v9.3.0
cd ../..
```

### Step 3 — Run the new migration Job before starting workloads

Kustomize has no implicit hook ordering or wait semantics. A completed static Job
is not rerun by `kubectl apply`; changing its Pod template also encounters immutable
fields. Pause ArgoCD auto-sync/self-healing for this maintenance operation so it
cannot undo the scale-down or race the Job replacement. The current ApplicationSet
does not orchestrate application upgrades; automate this sequence explicitly before
enabling unattended upgrades.

After a backup, stop all application consumers and wait for their Pods to exit.
Then remove the old Job and apply the updated overlay:

```bash
kubectl scale -n unit3d deployment/unit3d-app deployment/unit3d-queue \
  deployment/unit3d-scheduler --replicas=0
kubectl wait -n unit3d --for=delete pod \
  -l 'app.kubernetes.io/name in (unit3d-app,unit3d-queue,unit3d-scheduler)' --timeout=180s
kubectl delete job -n unit3d unit3d-migrate --ignore-not-found --wait
python3 scripts/security/apply-kustomize.py kustomize/overlays/prod-rwo
kubectl wait -n unit3d --for=condition=complete job/unit3d-migrate --timeout=15m
kubectl logs -n unit3d job/unit3d-migrate
```

Choose `prod-rwx` instead when that is the existing storage mode. The overlay
restores the configured replica counts; each new Pod waits for the new migration
Job before starting its application process. Keep the completed Job so later Pod
restarts can also verify success. Re-enable GitOps reconciliation only after the
rollout and database checks succeed.

### Step 4 — Verify the rollout

This maintenance sequence has downtime for both Kustomize storage modes. Helm's
revision-specific Job supports RWX rolling deployments, provided the new migrations
are compatible with the old running application. A migration failure blocks new
Pods; it does not automatically roll back the database. Inspect retained Job logs,
correct the cause, and retry, or restore a verified backup if required. Seeders run
only at initial database creation, because several upstream seeders cannot be repeated.

Verify the rollout completed:

```bash
kubectl rollout status deployment/unit3d-app -n unit3d
kubectl rollout status deployment/unit3d-queue -n unit3d
kubectl rollout status deployment/unit3d-scheduler -n unit3d

# Sanity: confirm the new image is actually running
kubectl get pods -n unit3d -l app.kubernetes.io/name=unit3d-app \
  -o jsonpath='{.items[*].spec.containers[*].image}'
```

### Path 3 rollback

```bash
# Revert the image tag to the previous version
cd kustomize/base
kustomize edit set image \
  ghcr.io/<operator>/unit3d=ghcr.io/<operator>/unit3d:v9.2.0 \
  ghcr.io/<operator>/unit3d-migrate=ghcr.io/<operator>/unit3d-migrate:v9.2.0
cd ../..

# Apply
python3 scripts/security/apply-kustomize.py kustomize/overlays/<target>

# Watch the rollback
kubectl rollout status deployment/unit3d-app -n unit3d
```

> **Important**: Laravel migrations are not always backwards-compatible. A migration in `v9.3.0` may drop a column that `v9.2.0` still reads, or change an enum type in a way that older code can't parse. **For major version bumps** (`v9.x` → `v10.x`) and risky minor bumps, anticipate the rollback path REQUIRES a MariaDB restore from the Step 1 backup. Image-only rollback is sufficient ONLY when migrations are additive (new columns, new tables) and the old code tolerates them — verify against the upstream release notes before committing to image-only rollback.

## Common: rollback discipline

- Always have a recent MariaDB dump before any major operation. The operator guide for the v0.2 backup pipeline ([`docs/backup-restore.md`](./backup-restore.md)) is the canonical mechanism.
- Always have an application data backup (PVC tarball OR S3 snapshot, depending on which disks are routed where).
- Document the rollback path BEFORE executing the upgrade — not during incident. A rollback procedure improvised at 02:00 with users reporting login failures is the worst time to discover a missing prerequisite.
- For Paths 1 and 2, retain the source deployment until the target is verified stable for at least 1 week. The "stable" bar means: no user-reported issues, no error spikes in app logs, no failed queue jobs that didn't exist before, no MariaDB slow-query regressions.

## See also

- [`docs/ROADMAP.md`](./ROADMAP.md) — v0.4 will ship the unified migration tool that automates the data-transfer portions of Paths 1 and 2 (`mariadb-backup` + Restic for DB, S3 sync for the 3 Storage-aware disks, PVC content cp for the 14 image disks).
- [`docs/backup-restore.md`](./backup-restore.md) — the v0.2 backup pipeline (`mariadb-backup` + Restic) is the canonical backup mechanism, used as the prerequisite for all upgrade paths.
- [`docs/architecture.md`](./architecture.md) — component overview and storage strategy diagrams.
- [ADR-0001](./adr/0001-database-deployment-topology.md) — MariaDB single-replica until v0.7 Galera. Rollback procedures don't need to handle multi-master split.
- [ADR-0002](./adr/0002-storage-strategy-unit3d-storage.md) — Storage strategy. The 3 Storage-aware disks vs 14 PVC-bound disks split drives Step 2 of Path 1 and Steps A2/B6-B7 of Path 2.
- [ADR-0003](./adr/0003-ingress-controller-assumption.md) — Ingress controller. DNS cutover (Path 1 Step 8) interacts with Traefik IngressRoute or vanilla Ingress depending on the operator's chosen Component.
- [ADR-0004](./adr/0004-secret-management.md) — Secret management. APP_KEY transfer (Path 1 Step 3) and sealed-secrets pattern (Step 4) follow the ADR's operator-supplied default.
- [ADR-0005](./adr/0005-ha-boundary-v0.3.md) — HA boundary. Path 2 (prod-rwo → prod-rwx) crosses the HA threshold for `unit3d-app` and `unit3d-queue`; the rest of the components stay single-replica per the ADR's per-component HA table.
