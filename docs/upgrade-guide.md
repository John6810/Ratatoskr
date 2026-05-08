# Upgrade guide

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
kubectl apply -k kustomize/overlays/<target>
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

Higher operator skill required; the rollback discipline is stricter. Only choose this if Option A's parallel namespace is infeasible (cluster resource pressure, RBAC constraints, etc.).

```bash
# Step B1 — Stop traffic to the existing deployment
kubectl scale -n unit3d deployment/unit3d-app --replicas=0
kubectl scale -n unit3d deployment/unit3d-queue --replicas=0
kubectl scale -n unit3d deployment/unit3d-scheduler --replicas=0

# Step B2 — Backup PVC contents (debug pod + tar). Use the
# pvc-loader pattern from Path 1 Step 6, but READ-only (kubectl cp
# from pod to local).
# DO NOT delete the local tarball until Step B8 verifies success.

# Step B3 — Backup MariaDB. Same mariadb-dump as Step A1.
# Even if the data is in the PVC, MariaDB lives on a separate VCT-
# managed volume — its accessModes are unaffected by the unit3d-
# storage PVC swap. Belt-and-suspenders backup.

# Step B4 — Delete the old PVC. Note: this CANNOT be undone.
kubectl delete pvc -n unit3d unit3d-storage
# Wait for the PVC to actually disappear (PVs may take a moment
# to detach):
kubectl wait --for=delete pvc/unit3d-storage -n unit3d --timeout=5m

# Step B5 — Apply prod-rwx (creates new PVC with RWX accessModes)
kubectl apply -k kustomize/overlays/prod-rwx

# Step B6 — Restore PVC contents to the new PVC.
# Use the same pvc-loader pattern + kubectl cp + tar as Path 1 Step 6.

# Step B7 — For the 3 Storage-aware disks, sync the corresponding
# subdirectories to the S3 bucket via rclone instead of restoring
# them to the PVC (the prod-rwx values.env points the disks at S3).

# Step B8 — Scale workloads back up
kubectl scale -n unit3d deployment/unit3d-app --replicas=2
kubectl scale -n unit3d deployment/unit3d-queue --replicas=2
kubectl scale -n unit3d deployment/unit3d-scheduler --replicas=1
```

### Path 2 rollback

- **Option A rollback**: revert the ingress swap (point ingress back at the old `unit3d` namespace's Service). No data loss; old namespace is intact.
- **Option B rollback**: requires the prepared PVC tarball + MariaDB dump from Steps B2-B3. Re-apply prod-rwo (`kubectl apply -k kustomize/overlays/prod-rwo`), restore tarball + dump using the Path 1 Steps 5-6 patterns. Higher risk because the original PVC was destroyed in Step B4 — there is no live source to fall back to.

> **Discipline for Option B**: do not delete local backups (PVC tarball + MariaDB dump) until prod-rwx is verified stable for at least 1 week. The fastest way to lose data on Option B is to assume the rollout succeeded after 1 hour and clean up backups before the slow-cooking issues surface.

## Path 3 — UNIT3D version bumps

Updating the ratatoskr-built image tag (e.g., from `v9.2.0` to `v9.3.0` when upstream UNIT3D releases a new minor version). Near-zero downtime on prod-rwx via the RollingUpdate strategy; brief Recreate-strategy downtime on prod-rwo. Laravel migrations run automatically via the `unit3d-migrate` init Job.

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

# Option B: kustomize edit (single command, applies to all four)
kustomize edit set image \
  ghcr.io/<operator>/unit3d=ghcr.io/<operator>/unit3d:v9.3.0
```

Commit + push to the GitOps repo. ArgoCD picks the change up via auto-sync if the ApplicationSet is configured with `syncPolicy.automated.selfHeal: true`. Otherwise, trigger sync manually (`argocd app sync ratatoskr-prod-rwx`) or `kubectl apply -k`.

### Step 3 — Migration Job runs automatically

The `unit3d-migrate` Job runs as part of the rollout (it has `helm.sh/hook: pre-install,pre-upgrade`-equivalent ordering via Kustomize wait semantics). Watch:

```bash
kubectl get jobs -n unit3d -w
kubectl logs -n unit3d job/unit3d-migrate -f
```

If the migrate Job fails (migration error, missing env, DB-credential mismatch post-bump), the workload Deployments will not roll because they wait on the Job's `Complete` condition. The old version stays running. Inspect logs, fix the issue (often a missing env var documented in the upstream release notes), re-trigger.

### Step 4 — Rollout completes via RollingUpdate

- **prod-rwx**: zero-downtime per `strategy: RollingUpdate, maxSurge: 1, maxUnavailable: 0`. New pods come up before old pods terminate; PDB `minAvailable: 1` enforces the floor.
- **prod-rwo**: brief downtime during the `Recreate` strategy. Old pod terminates, new pod starts, ~15-30 seconds of 502 from the ingress while the new pod boots.

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
  ghcr.io/<operator>/unit3d=ghcr.io/<operator>/unit3d:v9.2.0

# Apply
kubectl apply -k kustomize/overlays/<target>

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
