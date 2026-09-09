"""Run the macOS installer bootstrap with poisoned host Python/Brew commands."""
import os
from pathlib import Path
import shlex
import subprocess
import unittest
import test_release_dashboard_bundle as fixtures

INSTALLER = Path(__file__).resolve().parents[1] / 'scripts/install.sh'


class PortableBootstrap(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.Distribution('test_round_trip_keeps_exact_pair_and_build_time_after_source_removal')
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        f = self.fixture
        f.arch, f.asset = 'macos-arm64', 'masc-macos-arm64'
        self.bin = f.root / 'host-bin'
        self.bin.mkdir()
        self.calls = f.root / 'forbidden-calls'
        def command(name, body):
            path = self.bin / name
            path.write_text('#!/bin/sh\n' + body + '\n')
            path.chmod(0o755)
        command('uname', 'case "$1" in -m) echo arm64 ;; *) echo Darwin ;; esac')
        command('sw_vers', 'echo "${TEST_MACOS_VERSION:-14.0}"')
        command('python3', 'exit 98')
        for name in ('brew', 'xcode-select'):
            command(name, 'echo ' + name + ' >> ' + shlex.quote(str(self.calls)) + '; exit 98')
        self.env = dict(os.environ, PATH=str(self.bin) + ':/usr/bin:/bin:/usr/sbin:/sbin', MASC_WIZARD='0')

    def run_installer(self, args, mirror=None, **env):
        values = dict(self.env, **env)
        if mirror is not None:
            values['MASC_RELEASE_BASE_URL'] = mirror.parent.as_uri()
        result = subprocess.run(['/bin/bash', str(INSTALLER), '--prefix', str(self.fixture.prefix),
                                 '--base-path', str(self.fixture.root / 'workspace'), *args],
                                env=values, capture_output=True, text=True, timeout=60)
        self.assertFalse(self.calls.exists(), self.calls.read_text() if self.calls.exists() else '')
        return result

    def test_help_and_dry_run_never_launch_brew_or_xcode(self):
        for args in (['--help'], ['--dry-run', '--version', 'v9.9.9']):
            result = self.run_installer(args)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_dry_run_without_python_reports_force_and_provider_plan(self):
        binary = self.fixture.prefix / 'masc'
        binary.write_bytes(self.fixture.binary.read_bytes())
        binary.chmod(0o755)
        result = self.run_installer(['--dry-run', '--version', 'v9.9.9', '--force', '--provider', 'codex'], MASC_WIZARD='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('refreshing because --force is set', result.stdout + result.stderr)
        self.assertIn('requested provider: codex; catalog validation', result.stdout)
        self.assertIn('[dry-run] would download to', result.stdout)

    def test_dry_run_uses_available_non_system_python_for_full_planning(self):
        import sys
        marker = self.fixture.root / "python-used"
        interpreter = self.bin / "python3"
        interpreter.write_text("#!/bin/sh\necho used >> " + shlex.quote(str(marker)) +
                               "\nexec " + shlex.quote(sys.executable) + ' "$@"\n')
        result = self.run_installer(['--dry-run', '--version', 'v9.9.9', '--no-wizard', '--no-guest-shim'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(len(marker.read_text().splitlines()), 1)
        self.assertIn('[dry-run] would install verified binary/dashboard bundle', result.stdout)

    def test_dry_run_preserves_version_conflict(self):
        self.fixture.old()
        result = self.run_installer(['--dry-run', '--version', 'v9.9.9', '--no-wizard'])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('pass --force', result.stderr)

    def test_old_macos_fails_before_download(self):
        result = self.run_installer(['--version', 'v9.9.9'], TEST_MACOS_VERSION='13.6')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('minimum macOS 14.0', result.stderr)

    def test_offline_uninstall_needs_no_interpreter(self):
        self.fixture.old()
        result = self.run_installer(['--uninstall'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.fixture.prefix / 'masc').exists())

    def test_explicit_version_bootstraps_without_host_python(self):
        mirror = self.fixture.mirror()
        result = self.run_installer(['--version', 'v9.9.9', '--no-seed', '--no-guest-shim', '--no-wizard'], mirror)
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = (self.fixture.prefix / 'masc').resolve().parent
        fixtures.bundle.verify_tree(installed, self.fixture.asset)
        self.assertTrue((installed / 'python/bin/python3').is_file())

    def test_latest_resolution_precedes_python_bootstrap(self):
        mirror = self.fixture.mirror()
        # Stub only the public latest metadata response; every asset download,
        # checksum, extraction and interpreter execution remains real.
        curl = self.bin / 'curl'
        curl.write_text('#!/bin/sh\ncase "$*" in *api.github.com*/releases/latest*) '
                        'echo \'{"tag_name":"v9.9.9"}\' ;; *) exec /usr/bin/curl "$@" ;; esac\n')
        curl.chmod(0o755)
        result = self.run_installer(['--no-seed', '--no-guest-shim', '--no-wizard'], mirror)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unverified_override_cannot_execute_tampered_python(self):
        mirror = self.fixture.mirror()
        runtime = mirror / 'masc-runtime-macos-arm64.tar.gz'
        runtime.write_bytes(runtime.read_bytes() + b'tampered')
        result = self.run_installer(['--version', 'v9.9.9', '--allow-unverified', '--no-guest-shim'], mirror)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('bundled Python checksum differs', result.stderr)
        self.assertFalse((self.fixture.prefix / 'masc').exists())


if __name__ == '__main__':
    unittest.main()
