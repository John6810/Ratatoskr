# Migration scripts

Scripts under `scripts/migration/` operationalize procedures from
[`docs/upgrade-guide.md`](../../docs/upgrade-guide.md). Two scripts ship:
`migrate-rwo-to-rwx.sh` (Option B in-place, Path 2) and
`migrate-compose-to-k8s.sh` (guided 8-step Compose → K8s migration, Path 1).

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

---

## migrate-compose-to-k8s.sh

### Scope

- **In scope**: 8-step Compose → Kubernetes migration mapped to
  [`docs/upgrade-guide.md`](../../docs/upgrade-guide.md) § Path 1. Stepper with
  state persistence (resumable on interruption). Same-workstation source assumed
  — the Compose stack and `kubectl` must both be reachable from the host running
  the script.
- **Out of scope**: SSH-tunneled flows where the Compose stack lives on a remote
  host. Operators in that case follow
  [`docs/upgrade-guide.md`](../../docs/upgrade-guide.md) § Path 1 manually. APP_KEY
  Option B (fresh key via in-cluster generation) is also manual via the
  `bootstrap-app-key` Component.

### Required CLI flags

| Flag | Purpose |
|---|---|
| `--compose-root <path>` | Path to the Compose project root (must contain `docker-compose.yml` and `.env`) |
| `--target-overlay <name>` | `prod-rwo` or `prod-rwx` |

### Optional CLI flags

| Flag | Default | Effect |
|---|---|---|
| `--target-namespace <name>` | `unit3d` | Target K8s namespace |
| `--secrets-mode <mode>` | `sealed-secrets` | `sealed-secrets`, `eso`, or `vanilla` |
| `--kubectl-context <ctx>` | current context | Override the active kubectl context |
| `--kubeseal-cert <path>` | *(required when `--secrets-mode=sealed-secrets`)* | Path to the sealed-secrets controller public key |
| `--state-dir <path>` | `/tmp/ratatoskr-migration-<timestamp>` | Directory for state file, dumps, tarball, and secrets bundle |
| `--resume` | off | Continue from the last completed step (reads `$STATE_DIR/state.env`) |
| `--step <n>` | — | Run only step N (1–8); mutually exclusive with `--from-step`/`--to-step` |
| `--from-step <n>` | — | Start of partial run window |
| `--to-step <m>` | — | End of partial run window |
| `--dry-run` | off | Read-only mode; every mutation logs `[DRY-RUN]` and is skipped |
| `--verbose` | off | Echo every `kubectl`/`docker` command to stderr before running |
| `--yes` | off | Skip per-step confirmation prompts |
| `-h`, `--help` | — | Print usage and exit |

### Env overrides

| Var | Default | Effect |
|---|---|---|
| `PVC_LOADER_IMAGE` | `alpine:3.20` | Image used by Step 7's loader Pod. Pin a digest for supply-chain-locked environments: `alpine@sha256:<digest>` |
| `RCLONE_REMOTE` | *(required for `prod-rwx`)* | rclone remote name (e.g. `s3-target`) |
| `S3_BUCKET` | *(required for `prod-rwx`)* | S3 bucket name only — no `s3://` prefix |

### State file

Path: `<STATE_DIR>/state.env`. Format: `KEY=VALUE`, shell-sourceable. The
directory is created at mode `0700`; the file at mode `0600`.

Keys tracked across steps:

- `PHASE_COMPLETED` — integer 1–8; read by `--resume` to determine the next
  step to run
- `TIMESTAMP`, `COMPOSE_PROJECT_ROOT`, `TARGET_NAMESPACE`, `TARGET_OVERLAY`,
  `SECRETS_MODE`
- `BACKUP_TARBALL_PATH`, `BACKUP_TARBALL_SHA256`
- `DB_DUMP_PATH`, `DB_DUMP_TABLES`, `DB_DUMP_SHA256`
- `APP_KEY_HASH` — sha256 of the APP_KEY written as an audit trail; never the
  key itself
- `S3_ROUTING_VERIFIED` — set to `1` after successful rclone sync (prod-rwx
  only)

> ⚠️ Do not edit `PHASE_COMPLETED` manually. Re-running an already-completed
> step is generally idempotent (each step checks its own pre-state), but
> inflating the counter to skip a step will corrupt the migration by bypassing
> the prerequisite chain.

### Secrets modes (per ADR-0004)

Three paths, neutral by design. See
[`docs/adr/0004-secret-management.md`](../../docs/adr/0004-secret-management.md)
for the full trade-off comparison.

