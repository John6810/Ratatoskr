# `kustomize/components/bootstrap-app-key/`

Opt-in Kustomize Component that generates Laravel's `APP_KEY` in-cluster on a fresh install and patches it into `unit3d-secrets`. **Off by default in production overlays** per [ADR-0004](../../../docs/adr/0004-secret-management.md). Production operators supply `APP_KEY` via sealed-secrets or external-secrets-operator; this Component exists for the "deploy-and-go" first-time persona who wants a working tracker without learning `kubeseal` first.

## What it does

A `Job` with two containers:

1. **initContainer `generate-key`** (`ghcr.io/john6810/unit3d:v9.2.0`): runs `php artisan key:generate --show` and writes the result to a shared `emptyDir` at `/shared/app-key`.
2. **container `patch-secret`** (`bitnami/kubectl:1.32`): reads `/shared/app-key`, fetches the current `APP_KEY` from `unit3d-secrets`, and patches the Secret only if the existing value is empty or `CHANGEME`. Idempotent across redeploys — re-runs no-op once a real key is in place.

The Job uses a dedicated `ServiceAccount` (`unit3d-bootstrap-sa`) bound to a `Role` that grants `get` and `patch` on **only** `unit3d-secrets` (no wildcard, no other resources). RBAC blast radius is minimal.

## How to use

Include this Component from your overlay:

```yaml
# kustomize/overlays/<env>/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: unit3d

resources:
  - ../../base

components:
  - ../../components/bootstrap-app-key
```

The `unit3d-secrets` Secret must exist when the Job runs (otherwise `kubectl get secret` fails and the Job retries up to `backoffLimit: 3`). In `dev`, the overlay's `secretGenerator` creates it with deterministic dev values, including a fake `APP_KEY=base64:AAAA…`. The Component's Job sees the non-empty key and no-ops — fine.

In any overlay where `unit3d-secrets` ships without an `APP_KEY` (or with `CHANGEME`), the Job generates and patches the canonical key on first apply.

## Why it's a Component, not in `base/`

[ADR-0004](../../../docs/adr/0004-secret-management.md) commits to operator-supplied `APP_KEY` as the **default** in production. A bootstrap Job present in every deploy would conflict with the sealed-secrets / ESO flow:
- The Job's RBAC patch path is unnecessary when `APP_KEY` is already pinned by sealed-secrets.
- The Job adds a moving part (RBAC + ServiceAccount + Job) that production ops doesn't need.

Components in Kustomize are opt-in by design — overlays that need this behavior reference the Component, others ignore it.

## Hard rules

- **Off by default in `prod-rwo` and `prod-rwx` overlays.** When those overlays land, they include `unit3d-secrets` via a SealedSecret pre-populated with the operator's `APP_KEY` and do **not** include this Component.
- **No `key:generate` after first boot.** The Job's idempotency guard (the `EXISTING` check) ensures it never overwrites a real key. The `k8s-reviewer` agent flags any workflow that runs `key:generate --force` as CRITICAL — this Component does not pass `--force`, and the patch-secret container only writes when the key is empty.
- **APP_KEY rotation is out of scope** for this Component (and for ratatoskr at v0.3 generally — ADR-0004). Rotation requires re-encrypting every `encrypted` column, every signed URL, every encrypted session — manual procedure, not automated.
