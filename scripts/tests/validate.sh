#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
for tool in helm kustomize kubeconform python3; do command -v "$tool" >/dev/null; done
work="$(mktemp -d -t ratatoskr-validate-XXXXXX)"
trap 'rm -rf "$work"' EXIT
python3 -m unittest discover -s tests -v
while IFS= read -r script; do
    if head -1 "$script" | grep -q bash; then bash -n "$script"; else sh -n "$script"; fi
done < <(find scripts docker -name '*.sh' -type f)
helm lint helm/ratatoskr --strict -f helm/ratatoskr/ci/test-values.yaml
args=(ratatoskr helm/ratatoskr --namespace unit3d --kube-version 1.32.0 -f helm/ratatoskr/ci/test-values.yaml)
helm template "${args[@]}" > "$work/helm-default.yaml"
helm template "${args[@]}" -f helm/ratatoskr/ci/external-values.yaml > "$work/helm-external.yaml"
helm template "${args[@]}" --set unit3d.appKey= --set unit3d.bootstrapAppKey=true > "$work/helm-bootstrap.yaml"
helm template "${args[@]}" --set storage.accessMode=ReadWriteMany --set unit3d.replicas=2 \
    --set queue.replicas=2 --set hpa.app.enabled=true --set hpa.queue.enabled=true \
    --set pdb.app.enabled=true --set pdb.queue.enabled=true > "$work/helm-rwx.yaml"
for overlay in dev prod-rwo prod-rwx; do
    kustomize build "kustomize/overlays/$overlay" > "$work/kustomize-$overlay.yaml"
done
kubeconform -strict -summary -kubernetes-version 1.32.0 -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    "$work"/*.yaml
echo 'VALIDATION_RESULT=PASS'
