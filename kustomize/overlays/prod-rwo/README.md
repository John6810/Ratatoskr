# `kustomize/overlays/prod-rwo/`

Production overlay for clusters **without** an RWX storage class. Single-replica `unit3d-app` / `unit3d-queue` / `unit3d-scheduler`, `strategy: Recreate`, RWO PVC for both `unit3d-storage` (image disks per [ADR-0002](../../../docs/adr/0002-storage-strategy-unit3d-storage.md)) and the StatefulSets (mariadb, redis, meilisearch). Ingress via the [`ingress-traefik`](../../components/ingress-traefik/) Component.

For multi-replica HA prod with RWX storage, KEDA queue-length autoscaling, and HPA: see `kustomize/overlays/prod-rwx/` (separate overlay, separate commit).

## What this overlay ships

- `resources: [../../base]` — every base manifest (15 K8s resources at base alone, see `kustomize/base/README.md`).
- `components: [ingress-traefik]` — `IngressRoute` + Middlewares + cert-manager `ClusterIssuer` + `Certificate`. Operators on nginx-ingress / AWS ALB swap to a sibling `ingress-vanilla` Component (TBD at v0.3 scaffolding).
- `configMapGenerator` merging `values.env` into `unit3d-config` — operator-supplied `APP_URL`.
- `patches` — defense-in-depth ConfigMap pin: `APP_ENV=production`, `APP_DEBUG=false`, `LOG_LEVEL=info`, `MEILI_ENV=production`. Matches the base defaults but explicit at the overlay level.
- `secrets/` directory — empty by default (`.gitkeep` + README only). Operators drop their sealed-secret manifests here; `kustomization.yaml` has commented-out `resources:` lines they uncomment after.

## What this overlay does NOT ship

- **Sealed-secret manifests.** Per [ADR-0004](../../../docs/adr/0004-secret-management.md) and [`secrets/README.md`](secrets/), operators bring their own. The `kustomization.yaml` `resources:` list has commented-out lines for the five expected sealed files; uncomment after dropping the files.
- **Resource limit overrides.** Base values (req 250m/512Mi for `unit3d-app`, 250m/512Mi for `mariadb`, etc. per `.claude/rules/k8s.md` baseline) are the prod-rwo baseline. Sized for ~1K–3K active users on a 3-node cluster. For 5K+ scale envelopes, operators patch `unit3d-app`, `mariadb`, and `meilisearch` in their fork (no patches shipped here — premature standardization on a single scale point).
- **PodDisruptionBudget.** Single-replica makes PDB meaningless: a `minAvailable: 1` PDB would block every voluntary disruption (node drain, cluster upgrade), and `minAvailable: 0` is functionally absent. The prod-rwx overlay (multi-replica HPA min=2) ships a PDB.
- **`bootstrap-app-key` Component.** Off by default in prod per ADR-0004 — operator-supplied `APP_KEY` via sealed-secrets is the prod-grade flow. Operators who want in-cluster `APP_KEY` generation uncomment the Component reference in `kustomization.yaml`.
- **NetworkPolicy patches.** Base ships the full default-deny + additive-allow set (8 NetworkPolicies). prod-rwo inherits all of them unmodified. The only operator-side step is labeling the ingress namespace (see operator workflow below).

## Operator workflow

Step-by-step for a fresh cluster deploy:

1. **Fork ratatoskr.** This overlay lives in the upstream repo as scaffolding; operator-specific values (APP_URL, sealed secrets, domain patches) belong in your fork. Maintain a sibling GitOps repo if you prefer that pattern; the steps are equivalent.

2. **Edit `values.env`.** Replace `CHANGEME.example.org` with your tracker's real domain:
   ```bash
   sed -i 's|https://CHANGEME.example.org|https://tracker.your-domain.example|' \
     kustomize/overlays/prod-rwo/values.env
   ```

3. **Seal your secrets** per [`secrets/README.md`](secrets/). Drop the resulting `*-sealed.yaml` files in `secrets/`, and **never** commit the intermediate cleartext templates.

