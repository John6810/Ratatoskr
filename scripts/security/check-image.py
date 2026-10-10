#!/usr/bin/env python3
"""Fail closed on missing scans or any fixed vulnerability, at every severity."""
import collections
import json
import sys


def check(report):
    if report.get('SchemaVersion') != 2 or not report.get('Results'):
        raise ValueError('Expected a non-empty Trivy image report (schema 2)')
    if report.get('ArtifactType') != 'container_image':
        raise ValueError('Expected a container image scan')
    if not any(r.get('Class') == 'os-pkgs' for r in report['Results']):
        raise ValueError('OS package inventory is missing')
    findings = [v for r in report['Results'] for v in r.get('Vulnerabilities', [])]
    counts = collections.Counter(v['Severity'] for v in findings)
    print('Full inventory (including unfixed):', dict(sorted(counts.items())))
    fixed = [v for v in findings if v.get('FixedVersion', '').strip()]
    for v in fixed:
        print(f"FIX REQUIRED: {v['PkgName']} {v['VulnerabilityID']} "
              f"({v['Severity']}) {v['InstalledVersion']} -> {v['FixedVersion']}")
    print(f'Available-fix gate: {len(fixed)} findings')
    return bool(fixed)


if __name__ == '__main__':
    try:
        with open(sys.argv[1]) as source:
            sys.exit(int(check(json.load(source))))
    except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
        print(f'Invalid vulnerability report: {error}', file=sys.stderr)
        sys.exit(2)
