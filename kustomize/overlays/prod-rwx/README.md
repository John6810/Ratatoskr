# prod-rwx — production overlay for RWX storage clusters

Multi-replica HA production deployment of UNIT3D, designed for clusters with a `ReadWriteMany` storage class available. `unit3d-app` and `unit3d-queue` scale 2-N via HPA + PDB + RollingUpdate (zero-downtime app, conservative-default queue). MariaDB sized for the 5K-10K active-user envelope. S3 routing is **on by default** for the 3 Storage-aware disks per [ADR-0002](../../../docs/adr/0002-storage-strategy-unit3d-storage.md). The [`ingress-traefik`](../../components/ingress-traefik/) Component is composed by default; operators on nginx/ALB swap it in their fork.

For RWO-only clusters, see [`overlays/prod-rwo/`](../prod-rwo/).

## What this overlay ships

| Aspect | prod-rwx behavior | Source |
|---|---|---|
| `unit3d-app` | replicas: 2 (HPA 2-10), RollingUpdate `maxSurge:1 / maxUnavailable:0`, 1-4 CPU / 1-4 GiB | `patches/unit3d-app-multireplica.yaml` |
| `unit3d-queue` | replicas: 2 (HPA 2-8 CPU-only), RollingUpdate K8s defaults, base resources | `patches/unit3d-queue-multireplica.yaml` |
| `unit3d-scheduler` | replicas: 1 (HARD requirement — multiple schedulers = duplicate cron firings), no patch | base default |
| `mariadb` | 500m-2 CPU / 1-4 GiB, PVC 50Gi (vs base 10Gi) | `patches/mariadb-resources.yaml` |
| `unit3d-storage` PVC | accessModes: `[ReadWriteMany]`, storage: 50Gi (vs base RWO/5Gi) | `patches/pvc-unit3d-storage-rwx.yaml` |
| `meilisearch`, `redis` | base values (single-replica, fine for 5K-10K envelope) | base default |
| HPA | `unit3d-app` (CPU 70 + Memory 80, min 2 / max 10), `unit3d-queue` (CPU 70, min 2 / max 8) | `hpa/*.yaml` |
| PDB | `unit3d-app` (`minAvailable: 1`), `unit3d-queue` (`minAvailable: 1`) | `pdb/*.yaml` |
| Ingress | Traefik `IngressRoute` + cert-manager Let's Encrypt + middlewares | `components/ingress-traefik` |
| S3 routing | `torrent-files`, `subtitle-files`, `attachment-files` → S3 (operator-supplied bucket) | `values.env` |
| Trusted proxies | RFC1918 + RFC4193 + IPv6 link-local default | `values.env` |
| Defense-in-depth config | `APP_ENV=production`, `APP_DEBUG=false`, `LOG_LEVEL=info`, `MEILI_ENV=production` | `patches/unit3d-config-prod.yaml` |
| `bootstrap-app-key` Component | OFF by default (opt-in for "deploy-and-go" only) | commented in `kustomization.yaml` |
| `keda-queue-scaler` Component | OFF by default (CPU HPA on `unit3d-queue` is the v0.3 baseline) | commented in `kustomization.yaml` |

## Differences from prod-rwo

| Axis | prod-rwo | prod-rwx |
|---|---|---|
| `unit3d-app` replicas | 1 | 2 (HPA 2-10) |
| `unit3d-app` strategy | Recreate | RollingUpdate `maxSurge:1 / maxUnavailable:0` |
| `unit3d-app` resources (limits) | base (1 CPU / 2 GiB) | 4 CPU / 4 GiB |
| `unit3d-queue` replicas | 1 | 2 (HPA 2-8) |
| `unit3d-queue` strategy | Recreate | RollingUpdate (K8s defaults) |
| HPA shipped | none | yes — `unit3d-app` + `unit3d-queue` |
| PDB shipped | none (single-replica = PDB meaningless) | yes — `unit3d-app` + `unit3d-queue` `minAvailable:1` |
| MariaDB resources | base (250m-1 CPU / 512Mi-2Gi) | 500m-2 CPU / 1-4 GiB |
| MariaDB PVC | base (10 GiB) | 50 GiB |
| `unit3d-storage` PVC | RWO, 5 GiB | RWX, 50 GiB |
| S3 routing | OFF by default (opt-in via `unit3d-storage-secrets`) | **ON by default** (FILESYSTEM_*=s3 in `values.env`) |
| `unit3d-storage-secrets` | optional | **mandatory** (S3 routing requires AWS creds) |
| Required cluster capability | RWO storage class | **RWX storage class** + `allowVolumeExpansion` recommended |
| Target user envelope | ~1K-3K active users | ~5K-10K active users |

