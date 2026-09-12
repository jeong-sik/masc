"""Real installer uninstall against disposable files; dependency/network calls forbidden."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/install.sh'
NAMES = ('masc', 'masc-tui', 'masc-browser-host', 'masc-deployment-preflight-helper',
         'masc-check-runtime-deployment-preflight')


class Uninstall(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='masc-uninstall-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.prefix = self.root / 'custom bin'
        self.base = self.root / 'workspace'
        self.prefix.mkdir()
        (self.base / '.masc').mkdir(parents=True)
        (self.base / '.masc' / 'operator-data').write_text('keep')
        (self.prefix / 'unrelated-tool').write_text('keep')
        self.blocked = self.root / 'blocked'
        self.blocked.mkdir()
        for command in ('brew', 'curl', 'python3', 'uname', 'sw_vers'):
            stub = self.blocked / command
            stub.write_text('#!/bin/sh\necho forbidden-tool >&2\nexit 91\n')
            stub.chmod(0o755)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('MASC_')}
        self.env.update(PATH=str(self.blocked) + ':/usr/bin:/bin', HOME=str(self.root),
                        XDG_CONFIG_HOME=str(self.root / '.config'))

    def run_installer(self, *args):
        return subprocess.run(['/bin/bash', str(SCRIPT), '--prefix', str(self.prefix), *args],
                              env=self.env, cwd=self.root, text=True, capture_output=True)

    def install_layout(self):
        release = self.prefix / '.masc-releases' / 'release'
        release.mkdir(parents=True)
        (release / 'masc').write_text('binary')
        for index, name in enumerate(NAMES):
            if index % 2:
                (self.prefix / name).write_text('binary')
            else:
                (self.prefix / name).symlink_to(release / 'masc')

    def test_uninstall_removes_only_owned_installation_and_is_idempotent(self):
        self.install_layout()
        for _ in range(2):
            result = self.run_installer('--uninstall')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for name in NAMES + ('.masc-releases',):
            self.assertFalse(os.path.lexists(self.prefix / name))
        self.assertEqual((self.prefix / 'unrelated-tool').read_text(), 'keep')
        self.assertEqual((self.base / '.masc' / 'operator-data').read_text(), 'keep')
        self.assertTrue(self.prefix.is_dir())

    def test_explicit_purge_removes_only_selected_workspace(self):
        other = self.root / 'other'
        (other / '.masc').mkdir(parents=True)
        result = self.run_installer('--uninstall', '--purge-data', '--base-path', str(self.base))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.base / '.masc').exists())
        self.assertTrue(self.base.is_dir())
        self.assertTrue((other / '.masc').is_dir())

    def test_purge_unlinks_symlink_without_following_it(self):
        linked = self.root / 'linked-workspace'
        linked.mkdir()
        (linked / '.masc').symlink_to(self.base / '.masc', target_is_directory=True)
        result = self.run_installer('--uninstall', '--purge-data', '--base-path', str(linked))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(os.path.lexists(linked / '.masc'))
        self.assertEqual((self.base / '.masc' / 'operator-data').read_text(), 'keep')

    def test_purge_removes_record_for_equivalent_workspace_paths(self):
        record = self.root / '.config/masc/default-base-path'
        record.parent.mkdir(parents=True)
        alias = self.root / 'workspace-link'
        alias.symlink_to(self.base, target_is_directory=True)
        for spelling in (str(self.base) + '/', './workspace', str(alias)):
            with self.subTest(spelling=spelling):
                (self.base / '.masc').mkdir(exist_ok=True)
                record.write_text(str(self.base.resolve()) + '\n')
                result = self.run_installer('--uninstall', '--purge-data', '--base-path', spelling)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(record.exists())
                self.assertFalse((self.base / '.masc').exists())

    def test_purge_preserves_another_workspaces_record(self):
        record = self.root / '.config/masc/default-base-path'
        record.parent.mkdir(parents=True)
        other = self.root / 'other'
        (other / '.masc').mkdir(parents=True)
        content = str(other.resolve()) + '\n'
        record.write_text(content)
        result = self.run_installer('--uninstall', '--purge-data', '--base-path', str(self.base))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(record.read_text(), content)
        self.assertTrue((other / '.masc').is_dir())

    def test_unreadable_record_does_not_block_explicit_purge(self):
        record = self.root / '.config/masc/default-base-path'
        record.parent.mkdir(parents=True)
        content = str(self.base.resolve()) + '\n'
        record.write_text(content)
        head = self.blocked / 'head'
        head.write_text('#!/bin/sh\nexit 1\n')
        head.chmod(0o755)
        result = self.run_installer('--uninstall', '--purge-data', '--base-path', str(self.base))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.base / '.masc').exists())
        self.assertEqual(record.read_text(), content)
        self.assertIn('record could not be read', result.stdout)

    def test_dry_run_lists_exact_targets_without_changes(self):
        self.install_layout()
        result = self.run_installer('--uninstall', '--purge-data', '--base-path', str(self.base), '--dry-run')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for name in NAMES + ('.masc-releases',):
            self.assertIn('would remove: ' + str(self.prefix / name), result.stdout)
            self.assertTrue(os.path.lexists(self.prefix / name))
        self.assertIn('would remove: ' + str(self.base / '.masc'), result.stdout)
        self.assertTrue((self.base / '.masc').is_dir())

    def test_external_install_symlinks_are_unlinked_and_unexpected_directory_refused(self):
        external = self.root / 'external'
        external.mkdir()
        (external / 'binary').write_text('keep')
        (self.prefix / 'masc').symlink_to(external / 'binary')
        (self.prefix / '.masc-releases').symlink_to(external, target_is_directory=True)
        (self.prefix / 'masc-tui').mkdir()
        refused = self.run_installer('--uninstall')
        self.assertNotEqual(refused.returncode, 0)
        self.assertTrue((self.prefix / 'masc').is_symlink())
        (self.prefix / 'masc-tui').rmdir()
        result = self.run_installer('--uninstall')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((external / 'binary').read_text(), 'keep')
        self.assertFalse(os.path.lexists(self.prefix / '.masc-releases'))

    def test_invalid_combinations_and_pending_transaction_do_not_delete(self):
        self.install_layout()
        for args in (('--purge-data',), ('--uninstall', '--purge-data'),
                     ('--uninstall', '--provider', 'codex'), ('--uninstall', '--reset-config'),
                     ('--uninstall', '--team', 'classic'), ('--uninstall', '--force')):
            with self.subTest(args=args):
                result = self.run_installer(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(os.path.lexists(self.prefix / 'masc'))
        (self.prefix / '.masc-install-transaction').write_text('{}')
        result = self.run_installer('--uninstall')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('recover or roll back', result.stderr)
        self.assertTrue(os.path.lexists(self.prefix / 'masc'))


if __name__ == '__main__':
    unittest.main()
