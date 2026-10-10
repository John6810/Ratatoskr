"""Exercise destructive failure paths with disposable files and fake executables."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
STUB = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
a = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as out:
    out.write(json.dumps([name, *a]) + '\n')
scenario = os.environ.get('SCENARIO', '')
if name == 'helm':
    if a[0] == 'version': print('v3.16.4+test')
    elif a[0] == 'install': sys.exit(22)
    elif a[0] not in ['lint', 'status', 'uninstall']: sys.exit(97)
elif name == 'kubectl':
    if a[0] == 'version':
        print(json.dumps({'clientVersion': {'gitVersion': 'v1.32.0'}, 'serverVersion': {'gitVersion': 'v1.32.0'}}))
    elif a[:2] == ['get', 'storageclass']: pass
    elif a[:2] == ['get', 'namespace']:
        state = Path(os.environ['STATE'])
        if scenario == 'existing': print('existing-uid')
        elif not state.exists(): sys.exit(1)
        else: print('replacement-uid' if scenario == 'replacement' else 'owned-uid')
    elif a[:2] == ['create', 'namespace']:
        Path(os.environ['STATE']).touch()
        if scenario == 'create-race': sys.exit(1)
        print('owned-uid')
    elif a[:2] == ['delete', 'namespace']:
        if scenario == 'cleanup-failure': sys.exit(1)
    elif a[0] == '-n' and a[2:4] in [['get', 'pods'], ['get', 'events']]: pass
    else: sys.exit(97)
elif name == 'restic':
    if scenario == 'download': sys.exit(23)
    print('mock stream')
elif name == 'zstd': sys.stdout.write(sys.stdin.read())
elif name == 'mbstream': sys.stdin.read()
elif name == 'mariadb-backup':
    if '--prepare' in a:
        if scenario == 'prepare': sys.exit(24)
    elif '--copy-back' in a:
        target = Path(next(x.split('=', 1)[1] for x in a if x.startswith('--datadir=')))
        (target / 'restored.ibd').write_text('restored data')
        if scenario == 'copy-back': sys.exit(25)
    else: sys.exit(97)
elif name == 'chown': pass
else: sys.exit(97)
'''


class SafetyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='ratatoskr-tests-')
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.bin = self.work / 'bin'
        self.bin.mkdir()
        for name in ['helm', 'kubectl', 'restic', 'zstd', 'mbstream', 'mariadb-backup', 'chown']:
            executable = self.bin / name
            executable.write_text(STUB)
            executable.chmod(0o755)
        self.calls = self.work / 'calls'
        self.env = {**os.environ, 'PATH': f'{self.bin}:/usr/bin:/bin',
                    'KUBECONFIG': '/dev/null', 'CALLS': str(self.calls),
                    'STATE': str(self.work / 'namespace-created'), 'KEEP_NAMESPACE': '0',
                    'NAMESPACE': 'mock-only', 'RESTIC_REPOSITORY': 'mock:no-network',
                    'RESTIC_PASSWORD': 'CHANGEME', 'RESTORE_FORCE': 'true'}

    def run_script(self, script, scenario, **extra):
        return subprocess.run(['bash' if script == 'restore.sh' else 'sh', str(ROOT / 'scripts' / script)],
                              cwd=ROOT, env={**self.env, 'SCENARIO': scenario, **extra},
                              text=True, capture_output=True, timeout=20)

    def mutations(self):
        return [c for c in map(json.loads, self.calls.read_text().splitlines())
                if c[:2] in [['helm', 'uninstall'], ['kubectl', 'delete']]]

    def test_preexisting_namespace_is_never_removed(self):
        result = self.run_script('smoke/helm-chart-smoke.sh', 'existing')
        self.assertEqual(result.returncode, 15, result.stderr)
        self.assertEqual(self.mutations(), [])
        self.assertTrue(result.stdout.rstrip().endswith('SMOKE_RESULT=FAIL'))

    def test_namespace_creation_race_does_not_transfer_ownership(self):
        result = self.run_script('smoke/helm-chart-smoke.sh', 'create-race')
        self.assertEqual(result.returncode, 20, result.stderr)
        self.assertEqual(self.mutations(), [])

    def test_replacement_namespace_is_not_removed(self):
        result = self.run_script('smoke/helm-chart-smoke.sh', 'replacement')
        self.assertEqual(result.returncode, 40, result.stderr)
        self.assertEqual(self.mutations(), [])

    def test_failed_install_cleans_up_only_owned_namespace(self):
        result = self.run_script('smoke/helm-chart-smoke.sh', 'install')
        self.assertEqual(result.returncode, 22, result.stderr)
        self.assertEqual(len(self.mutations()), 2)

    def test_failed_restore_preserves_regular_and_hidden_files(self):
        for failure in ['download', 'prepare', 'copy-back']:
            with self.subTest(failure=failure):
                target = self.work / failure
                target.mkdir()
                (target / 'original.ibd').write_text('original')
                (target / '.metadata').write_text('hidden original')
                result = self.run_script('restore.sh', failure, TARGET_DIR=str(target))
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((target / 'original.ibd').read_text(), 'original', result.stderr)
                self.assertEqual((target / '.metadata').read_text(), 'hidden original')
                self.assertFalse((target / 'restored.ibd').exists())

    def test_successful_restore_keeps_original_datadir_for_verification(self):
        target = self.work / 'success'
        target.mkdir()
        (target / 'original.ibd').write_text('original')
        result = self.run_script('restore.sh', 'success', TARGET_DIR=str(target))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((target / 'restored.ibd').exists())
        retained = list(target.glob('.ratatoskr-before-restore-*/original.ibd'))
        self.assertEqual(len(retained), 1)
        self.assertEqual(retained[0].read_text(), 'original')

    def test_restore_refuses_root_and_nonempty_unforced_target(self):
        target = self.work / 'nonempty'
        target.mkdir()
        (target / 'original').touch()
        for destination in ['/', str(target)]:
            result = self.run_script('restore.sh', 'success', TARGET_DIR=destination, RESTORE_FORCE='false')
            self.assertNotEqual(result.returncode, 0)
        self.assertTrue((target / 'original').exists())
        self.assertFalse(self.calls.exists())

    def test_migration_finalization_never_reclaims_source_volume(self):
        source = (ROOT / 'scripts/migration/migrate-rwo-to-rwx.sh').read_text()
        source = source.rsplit('main "$@"', 1)[0]
        source += '\nOLD_PV=original-volume\nkc_mutate() { printf "%s\\n" "$*"; }\nmutate_finalize_old_pv\n'
        result = subprocess.run(['sh'], input=source, env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"persistentVolumeReclaimPolicy":"Retain"', result.stdout)
        self.assertNotIn('"persistentVolumeReclaimPolicy":"Delete"', result.stdout)

    def test_migration_checksum_io_errors_abort_instead_of_passing_as_empty(self):
        source = (ROOT / 'scripts/migration/migrate-rwo-to-rwx.sh').read_text().rsplit('main "$@"', 1)[0]
        source += r'''
kc() {
    case "$*" in
        *"cd /old"*)
            [ "$VERIFY_ERROR" != source ] || return 42
            printf 'checksum  ./file\n' ;;
        *"cd /new"*)
            [ "$VERIFY_ERROR" != destination ] || return 43
            printf 'checksum  ./file\n' ;;
    esac
}
mutate_rsync_and_verify
echo UNEXPECTED_SUCCESS
'''
        for side in ['source', 'destination']:
            with self.subTest(side=side):
                result = subprocess.run(['sh'], input=source, env={**self.env, 'VERIFY_ERROR': side},
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, 28, result.stderr)
                self.assertNotIn('UNEXPECTED_SUCCESS', result.stdout)


if __name__ == '__main__':
    unittest.main()
