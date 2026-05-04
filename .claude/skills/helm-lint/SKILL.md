---
name: helm-lint
description: Lint the ratatoskr Helm chart, resolve dependencies, render it against multiple values files (default, dev, prod), and validate the rendered manifests with kubeconform. Catches templating errors, broken conditionals (mariadb.enabled, redis.enabled toggles), missing values, and invalid Kubernetes manifests. Use after any change in helm/, before publishing a new chart version, before tagging a release.
allowed-tools: Bash(helm lint:*), Bash(helm template:*), Bash(helm dependency:*), Bash(helm show:*), Bash(helm version:*), Bash(helm repo:*), Bash(helm search:*), Bash(kubeconform:*), Bash(yq:*), Bash(jq:*), Bash(rg:*), Bash(grep:*), Bash(find:*), Bash(cat:*), Bash(ls:*), Read, Glob
---

# Helm chart lint & validate

Lint, template, and validate the chart with all canonical values combinations. Report a per-values pass/fail table.

## When to invoke

- After changes in `helm/unit3d/` (templates, values, Chart.yaml)
- Before bumping `version` or `appVersion` in `Chart.yaml`
- Before publishing to a chart repo or Artifact Hub
- When the user asks "lint the chart", "render with prod values", "validate helm"

## Pre-flight

```bash
helm version
kubeconform -v
test -f helm/unit3d/Chart.yaml || { echo "No Helm chart yet — skill cannot run"; exit 1; }
```

## Workflow

### 1. Resolve dependencies

```bash
cd helm/unit3d
helm dependency update
helm dependency list
```

If `Chart.lock` is missing or `helm dependency list` shows `missing`, dependencies are not resolved — stop and report. The chart may pull Bitnami MariaDB/Redis subcharts; they must be in `charts/` before rendering.

### 2. Lint

```bash
helm lint helm/unit3d --strict
helm lint helm/unit3d --strict --values helm/unit3d/values-prod.yaml
```

`--strict` treats warnings as errors. Run it once with default values, then once per `values-*.yaml` file present.

### 3. Render every canonical values combination

The chart must work with subcharts on (default) and off (when operators bring their own managed DB/Redis). Render both:

```bash
# Default — subcharts enabled (mariadb, redis, meilisearch in-chart)
helm template ratatoskr helm/unit3d \
  --namespace unit3d --create-namespace > /tmp/render-default.yaml

# Production — assume external DB/Redis
helm template ratatoskr helm/unit3d \
  --namespace unit3d --create-namespace \
  --values helm/unit3d/values-prod.yaml > /tmp/render-prod.yaml

# Toggle off subcharts explicitly (sanity check)
helm template ratatoskr helm/unit3d \
  --namespace unit3d --create-namespace \
  --set mariadb.enabled=false \
  --set redis.enabled=false > /tmp/render-external.yaml
```

If a render fails (missing required value, undefined template), capture the exact `helm template` error message and stop — do not proceed to validation.

### 4. Validate each rendered manifest

```bash
for f in /tmp/render-default.yaml /tmp/render-prod.yaml /tmp/render-external.yaml; do
  kubeconform -strict -summary \
    -kubernetes-version 1.32.0 \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    "$f"
done
```

Same K8s target as `kustomize-validate` (1.32.0) — keep them in lockstep.

### 5. Optional: run chart tests

If `helm/unit3d/templates/tests/` exists, render and validate them too. Do not run `helm test` against a real cluster from this skill.

## Output format

```markdown
## Helm validation — <YYYY-MM-DD>

| Step | Result |
|---|---|
| Dependencies resolved | ✅ mariadb 19.x, redis 20.x |
| Lint (default values) | ✅ |
| Lint (values-prod.yaml) | ✅ |
| Render default (subcharts on) | ✅ 22 resources |
| Render prod (external DB/Redis) | ✅ 14 resources |
| Render with subcharts off | ✅ 14 resources |
| kubeconform — default | ✅ all valid |
| kubeconform — prod | ✅ all valid |
| kubeconform — external | ❌ 1 error |

### Errors
- `render-external.yaml`: `Service/unit3d-redis` references missing `redis-master` selector — conditional missed when `redis.enabled=false`.
```

## Pitfalls

- **Forgetting `--strict` on lint**: warnings about deprecated APIs or missing icons in `Chart.yaml` will be silently ignored. Always strict.
- **Subchart toggles**: the most common templating bug is a Service or NetworkPolicy that references the subchart even when `redis.enabled=false`. The "render with subcharts off" pass catches this.
- **Bitnami breaking changes**: Bitnami MariaDB/Redis subcharts have major bumps that change value paths (`auth.rootPassword` vs `auth.root.password`). When `helm dependency update` pulls a new major, re-render and check.
- **`helm template` does not run hooks**: pre-install hooks (e.g. the `php artisan migrate` Job) are rendered but the order is not enforced. Annotate them with `helm.sh/hook-weight` and verify the annotations are present in the rendered output.
- **`appVersion` vs `version`**: `version` is the chart version (semver, bumped on every chart change), `appVersion` is the UNIT3D version (`v9.2.0`). They drift independently. Don't confuse them at release time.
- **CRDs in subcharts**: if a subchart installs CRDs, kubeconform needs them in the schema-location list. Add them to the second `-schema-location` URL pattern.
