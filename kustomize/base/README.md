# `kustomize/base/`

Environment-agnostic Kubernetes manifests for the ratatoskr stack. The base/ tree contains the shape of every component (Deployments, Services, ConfigMaps, NetworkPolicies) without environment-specific values — replica counts, resource limits, image tags beyond the build image, storage class names. Overlays under `kustomize/overlays/` compose components and apply per-environment patches. Architectural decisions in [docs/adr/](../../docs/adr/).

## Planned layout

```
kustomize/base/
├── kustomization.yaml         # root base kustomization (namespace, shared labels, resources list)
├── namespace.yaml             # Namespace `unit3d`
├── mariadb/                   # TBD — StatefulSet + ClusterIP Service + PVC (ADR-0001)
├── redis/                     # TBD — Deployment + Service + PVC
├── meilisearch/               # TBD — StatefulSet + Service (single-node, no HA)
├── unit3d-app/                # TBD — Deployment + Service + ConfigMap filesystems.php override (ADR-0002)
├── unit3d-queue/              # TBD — Deployment for queue worker
├── unit3d-scheduler/          # TBD — CronJob `* * * * *` artisan schedule:run
├── unit3d-migrate/            # TBD — Job, pre-install hook
├── networkpolicies/           # TBD — default-deny + explicit allows
├── secrets-templates/         # TBD — sealed-secrets templates with CHANGEME (ADR-0004)
└── README.md                  # this file
```

The tree is added incrementally — components land in their own atomic commits and this README is updated as they arrive. Today the base ships only the namespace; subsequent commits add component subdirectories one at a time, each validated by the `kustomize-validate` skill before commit.

`secrets-templates/` ships placeholder manifests only. Operators seal real values into their own GitOps repo per [ADR-0004](../../docs/adr/0004-secret-management.md).

## Conventions

- **Namespace** `unit3d` set via `namespace:` in kustomization.yaml; never hardcoded on individual resources.
- **Shared labels** (`app.kubernetes.io/instance`, `part-of`, `managed-by`) applied via the kustomization's `labels:` block. The modern `labels:` field is preferred over `commonLabels:` because the legacy field injects labels into Deployment/Service selectors — selectors are immutable post-create, so a labels change forces resource recreation. `labels:` with `includeSelectors: false` keeps selectors stable.
- **Per-component labels** (`app.kubernetes.io/name`, `app.kubernetes.io/component`) set in each component's own manifests, not in the root kustomization.
- **No environment-specific values** in base/. Replicas, resource limits, image tags beyond the build image, and storage class names live in overlays.
