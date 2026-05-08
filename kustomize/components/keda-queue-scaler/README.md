# `kustomize/components/keda-queue-scaler/`

Opt-in Kustomize Component that replaces a CPU-based HPA on `unit3d-queue` with a Redis-queue-length-driven KEDA `ScaledObject`. Designed for `prod-rwx` and any operator-defined overlay where queue throughput is the binding constraint, not CPU.

**Off by default.** Operators include this Component explicitly in their overlay's `components:` list. Without KEDA installed in the cluster (see prerequisites below), the manifests fail at apply time on missing CRDs (`keda.sh/v1alpha1 ScaledObject`, `TriggerAuthentication`).

## Prerequisites

Operators MUST install KEDA in their cluster before applying an overlay that includes this Component:

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda --namespace keda --create-namespace
```

Upstream install docs: <https://keda.sh/docs/latest/deploy/>.

KEDA installation is operator-managed, not bundled here — KEDA is a cluster-wide controller (CRDs, operator pod, metrics adapter), the same way cert-manager and sealed-secrets are. Bundling it in ratatoskr would force the install on operators who don't want KEDA-driven autoscaling.

## What this Component ships

| File | Resource | Purpose |
|---|---|---|
| `scaledobject-queue.yaml` | `keda.sh/v1alpha1 ScaledObject` | Targets `unit3d-queue` Deployment. Scales 2→8 on Redis `queues:default` LLEN ≥ 10. |
| `triggerauthentication.yaml` | `keda.sh/v1alpha1 TriggerAuthentication` | Wires the ScaledObject's redis trigger to `redis-secrets.REDIS_PASSWORD`. |

## When this Component fires

Activated when the operator includes it in their overlay's `components:` list. The `ScaledObject` then:

1. Polls Redis every 15s (`pollingInterval`) for the LLEN of `queues:default`.
2. Targets average backlog of 10 jobs per replica (`listLength: "10"`).
3. Scales the `unit3d-queue` Deployment between `minReplicaCount: 2` and `maxReplicaCount: 8`.
4. Scale-up: aggressive (100% per 15s, no stabilization) — queue backlog is user-visible latency.
5. Scale-down: conservative (50% per minute, 5-minute stabilization) — idle workers cost little, churn costs job latency at the next spike.

KEDA creates an underlying HPA that owns the Deployment's `replicas` field while the ScaledObject is active. The base/ Deployment manifest's `replicas: 1` is overridden — operators don't need to patch it.

**Operators MUST NOT enable both this Component AND a CPU/memory HPA targeting `unit3d-queue`.** KEDA's HPA fights any user-managed HPA on the same Deployment; the result is oscillation, no clear scaling signal, and noisy logs. If the overlay's `kustomization.yaml` includes a `HorizontalPodAutoscaler` for `unit3d-queue`, remove it before adding this Component.

## Laravel queue list name assumption

`listName: queues:default` works for UNIT3D's stock queue config — Laravel's `QUEUE_CONNECTION=redis` writes to `queues:<connection-name>` where the default connection is named `default`. The unit3d-queue Deployment runs `php artisan queue:work` with no `--queue=` flag, which means it reads from `queues:default`.

Operators using named queues:

```bash
# unit3d-queue Deployment patched to:
php artisan queue:work --tries=3 --max-time=3600 --sleep=3 --queue=high,default,low
```

— must patch `listName` per scaler, OR ship multiple ScaledObjects (one per queue), OR use a single trigger with `listLength` reflecting the aggregate. The simplest pattern is one ScaledObject per logical priority lane:

```yaml
# Operator's overlay (NOT this Component)
patches:
  - target: { kind: ScaledObject, name: unit3d-queue }
    patch: |-
      apiVersion: keda.sh/v1alpha1
      kind: ScaledObject
      metadata:
        name: unit3d-queue
      spec:
        triggers:
          - type: redis
            metadata:
              address: redis:6379
              listName: queues:high
              listLength: "5"
              databaseIndex: "0"
              enableTLS: "false"
            authenticationRef:
              name: unit3d-queue-redis-auth
          - type: redis
            metadata:
              address: redis:6379
              listName: queues:default
              listLength: "20"
              databaseIndex: "0"
              enableTLS: "false"
            authenticationRef:
              name: unit3d-queue-redis-auth
```

## Opt-in pattern

Include from your overlay's `kustomization.yaml`:

```yaml
# overlays/prod-rwx/kustomization.yaml (excerpt — when prod-rwx lands)
components:
  - ../../components/ingress-traefik
  - ../../components/keda-queue-scaler   # ← uncomment to enable
```

The Component is shipped as a separate directory rather than bundled into the prod-rwx overlay because:

- KEDA isn't universal. Clusters without KEDA installed would fail validate-time on missing CRDs (`keda.sh/v1alpha1`) when running `kustomize-validate`. Keeping it as a Component means `prod-rwx` (without keda-queue-scaler) builds and validates cleanly even on KEDA-less clusters; operators who want KEDA opt in.
- Single responsibility: this Component's only job is queue autoscaling. Operators who want CPU autoscaling or no autoscaling drop it without touching the rest of the overlay.

## Authentication wiring

`TriggerAuthentication` references `redis-secrets.REDIS_PASSWORD` — the canonical Secret already populated by the operator's sealed-secrets workflow per [ADR-0004](../../../docs/adr/0004-secret-management.md). The same Secret the `unit3d-app` / `unit3d-queue` / `unit3d-scheduler` workloads consume via `envFrom`. Zero secret duplication.

If the operator's cluster uses KEDA in a non-default namespace (typical: `keda` namespace), KEDA's controller pod must be able to read `redis-secrets` in the `unit3d` namespace. KEDA's documentation on cross-namespace `TriggerAuthentication`:

- Default `TriggerAuthentication` (this Component) is namespaced — both the resource and the Secret it references must be in the same namespace as the `ScaledObject` target. ratatoskr satisfies this: `ScaledObject` targets `unit3d-queue` (in `unit3d`), `TriggerAuthentication` lives in `unit3d`, references `redis-secrets` in `unit3d`. KEDA's controller reads via the Secret API, no cross-namespace permission needed.
- `ClusterTriggerAuthentication` exists for cross-namespace patterns; not needed here.

## Validation note

Composing this Component with `kustomize/base/` via `kubectl kustomize` succeeds (Kustomize doesn't validate CRD schemas at build time). `kubeconform -strict` against K8s 1.32.0 schemas reports the `keda.sh/v1alpha1` CRDs as missing unless the schema-location flag includes the datreeio CRDs catalog (which the `kustomize-validate` skill already configures). Composed validation is part of the prod-rwx overlay's CI; this Component on its own is intentionally not added to a CI matrix because it's only deployable with KEDA installed.

## See also

- [ADR-0004](../../../docs/adr/0004-secret-management.md) — sealed-secrets / ESO secret patterns; `redis-secrets` lifecycle.
- [`kustomize/base/unit3d-queue/deployment.yaml`](../../base/unit3d-queue/deployment.yaml) — the workload this Component scales.
- KEDA Redis scaler reference: <https://keda.sh/docs/latest/scalers/redis-lists/>.
- KEDA `TriggerAuthentication` reference: <https://keda.sh/docs/latest/concepts/authentication/>.
