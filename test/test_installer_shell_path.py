#!/usr/bin/env python3
"""Exercise installed shell configuration in fresh fixture HOME directories."""
import fcntl
import os
from pathlib import Path
import pty
import select
import shlex
import shutil
import subprocess
import sys
import tempfile
import termios
import time
import unittest

INSTALLER = Path(__file__).resolve().parents[1]/'scripts/install.sh'


class ShellPath(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='masc-shell-path-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root/'home'
        self.home.mkdir(mode=0o700)
        self.prefix = self.home/"bin ' $(touch MASC_SHOULD_NOT_EXIST)"
        self.prefix.mkdir()
        masc = self.prefix/'masc'
        masc.write_text('#!/bin/sh\nprintf "fixture-masc-ready\\n"\n')
        masc.chmod(0o755)
        # Load production definitions only; do not duplicate profile-write logic.
        definitions = INSTALLER.read_text().split('\nwhile [ $# -gt 0 ]; do', 1)[0]
        self.library = self.root/'installer-functions.sh'
        self.library.write_text(definitions)
        self.env = dict(os.environ, HOME=str(self.home), ZDOTDIR=str(self.home),
                        MASC_PREFIX=str(self.prefix), MASC_WIZARD='0',
                        PATH=str(Path(sys.executable).parent)+':/usr/bin:/bin:/usr/sbin:/sbin')
        self.env.pop('BASH_ENV', None)
        self.env.pop('ENV', None)

    def configure(self, mode, **env):
        code = '. '+shlex.quote(str(self.library))+'; SHELL_PATH_MODE='+shlex.quote(mode)+'; configure_shell_path'
        return subprocess.run(['/bin/bash', '-c', code], env=dict(self.env, **env), capture_output=True, text=True, timeout=15)

    def shell(self, executable, *flags):
        return subprocess.run([executable, *flags, 'command -v masc; masc'],
                              env=dict(self.env, PATH='/usr/bin:/bin:/usr/sbin:/sbin'),
                              cwd=self.home, capture_output=True, text=True, timeout=15)

    def test_bash_fresh_interactive_and_login_shell_preserve_existing_profile(self):
        original = b'# user settings\nexport USER_PROFILE_SENTINEL=preserved\n'
        profile = self.home/'.profile'
        profile.write_bytes(original)
        result = self.configure('bash')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Enabled masc PATH', result.stdout)
        self.assertTrue(profile.read_bytes().startswith(original))
        self.assertFalse((self.home/'.bash_profile').exists())
        backups = list(self.home.glob('..profile.masc-path-backup-*'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), original)
        self.assertEqual(backups[0].stat().st_mode & 0o777, 0o600)
        for flags in [('--noprofile', '-ic'), ('-lic',)]:
            ran = self.shell('/bin/bash', *flags)
            self.assertEqual(ran.returncode, 0, ran.stderr)
            self.assertIn('fixture-masc-ready', ran.stdout)
        self.assertFalse((self.home/'MASC_SHOULD_NOT_EXIST').exists())
        first = (self.home/'.bashrc').read_bytes()
        self.configure('bash')
        self.assertEqual((self.home/'.bashrc').read_bytes(), first)
        self.assertEqual(len(list(self.home.glob('..profile.masc-path-backup-*'))), 1)

    def test_zsh_new_terminal_uses_literal_prefix(self):
        zsh = shutil.which('zsh')
        self.assertIsNotNone(zsh, 'zsh is required for the new-terminal acceptance suite')
        self.assertIn('Enabled masc PATH', self.configure('zsh').stdout)
        ran = self.shell(zsh, '-lic')
        self.assertEqual(ran.returncode, 0, ran.stderr)
        self.assertIn('fixture-masc-ready', ran.stdout)
        self.assertFalse((self.home/'MASC_SHOULD_NOT_EXIST').exists())

    def test_no_wizard_and_noninteractive_leave_profiles_unchanged(self):
        self.configure('auto')
        self.configure('auto', MASC_WIZARD='1')
        self.configure('none')
        self.assertEqual(sorted(p.name for p in self.home.iterdir()), [self.prefix.name])

    def test_complete_installer_explicit_flag_prepares_new_bash_terminal(self):
        import test_release_dashboard_bundle as fixtures
        distribution = fixtures.Distribution('test_round_trip_keeps_exact_pair_and_build_time_after_source_removal')
        distribution.setUp()
        self.addCleanup(distribution.doCleanups)
        mirror = distribution.mirror()
        env = dict(self.env, MASC_RELEASE_BASE_URL=mirror.parent.as_uri())
        installed = subprocess.run(['/bin/bash', str(INSTALLER), '--version', 'v9.9.9',
                                    '--prefix', str(distribution.prefix), '--base-path', str(self.home/'workspace'),
                                    '--no-seed', '--no-wizard', '--no-guest-shim', '--shell-path', 'bash'],
                                   env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(installed.returncode, 0, installed.stdout+installed.stderr)
        ran = subprocess.run(['/bin/bash', '-lic', 'masc --version'],
                             env=dict(self.env, PATH='/usr/bin:/bin:/usr/sbin:/sbin'),
                             cwd=self.home, capture_output=True, text=True, timeout=15)
        self.assertEqual(ran.returncode, 0, ran.stderr)
        self.assertEqual(ran.stdout.strip(), '9.9.9')

    def test_link_and_malformed_marker_are_preserved(self):
        target = self.root/'other-settings'
        target.write_text('preserve me\n')
        (self.home/'.zshrc').symlink_to(target)
        self.assertIn('needs attention', self.configure('zsh').stderr)
        self.assertEqual(target.read_text(), 'preserve me\n')
        (self.home/'.zshrc').unlink()
        (self.home/'.zshrc').write_text('# >>> MASC PATH >>>\nunterminated user content\n')
        before = (self.home/'.zshrc').read_bytes()
        self.configure('zsh')
        self.assertEqual((self.home/'.zshrc').read_bytes(), before)

    def test_pipe_installer_can_read_controlling_terminal_without_consuming_script(self):
        master, slave = pty.openpty()
        def session():
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        code = '. '+shlex.quote(str(self.library))+'''; is_tty || exit 12
printf 'READY_FOR_SELECTION\\n' >&2
read_terminal_line answer
printf 'READ=%s\\n' "$answer" >&2
with_terminal_input python3 -c 'import sys; print("CHILD_TTY="+str(sys.stdin.isatty()), file=sys.stderr)'
printf 'SCRIPT_REMAINDER_RAN\\n' >&2
'''
        process = subprocess.Popen(['/bin/bash'], stdin=subprocess.PIPE, stdout=slave, stderr=slave,
                                   env=self.env, preexec_fn=session)
        os.close(slave)
        try:
            process.stdin.write(code.encode())
            process.stdin.close()
            output = b''
            deadline = time.monotonic()+15
            answered = False
            while time.monotonic() < deadline:
                if select.select([master], [], [], .1)[0]:
                    try:
                        data = os.read(master, 65536)
                    except OSError:
                        break
                    if not data:
                        break
                    output += data
                    if b'READY_FOR_SELECTION' in output and not answered:
                        os.write(master, b'zsh\n')
                        answered = True
                if process.poll() is not None:
                    break
            self.assertEqual(process.wait(timeout=5), 0, output.decode())
            self.assertIn(b'READ=zsh', output)
            self.assertIn(b'CHILD_TTY=True', output)
            self.assertIn(b'SCRIPT_REMAINDER_RAN', output)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)


    def test_piped_installer_hands_the_setup_journey_the_terminal(self):
        # The journey asks for a model and a sandbox. Read from a pipe without
        # this, it reads the pipe instead and the wizard reports a cancellation
        # the operator never asked for.
        probe = self.prefix/'masc-journey-probe'
        probe.write_text('#!/bin/sh\n'
                         'if [ -t 0 ]; then printf "JOURNEY_STDIN=terminal\\n" >&2\n'
                         'else printf "JOURNEY_STDIN=pipe\\n" >&2; fi\n')
        probe.chmod(0o755)
        master, slave = pty.openpty()
        def session():
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        code = ('. '+shlex.quote(str(self.library))+'\n'
                'RUN_SETUP_JOURNEY=1\n'
                'DRY_RUN=0\n'
                'DEST='+shlex.quote(str(probe))+'\n'
                'BASE_PATH='+shlex.quote(str(self.home))+'\n'
                'MASC_PORT=8945\n'
                'finish_setup_journey\n'
                "printf 'JOURNEY_RETURNED\\n' >&2\n")
        process = subprocess.Popen(['/bin/bash'], stdin=subprocess.PIPE, stdout=slave, stderr=slave,
                                   env=self.env, preexec_fn=session)
        os.close(slave)
        try:
            process.stdin.write(code.encode())
            process.stdin.close()
            output = b''
            deadline = time.monotonic()+15
            while time.monotonic() < deadline:
                if select.select([master], [], [], .1)[0]:
                    try:
                        data = os.read(master, 65536)
                    except OSError:
                        break
                    if not data:
                        break
                    output += data
                if process.poll() is not None:
                    break
            self.assertEqual(process.wait(timeout=5), 0, output.decode())
            self.assertIn(b'JOURNEY_STDIN=terminal', output)
            self.assertIn(b'JOURNEY_RETURNED', output)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)


if __name__ == '__main__':
    unittest.main()
