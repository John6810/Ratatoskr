# Migration scripts

Scripts under `scripts/migration/` operationalize procedures from
[`docs/upgrade-guide.md`](../../docs/upgrade-guide.md). Currently shipped:
`migrate-rwo-to-rwx.sh` (Option B in-place, Path 2). The Compose → K8s
migration script ships in a follow-up commit.

---

## migrate-rwo-to-rwx.sh

### Scope

- **In scope**: Option B in-place RWO → RWX swap of the `unit3d-storage` PVC.
  Workloads stay in the same namespace; only the PVC is replaced. The old PV is
  preserved (`reclaimPolicy: Retain`) and rsynced into the new RWX PVC via a
  temporary loader Pod that mounts both volumes.
- **Out of scope**: Option A (fresh parallel namespace). Operators wanting
  Option A follow [`docs/upgrade-guide.md`](../../docs/upgrade-guide.md) §
  "Option A" manually. The Compose → K8s flow is a separate script.

### Required env vars

| Var | Default | Purpose |
|---|---|---|
| `NAMESPACE` | `unit3d` | Target K8s namespace |
| `NEW_STORAGE_CLASS` | *(required)* | RWX-capable StorageClass for the new PVC |

`NEW_STORAGE_CLASS` has no default. The script exits 14 if it is unset or if
the named StorageClass does not exist in the cluster.

### Optional env vars

| Var | Default | Effect |
|---|---|---|
| `KUBECTL_CONTEXT` | current context | Override the kubectl context |
| `OVERLAY_PATH` | `kustomize/overlays/prod-rwx` | Path to the prod-rwx overlay (relative to CWD) |
| `PVC_LOADER_IMAGE` | `alpine:3.20` | Image used for the temporary rsync Pod |
| `DRY_RUN=1` | unset | Read-only mode — every mutation logs `[DRY-RUN]` and is skipped |
| `VERBOSE=1` | unset | Echo every kubectl command to stderr before running |
| `BACKUP_VERIFIED=1` | unset | Bypass the `/tmp/ratatoskr-backup-marker` preflight check (loud warning printed) |
| `PROCEED=1` | unset | Bypass the kubectl-context-mismatch confirmation prompt |

Operators on locked-down supply chains can pin a digest:
`PVC_LOADER_IMAGE=alpine@sha256:<digest>`.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Generic error (unset required env var, unexpected failure) |
| `10` | Missing required tool (`kubectl` or `jq`) |
| `11` | kubectl context mismatch and `PROCEED` not set |
| `12` | Namespace does not exist |
| `13` | `unit3d-storage` PVC missing, unbound, or not RWO |
| `14` | `NEW_STORAGE_CLASS` unset or StorageClass not found |
| `15` | `unit3d-app` Deployment is not single-replica |
| `16` | MariaDB StatefulSet rollout unhealthy |
| `17` | Backup marker absent or older than 60 minutes, and `BACKUP_VERIFIED` unset |
| `18` | `unit3d-migrate` Job is currently active |
| `19` | Insufficient RBAC for required verbs |
| `20` | Failed to scale down workloads (PHASE 1) |
| `21` | Failed to capture old PVC manifest (PHASE 2) |
| `22` | Failed to patch old PV `reclaimPolicy` or clear `claimRef` (PHASE 2) |
| `23` | Failed to delete old PVC (PHASE 2) |
| `24` | Failed to apply rescue PVC (rebind to old PV) (PHASE 2) |
| `25` | Failed to apply new RWX PVC (PHASE 2) |
| `26` | Failed to apply pvc-loader Pod (PHASE 3) |
| `27` | rsync inside pvc-loader returned non-zero (PHASE 3) |
| `28` | Checksum verification failed (PHASE 3) |
| `29` | Failed to apply prod-rwx overlay or rollout timed out (PHASE 4) |
| `30` | User abort (Ctrl+C, SIGTERM, explicit decline) |

### Required tools

- `kubectl` — any version compatible with the cluster API
- `jq` — used for PVC accessModes manipulation; the script aborts at preflight
  check 10 if either binary is absent from `PATH`

### Backup discipline

Take a fresh backup with `scripts/backup.sh` and drop the marker file
immediately before running:

```bash
scripts/backup.sh
touch /tmp/ratatoskr-backup-marker
```

Preflight check 17 verifies that `/tmp/ratatoskr-backup-marker` exists and is
less than 60 minutes old. `BACKUP_VERIFIED=1` bypasses this check — never
bypass it silently. The guidance in
[`docs/upgrade-guide.md`](../../docs/upgrade-guide.md) § "Discipline for Option
B" applies: keep both the PVC tarball and the MariaDB dump for at least one
week after the migration succeeds.

### Usage

Run all commands from the repo root so that the default `OVERLAY_PATH`
(`kustomize/overlays/prod-rwx`) resolves correctly.

```bash
# Dry-run first — exercises every preflight check; no mutations
NEW_STORAGE_CLASS=longhorn-rwx DRY_RUN=1 \
  ./scripts/migration/migrate-rwo-to-rwx.sh

# Real run, after the dry-run is clean
NEW_STORAGE_CLASS=longhorn-rwx \
  ./scripts/migration/migrate-rwo-to-rwx.sh

# With an explicit context and verbose kubectl logging
NEW_STORAGE_CLASS=longhorn-rwx \
  KUBECTL_CONTEXT=prod-cluster \
  VERBOSE=1 \
  ./scripts/migration/migrate-rwo-to-rwx.sh
```

### What the script does

The script tracks its progress via an internal `PHASE` counter (0–4). The abort
handler prints recovery guidance specific to the phase that was active when the
script exited non-zero.