- **`sealed-secrets`** (default) — the script generates an unsealed `Secret`
  manifest with the Compose `APP_KEY` in `stringData`, pipes it through
  `kubeseal --cert <path>`, and applies the resulting `SealedSecret` directly.
  The plaintext key never leaves the script's runtime memory and a temporary
  `$STATE_DIR/.app_key` file (mode `0600`). The EXIT trap shreds the file via
  `dd if=/dev/zero` on script termination, whether success or failure.

- **`eso`** — the script emits an `ExternalSecret` template at
  `$STATE_DIR/secrets/unit3d-secrets.yaml` and halts at Step 5. The operator
  populates the KMS backend referenced by the template, applies the manifest,
  then re-runs with `--resume` to continue from Step 5.

- **`vanilla`** — the script emits a raw `Secret` manifest with
  `stringData.APP_KEY`. A loud warning is printed; explicit operator
  confirmation is required. The script halts after writing the file. The
  operator must `kubectl apply` the file and re-run `--resume`. Do not commit
  the file.

### Disk routing (per ADR-0002)

See
[`docs/adr/0002-storage-strategy-unit3d-storage.md`](../../docs/adr/0002-storage-strategy-unit3d-storage.md)
for the full disk inventory and routing rationale.

- **`prod-rwo` target** — Step 3 tarballs the entire `./storage/app/` subtree.
  Step 7 extracts it into the `unit3d-storage` PVC. All 17 Laravel filesystem
  disks ride the tarball.

- **`prod-rwx` target** — Step 3 tarballs `./storage/app/` with the 3
  Storage-aware disk subtrees excluded (`app/files/torrents/files`,
  `app/files/subtitles/files`, `app/files/attachments/files`), then runs
  `rclone copy` to sync those three directories to
  `$RCLONE_REMOTE:$S3_BUCKET/{torrent-files,subtitle-files,attachment-files}/`.
  The 14 PVC-bound disks (8 image + 6 Laravel-default) ride the tarball into the
  new RWX PVC. The script aborts at preflight check 13 if `RCLONE_REMOTE` or
  `S3_BUCKET` is unset.

### Required tools

- `kubectl`, `docker`, `tar`, `grep`, `sed`, `awk`, and `sha256sum` (or `shasum`
  on macOS) must be present in `PATH`.
- `kubeseal` — required when `--secrets-mode=sealed-secrets`.
- `rclone` — required when `--target-overlay=prod-rwx`.

The script aborts at preflight check 10 if any required tool is missing.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Generic error (bad CLI usage, missing required flag) |
| `10` | Missing required tool |
| `11` | Compose root invalid, stack still running, or `.env` missing required key |
| `12` | Target namespace already has a `unit3d-app` Deployment and `--resume` was not passed |
| `13` | Secrets-mode prerequisites missing (`kubeseal` cert absent, or `RCLONE_REMOTE`/`S3_BUCKET` unset for prod-rwx) |
| `14` | Insufficient disk space at `$STATE_DIR` (requires ~1.5× the `./storage` size) |
| `20` | Step 2 (DB backup) failed |
| `21` | Step 3 (data sync / tarball or rclone) failed |
| `22` | Step 4 (APP_KEY extraction) failed |
| `23` | Step 5 (provision overlay) failed |
| `24` | Step 6 (DB restore) failed |
| `25` | Step 7 (PVC restore) failed |
| `26` | Step 8 (verification / overlay re-apply) failed |
| `30` | User abort (Ctrl+C, SIGTERM, declined confirmation prompt) |
| `40` | Invalid `--step` / `--from-step` / `--to-step` value |
| `41` | `--resume` requested but no `/tmp/ratatoskr-migration-*` directory found |

### Backup discipline

`$STATE_DIR/db.sql` and `$STATE_DIR/storage.tar.gz` are the rollback path for
the entire migration. They must exist and be intact before any DNS cutover.

Keep both files for at least one week after the cutover before deleting them.
The guidance in
[`docs/upgrade-guide.md`](../../docs/upgrade-guide.md) § "Path 1 rollback"
applies: if verification fails at any point, revert DNS to the Compose host's
IP, restart `docker compose up -d`, and investigate the K8s deployment offline.
The Compose deployment is the canonical source throughout the migration; the K8s
deployment is a parallel restore that does not feed back to Compose.

### Usage

Run all commands from the repo root so that
`kustomize/overlays/<target-overlay>` resolves correctly.

