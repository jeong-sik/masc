"""Exercise binary selection with a real isolated linked Git worktree."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BOOTSTRAP = (Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 and not sys.argv[1].startswith('-')
             else Path(__file__).resolve().parents[1] / 'scripts/harness/lib/server_bootstrap.sh')


class ServerBinarySelection(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='masc-binary-selection-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.main = self.root / 'main checkout'
        self.worktree = self.root / 'linked worktree'
        self.git('init', '-q', str(self.main))
        (self.main / 'fixture').write_text('isolated fixture\n')
        self.git('-C', str(self.main), 'add', 'fixture')
        self.git('-C', str(self.main), '-c', 'user.name=Harness Fixture',
                 '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false',
                 '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'fixture')
        self.git('-C', str(self.main), 'worktree', 'add', '-q', '--detach', str(self.worktree))
        self.parent_binary = self.binary(self.main, '_build/default/bin/main_eio.exe', 'parent')

    def git(self, *args):
        subprocess.run(['git', '-c', 'core.hooksPath=/dev/null', *args], check=True, capture_output=True, text=True)

    def binary(self, root, name, marker):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('#!/bin/sh\nprintf "%s\\n" ' + marker + '\n')
        path.chmod(0o755)
        return path

    def select(self, explicit='', build_dir=None):
        env = dict(os.environ)
        env.pop('DUNE_BUILD_DIR', None)
        if build_dir is not None:
            env['DUNE_BUILD_DIR'] = str(build_dir)
        return subprocess.run(['bash', '-c',
            'source "$1"; harness_find_server_exe "$2" "$3"', 'harness-fixture',
            str(BOOTSTRAP), str(self.worktree), str(explicit)],
            env=env, capture_output=True, text=True)

    def assert_missing(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_parent_checkout_is_not_an_implicit_fallback(self):
        self.assert_missing(self.select())

    def test_requested_checkout_is_selected_and_runs(self):
        path = self.binary(self.worktree, '_build/default/bin/main_eio.exe', 'requested')
        result = self.select()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(path.resolve()))
        self.assertEqual(subprocess.check_output([result.stdout.strip()], text=True), 'requested\n')
        self.assertIn('source=requested_checkout', result.stderr)

    def test_explicit_external_binary_is_selected_and_runs(self):
        result = self.select(self.parent_binary)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(subprocess.check_output([result.stdout.strip()], text=True), 'parent\n')
        self.assertIn('source=explicit', result.stderr)

    def test_invalid_explicit_does_not_fall_back(self):
        self.binary(self.worktree, 'bin/main_eio.exe', 'requested')
        self.assert_missing(self.select(self.root / 'missing'))

    def test_custom_build_inside_checkout(self):
        path = self.binary(self.worktree, 'custom/default/bin/main_eio.exe', 'custom')
        result = self.select(build_dir='custom')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(path.resolve()))

    def test_external_build_directory_needs_explicit_binary(self):
        self.assert_missing(self.select(build_dir=self.main / '_build'))

    def test_symlink_cannot_import_parent_build_implicitly(self):
        (self.worktree / '_build').symlink_to(self.main / '_build', target_is_directory=True)
        self.assert_missing(self.select())

    def test_non_executable_is_rejected(self):
        path = self.binary(self.worktree, 'bin/main_eio.exe', 'requested')
        path.chmod(0o644)
        self.assert_missing(self.select())


if __name__ == '__main__':
    unittest.main()
