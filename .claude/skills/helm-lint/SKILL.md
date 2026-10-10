---
name: helm-lint
description: Validate the dependency-free ratatoskr chart and its supported values combinations with regression tests, Helm lint, rendering, and Kubernetes schemas.
---

# Helm chart validation

Run after edits under `helm/ratatoskr/`. The chart has no external subcharts;
there is no Chart.lock or dependency-update step.

## Workflow

From the repository root, ensure Helm, Kustomize, kubeconform, Python 3, and
PyYAML are installed. Pinned tools can be installed into a temporary directory
with `scripts/tests/install-tools.sh`; add that directory to PATH.

```bash
bash scripts/tests/validate.sh
```

This runs regression tests, shell syntax checks, strict Helm lint with public
placeholder values, and default/bootstrap/RWX/external-service renders. It also
builds all three Kustomize overlays. kubeconform validates Kubernetes 1.32.0 and
referenced CRD schemas without skipping unknown kinds.

Report failures and the actual resource count. Never present rendering as runtime
proof: client-side lookup cannot test Secret preservation, and schemas cannot
verify migrations, authentication, network enforcement, or data retention.

Runtime tests live in `scripts/tests/helm-lifecycle.sh` and require an explicitly
selected disposable cluster. They are separate from this read-only validation
workflow. Chart tests can be run with `helm test` on that disposable release.