```bash
# Dry-run end-to-end — exercises preflights and step shells; no mutations
./scripts/migration/migrate-compose-to-k8s.sh \
  --compose-root /home/op/ratatoskr-compose \
  --target-overlay prod-rwo \
  --secrets-mode sealed-secrets \
  --kubeseal-cert /home/op/sealed-secrets-pub.pem \
  --dry-run

# Real run, prod-rwo target
./scripts/migration/migrate-compose-to-k8s.sh \
  --compose-root /home/op/ratatoskr-compose \
  --target-overlay prod-rwo \
  --kubeseal-cert /home/op/sealed-secrets-pub.pem

# Real run, prod-rwx with S3 routing
RCLONE_REMOTE=s3-target S3_BUCKET=my-unit3d-prod \
./scripts/migration/migrate-compose-to-k8s.sh \
  --compose-root /home/op/ratatoskr-compose \
  --target-overlay prod-rwx \
  --kubeseal-cert /home/op/sealed-secrets-pub.pem

# Resume after a transient failure
./scripts/migration/migrate-compose-to-k8s.sh --resume \
  --compose-root /home/op/ratatoskr-compose \
  --target-overlay prod-rwx \
  --kubeseal-cert /home/op/sealed-secrets-pub.pem

# Run only step 6 (DB restore)
./scripts/migration/migrate-compose-to-k8s.sh --step 6 \
  --compose-root /home/op/ratatoskr-compose \
  --target-overlay prod-rwo \
  --kubeseal-cert /home/op/sealed-secrets-pub.pem
```

### What the script does

1. **Step 1 — Pre-migration checklist** (`step_1_preflight`): checks required
   tools; verifies `$COMPOSE_ROOT` contains `docker-compose.yml` and `.env`;
   confirms the Compose stack has no running containers; validates that
   `APP_KEY`, `APP_URL`, `DB_DATABASE`, `DB_USERNAME`, and `DB_PASSWORD` are
   present in `.env`; confirms `kubectl cluster-info` is reachable; checks the
   target namespace does not already have a `unit3d-app` Deployment (unless
   `--resume`); estimates disk space at `$STATE_DIR` against 1.5× the
   `./storage` tree size. Persists initial state keys to `state.env`.

2. **Step 2 — Database backup** (`step_2_db_backup`): starts only the
   `mariadb` Compose service, runs `mariadb-dump --single-transaction --quick
   --lock-tables=false` against the database named in `DB_DATABASE`, writes the
   dump to `$STATE_DIR/db.sql`, stops `mariadb`, validates the dump contains at
   least 50 `CREATE TABLE` statements, and records the path, table count, and
   sha256 in `state.env`.

3. **Step 3 — Application data sync** (`step_3_data_sync`): creates
   `$STATE_DIR/storage.tar.gz` from `$COMPOSE_ROOT/storage/app/`. For
   `prod-rwx`, excludes the 3 Storage-aware disk subtrees from the tarball and
   runs three `rclone copy` commands (one per S3-aware disk, `--transfers 8`) to
   sync them to `$RCLONE_REMOTE:$S3_BUCKET/`. Records tarball path, sha256, and
   `S3_ROUTING_VERIFIED` in `state.env`.

4. **Step 4 — APP_KEY transfer** (`step_4_app_key`): reads `APP_KEY` from
   `$COMPOSE_ROOT/.env`, warns if it does not start with `base64:`, writes the
   key to `$STATE_DIR/.app_key` at mode `0600` for Step 5's use, and records
   only the sha256 hash in `state.env`. The EXIT trap shreds the file on script
   termination.

5. **Step 5 — Provision the K8s overlay** (`step_5_provision`): generates the
   secrets bundle per `--secrets-mode` (sealed-secrets: runs `kubeseal`; eso:
   emits an `ExternalSecret` template and halts for operator action; vanilla:
   emits a plaintext `Secret` and halts for operator review); applies
   `kustomize/overlays/$TARGET_OVERLAY` via `kubectl apply -k`; for
   sealed-secrets mode applies the bundle; waits up to 10 minutes for the
   `unit3d-migrate` Job to reach `Complete`; scales `unit3d-app` to 0 replicas
   (data not restored yet).

6. **Step 6 — Database restore** (`step_6_db_restore`): reads
   `MARIADB_ROOT_PASSWORD` from the in-cluster `mariadb-secrets` Secret; issues
   `DROP DATABASE IF EXISTS` + `CREATE DATABASE` against `mariadb-0`; pipes
   `$STATE_DIR/db.sql` into `mariadb` via `kubectl exec -i`; verifies the
   restored table count is at least the count recorded in Step 2; confirms the
   `users` table has at least one row.

7. **Step 7 — PVC data restore** (`step_7_pvc_restore`): applies the
   `pvc-loader-compose-import` Pod (image `$PVC_LOADER_IMAGE`, runs as UID/GID
   33, mounts `unit3d-storage` at `/storage`, `emptyDir` at `/tmp`,
   read-only root filesystem, all capabilities dropped); waits up to 180 seconds
   for the Pod to become Ready; copies `$STATE_DIR/storage.tar.gz` into the Pod
   via `kubectl cp`; extracts the tarball into `/storage/`; verifies the
   `images/users/avatars` subdirectory is present; deletes the loader Pod.

