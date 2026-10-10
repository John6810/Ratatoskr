"""API allowlists must be explicit, cluster-specific and preserve Secrets."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('api_egress', Path(__file__).resolve().parents[1] / 'scripts/security/configure-api-egress.py')
api = importlib.util.module_from_spec(spec)
spec.loader.exec_module(api)


class ApiEgressTests(unittest.TestCase):
    def test_requires_explicit_cluster_without_running_kubectl(self):
        with patch.dict('os.environ', {}, clear=True), patch.object(api.subprocess, 'check_output') as call:
            with self.assertRaisesRegex(ValueError, 'explicitly'):
                api.api_cidrs()
            call.assert_not_called()

    def test_uses_selected_context_and_exact_dual_stack_destinations(self):
        service = {'spec': {'clusterIP': '10.96.0.1', 'clusterIPs': ['10.96.0.1', 'fd00::1']}}
        endpoints = {'subsets': [{'addresses': [{'ip': '192.0.2.2'}, {'ip': '192.0.2.2'}]}]}
        with patch.dict('os.environ', {'KUBECTL_CONTEXT': 'chosen'}, clear=True), patch.object(api.subprocess, 'check_output', side_effect=[json.dumps(service), json.dumps(endpoints)]) as call:
            self.assertEqual(api.api_cidrs(), ['10.96.0.1/32', '192.0.2.2/32', 'fd00::1/128'])
            for args in call.call_args_list:
                self.assertEqual(args.args[0][:3], ['kubectl', '--context', 'chosen'])

    def test_missing_endpoints_fails_before_apply(self):
        with patch.dict('os.environ', {'KUBECONFIG': '/test/cluster'}, clear=True), patch.object(api.subprocess, 'check_output', side_effect=[json.dumps({'spec': {'clusterIP': '10.96.0.1'}}), '{}']):
            with self.assertRaisesRegex(ValueError, 'no ready address'):
                api.api_cidrs()

    def test_replaces_only_api_destinations_and_preserves_secret_bytes(self):
        secret = {'kind': 'Secret', 'data': {'APP_KEY': 'dGVzdC1vbmx5'}, 'stringData': {'quoted': 'literal: value\n'}}
        policy = {'kind': 'NetworkPolicy', 'metadata': {'name': 'unit3d-migration-api'}, 'spec': {'egress': [{'ports': [{'port': 6443}], 'to': [{'ipBlock': {'cidr': '127.0.0.1/32'}}]}]}}
        docs = [copy.deepcopy(secret), policy]
        api.configure(docs, ['192.0.2.2/32'])
        self.assertEqual(docs[0], secret)
        self.assertEqual(policy['spec']['egress'], [{'ports': [{'port': 6443}], 'to': [{'ipBlock': {'cidr': '192.0.2.2/32'}}]}])
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            api.configure([secret], ['192.0.2.2/32'])
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            api.configure([policy, copy.deepcopy(policy)], ['192.0.2.2/32'])