4. **Uncomment** the matching `resources:` lines in `kustomization.yaml`:
   ```yaml
   resources:
     - ../../base
     - secrets/unit3d-secrets-sealed.yaml
     - secrets/mariadb-secrets-sealed.yaml
     - secrets/redis-secrets-sealed.yaml
     - secrets/meilisearch-secrets-sealed.yaml
   # - secrets/unit3d-storage-secrets-sealed.yaml   # only if S3 routing opt-in
   ```

5. **Patch the ingress-traefik domain placeholders** in `kustomization.yaml`'s `patches:` block. The same domain string from `values.env` goes into the IngressRoute Host header, the Certificate's `dnsNames`, and the ClusterIssuer's `email`. The strategic-merge recipe is documented in [`../../components/ingress-traefik/README.md`](../../components/ingress-traefik/README.md#operator-workflow--three-placeholders-to-patch).

6. **Label the ingress controller's namespace** so `base/networkpolicies/30-ingress-to-app.yaml` permits Traefik → unit3d-app:80:
   ```bash
   kubectl label namespace traefik network.ratatoskr.io/ingress=true
   # or wherever your Traefik controller pods live
   ```

7. **Apply:**
   ```bash
   kubectl apply -k kustomize/overlays/prod-rwo/
   ```

The bootstrap chain runs in this order: `unit3d-migrate` Job (migrate + seed + scout-sync) → `unit3d-app` Deployment becomes Ready → IngressRoute starts serving once cert-manager populates the `unit3d-tls` Secret.

## Sizing guidance

Base values are calibrated for ~1K–3K active users on a 3-node cluster. For scale envelopes beyond that:

| Component | Tune up first | Then |
|---|---|---|
| `unit3d-app` | 500m–1000m CPU req, 1Gi–2Gi memory | Move to prod-rwx for multi-replica |
| `mariadb` | 1Gi–2Gi memory, larger PVC (50Gi+) | v0.7 introduces Galera/replicas (ADR-0001 reopen target) |
| `meilisearch` | 1Gi memory, PVC sized to index growth | Single-node by design — no scale-out at v0.3 |
| `redis` | 256Mi–512Mi memory | Same — no clustering at v0.3 |

Operators on RWX clusters should evaluate `prod-rwx` instead of scaling prod-rwo vertically; multi-replica `unit3d-app` is the higher-leverage move.

## APP_KEY policy

`APP_KEY` is operator-supplied via sealed-secrets per ADR-0004 default. The prod-rwo overlay does **not** include the `bootstrap-app-key` Component. If `APP_KEY` is missing from your sealed-secrets bundle, the `unit3d-migrate` Job fails at runtime with "no APP_KEY set" — surface the error and add the key, never `kubectl exec` into a pod to generate one ad-hoc (loses the GitOps audit trail).

For "deploy-and-go" first-time operators who want in-cluster `APP_KEY` generation without learning kubeseal, uncomment the `bootstrap-app-key` Component reference in `kustomization.yaml`. Off by default in prod for the reasons in ADR-0004.

## See also

- [ADR-0001](../../../docs/adr/0001-database-deployment-topology.md) — MariaDB embedded StatefulSet topology (toggle for managed DB).
- [ADR-0002](../../../docs/adr/0002-storage-strategy-unit3d-storage.md) — hybrid storage; prod-rwo runs on RWO PVC, S3 routing opt-in via `unit3d-storage-secrets`.
- [ADR-0003](../../../docs/adr/0003-ingress-controller-assumption.md) — ingress controller positioning, /announce hard rules.
- [ADR-0004](../../../docs/adr/0004-secret-management.md) — sealed-secrets default, operator-supplied APP_KEY.
- [`../../components/ingress-traefik/README.md`](../../components/ingress-traefik/README.md) — the Component this overlay composes.
- [`secrets/README.md`](secrets/) — kubeseal workflow.
