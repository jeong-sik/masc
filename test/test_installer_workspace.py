"""Workspace selection uses native observation, never CWD scanning or mkdir."""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shlex
import subprocess
import tempfile
import termios
import time
import unittest

INSTALLER = Path(__file__).resolve().parents[1] / 'scripts/install.sh'


class WorkspaceSelection(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='masc-workspace-selection-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / 'home'
        self.home.mkdir()
        self.cwd = self.root / 'unrelated-checkout'
        (self.cwd / '.masc/config').mkdir(parents=True)
        self.library = self.root / 'installer-functions.sh'
        self.library.write_text(INSTALLER.read_text().split('\nwhile [ $# -gt 0 ]; do', 1)[0])
        self.observation = self.root / 'native-status.json'
        self.observation.write_text(json.dumps(dict(schema='masc.onboarding_status.v1', base_path=None)))
        self.binary = self.root / 'masc'
        self.binary.write_text('#!/bin/sh\n[ "$1" = doctor ] && [ "$2" = --json ] || exit 87\ncat ' + shlex.quote(str(self.observation)) + '\n')
        self.binary.chmod(0o700)
        self.env = dict(os.environ, HOME=str(self.home), MASC_WIZARD='0')
        for key in ('MASC_BASE_PATH', 'BASH_ENV', 'ENV'):
            self.env.pop(key, None)
        self.code = '. ' + shlex.quote(str(self.library)) + '; DEST=' + shlex.quote(str(self.binary)) + '; resolve_install_base_path; printf "CHOSEN=%s\\n" "$BASE_PATH"\n'

    def run_selection(self, **env):
        return subprocess.run(['/bin/bash', '-c', self.code], cwd=self.cwd, env=dict(self.env, **env), capture_output=True, text=True)

    def test_saved_default_comes_from_native_observation(self):
        saved = self.root / 'saved-workspace'
        self.observation.write_text(json.dumps(dict(schema='masc.onboarding_status.v1', base_path=str(saved))))
        result = self.run_selection()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('CHOSEN=' + str(saved), result.stdout)
        self.assertFalse(saved.exists())

    def test_explicit_environment_bypasses_saved_observation(self):
        self.binary.unlink()
        requested = self.root / 'requested workspace'
        result = self.run_selection(MASC_BASE_PATH=str(requested))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('CHOSEN=' + str(requested), result.stdout)
        self.assertFalse(requested.exists())

    def test_noninteractive_without_saved_workspace_requires_explicit_choice(self):
        result = self.run_selection()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('pass --base-path', result.stderr)
        self.assertFalse((self.home / 'MASC').exists())
        self.assertTrue((self.cwd / '.masc/config').is_dir())

    def test_pipe_installer_offers_home_masc_before_creating_it(self):
        master, slave = pty.openpty()
        def session():
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        process = subprocess.Popen(['/bin/bash'], stdin=subprocess.PIPE, stdout=slave, stderr=slave,
                                   cwd=self.cwd, env=dict(self.env, MASC_WIZARD='1'), preexec_fn=session)
        os.close(slave)
        try:
            process.stdin.write(self.code.encode())
            process.stdin.close()
            output, answered = b'', False
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if select.select([master], [], [], .1)[0]:
                    try:
                        data = os.read(master, 65536)
                    except OSError:
                        break
                    if not data:
                        break
                    output += data
                    if b'? Workspace [1]:' in output and not answered:
                        self.assertFalse((self.home / 'MASC').exists())
                        os.write(master, b'\n')
                        answered = True
                if process.poll() is not None:
                    break
            self.assertEqual(process.wait(timeout=5), 0, output.decode())
            self.assertIn(('CHOSEN=' + str(self.home / 'MASC')).encode(), output)
            self.assertNotIn(('Use ' + str(self.cwd)).encode(), output)
            self.assertFalse((self.home / 'MASC').exists())
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)


if __name__ == '__main__':
    unittest.main()
