---
applies-to:
  - kustomize/**
  - helm/**
  - argocd/**
---

# Kubernetes rules

> Active when writing or editing manifests under `kustomize/`, `helm/`, or `argocd/`. Complements `00-global.md`. The `k8s-reviewer` agent audits results; these rules guide authoring.

## Target version

- **Kubernetes 1.32** is the current target. Bump in lockstep with the cluster baseline; never silently change the target API versions.
- **Avoid deprecated APIs**: `policy/v1beta1 PodDisruptionBudget`, `extensions/v1beta1 Ingress`, `autoscaling/v2beta2 HPA`. Use the GA equivalents.

## Naming & labels

- **Namespace**: `unit3d` for everything. Set explicitly on every namespaced resource (Kustomize transformer is OK, implicit `default` is not).
- **Resource names**: `<component>` lowercase with hyphens. Examples: `mariadb`, `redis`, `meilisearch`, `unit3d-app`, `unit3d-queue`, `unit3d-scheduler`, `unit3d-reverb`. No `unit3d-mariadb` — the namespace already scopes it.
- **Recommended labels** on every resource:
  ```yaml
  app.kubernetes.io/name: <component>
  app.kubernetes.io/instance: ratatoskr
  app.kubernetes.io/component: <database|cache|search|app|worker|scheduler|broadcast>
  app.kubernetes.io/part-of: ratatoskr
  app.kubernetes.io/managed-by: <Helm|Kustomize|ArgoCD>
  ```

## Resource baselines

Document expected resources in values/configmap, never hardcode without a value override. Sensible defaults for the `dev` overlay:

| Component | requests CPU / mem | limits CPU / mem |
|---|---|---|
| `unit3d-app` | 250m / 512Mi | 1000m / 2Gi |
| `unit3d-queue` | 100m / 256Mi | 500m / 1Gi |
| `unit3d-scheduler` | 50m / 128Mi | 200m / 256Mi |
| `mariadb` | 250m / 512Mi | 1000m / 2Gi |
| `redis` | 50m / 128Mi | 200m / 512Mi |
| `meilisearch` | 100m / 256Mi | 500m / 1Gi |
| `reverb` | 100m / 128Mi | 300m / 512Mi |

`prod` overlay scales these up; never down. Document any change in the relevant `values-*.yaml` or overlay README.

## Storage

- **Single-replica + RWO PVC** is acceptable only for `dev` and Compose paths. Tag the file with a comment.
- **Multi-replica setups must use S3-compatible** for the Laravel `storage/` disk. Never RWX hacks except for documented edge cases.
- **MariaDB and MeiliSearch use StatefulSets** with their own PVCs. Never deploy them as Deployment + PVC.
- **PVC `storageClassName` is not hardcoded** — use `${STORAGE_CLASS}` value or rely on the cluster default.

## Secrets

- **No raw `Secret` resources committed with base64 values.** Always sealed-secrets or external-secrets. Base64 is encoding, not encryption.
- **`APP_KEY` lives in a long-lived Secret**, generated once. The migration init container does not regenerate it.
- **Secret names follow the pattern `<component>-secrets`**: `unit3d-secrets`, `mariadb-secrets`, `meilisearch-secrets`.
- **Reference secrets via `valueFrom.secretKeyRef`**, never inline. Even in test fixtures.

## NetworkPolicy

- **Default-deny is required in `prod`.** Add a `default-deny-all` policy first, then explicit allows.
- **CoreDNS egress allow** is required for every namespace that has policies. Without it, every pod is broken.
- **`policyTypes` always explicit** (`Ingress`, `Egress`, or both). Never rely on defaults.
- **Match labels precisely.** A `podSelector: {}` matches all pods in the namespace; use it deliberately.

## Workload patterns

- **Migrations as a `Job` (Kustomize) or pre-install hook (Helm)**, never the entrypoint of the app pod. Use `helm.sh/hook: pre-install,pre-upgrade` and `helm.sh/hook-weight` for ordering.
- **Scheduler is a `CronJob`** with schedule `* * * * *` running `php artisan schedule:run`. Concurrency policy `Forbid` to avoid overlap.
- **Queue workers are a separate `Deployment`** — distinct image command, distinct HPA. Co-locating workers in the app pod is rejected.
- **Reverb is its own `Deployment` + `Service` on port 8080.** Sticky sessions (Traefik annotation or session affinity) on the Service.
- **`/announce` is served by `unit3d-app`**, not a separate daemon. Routing rule on the Ingress, not a different Service. See [`/announce` traffic rules](#announce-traffic-rules) below for hard constraints on the route itself.

## `/announce` traffic rules

Hard constraints on the BitTorrent announce path. Full rationale, alternatives, and trade-offs in [ADR-0003](../../docs/adr/0003-ingress-controller-assumption.md). The `k8s-reviewer` agent flags violations on PRs touching ingress routing.

- **Never configure body-rewriting or substitution middleware on `/announce`.** The response is bencoded; any rewrite corrupts the payload and breaks every connected client. Default ingress configurations are safe; the risk is operator-added middlewares (Traefik substitution, nginx `sub_filter`, etc.).
- **Never configure redirects on `/announce`** — 301, 302, scheme rewrites, or trailing-slash rewrites that alter the URL. BitTorrent clients (rtorrent, older qBittorrent variants) do not reliably follow redirects, and `.torrent` files are immutable: the announce URL is baked in forever.
- **Never enable response compression (gzip) on `/announce`** by default. Some BT client decoders are historically brittle; the cost of being wrong (silent breakage for a subset of users) outweighs the bandwidth saving on typically-small announce responses.
- **Trusted proxy headers must be forwarded.** The ingress controller forwards `X-Forwarded-For`, `X-Forwarded-Proto`, and `X-Real-IP`; `unit3d-app` reads them via `TRUSTED_PROXIES` (the controller's pod CIDR). Without this chain, every peer logs as the ingress IP — peer tracking, ratio enforcement, ban hammer, and rate limits all see one synthetic address. Required at every overlay (dev, staging, prod) — a tracker silently logging wrong client IPs is worse than a broken tracker.

## Helm conventions

- **Subcharts behind toggles** (`mariadb.enabled`, `redis.enabled`, `meilisearch.enabled`, default `true`). Operators with managed databases turn them off.
- **`Chart.yaml` `appVersion`** = UNIT3D version (`v9.2.0`). `version` = chart version, bumped on every chart change.
- **`values.yaml` documented inline** — every key has a comment explaining what it does and what the default expects.
- **Templates use `tpl` for user-supplied values** that may contain template syntax (e.g. annotations).

## Kustomize conventions

- **`base/` is environment-agnostic** — no replicas count, no resource limits, no image tags pinned beyond the build image. Overlays set those.
- **Overlays patch, never duplicate.** If `prod/deployment.yaml` looks like a copy of `base/deployment.yaml`, refactor into a strategic merge patch.
- **`kustomization.yaml` has `commonLabels` and `namePrefix` set per overlay** when warranted (e.g. `dev-` prefix in dev overlay).

## ArgoCD

- **`ApplicationSet` over manual `Application`** when more than one environment is targeted. The repo ships an ApplicationSet template.
- **`syncPolicy.automated` with `prune: true, selfHeal: true`** for production; manual sync acceptable for `dev` if the operator wants a click in between.
- **`ignoreDifferences` only with a written reason in the Application annotations.** Silent diffs accumulate and rot.

## Hard rules

- **Never set `imagePullPolicy: Always`** on a pinned tag — defeats caching, slow deploys.
- **Never use `:latest`** in any committed manifest, even in dev overlays.
- **Never expose Reverb without auth** in any overlay.
- **Never commit raw kubeconfigs** in `argocd/` or anywhere else.
- **Run the relevant validation skill** before suggesting a commit: `kustomize-validate` for Kustomize changes, `helm-lint` for chart changes.
