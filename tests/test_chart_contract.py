"""Validate supported configurations and application/dependency contracts."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
HELM = os.environ.get('HELM_BINARY', shutil.which('helm'))


@unittest.skipUnless(HELM, 'helm is required')
class ChartTests(unittest.TestCase):
    def render(self, *overrides, succeeds=True, chart='helm/ratatoskr'):
        args = [HELM, 'template', 'ratatoskr', str(chart), '--namespace', 'test',
                '--kube-version', '1.32.0', '-f', 'helm/ratatoskr/ci/test-values.yaml']
        for value in overrides:
            args += ['--set', value]
        result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True)
        if not succeeds:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            return result.stderr
        self.assertEqual(result.returncode, 0, result.stderr)
        return [d for d in yaml.safe_load_all(result.stdout) if d]

    def test_chart_and_app_version_changes_preserve_immutable_claim_templates(self):
        before = {d['metadata']['name']: d['spec']['volumeClaimTemplates']
                  for d in self.render() if d['kind'] == 'StatefulSet'}
        with tempfile.TemporaryDirectory() as directory:
            chart = Path(directory) / 'chart'
            shutil.copytree(ROOT / 'helm/ratatoskr', chart)
            metadata = yaml.safe_load((chart / 'Chart.yaml').read_text())
            metadata.update(version='0.0.0-regression', appVersion='synthetic-version')
            (chart / 'Chart.yaml').write_text(yaml.safe_dump(metadata))
            after = {d['metadata']['name']: d['spec']['volumeClaimTemplates']
                     for d in self.render(chart=chart) if d['kind'] == 'StatefulSet'}
        self.assertEqual(before, after)

    def test_first_install_job_has_created_dependencies_and_workload_gates(self):
        docs = self.render()
        job = next(d for d in docs if d['kind'] == 'Job')
        self.assertNotIn('helm.sh/hook', job['metadata'].get('annotations', {}))
        self.assertNotIn('ttlSecondsAfterFinished', job['spec'])
        role = next(d for d in docs if d['kind'] == 'Role')
        self.assertEqual(role['rules'][0]['resourceNames'], [job['metadata']['name']])
        for resource in [d for d in docs if d['kind'] in ['Deployment', 'Job']]:
            pod = resource['spec']['template']['spec']
            main = pod['containers'][0]
            variables = {e['name']: e for e in main['env']}
            self.assertIn('MEILISEARCH_KEY', variables)
            self.assertEqual(variables['MEILISEARCH_KEY']['valueFrom']['secretKeyRef']['key'], 'MEILI_MASTER_KEY')
            self.assertNotIn('ratatoskr-mariadb', [e.get('secretRef', {}).get('name') for e in main['envFrom']])
            self.assertFalse(pod['automountServiceAccountToken'])
            if resource['kind'] == 'Deployment':
                self.assertEqual(pod['initContainers'][0]['env'][0]['value'], job['metadata']['name'])
                self.assertEqual(pod['serviceAccountName'], 'ratatoskr')

    def test_external_services_do_not_require_embedded_credentials(self):
        docs = self.render('mariadb.enabled=false', 'redis.enabled=false', 'meilisearch.enabled=false',
                           'mariadb.auth.rootPassword=', 'mariadb.auth.password=', 'redis.auth.password=',
                           'meilisearch.masterKey=', 'networkPolicies.enabled=false',
                           'unit3d.database.host=db.example.invalid', 'unit3d.database.existingSecret=db',
                           'unit3d.database.existingSecretPasswordKey=password',
                           'unit3d.redis.host=cache.example.invalid', 'unit3d.redis.existingSecret=cache',
                           'unit3d.meilisearch.host=search.example.invalid', 'unit3d.meilisearch.existingSecret=search')
        self.assertFalse(any(d['kind'] == 'StatefulSet' for d in docs))
        for d in docs:
            if d['kind'] == 'Deployment':
                variables = {e['name']: e for e in d['spec']['template']['spec']['containers'][0]['env']}
                self.assertEqual(variables['DB_PASSWORD']['valueFrom']['secretKeyRef'], {'name': 'db', 'key': 'password'})

    def test_unsupported_configurations_fail_with_explanations(self):
        cases = [('ingress.enabled=true', 'ingress.enabled'),
                 ('unit3d.frankenphp.workers=4', 'threads must exceed workers'),
                 ('storage.enabled=false', 'writable PVC'),
                 ('storage.accessMode=ReadWriteOncePod', 'ReadWriteMany'),
                 ('unit3d.replicas=2', 'ReadWriteMany')]
        for value, message in cases:
            with self.subTest(value=value):
                self.assertIn(message, self.render(value, succeeds=False))
        self.assertIn('ReadWriteMany', self.render('hpa.app.enabled=true', 'hpa.app.minReplicas=1',
                                                  'hpa.app.maxReplicas=10', succeeds=False))

    def test_rwx_rollouts_preserve_available_replicas(self):
        docs = self.render('storage.accessMode=ReadWriteMany', 'unit3d.replicas=2', 'queue.replicas=2',
                           'hpa.app.enabled=true', 'hpa.queue.enabled=true')
        for d in docs:
            if d['kind'] == 'Deployment' and d['metadata']['name'] != 'ratatoskr-unit3d-scheduler':
                self.assertEqual(d['spec']['strategy']['type'], 'RollingUpdate')
                self.assertEqual(d['spec']['strategy']['rollingUpdate']['maxUnavailable'], 0)
                self.assertNotIn('affinity', d['spec']['template']['spec'])

    def test_probes_accounts_and_secret_keys_are_wired(self):
        docs = self.render('unit3d.appKey=', 'unit3d.existingSecret=application',
                           'unit3d.existingSecretAppKeyKey=key', 'serviceAccount.name=custom',
                           'unit3d.probes.readiness.tcpSocket.port=80')
        app = next(d for d in docs if d['kind'] == 'Deployment' and d['metadata']['name'] == 'ratatoskr-unit3d-app')
        pod = app['spec']['template']['spec']
        self.assertEqual(pod['serviceAccountName'], 'custom')
        self.assertEqual(pod['containers'][0]['readinessProbe'], {'tcpSocket': {'port': 80}})
        key = next(e for e in pod['containers'][0]['env'] if e['name'] == 'APP_KEY')
        self.assertEqual(key['valueFrom']['secretKeyRef'], {'name': 'application', 'key': 'key'})

    def test_emptydir_infrastructure_has_bound_volume_names(self):
        docs = self.render('mariadb.persistence.enabled=false', 'redis.persistence.enabled=false',
                           'meilisearch.persistence.enabled=false')
        for d in docs:
            if d['kind'] == 'StatefulSet':
                volumes = {v['name']: v for v in d['spec']['template']['spec']['volumes']}
                self.assertEqual(volumes['data']['emptyDir'], {})

    def test_bootstrap_key_is_valid_without_a_secret_mutation_job(self):
        import base64
        docs = self.render('unit3d.appKey=', 'unit3d.bootstrapAppKey=true')
        secret = next(d for d in docs if d['kind'] == 'Secret' and d['metadata']['name'] == 'ratatoskr-unit3d-app')
        key = secret['stringData']['APP_KEY']
        self.assertTrue(key.startswith('base64:'))
        self.assertEqual(len(base64.b64decode(key[7:], validate=True)), 32)
        self.assertEqual(len([d for d in docs if d['kind'] == 'Job']), 1)

    def test_lifecycle_scripts_stay_in_sync(self):
        self.assertEqual((ROOT / 'helm/ratatoskr/files/lifecycle.php').read_bytes(),
                         (ROOT / 'kustomize/base/config/lifecycle.php').read_bytes())
        self.assertEqual((ROOT / 'helm/ratatoskr/files/lifecycle.php').read_bytes(),
                         (ROOT / 'docker/lifecycle.php').read_bytes())

    def test_bootstrap_upgrade_refuses_to_replace_a_missing_key(self):
        result = subprocess.run([HELM, 'template', 'ratatoskr', 'helm/ratatoskr', '--is-upgrade',
                                 '-f', 'helm/ratatoskr/ci/test-values.yaml', '--set', 'unit3d.appKey=',
                                 '--set', 'unit3d.bootstrapAppKey=true'], cwd=ROOT, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('restore the original Secret', result.stderr)

    def test_http_startup_and_rwo_placement(self):
        docs = self.render()
        for d in docs:
            if d['kind'] in ['Deployment', 'Job']:
                pod = d['spec']['template']['spec']
                affinity = pod['affinity']['podAffinity']['requiredDuringSchedulingIgnoredDuringExecution'][0]
                self.assertEqual(affinity['topologyKey'], 'kubernetes.io/hostname')
                if d['metadata']['name'] == 'ratatoskr-unit3d-app':
                    app = pod['containers'][0]
                    self.assertIn({'name': 'net.ipv4.ip_unprivileged_port_start', 'value': '80'}, pod['securityContext']['sysctls'])
                    self.assertEqual(app['args'][0:2], ['frankenphp', 'run'])
                    self.assertIn('NET_BIND_SERVICE', app['securityContext']['capabilities']['add'])
                    self.assertIn('curl', app['startupProbe']['exec']['command'])
                    self.assertNotIn('--location', app['startupProbe']['exec']['command'])
                    self.assertEqual(app['lifecycle']['preStop']['exec']['command'], ['sleep', '10'])
                if d['kind'] == 'Job':
                    self.assertEqual(pod['restartPolicy'], 'Never')
                    self.assertEqual(pod['containers'][0]['command'][-1], 'migrate')


if __name__ == '__main__':
    unittest.main()