1. **Preflight (PHASE 0, exits 10–19)** — read-only checks: `kubectl` and `jq`
   present, kubectl context confirmed, namespace exists, `unit3d-storage` PVC is
   Bound and RWO, `NEW_STORAGE_CLASS` exists in the cluster, `unit3d-app` is
   single-replica, MariaDB StatefulSet healthy, backup marker fresh, no active
   `unit3d-migrate` Job, RBAC verbs available (`patch persistentvolumes`, `delete
   persistentvolumeclaims`, `apply persistentvolumeclaims`).

2. **Scale down (PHASE 1, exit 20)** — scales `unit3d-app`, `unit3d-queue`, and
   `unit3d-scheduler` to 0 replicas and waits up to 180 seconds per deployment for
   all pods to drain.

3. **Capture and retain (PHASE 2, exits 21–22)** — writes the old PVC and PV
   manifests to `/tmp/ratatoskr-migration-<timestamp>/` for forensics, then
   patches the old PV to `reclaimPolicy: Retain` (idempotent).

4. **PVC swap (PHASE 2, exits 23–25)** — deletes the old PVC (the PV survives
   because of Retain), clears the old PV's stale `claimRef`, applies a rescue PVC
   (`unit3d-storage-rescue`) that rebinds the old PV by `volumeName`, then applies
   the new `unit3d-storage` PVC against `NEW_STORAGE_CLASS` with
   `accessModes: [ReadWriteMany]`. Waits for both PVCs to reach `Bound`.

5. **Loader and copy (PHASE 3, exits 26–28)** — applies the `pvc-loader-rwx-migration`
   Pod (`alpine:3.20`, runs as UID 33, old PVC mounted read-only at `/old`, new PVC
   at `/new`). Runs `rsync -a --delete /old/ /new/` inside the Pod, falling back to
   `cp -a /old/. /new/` if rsync is absent. Checksums a sample of up to 100 files
   from both mounts and aborts on mismatch (diffs written to the work directory).

6. **Loader cleanup (PHASE 3)** — deletes the `pvc-loader-rwx-migration` Pod and
   the `unit3d-storage-rescue` PVC. The old PV enters `Released` state with
   `reclaimPolicy: Retain`.

7. **Overlay apply (PHASE 4, exit 29)** — runs `kubectl apply -k <OVERLAY_PATH>`
   (default `kustomize/overlays/prod-rwx`) and waits up to 600 seconds for the
   `unit3d-app` rollout to complete.

8. **Finalize old PV (PHASE 4)** — flips the old PV's `reclaimPolicy` back to
   `Delete`. The PV remains in the cluster (`Released`); the operator deletes it
   manually after a 24-hour soak period (see [After the migration](#after-the-migration)).

9. **Post-flight** — execs into a running `unit3d-app` pod and smoke-checks
   `php artisan --version` and `ls /app/storage/`. Both failures are non-fatal
   (warn only) to handle S3-routed storage.

### Recovery

Full rollback procedures are in
[`docs/upgrade-guide.md`](../../docs/upgrade-guide.md) § "Path 2 rollback
(Option B)". The notes below are orientation pointers, not complete procedures.

**Aborted during preflight (PHASE 0)** — no mutations were applied. Fix the
failing preflight check and re-run.

**Aborted during scale-down (PHASE 1)** — workloads are at `replicas=0`. Scale
them back manually:

```bash
kubectl scale -n <namespace> deployment/unit3d-app --replicas=1
kubectl scale -n <namespace> deployment/unit3d-queue --replicas=1
kubectl scale -n <namespace> deployment/unit3d-scheduler --replicas=1
```

**Aborted during PVC swap (PHASE 2)** — the old PVC may be deleted; the old PV
is retained with `claimRef` cleared. The work directory
`/tmp/ratatoskr-migration-<timestamp>/` holds the captured manifests for
forensic reference. The backup tarball and MariaDB dump from preflight are the
recovery path — see `docs/upgrade-guide.md` § "Path 2 rollback (Option B)".

> ⚠️ PHASE 2 abort is the highest-risk failure mode. Do not attempt ad-hoc
> recovery without reading the rollback procedure in full first.

**Aborted during rsync (PHASE 3)** — delete the loader Pod and re-run. The
preflights detect partial state (the rescue PVC and new PVC already exist) and
skip re-creation:

```bash
kubectl delete pod -n <namespace> pvc-loader-rwx-migration
```

Then re-run the script from the repo root with the same env vars.

**Aborted during overlay apply (PHASE 4)** — roll back the `unit3d-app`
Deployment, then investigate before re-applying the overlay:

```bash
kubectl rollout undo -n <namespace> deployment/unit3d-app
```

### After the migration

After 24+ hours of verified prod-rwx operation, clean up the orphaned old PV:

```bash
# Confirm the PV is Released (not Bound)
kubectl get pv | grep <old-pv-name>

# Delete the orphaned PV
kubectl delete pv <old-pv-name>
```

Do not delete the backup tarball or MariaDB dump for at least one week. See
[`docs/upgrade-guide.md`](../../docs/upgrade-guide.md) § "Discipline for
Option B".

### See also

- [`docs/upgrade-guide.md`](../../docs/upgrade-guide.md) — full Option A vs
  Option B comparison, step-by-step manual procedures, and rollback
- [`docs/architecture.md`](../../docs/architecture.md) — what `unit3d-storage`
  holds and why RWX matters for multi-replica deployments
- [`docs/security-hardening.md`](../../docs/security-hardening.md) — backup
  discipline and incident response
- [`scripts/backup.sh`](../backup.sh) — the backup pipeline that produces the
  marker file
