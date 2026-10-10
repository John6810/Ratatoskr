"""Regressions for severity-independent, fail-closed vulnerability gating."""
import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[1] / 'scripts/security/check-image.py'
spec = importlib.util.spec_from_file_location('image_gate', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ImageGateTests(unittest.TestCase):
    def report(self, severity='UNKNOWN', fixed='2'):
        return {'SchemaVersion': 2, 'ArtifactType': 'container_image', 'Results': [
            {'Class': 'os-pkgs', 'Vulnerabilities': [{'PkgName': 'fixture',
             'VulnerabilityID': 'TEST-1', 'Severity': severity,
             'InstalledVersion': '1', 'FixedVersion': fixed}]}]}

    def test_fixable_unknown_and_low_are_blocking(self):
        for severity in ['UNKNOWN', 'LOW', 'MEDIUM', 'HIGH', 'CRITICAL']:
            self.assertTrue(module.check(self.report(severity)))

    def test_unfixed_inventory_is_retained_but_not_misrepresented_as_fixable(self):
        self.assertFalse(module.check(self.report('CRITICAL', '')))

    def test_missing_os_scan_fails_closed(self):
        for report in [{}, {'SchemaVersion': 2, 'ArtifactType': 'container_image',
                            'Results': [{'Class': 'lang-pkgs'}]}]:
            with self.assertRaises(ValueError):
                module.check(report)
