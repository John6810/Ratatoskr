# `argocd/`

ArgoCD `ApplicationSet` template for ratatoskr deployments. **Reference template — operators customize in their fork.** Closes the v0.3 [ROADMAP](../docs/ROADMAP.md) "ArgoCD ApplicationSet template for GitOps adoption" item.

## Prerequisites

- **ArgoCD installed in the cluster** — operator-managed, see <https://argo-cd.readthedocs.io/en/stable/getting_started/>. ratatoskr does not bundle ArgoCD; it's cluster-wide infrastructure like cert-manager and sealed-secrets.
- **ArgoCD project** — the `default` project works for most setups; create a dedicated `ratatoskr` project for stricter RBAC if you isolate ratatoskr deployments from other tenants on the same ArgoCD instance.
- **Operator's ratatoskr fork accessible to ArgoCD** — public repo, or repo credentials configured in ArgoCD via `argocd repo add` (or a `Secret` with `argocd.argoproj.io/secret-type: repository`).
- **Sealed-secrets dropped in the operator's fork BEFORE first sync** — without them, the Application boots into `SyncFailed` state because the workload Deployments reference Secrets that don't exist. See per-overlay `secrets/README.md` (e.g. [`overlays/prod-rwx/secrets/README.md`](../kustomize/overlays/prod-rwx/secrets/README.md)).

## Customization (2 mandatory placeholders)

Replace `https://github.com/CHANGEME-OPERATOR/ratatoskr-fork.git` × 2 with the operator's actual fork URL. Both occurrences (in `generators.git.repoURL` and `template.spec.source.repoURL`) must point to the same repo:

```bash
# In the operator's fork:
sed -i 's|https://github.com/CHANGEME-OPERATOR/ratatoskr-fork.git|https://github.com/myorg/ratatoskr-prod.git|g' \
  argocd/applicationset.yaml
```

## Three usage patterns

### Pattern A — Smoke-test all overlays (default behavior)

The shipped ApplicationSet generates 3 Applications (one per overlay) into 3 separate namespaces (`unit3d-dev`, `unit3d-prod-rwo`, `unit3d-prod-rwx`). Useful for testing the full overlay matrix on a single cluster.

```bash
kubectl apply -f argocd/applicationset.yaml
```

ArgoCD then creates `ratatoskr-dev`, `ratatoskr-prod-rwo`, and `ratatoskr-prod-rwx` Applications. Each tracks the corresponding overlay directory; pushing changes to the fork triggers ArgoCD sync.

### Pattern B — Single overlay (typical production)

Operators running ratatoskr in production typically deploy ONE overlay (`prod-rwo` OR `prod-rwx`, never both on the same cluster). Edit `argocd/applicationset.yaml` to restrict the generator:

```yaml
# Restrict to a single overlay path:
generators:
  - git:
      repoURL: https://github.com/<operator>/ratatoskr-fork.git
      revision: main
      directories:
        - path: kustomize/overlays/prod-rwx   # specific overlay
```

OR use exclude entries to skip the others:

```yaml
generators:
  - git:
      repoURL: https://github.com/<operator>/ratatoskr-fork.git
      revision: main
      directories:
        - path: kustomize/overlays/*
        - path: kustomize/overlays/dev
          exclude: true
        - path: kustomize/overlays/prod-rwo
          exclude: true
```

The exclude pattern is preferred when the operator might add a new overlay later (e.g. a `prod-staging` for dry-run testing); they only need to add a new exclude line, not rewrite the directories list.

### Pattern C — Multi-cluster (advanced)

Production deployments spanning multiple clusters use a `Matrix` generator combining Git directory + Cluster generator:

```yaml
spec:
  generators:
    - matrix:
        generators:
          - git:
              repoURL: https://github.com/<operator>/ratatoskr-fork.git
              revision: main
              directories:
                - path: kustomize/overlays/prod-rwx
          - clusters:
              selector:
                matchLabels:
                  ratatoskr.io/deploy: "true"
```

Each cluster registered with ArgoCD and labeled `ratatoskr.io/deploy=true` gets the `prod-rwx` overlay. Combine with destination naming convention to manage per-cluster namespace if needed (e.g. `namespace: 'unit3d-{{.name}}'` to encode the cluster name in the namespace).

See <https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Matrix/> for the full Matrix generator reference.

## Notes

- **Namespace override** — the ApplicationSet's `kustomize.namespace` field overrides the namespace defined in each overlay's `kustomization.yaml` (which is `unit3d` per [CLAUDE.md](../CLAUDE.md) K8s naming convention). This allows multiple overlays in one cluster without collision. Operators on a single overlay can drop the override and use the overlay's native namespace by removing both `kustomize.namespace` from the source spec AND setting `destination.namespace: unit3d`.
- **`CreateNamespace=true`** — ArgoCD creates the destination namespace if missing. Required for first deploy; benign no-op afterward.
- **`ServerSideApply=true`** — avoids client-side merge conflicts on CRDs (cert-manager `Certificate`, Traefik `IngressRoute`, KEDA `ScaledObject`, sealed-secrets `SealedSecret`). Recommended for any ratatoskr deployment because the overlay tree composes multiple CRD-defining components.
- **Retry policy** — 5 retries with exponential backoff up to 5 min. Recovers from transient errors during initial sync (CRDs not yet installed by the time ArgoCD tries to create resources, network blips, rate-limited registry pulls).
- **`selfHeal: true`** — ArgoCD reverts manual `kubectl edit` / `kubectl patch` against the cluster. Operators testing changes manually should set `selfHeal: false` temporarily, OR (preferred) commit the change to the fork and let ArgoCD apply it through the standard flow. Manual cluster edits with `selfHeal: true` are silently undone within seconds; debugging that is painful.
- **`PrunePropagationPolicy=foreground` + `PruneLast=true`** — when an overlay removes a resource (e.g. operator deletes an HPA from `kustomization.yaml`), ArgoCD waits for the dependent resources to clean up before deleting the parent. `PruneLast=true` ensures CRD-instance resources are removed before their CRDs are pruned (avoids orphaned API objects).

## See also

- [`docs/ROADMAP.md`](../docs/ROADMAP.md) — v0.3 closes the "ArgoCD ApplicationSet template for GitOps adoption" item with this file.
- [`kustomize/overlays/dev/README.md`](../kustomize/overlays/dev/README.md), [`prod-rwo/README.md`](../kustomize/overlays/prod-rwo/README.md), [`prod-rwx/README.md`](../kustomize/overlays/prod-rwx/README.md) — per-overlay operator workflows.
- ArgoCD `ApplicationSet` reference: <https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/>.
- Git directory generator: <https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Git/>.