8. **Step 8 — Verification before cutover** (`step_8_verify`): re-applies the
   overlay to restore the canonical replica count; waits up to 600 seconds for
   the `unit3d-app` rollout to complete; exec-checks `php artisan --version` and
   `/app/storage` accessibility from a running pod (non-fatal warnings on
   failure, to tolerate S3-routed storage); prints the DNS cutover checklist
   from `upgrade-guide.md` § Path 1 Step 8 including the ADR-0003 `/announce`
   URL permanence warning.

### Recovery

Full rollback procedures are in
[`docs/upgrade-guide.md`](../../docs/upgrade-guide.md) § "Path 1 rollback".
Do not delete `$STATE_DIR` after a partial run — it holds both the rollback
artifacts and the state needed for `--resume`.

**Aborted in Step 1 (preflight)** — nothing was applied. Fix the failing check
and re-run from scratch.

**Aborted in Step 2 (DB backup)** — `mariadb-dump` may have produced a partial
file. Delete `$STATE_DIR/db.sql` before re-running, so Step 2 starts clean:

```bash
rm "$STATE_DIR/db.sql"
./scripts/migration/migrate-compose-to-k8s.sh --resume ...
```

**Aborted in Step 3 (tarball / rclone)** — delete the partial tarball before
resuming. For prod-rwx, `rclone copy` is idempotent — re-running re-syncs only
changed files, so no cleanup is needed on the S3 side:

```bash
rm "$STATE_DIR/storage.tar.gz"
./scripts/migration/migrate-compose-to-k8s.sh --resume ...
```

**Aborted in Step 5 (overlay provision)** — depends on the sub-step. The most
common failure is the `unit3d-migrate` Job timing out or failing. Inspect logs,
fix the underlying issue (typically a DB-credential or env mismatch), then
resume:

```bash
kubectl logs job/unit3d-migrate -n <namespace>
./scripts/migration/migrate-compose-to-k8s.sh --resume ...
```

**Aborted in Step 6 (DB restore)** — the database may be in a partial state.
The `DROP DATABASE IF EXISTS` at Step 6 start makes re-running safe: `--resume`
will re-drop and re-restore from `$STATE_DIR/db.sql`.

**Aborted in Step 7 (PVC restore)** — the loader Pod may still be running.
Delete it, then resume:

```bash
kubectl delete pod pvc-loader-compose-import -n <namespace>
./scripts/migration/migrate-compose-to-k8s.sh --resume ...
```

**Aborted in Step 8** — the app may be at `replicas=0` or mid-rollout. Fix the
underlying issue (check `kubectl describe deployment/unit3d-app -n <namespace>`
and pod events), then resume.

### Downtime envelope

Downtime begins when Step 2 starts (the Compose stack must be stopped before
the dump runs) and ends when Step 8 verification passes and traffic is confirmed
on the new K8s ingress. No Compose service serves traffic during this window.

| Dataset size | Expected window |
|---|---|
| < 5 GB | 15–30 min |
| 5–50 GB | 30 min – 2 h |
| > 50 GB | Plan a longer window. For the DB layer, consider `mariabackup` (physical hot backup, faster restore) instead of `mariadb-dump` — see [`docs/backup-restore.md`](../../docs/backup-restore.md). Run the migration script's Steps 3–8 only and perform the DB backup/restore manually. |

The bulk of the window is dominated by `tar czf` and `kubectl cp` of the storage
tarball and the `mariadb-dump | mariadb` round-trip. For prod-rwx, the rclone
S3 sync runs in parallel with the SQL pipeline and is typically network-bound.

### See also

- [`docs/upgrade-guide.md`](../../docs/upgrade-guide.md) § Path 1 — canonical
  procedure and rollback
- [`docs/adr/0002-storage-strategy-unit3d-storage.md`](../../docs/adr/0002-storage-strategy-unit3d-storage.md)
  — disk routing rationale (prod-rwo all-PVC vs prod-rwx hybrid)
- [`docs/adr/0003-ingress-controller-assumption.md`](../../docs/adr/0003-ingress-controller-assumption.md)
  — `/announce` URL permanence and DNS cutover constraint
- [`docs/adr/0004-secret-management.md`](../../docs/adr/0004-secret-management.md)
  — sealed-secrets / ESO neutrality
- [`docs/security-hardening.md`](../../docs/security-hardening.md) — APP_KEY
  discipline
