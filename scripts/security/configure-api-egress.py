#!/usr/bin/env python3
"""Resolve exact API destinations in a rendered manifest; never apply it."""
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import sys

import yaml


def api_cidrs():
    if not os.environ.get('KUBECONFIG') and not os.environ.get('KUBECTL_CONTEXT'):
        raise ValueError('Set KUBECONFIG or KUBECTL_CONTEXT explicitly for the intended cluster')
    def get(kind):
        return json.loads(subprocess.check_output(
            kubectl_command() + ['-n', 'default', 'get', kind, 'kubernetes', '-o', 'json']))
    service, endpoints = get('service'), get('endpoints')
    addresses = service['spec'].get('clusterIPs', [service['spec']['clusterIP']])
    endpoint_ips = [a['ip'] for s in endpoints.get('subsets', []) for a in s.get('addresses', [])]
    if not endpoint_ips:
        raise ValueError('API Endpoints has no ready address; refusing incomplete egress configuration')
    addresses += endpoint_ips
    return sorted({str(ipaddress.ip_network(ipaddress.ip_address(a))) for a in addresses})


def kubectl_command():
    context = os.environ.get('KUBECTL_CONTEXT')
    return ['kubectl'] + (['--context', context] if context else [])


def configure(docs, cidrs):
    count = 0
    for doc in docs:
        if doc and doc.get('kind') == 'NetworkPolicy' and doc['metadata']['name'].endswith('-migration-api'):
            for rule in doc['spec']['egress']:
                rule['to'] = [{'ipBlock': {'cidr': cidr}} for cidr in cidrs]
            count += 1
    if count != 1:
        raise ValueError(f'Expected exactly one migration API policy, found {count}')


if __name__ == '__main__':
    cidrs = api_cidrs()
    if sys.argv[1:] == ['--check']:
        print('API discovery ready:', ', '.join(cidrs), file=sys.stderr)
        sys.exit(0)
    docs = list(yaml.safe_load_all(Path(sys.argv[1]).read_text()))
    configure(docs, cidrs)
    Path(sys.argv[2]).write_text(yaml.safe_dump_all(docs, sort_keys=False))
    print('API egress destinations:', ', '.join(cidrs), file=sys.stderr)
