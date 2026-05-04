---
name: kustomize-validate
description: Build all Kustomize overlays and validate the rendered manifests against Kubernetes API schemas using kubeconform. Catches missing fields, wrong apiVersions, deprecated kinds, and bad references. Use after any change in kustomize/base/ or kustomize/overlays/, before opening a PR that touches manifests, and before bumping the targeted Kubernetes version.
allowed-tools: Bash(kustomize build:*), Bash(kustomize version:*), Bash(kubeconform:*), Bash(kubectl explain:*), Bash(yq:*), Bash(rg:*), Bash(grep:*), Bash(find:*), Bash(cat:*), Bash(ls:*), Read, Glob
---

# Kustomize validate

Render every overlay and feed the output to `kubeconform`. Report a per-overlay pass/fail table and any specific resource error.

## When to invoke

- After changes in `kustomize/base/` or `kustomize/overlays/`
- Before opening a PR touching manifests
- Before bumping the Kubernetes target version (`-k 1.32` etc.)
- When the user asks "are the manifests valid?", "validate kustomize"

## Pre-flight

```bash
kustomize version
kubeconform -v
test -d kustomize/base || { echo "No kustomize/ tree yet — skill cannot run"; exit 1; }
```

If the binaries are missing, tell the user how to install them (`brew install kustomize kubeconform`) instead of trying to substitute.

## Workflow

### 1. Discover overlays

```bash
find kustomize/overlays -mindepth 1 -maxdepth 1 -type d
```

If none exist yet, fall back to validating only `kustomize/base/`.

### 2. Render and validate each

For each overlay path, run:

```bash
kustomize build "$overlay" | kubeconform \
  -strict \
  -summary \
  -kubernetes-version 1.32.0 \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  -output text
```

The second `-schema-location` covers CRDs (Traefik, ArgoCD, sealed-secrets, etc.) that aren't in the default kubeconform schemas.

Target Kubernetes version is `1.32.0` to match the current Canonical k8s baseline. Bump in lockstep with the cluster target — do not silently change.

### 3. Report

Output one table covering all overlays:

```markdown
## Kustomize validation — <YYYY-MM-DD>

| Overlay | Resources | Result |
|---|---|---|
| base | 14 | ✅ all valid |
| overlays/dev | 16 | ✅ all valid |
| overlays/staging | 17 | ⚠️ 1 warning (deprecated PodDisruptionBudget v1beta1) |
| overlays/prod | 18 | ❌ 1 error (NetworkPolicy missing podSelector) |

### Errors
- `overlays/prod/networkpolicy-redis.yaml`: missing `.spec.podSelector` (required field)
```

For passes, no extra detail. For failures, point to the specific file and field — never paste a 200-line diff.

## Pitfalls

- **CRDs without schema**: kubeconform fails on unknown kinds unless the second `-schema-location` is set. If you see "could not find schema for X", check the datreeio CRDs catalog URL.
- **`-strict` flag matters**: without it, kubeconform silently passes manifests that have unknown fields — exactly the bugs we want to catch.
- **Kustomize build is not a guarantee of apply success**: schema validation does not check RBAC, admission webhooks, or runtime constraints (resource quotas, image pull secrets). Treat ✅ as "syntactically valid", not "will deploy".
- **Generators are expanded silently**: `configMapGenerator` and `secretGenerator` produce final resources at build time. If a generator references a missing file, `kustomize build` fails before kubeconform even runs — read its stderr first.
- **NetworkPolicy is the most error-prone resource**: missing `podSelector`, wrong `policyTypes`, mismatched `matchLabels`. Most overlay failures end up here.
