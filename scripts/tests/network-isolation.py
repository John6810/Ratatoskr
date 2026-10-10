#!/usr/bin/env python3
"""Prove default-deny behavior with a foreign release and a decoy API port."""
import json
import os
import secrets
import subprocess
import sys

if not os.environ.get('KUBECONFIG'):
    raise SystemExit('Set KUBECONFIG explicitly')
namespace, image = sys.argv[1:3]
name = 'security-probe-' + secrets.token_hex(5)


def kubectl(*args, **kwargs):
    return subprocess.check_output(['kubectl', '-n', namespace, *args], text=True, **kwargs)


def connect(pod, address, port, allowed):
    code = '$s=@stream_socket_client($argv[1],$e,$m,3); exit((bool)$s === ($argv[2]==="true") ? 0 : 1);'
    kubectl('exec', pod, '--', 'php', '-r', code, f'tcp://{address}:{port}', str(allowed).lower())


pod = {'apiVersion': 'v1', 'kind': 'Pod', 'metadata': {'name': name, 'labels': {
    'app.kubernetes.io/instance': 'foreign-release', 'app.kubernetes.io/component': 'app'}},
    'spec': {'restartPolicy': 'Never', 'automountServiceAccountToken': False,
             'securityContext': {'runAsNonRoot': True, 'runAsUser': 33, 'runAsGroup': 33,
                                 'seccompProfile': {'type': 'RuntimeDefault'}},
             'containers': [{'name': 'probe', 'image': image, 'imagePullPolicy': 'IfNotPresent',
                             'command': ['php', '-S', '0.0.0.0:6443', '-t', '/app/public'],
                             'securityContext': {'readOnlyRootFilesystem': True,
                                                 'allowPrivilegeEscalation': False,
                                                 'capabilities': {'drop': ['ALL']}},
                             'resources': {'requests': {'cpu': '10m', 'memory': '32Mi'},
                                           'limits': {'cpu': '100m', 'memory': '64Mi'}}}]}}
created = False
try:
    kubectl('create', '-f', '-', input=json.dumps(pod))
    created = True
    kubectl('wait', '--for=condition=Ready', 'pod/' + name, '--timeout=120s')
    ip = kubectl('get', 'pod', name, '-o', 'jsonpath={.status.podIP}').strip()
    connect(name, '127.0.0.1', 6443, True)
    for service, port in [('ratatoskr-mariadb', 3306), ('ratatoskr-redis', 6379),
                          ('ratatoskr-meilisearch', 7700)]:
        target = kubectl('get', 'service', service, '-o', 'jsonpath={.spec.clusterIP}').strip()
        connect('deployment/ratatoskr-unit3d-app', target, port, True)
        connect(name, target, port, False)
    connect('deployment/ratatoskr-unit3d-app', ip, 6443, False)
    kubectl('exec', 'deployment/ratatoskr-unit3d-app', '--', 'php', '-r',
            'foreach (["MARIADB_ROOT_PASSWORD", "MARIADB_BACKUP_PASSWORD", "DEFAULT_OWNER_PASSWORD"] as $key) if (getenv($key)) exit(1); '
            'if (file_exists("/var/run/secrets/kubernetes.io/serviceaccount/token")) exit(1); '
            'if (is_writable("/app/public") || is_writable("/app/vendor")) exit(1);')
    print('NETWORK_ISOLATION_RESULT=PASS: authorized traffic works; foreign release and decoy API denied')
finally:
    if created:
        kubectl('delete', 'pod', name, '--wait', '--timeout=60s')
