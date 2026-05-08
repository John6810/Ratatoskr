# `kustomize/overlays/dev/`

Development overlay for K3s mono-node, Docker Desktop, Kind, or any single-node Kubernetes that an operator can `kubectl apply -k` against without external dependencies. Targets the **deploy-and-go** persona: minimal setup, no sealed-secrets controller required, no S3 endpoint, no DNS, no external load balancer.

## What this patches vs `base/`

- **`unit3d-config` ConfigMap** — adds `APP_ENV=local`, `APP_DEBUG=true`, `LOG_LEVEL=debug`, `MEILI_ENV=development`. The base values for `DB_HOST`, `REDIS_HOST`, `MEILISEARCH_HOST`, `APP_URL`, `VITE_ECHO_ADDRESS`, etc. are preserved (strategic merge).
- **Resources halved across the board** (`patches/resources-*.yaml`) so the full stack fits comfortably on a 4 GB K3s node:

  | Component | base req → dev req | base lim → dev lim |
  |---|---|---|
  | mariadb | 250m/512Mi → 100m/256Mi | 1000m/2Gi → 500m/1Gi |
  | redis | 50m/128Mi → 25m/64Mi | 200m/512Mi → 100m/256Mi |
  | meilisearch | 100m/256Mi → 50m/128Mi | 500m/1Gi → 250m/512Mi |
  | unit3d-app | 250m/512Mi → 100m/256Mi | 1000m/2Gi → 500m/1Gi |
  | unit3d-queue | 100m/256Mi → 50m/128Mi | 500m/1Gi → 250m/512Mi |
  | unit3d-scheduler | 50m/128Mi → 25m/64Mi | 200m/256Mi → 100m/256Mi |

- **PVC sizes shrunk to 1Gi each** (mariadb, redis, meilisearch via VCT; unit3d-storage as standalone PVC). VCT updates only land on a fresh deploy — Kubernetes rejects size changes on existing StatefulSets, so re-deploying against a populated dev cluster requires `kubectl delete -k` first.

- **`bootstrap-app-key` Component included.** The Job no-ops in dev because the `secretGenerator` below pre-populates `APP_KEY`, but including it exercises the Component path on every CI build of this overlay.

## Secrets — DEV ONLY

The overlay generates four Secrets via `secretGenerator` with `disableNameSuffixHash: true` and deterministic placeholder values. **Never reuse these values outside dev.** Anyone with read access to this file knows every credential.

| Secret | Keys | Notes |
|---|---|---|
| `unit3d-secrets` | `APP_KEY` (32 zero bytes, base64-encoded), `DEFAULT_OWNER_NAME`, `DEFAULT_OWNER_EMAIL`, `DEFAULT_OWNER_PASSWORD` | Format-valid APP_KEY, zero entropy. Acceptable in dev only. |
| `mariadb-secrets` | `MARIADB_ROOT_PASSWORD`, `DB_PASSWORD`, `MARIADB_BACKUP_PASSWORD` | Plain `dev-*` literals. |
| `redis-secrets` | `REDIS_PASSWORD` | Plain `dev-redis-password`. |
| `meilisearch-secrets` | `MEILI_MASTER_KEY` | Padded to 48 bytes — Meili production mode requires 16+ bytes. |

`unit3d-storage-secrets` is **not** generated. Every disk in `config/filesystems.php` falls back to its `local` driver default since the `FILESYSTEM_<DISK>` env vars are unset, and the Deployment's `secretRef` for `unit3d-storage-secrets` is marked `optional: true` so its absence does not block pod start. Per ADR-0002 hybrid storage model: dev runs all 17 disks on the local PVC, no S3 routing.

For prod (sealed-secrets / ESO), see `kustomize/overlays/prod-rwo/`, `kustomize/overlays/prod-rwx/` (when those land) and [ADR-0004](../../../docs/adr/0004-secret-management.md).

## Deploy

```bash
# Fresh cluster, no NetworkPolicy controller required for basic dev
# (default-deny only enforces with a CNI that supports NetworkPolicies
# — k3s defaults work; Kind needs Calico or similar).
kubectl apply -k kustomize/overlays/dev
```

Wait for the bootstrap chain:
```bash
kubectl wait --for=condition=complete job/unit3d-bootstrap-app-key -n unit3d --timeout=2m
kubectl wait --for=condition=complete job/unit3d-migrate -n unit3d --timeout=5m
kubectl wait --for=condition=available deployment/unit3d-app -n unit3d --timeout=5m
```

## Testing without ingress

The dev overlay does not configure an ingress controller. Reach `unit3d-app` via port-forward:

```bash
kubectl port-forward -n unit3d svc/unit3d-app 8080:80
# Open http://localhost:8080 — log in with admin / dev-not-a-real-password
```

To test the bootstrap admin login, the credentials are deterministic:
- email: `admin@dev.local`
- password: `dev-not-a-real-password`

Rotate the password via the UNIT3D admin UI on first login if you plan to keep the dev cluster running.

## Teardown

```bash
kubectl delete -k kustomize/overlays/dev
# PVCs are NOT deleted by `kubectl delete -k` (claim retention policy).
# Clean them up explicitly:
kubectl delete pvc -n unit3d --all
# Or wipe the whole namespace:
kubectl delete namespace unit3d
```

## See also

- [ADR-0001](../../../docs/adr/0001-database-deployment-topology.md) — MariaDB embedded StatefulSet topology.
- [ADR-0002](../../../docs/adr/0002-storage-strategy-unit3d-storage.md) — hybrid storage; dev keeps all disks on `local`.
- [ADR-0004](../../../docs/adr/0004-secret-management.md) — sealed-secrets default in prod, dev overlay uses `secretGenerator` with deterministic values.
- [`kustomize/components/bootstrap-app-key/README.md`](../../components/bootstrap-app-key/README.md) — Component included by this overlay.
