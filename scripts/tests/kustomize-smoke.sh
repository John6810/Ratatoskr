#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${KUBECONFIG:?Set KUBECONFIG explicitly to a disposable cluster}"
namespace="ratatoskr-kustomize-$RANDOM-$RANDOM"
work="$(mktemp -d -t ratatoskr-kustomize-XXXXXX)"
uid=""
cleanup() {
    rc=$?
    trap - EXIT
    if [ -n "$uid" ] && [ "$(kubectl get ns "$namespace" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)" = "$uid" ]; then
        if [ "$rc" != 0 ]; then kubectl -n "$namespace" get pods,jobs; fi
        kubectl delete namespace "$namespace" --wait --timeout=180s >/dev/null || rc=1
    fi
    rm -rf "$work"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
uid="$(kubectl create namespace "$namespace" -o jsonpath='{.metadata.uid}')"
kustomize build kustomize/overlays/dev > "$work/source.yaml"
python3 - "$work" "$namespace" <<'PY'
import os, sys, yaml
from pathlib import Path
work, namespace = Path(sys.argv[1]), sys.argv[2]
docs = list(yaml.safe_load_all((work / 'source.yaml').read_text()))
for d in docs:
    if d['kind'] == 'Namespace':
        d['metadata']['name'] = namespace
    elif d['metadata'].get('namespace') == 'unit3d':
        d['metadata']['namespace'] = namespace
    for subject in d.get('subjects', []):
        if subject.get('namespace') == 'unit3d':
            subject['namespace'] = namespace
    if d['kind'] == 'Secret' and d['metadata']['name'] == 'unit3d-secrets':
        d['data'].pop('APP_KEY', None)  # Exercise actual key generation.
    pod = d.get('spec', {}).get('template', {}).get('spec', {})
    for c in pod.get('containers', []) + pod.get('initContainers', []):
        if c['image'].startswith('ghcr.io/john6810/unit3d-migrate:') and os.environ.get('UNIT3D_TEST_IMAGE'):
            c['image'] = os.environ.get('UNIT3D_MIGRATION_IMAGE', os.environ['UNIT3D_TEST_IMAGE'] + '-migration')
        if c['image'].startswith('ghcr.io/john6810/unit3d:') and os.environ.get('UNIT3D_TEST_IMAGE'):
            c['image'] = os.environ['UNIT3D_TEST_IMAGE']
    if d['kind'] == 'Job' and d['metadata']['name'] == 'unit3d-bootstrap-app-key':
        (work / 'bootstrap.yaml').write_text(yaml.safe_dump(d))
(work / 'render.yaml').write_text(yaml.safe_dump_all(docs))
PY
python3 scripts/security/configure-api-egress.py "$work/render.yaml" "$work/render.yaml"
kubectl apply -f "$work/render.yaml" >/dev/null
kubectl -n "$namespace" wait --for=condition=complete job/unit3d-bootstrap-app-key --timeout=180s
kubectl -n "$namespace" wait --for=condition=complete job/unit3d-migrate --timeout=600s
for component in app queue scheduler; do
    kubectl -n "$namespace" rollout status "deployment/unit3d-$component" --timeout=180s
done
kubectl -n "$namespace" exec deployment/unit3d-app -- curl -fsS --max-time 10 -o /dev/null -w '%{http_code}\n' http://127.0.0.1/
kubectl -n "$namespace" exec deployment/unit3d-app -- php artisan scout:sync-index-settings
before="$(kubectl -n "$namespace" get secret unit3d-secrets -o jsonpath='{.data.APP_KEY}' | sha256sum)"
kubectl -n "$namespace" delete job unit3d-bootstrap-app-key --wait >/dev/null
kubectl apply -f "$work/bootstrap.yaml" >/dev/null
kubectl -n "$namespace" wait --for=condition=complete job/unit3d-bootstrap-app-key --timeout=180s
test "$before" = "$(kubectl -n "$namespace" get secret unit3d-secrets -o jsonpath='{.data.APP_KEY}' | sha256sum)"
echo KUSTOMIZE_SMOKE_RESULT=PASS