> ⚠️ **PVC `accessModes` is immutable post-create.** A live prod-rwo cluster cannot migrate to prod-rwx via `kubectl apply -k`. See **Upgrade gotchas** below.

## RWX storage class options (2026 landscape)

ratatoskr is RWX-provider-agnostic. The PVC patch sets `accessModes: [ReadWriteMany]` and leaves `storageClassName` empty (cluster default). Operators select an RWX class based on platform:

| Provider | Type | Notes |
|---|---|---|
| [Longhorn](https://longhorn.io/) | Self-hosted, CNCF Incubating | RWX via NFSv4 share-manager pod. Easiest self-hosted option; `allowVolumeExpansion: true` supported. |
| [CephFS via Rook](https://rook.io/) | Self-hosted, CNCF Graduated | Production-grade, more setup. Best perf at scale; storage class with `volumeBindingMode: WaitForFirstConsumer` recommended. |
| [Azure Files](https://learn.microsoft.com/azure/aks/azure-files-csi) | Cloud managed | SMB or NFS modes. Premium tier (`sku: Premium_LRS`) for sub-ms latency; standard tier acceptable for image-disk workload. |
| [AWS EFS](https://aws.amazon.com/efs/) | Cloud managed | NFSv4-only. Network bandwidth scales with provisioned throughput; Bursting mode acceptable for image disks. |
| [GCP Filestore](https://cloud.google.com/filestore) | Cloud managed | NFS. High-throughput tiers (Zonal, Regional) available; Basic HDD tier sufficient for v0.3 sizing. |
| [JuiceFS](https://juicefs.com/) | S3-backed RWX | Requires Redis or compatible KV for metadata; POSIX-compliant. Operator who already runs Redis can reuse it (separate database). |

For pure cloud-managed deployments (AKS, EKS, GKE), the platform's native CSI driver is the path of least resistance. Self-hosted operators on bare metal or single-cloud-region typically pick Longhorn for ease of install or CephFS for proven scale.

## Operator workflow

Step-by-step for a fresh prod-rwx deploy:

1. **Fork ratatoskr** to your GitOps repo (or maintain a sibling repo with overlays patched against the upstream `kustomize/`).

2. **Edit `values.env`**:
   - Replace `CHANGEME.example.org` with your real tracker domain.
   - Adjust `TRUSTED_PROXIES` if tightening to the ingress controller's pod CIDR (see [Tightening TRUSTED_PROXIES](#tightening-trusted_proxies) below).
   - `FILESYSTEM_*=s3` is the prod-rwx default. Set to `local` only if you explicitly want to disable S3 routing — defeats the prod-rwx HA premise (loses RWX-shared storage benefits across replicas).

3. **Generate sealed-secrets** from `base/secrets-templates/` via `kubeseal`. Required at prod-rwx:
   - `unit3d-secrets` (APP_KEY, mailer creds if used)
   - `mariadb-secrets`
   - `redis-secrets`
   - `meilisearch-secrets`
   - `unit3d-storage-secrets` (S3 creds — **MANDATORY at prod-rwx**)

   See [`secrets/README.md`](secrets/) for the full kubeseal recipe. Drop the resulting `*-sealed.yaml` files in `secrets/`.

4. **Uncomment** the matching `- secrets/*-sealed.yaml` lines in `kustomization.yaml` `resources:` block.

5. **Patch ingress-traefik domain placeholders** (Host, dnsNames, ACME email) in your fork's overlay. See [`components/ingress-traefik/README.md`](../../components/ingress-traefik/README.md) for the strategic merge example. Do this in your fork; do **not** modify ratatoskr upstream.

6. **Apply the ingress namespace label** so `base/networkpolicies/30-ingress-to-app.yaml` permits Traefik → unit3d-app:
   ```bash
   kubectl label namespace traefik network.ratatoskr.io/ingress=true
   ```
   Replace `traefik` with your actual ingress controller's namespace (`ingress-nginx`, `kong`, etc.) if different.

7. **Optional — KEDA queue scaling.** If you want Redis-queue-length-driven autoscaling instead of CPU on `unit3d-queue`:
   - Install KEDA in your cluster: <https://keda.sh/docs/deploy/>
   - Uncomment `- ../../components/keda-queue-scaler` in `kustomization.yaml` `components:` block.
   - **Remove** `- hpa/unit3d-queue-hpa.yaml` from `resources:` (two HPAs targeting the same Deployment cause oscillation per K8s docs).

8. **Apply:**
   ```bash
   kubectl apply -k kustomize/overlays/prod-rwx/
   ```

9. **Verify rollout:**
   ```bash
   kubectl get pods -n unit3d -w
   ```
   Expected sequence: `unit3d-migrate` Job runs and completes → `unit3d-app` (2 replicas), `unit3d-queue` (2 replicas), `unit3d-scheduler` (1 replica) become Ready → cert-manager populates `unit3d-tls` Secret → IngressRoute starts serving.

## Sizing guidance

The shipped values target ~5K-10K active users on a 3-node cluster:

| Component | Tuning | Scale-up trigger |
|---|---|---|
| `unit3d-app` | HPA min 2 / max 10, 1-4 CPU, 1-4 GiB | Avg CPU > 70% sustained → bump max replicas |
| `unit3d-queue` | HPA min 2 / max 8 | Queue backlog or KEDA Component |
| `mariadb` | 500m-2 CPU, 1-4 GiB, PVC 50 GiB | Slow query log, buffer pool hit ratio |
| `meilisearch`, `redis` | base values | Single-replica fine through 10K |

For >10K active users:

- Bump `mariadb` resources (4-8 CPU, 8-16 GiB) and PVC (100-500 GiB).
- Consider HPA `maxReplicas: 20+` on `unit3d-app`.
- Future v0.7 ADR will document MariaDB Galera HA. At >50K users, single-replica MariaDB becomes the bottleneck (write contention, no read scaling).
- Consider KEDA opt-in (queue length is a more accurate signal than CPU at high throughput).

## Tightening TRUSTED_PROXIES

Default covers RFC1918 + RFC4193 + IPv6 link-local. Maximum security posture: limit to the ingress controller's pod CIDR specifically.

```bash
# Find your ingress controller's pod CIDR
kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}'
```

Then set `TRUSTED_PROXIES=10.244.0.0/16` (or your cluster's actual pod CIDR) in `values.env`. The default broad ranges cover heterogeneous network setups; tightening is operator policy.

## PDB rationale

Math invariant for `unit3d-app` voluntary disruptions:

```
HPA minReplicas:    2  (always at least 2 pods up)
PDB minAvailable:   1  (at most 1 pod can voluntarily drain)
RollingUpdate maxUnavailable:  0  (zero pod-down during rollouts)
```

→ Cluster always has at least 1 `unit3d-app` pod serving during node drain, cluster upgrade, or kustomize rollout.

`unit3d-queue` PDB applies cleanly under both autoscaling paths:
- CPU HPA (default): `minReplicas: 2` ensures PDB `minAvailable: 1` always satisfied.
- KEDA ScaledObject (opt-in): `minReplicaCount: 2` same arithmetic. KEDA's underlying HPA respects PDB the same way standard HPA does.

`unit3d-scheduler` has no PDB by design — `replicas: 1` is a hard requirement (multiple schedulers = duplicate cron firings, race conditions on counters and ratios).

## APP_KEY policy

Operator-supplied via sealed-secrets per [ADR-0004](../../../docs/adr/0004-secret-management.md) default. The `bootstrap-app-key` Component is shipped in `kustomize/components/` but commented out in this overlay's `components:` list — opt-in only for "deploy-and-go" first-time operators who want in-cluster `APP_KEY` generation.

For prod operators who already use `kubeseal`, the operator-supplied flow is the prod-grade path. `APP_KEY` is generated once and never rotated — see ADR-0004 for the rotation footgun rationale.

## Upgrade gotchas

Two Kubernetes invariants operators MUST know before attempting prod-rwo → prod-rwx migration or VCT changes:

### 1. PVC `accessModes` is immutable post-create

Migrating an existing prod-rwo cluster (`unit3d-storage` PVC = RWO) to prod-rwx (RWX) **CANNOT be done in-place via `kubectl apply -k`**. Kubernetes rejects the change with `Forbidden: spec is immutable after creation`. Options:

- **Fresh deploy on a new namespace.** Restore data via `mariabackup` (the v0.2 backup pipeline supports this end-to-end). Recommended path; operator switches DNS to the new cluster after parity verified.
- **Manual PVC migration.** Detach pod consumers (`kubectl scale --replicas=0` on `unit3d-app`/`unit3d-queue`/`unit3d-scheduler`), copy data off the RWO PVC, `kubectl delete pvc unit3d-storage`, recreate via `apply -k`, copy data back. Disruptive; only viable during a planned maintenance window.

The v0.4 unified migration tool will automate the second path with checksum verification and rollback. Until v0.4 lands, fresh-deploy is the safe path.

### 2. VCT (StatefulSet `volumeClaimTemplates`) storage size bumps

The `mariadb` StatefulSet VCT change from 10Gi → 50Gi is **metadata-only** — applied at fresh StatefulSet deploy. Bumping an existing VCT-backed PVC requires **two conditions**:

1. The storage class supports `allowVolumeExpansion: true`. Verify:
   ```bash
   kubectl get sc <name> -o jsonpath='{.allowVolumeExpansion}'
   ```
2. A separate `kubectl patch` after the VCT change lands:
   ```bash
   kubectl patch pvc data-mariadb-0 \
     --namespace unit3d \
     --type=merge \
     --patch '{"spec":{"resources":{"requests":{"storage":"50Gi"}}}}'
   ```

If `allowVolumeExpansion` is `false` or absent, the bump requires a fresh StatefulSet (data migration via `mariabackup` first).

## NetworkPolicy ingress label

`base/networkpolicies/30-ingress-to-app.yaml` permits ingress to `unit3d-app:80` from any pod in a namespace labeled `network.ratatoskr.io/ingress=true`. Without this label, ALL traffic from the ingress controller is denied at the namespace boundary — the default-deny baseline applies.

```bash
# Apply (replace 'traefik' with your actual ingress namespace if different):
kubectl label namespace traefik network.ratatoskr.io/ingress=true

# Verify:
kubectl get namespace traefik -o jsonpath='{.metadata.labels}'
# Expected output includes: "network.ratatoskr.io/ingress":"true"
```

## See also

- [ADR-0001](../../../docs/adr/0001-database-deployment-topology.md) — MariaDB single-replica until v0.7 Galera reopen.
- [ADR-0002](../../../docs/adr/0002-storage-strategy-unit3d-storage.md) — S3 hybrid storage strategy, disk inventory, controller refactor PRs upstream.
- [ADR-0003](../../../docs/adr/0003-ingress-controller-assumption.md) — ingress controller positioning, Component-based decomposition, /announce hard rules.
- [ADR-0004](../../../docs/adr/0004-secret-management.md) — sealed-secrets default, ESO alternative, APP_KEY rotation policy.
- [`overlays/prod-rwo/README.md`](../prod-rwo/README.md) — RWO-storage baseline; prod-rwx differences highlighted in the comparison table above.
- [`components/ingress-traefik/README.md`](../../components/ingress-traefik/README.md) — domain customization, two-Route split, INGRESS_TLS toggle.
- [`components/keda-queue-scaler/README.md`](../../components/keda-queue-scaler/README.md) — KEDA opt-in workflow, do-not-double-HPA constraint.
- [`components/bootstrap-app-key/README.md`](../../components/bootstrap-app-key/README.md) — APP_KEY in-cluster generation (off by default in prod).
