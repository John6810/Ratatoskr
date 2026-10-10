#!/usr/bin/env bash
# Exercise real storage migration and rollback in an owned namespace.
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${KUBECONFIG:?Select a disposable cluster explicitly}"
: "${RWX_STORAGE_CLASS:?Provide a real RWX StorageClass}"
source scripts/tests/lib/static-nfs.sh
namespace="ratatoskr-rwx-$RANDOM-$RANDOM"
work="$(mktemp -d -t ratatoskr-rwx-XXXXXX)"
chmod 700 "$work"
uid=""
cleanup() {
    rc=$?
    trap - EXIT
    if [ -n "$uid" ] && [ "$(kubectl get ns "$namespace" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)" = "$uid" ]; then
        if [ "$rc" != 0 ]; then
            kubectl -n "$namespace" get pods,jobs,pvc
            kubectl -n "$namespace" get events --sort-by=.lastTimestamp | tail -20
        fi
        if [ "${KEEP_FAILED_NAMESPACE:-0}" = 1 ] && [ "$rc" != 0 ]; then
            echo "Failure retained for inspection: namespace=$namespace work=$work" >&2
            exit "$rc"
        fi
        # Only PVs belonging to this exact namespace UID are eligible for cleanup.
        kubectl get pv -o json > "$work/pvs.json"
        python3 - "$work/pvs.json" "$namespace" <<'PY' > "$work/pv-names"
import json, sys
for pv in json.load(open(sys.argv[1]))['items']:
    if pv['spec'].get('claimRef', {}).get('namespace') == sys.argv[2]:
        print(pv['metadata']['name'])
PY
        while read -r pv; do
            kubectl patch pv "$pv" --type=merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' >/dev/null
        done < "$work/pv-names"
        kubectl delete ns "$namespace" --wait --timeout=180s >/dev/null || rc=1
        static_nfs_cleanup "$namespace" "$uid" || rc=1
    fi
    rm -rf "$work"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
uid="$(kubectl create namespace "$namespace" -o jsonpath='{.metadata.uid}')"
static_nfs_volume "$namespace" unit3d-storage
kustomize build kustomize/overlays/dev > "$work/source.yaml"
python3 - "$work" "$namespace" <<'PY'
import base64, copy, os, secrets, sys, yaml
from pathlib import Path
work, ns = Path(sys.argv[1]), sys.argv[2]
docs = list(yaml.safe_load_all((work / 'source.yaml').read_text()))
for d in docs:
    if d['kind'] == 'Namespace':
        d['metadata']['name'] = ns
    elif d['metadata'].get('namespace') == 'unit3d':
        d['metadata']['namespace'] = ns
    for subject in d.get('subjects', []):
        if subject.get('namespace') == 'unit3d':
            subject['namespace'] = ns
    if d['kind'] == 'Secret':
        for key in d.get('data', {}):
            value = 'base64:' + base64.b64encode(secrets.token_bytes(32)).decode() if key == 'APP_KEY' else secrets.token_hex(24)
            if key == 'DEFAULT_OWNER_NAME': value = 'admin'
            if key == 'DEFAULT_OWNER_EMAIL': value = 'admin@example.invalid'
            d['data'][key] = base64.b64encode(value.encode()).decode()
    pod = d.get('spec', {}).get('template', {}).get('spec', {})
    for c in pod.get('containers', []) + pod.get('initContainers', []):
        if c['image'].startswith('ghcr.io/john6810/unit3d:') and os.environ.get('UNIT3D_TEST_IMAGE'):
            c['image'] = os.environ['UNIT3D_TEST_IMAGE']
(work / 'rwo.yaml').write_text(yaml.safe_dump_all(docs))
# Apply the actual production replica/strategy patches, with dev-sized services.
target = work / 'rwx'
target.mkdir()
(target / 'source.yaml').write_text(yaml.safe_dump_all(docs))
patches = []
for component in ['app', 'queue']:
    source = Path(f'kustomize/overlays/prod-rwx/patches/unit3d-{component}-multireplica.yaml')
    (target / source.name).write_text(source.read_text())
    patches.append({'path': source.name, 'target': {'kind': 'Deployment', 'name': f'unit3d-{component}'}})
patches.append({'target': {'kind': 'Deployment|Job', 'name': 'unit3d-(app|queue|scheduler|migrate)'},
    'patch': '- op: remove\n  path: /spec/template/spec/affinity'})
patches.append({'target': {'kind': 'PersistentVolumeClaim', 'name': 'unit3d-storage'},
    'patch': yaml.safe_dump([
        {'op': 'replace', 'path': '/spec/accessModes', 'value': ['ReadWriteMany']},
        {'op': 'add', 'path': '/spec/storageClassName', 'value': os.environ['RWX_STORAGE_CLASS']}])})
# Ensure the test really runs app replicas on different worker nodes, including rolling upgrades.
patches.append({'target': {'kind': 'Deployment', 'name': 'unit3d-app'}, 'patch': yaml.safe_dump([
    {'op': 'add', 'path': '/spec/template/spec/topologySpreadConstraints', 'value': [{
        'maxSkew': 1, 'topologyKey': 'kubernetes.io/hostname', 'whenUnsatisfiable': 'DoNotSchedule',
        'labelSelector': {'matchLabels': {'app.kubernetes.io/name': 'unit3d-app'}}}]}])})
(target / 'kustomization.yaml').write_text(yaml.safe_dump({
    'apiVersion': 'kustomize.config.k8s.io/v1beta1', 'kind': 'Kustomization',
    'resources': ['source.yaml'], 'patches': patches}))
PY
kubectl apply -f "$work/rwo.yaml" >/dev/null
wait_app() {
    kubectl -n "$namespace" wait --for=condition=complete job/unit3d-migrate --timeout=600s
    for component in app queue scheduler; do
        kubectl -n "$namespace" rollout status "deployment/unit3d-$component" --timeout=300s
    done
    kubectl -n "$namespace" exec deploy/unit3d-app -- curl -fsS --max-time 10 -o /dev/null http://127.0.0.1/
}
wait_app
old_pv="$(kubectl -n "$namespace" get pvc unit3d-storage -o jsonpath='{.spec.volumeName}')"
old_class="$(kubectl get pv "$old_pv" -o jsonpath='{.spec.storageClassName}')"
before="$(kubectl -n "$namespace" get secret unit3d-secrets -o jsonpath='{.data.APP_KEY}' | sha256sum)"
kubectl -n "$namespace" exec deploy/unit3d-app -- php -r '
$dir="/app/storage/app/ratatoskr-drill"; mkdir($dir);
for($i=0;$i<128;$i++) file_put_contents("$dir/file $i.txt", hash("sha256",(string)$i));
file_put_contents("$dir/.hidden", "hidden sentinel");
file_put_contents("$dir/unicode-é.txt", "unicode sentinel");
file_put_contents("$dir/quote\".txt", "quoted filename");
file_put_contents("$dir/line\nbreak.txt", "newline filename");
symlink("file 0.txt", "$dir/link");
$db=new PDO("mysql:host=".getenv("DB_HOST").";dbname=".getenv("DB_DATABASE"),getenv("DB_USERNAME"),getenv("DB_PASSWORD"));
$db->exec("CREATE TABLE ratatoskr_rwx_sentinel(id INT PRIMARY KEY)");
$db->exec("INSERT INTO ratatoskr_rwx_sentinel VALUES(1)");'
verify_data() {
    kubectl -n "$namespace" exec deploy/unit3d-app -- php -r '
    $dir="/app/storage/app/ratatoskr-drill";
    for($i=0;$i<128;$i++) if(file_get_contents("$dir/file $i.txt")!==hash("sha256",(string)$i)) exit(1);
    if(file_get_contents("$dir/.hidden")!=="hidden sentinel" || file_get_contents("$dir/unicode-é.txt")!=="unicode sentinel" || readlink("$dir/link")!=="file 0.txt") exit(1);
    if(file_get_contents("$dir/quote\".txt")!=="quoted filename" || file_get_contents("$dir/line\nbreak.txt")!=="newline filename") exit(1);
    $db=new PDO("mysql:host=".getenv("DB_HOST").";dbname=".getenv("DB_DATABASE"),getenv("DB_USERNAME"),getenv("DB_PASSWORD"));
    if($db->query("SELECT COUNT(*) FROM ratatoskr_rwx_sentinel WHERE id=1")->fetchColumn()!=1) exit(1);
    echo "All 132 files, symlink, and database sentinel verified\n";'
    test "$before" = "$(kubectl -n "$namespace" get secret unit3d-secrets -o jsonpath='{.data.APP_KEY}' | sha256sum)"
}
# Real, private backups before invoking the operational migration script.
kubectl -n "$namespace" exec deploy/unit3d-app -- tar -C /app/storage -czf - . > "$work/storage.tar.gz"
kubectl -n "$namespace" exec sts/mariadb -- sh -ec 'exec mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction unit3d' > "$work/database.sql"
test -s "$work/storage.tar.gz" && test -s "$work/database.sql"
echo 'Migrating real RWO storage to RWX'
NAMESPACE="$namespace" NEW_STORAGE_CLASS="$RWX_STORAGE_CLASS" OVERLAY_PATH="$work/rwx" BACKUP_VERIFIED=1 PROCEED=1 \
    sh scripts/migration/migrate-rwo-to-rwx.sh
wait_app
verify_data
test "$(kubectl get pv "$old_pv" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')" = Retain
test "$(kubectl get pv "$old_pv" -o jsonpath='{.status.phase}')" = Released
mapfile -t pods < <(kubectl -n "$namespace" get pods -l app.kubernetes.io/name=unit3d-app -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
test "${#pods[@]}" = 2
node_a="$(kubectl -n "$namespace" get pod "${pods[0]}" -o jsonpath='{.spec.nodeName}')"
node_b="$(kubectl -n "$namespace" get pod "${pods[1]}" -o jsonpath='{.spec.nodeName}')"
test "$node_a" != "$node_b"
echo "RWX replicas confirmed on different nodes: $node_a, $node_b"
kubectl -n "$namespace" exec "${pods[0]}" -- sh -ec 'echo cross-node-sentinel > /app/storage/app/rwx-cross-node'
test "$(kubectl -n "$namespace" exec "${pods[1]}" -- cat /app/storage/app/rwx-cross-node)" = cross-node-sentinel
kubectl -n "$namespace" delete pod "${pods[0]}" --wait >/dev/null
kubectl -n "$namespace" rollout status deploy/unit3d-app --timeout=300s
verify_data
echo 'Rolling back to the retained original RWO volume'
kubectl -n "$namespace" scale deploy/unit3d-app deploy/unit3d-queue deploy/unit3d-scheduler --replicas=0 >/dev/null
kubectl -n "$namespace" delete job unit3d-migrate --wait >/dev/null
kubectl -n "$namespace" wait --for=delete pod -l ratatoskr.io/storage=unit3d --timeout=180s
new_pv="$(kubectl -n "$namespace" get pvc unit3d-storage -o jsonpath='{.spec.volumeName}')"
kubectl patch pv "$new_pv" --type=merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' >/dev/null
kubectl -n "$namespace" delete pvc unit3d-storage --wait --timeout=120s >/dev/null
kubectl patch pv "$old_pv" --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]' >/dev/null
python3 - "$work/rwo.yaml" "$old_pv" "$old_class" <<'PY' > "$work/rollback.yaml"
import sys, yaml
docs=list(yaml.safe_load_all(open(sys.argv[1])))
for d in docs:
    if d['kind']=='PersistentVolumeClaim' and d['metadata']['name']=='unit3d-storage':
        d['spec'].update(volumeName=sys.argv[2], storageClassName=sys.argv[3])
yaml.safe_dump_all(docs, sys.stdout)
PY
kubectl apply -f "$work/rollback.yaml" >/dev/null
wait_app
verify_data
test "$(kubectl -n "$namespace" get pvc unit3d-storage -o jsonpath='{.spec.volumeName}')" = "$old_pv"
echo RWX_MIGRATION_ROLLBACK_RESULT=PASS
