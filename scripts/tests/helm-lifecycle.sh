#!/usr/bin/env bash
# Destructive tests are confined to a newly created, uniquely named namespace.
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${KUBECONFIG:?Set KUBECONFIG explicitly to a disposable cluster}"
source scripts/tests/lib/static-nfs.sh
NAMESPACE="${NAMESPACE:-ratatoskr-lifecycle-$RANDOM-$RANDOM}"
RELEASE=ratatoskr
work="$(mktemp -d -t ratatoskr-lifecycle-XXXXXX)"
chmod 700 "$work"
created=0
uid=""
cleanup() {
    rc=$?
    trap - EXIT
    if [ "$created" = 1 ] && [ "${KEEP_NAMESPACE:-0}" != 1 ]; then
        current="$(kubectl get ns "$NAMESPACE" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
        if [ "$current" = "$uid" ] && [ -n "$uid" ]; then
            kubectl delete namespace "$NAMESPACE" --wait --timeout=180s >/dev/null || rc=1
            static_nfs_cleanup "$NAMESPACE" "$uid" || rc=1
        elif [ -n "$current" ]; then
            echo "Namespace identity changed; refusing cleanup" >&2
            rc=1
        fi
    fi
    rm -rf "$work"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
uid="$(kubectl create namespace "$NAMESPACE" -o jsonpath='{.metadata.uid}')"
created=1
static_nfs_volume "$NAMESPACE" ratatoskr-unit3d-storage
static_nfs_volume "$NAMESPACE" external-unit3d-storage

python3 - "$work/values.yaml" <<'PY'
import os, secrets, sys, yaml
values = {
    'unit3d': {'bootstrapAppKey': True, 'appUrl': 'http://localhost:18080',
               'owner': {'name': 'admin', 'email': 'admin@example.invalid', 'password': secrets.token_hex(24)}},
    'mariadb': {'auth': {'rootPassword': secrets.token_hex(24), 'password': secrets.token_hex(24)}},
    'redis': {'auth': {'password': secrets.token_hex(24)}},
    'meilisearch': {'masterKey': secrets.token_hex(24)},
}
if os.environ.get('UNIT3D_TEST_IMAGE'):
    repository, tag = os.environ['UNIT3D_TEST_IMAGE'].rsplit(':', 1)
    values['unit3d']['image'] = {'registry': '', 'repository': repository, 'tag': tag}
if os.environ.get('RWX_STORAGE_CLASS'):
    values['storage'] = {'storageClass': os.environ['RWX_STORAGE_CLASS'], 'accessMode': 'ReadWriteMany', 'size': '5Gi'}
    values['unit3d']['replicas'] = 2
    values['queue'] = {'replicas': 2}
with open(sys.argv[1], 'w') as output:
    yaml.safe_dump(values, output)
os.chmod(sys.argv[1], 0o600)
PY

helm_args=(ratatoskr helm/ratatoskr -n "$NAMESPACE" -f "$work/values.yaml" --wait --wait-for-jobs --timeout=12m)
snapshot_secrets() {
    kubectl -n "$NAMESPACE" get secrets -l app.kubernetes.io/instance=ratatoskr -o json |
        python3 -c 'import hashlib,json,sys; s=json.load(sys.stdin); print(hashlib.sha256(json.dumps({x["metadata"]["name"]:x.get("data",{}) for x in s["items"]},sort_keys=True).encode()).hexdigest())'
}
check_database() {
    kubectl -n "$NAMESPACE" exec deploy/ratatoskr-unit3d-app -- php -r '
    $db = new PDO("mysql:host=".getenv("DB_HOST").";dbname=".getenv("DB_DATABASE"), getenv("DB_USERNAME"), getenv("DB_PASSWORD"));
    if ($db->query("SELECT COUNT(*) FROM ratatoskr_lifecycle_sentinel WHERE id=1")->fetchColumn() != 1) { exit(1); }'
}

check_search() {
    kubectl -n "$NAMESPACE" exec "deploy/$1" -- php -r '
    for ($attempt=0; $attempt<10; $attempt++) {
        $context = stream_context_create(["http" => ["method" => "POST", "timeout" => 5, "ignore_errors" => true,
            "header" => "Content-Type: application/json\r\nAuthorization: Bearer ".getenv("MEILISEARCH_KEY"), "content" => "{\"q\":\"\"}"]]);
        $body = file_get_contents(getenv("MEILISEARCH_HOST")."/indexes/torrents/search", false, $context);
        if (preg_match("/ 200 /", $http_response_header[0] ?? "") && isset(json_decode($body, true)["hits"])) { echo "Authenticated search succeeded\n"; exit(0); }
        sleep(1);
    }
    exit(1);'
}

echo "Fresh install with generated APP_KEY"
# A different chart version catches immutable StatefulSet claim-label drift.
cp -a helm/ratatoskr "$work/initial-chart"
python3 - "$work/initial-chart/Chart.yaml" <<'PY'
import sys, yaml
from pathlib import Path
p=Path(sys.argv[1]); d=yaml.safe_load(p.read_text())
d['version']='0.0.0-ci-initial'
p.write_text(yaml.safe_dump(d))
PY
install_args=("${helm_args[@]}")
install_args[1]="$work/initial-chart"
helm install "${install_args[@]}"
helm test ratatoskr -n "$NAMESPACE" --logs --timeout=120s
before="$(snapshot_secrets)"
kubectl -n "$NAMESPACE" exec deploy/ratatoskr-unit3d-app -- php -r '
$db = new PDO("mysql:host=".getenv("DB_HOST").";dbname=".getenv("DB_DATABASE"), getenv("DB_USERNAME"), getenv("DB_PASSWORD"));
$db->exec("CREATE TABLE ratatoskr_lifecycle_sentinel (id INT PRIMARY KEY)");
$db->exec("INSERT INTO ratatoskr_lifecycle_sentinel VALUES (1)");'
kubectl -n "$NAMESPACE" exec deploy/ratatoskr-unit3d-app -- php artisan scout:sync-index-settings
check_search ratatoskr-unit3d-app

echo "Upgrade must preserve credentials, data, and migration gating"
helm upgrade "${helm_args[@]}" --set unit3d.logLevel=debug --set "mariadb.auth.password=$(openssl rand -hex 24)"
test "$before" = "$(snapshot_secrets)"
check_database
helm test ratatoskr -n "$NAMESPACE" --logs --timeout=120s

echo "Failed migration must prevent new application pods from starting"
if helm upgrade "${helm_args[@]}" --timeout=150s \
    --set mariadb.auth.database=ratatoskr_missing_database --set migrate.timeoutSeconds=60 >"$work/expected-failure.log" 2>&1; then
    echo "Expected migration failure, but upgrade succeeded" >&2
    exit 1
fi
kubectl -n "$NAMESPACE" wait --for=condition=Failed job/ratatoskr-migrate-3 --timeout=90s
available="$(kubectl -n "$NAMESPACE" get deploy ratatoskr-unit3d-app -o jsonpath='{.status.availableReplicas}')"
if [ -n "${RWX_STORAGE_CLASS:-}" ]; then
    # RollingUpdate retains the old working replicas while new Pods wait for the failed Job.
    test "${available:-0}" = 2
    kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=unit3d-app -o json > "$work/pods.json"
    python3 - "$work/pods.json" <<'PY'
import json, sys
pods=json.load(open(sys.argv[1]))['items']
old=[p for p in pods if any(c['type']=='Ready' and c['status']=='True' for c in p['status'].get('conditions', []))]
assert len(old)==2
assert len({p['spec']['nodeName'] for p in old})==2, 'RWX replicas must run on different nodes in this test'
new=[p for p in pods if p not in old and not p['metadata'].get('deletionTimestamp')]
assert new and all(not p['status'].get('containerStatuses', [{}])[0].get('ready', False) for p in new)
PY
    echo "Rolling back the failed release to revision 2"
    helm rollback ratatoskr 2 -n "$NAMESPACE" --wait --wait-for-jobs --timeout=5m
    helm test ratatoskr -n "$NAMESPACE" --logs --timeout=120s
    check_database
else
    test "${available:-0}" = 0
fi
test "$before" = "$(snapshot_secrets)"

echo "Recovery upgrade"
helm upgrade "${helm_args[@]}"
test "$before" = "$(snapshot_secrets)"
check_database
kubectl -n "$NAMESPACE" exec deploy/ratatoskr-unit3d-app -- php artisan migrate:status --no-ansi
echo "External services with custom Secret key names"
kubectl -n "$NAMESPACE" get secret ratatoskr-unit3d-app ratatoskr-mariadb ratatoskr-redis ratatoskr-meilisearch -o json > "$work/secrets.json"
python3 - "$work" "$NAMESPACE" <<'EXTERNAL'
import json, sys, yaml
from pathlib import Path
work, namespace = Path(sys.argv[1]), sys.argv[2]
source = {s['metadata']['name']: s['data'] for s in json.loads((work / 'secrets.json').read_text())['items']}
app = dict(source['ratatoskr-unit3d-app'])
app['application_key'] = app.pop('APP_KEY')
secrets = {
    'external-app': app,
    'external-db': {'client_password': source['ratatoskr-mariadb']['DB_PASSWORD']},
    'external-cache': {'client_password': source['ratatoskr-redis']['REDIS_PASSWORD']},
    'external-search': {'client_key': source['ratatoskr-meilisearch']['MEILI_MASTER_KEY']},
}
(work / 'external-secrets.yaml').write_text(yaml.safe_dump_all([
    {'apiVersion': 'v1', 'kind': 'Secret', 'metadata': {'name': name, 'namespace': namespace}, 'data': data}
    for name, data in secrets.items()
]))
values = yaml.safe_load((work / 'values.yaml').read_text())
values['fullnameOverride'] = 'external'
values['networkPolicies'] = {'enabled': True, 'extraEgress': [{'to': [{'podSelector': {'matchLabels': {'app.kubernetes.io/instance': 'ratatoskr'}}}], 'ports': [{'protocol': 'TCP', 'port': p} for p in [3306, 6379, 7700]]}]}
values['unit3d'].update({
    'bootstrapAppKey': False, 'appKey': '', 'existingSecret': 'external-app', 'existingSecretAppKeyKey': 'application_key',
    'database': {'host': 'ratatoskr-mariadb', 'name': 'unit3d', 'user': 'unit3d', 'existingSecret': 'external-db', 'existingSecretPasswordKey': 'client_password'},
    'redis': {'host': 'ratatoskr-redis', 'existingSecret': 'external-cache', 'existingSecretPasswordKey': 'client_password'},
    'meilisearch': {'host': 'ratatoskr-meilisearch', 'existingSecret': 'external-search', 'existingSecretMasterKeyKey': 'client_key'},
})
values['mariadb'] = {'enabled': False, 'auth': {'rootPassword': '', 'password': ''}}
values['redis'] = {'enabled': False, 'auth': {'password': ''}}
values['meilisearch'] = {'enabled': False, 'masterKey': ''}
(work / 'external-values.yaml').write_text(yaml.safe_dump(values))
EXTERNAL
kubectl apply -f "$work/external-secrets.yaml" >/dev/null
helm install external helm/ratatoskr -n "$NAMESPACE" -f "$work/external-values.yaml" --wait --wait-for-jobs --timeout=5m
helm test external -n "$NAMESPACE" --logs --timeout=120s
kubectl -n "$NAMESPACE" exec deploy/external-unit3d-app -- php -r '
$db = new PDO("mysql:host=".getenv("DB_HOST").";dbname=".getenv("DB_DATABASE"), getenv("DB_USERNAME"), getenv("DB_PASSWORD"));
if ($db->query("SELECT COUNT(*) FROM ratatoskr_lifecycle_sentinel WHERE id=1")->fetchColumn() != 1) { exit(1); }'
kubectl -n "$NAMESPACE" exec deploy/external-unit3d-app -- php artisan scout:sync-index-settings
check_search external-unit3d-app
echo "HELM_LIFECYCLE_RESULT=PASS"
