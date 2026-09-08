"""Hermetic tests of the installer's native dependency bootstrap (no real brew)."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

INSTALLER = Path(__file__).resolve().parents[1] / 'scripts/install.sh'


class MacDependencies(unittest.TestCase):
    def run_bootstrap(self, *, system='Darwin', arch='arm64', version='14.0',
                      prefix='/opt/homebrew', ready=True, brew=True, dry=False, interactive=False):
        source = INSTALLER.read_text().split('# --- macOS dependency bootstrap ---', 1)[1].split(
            '# --- end macOS dependency bootstrap ---', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            calls = root / 'calls'
            # shell functions shadow external commands; all brew invocations are
            # recorded and never reach the host's package manager.
            script = '''set -eu
log() { printf '%s\\n' "$*"; }
die() { printf '%s\\n' "$*" >&2; exit 1; }
uname() { if [ "${1:-}" = -m ]; then printf '%s\\n' "$FAKE_ARCH"; else printf '%s\\n' "$FAKE_SYSTEM"; fi; }
sw_vers() { printf '%s\\n' "$FAKE_VERSION"; }
'''
            script += '''brew() {
  printf '%s\\n' "$*" >> "$CALLS"
  case "${1:-}" in --prefix) printf '%s\\n' "$FAKE_PREFIX" ;; install) FAKE_READY=1 ;; *) return 0 ;; esac
}
'''
            if not brew:
                # Override command discovery only for brew, delegating every
                # other lookup to Bash's builtin with the real PATH.
                script += '''[() { if builtin [ "${1:-}" = -x ] && [[ "${2:-}" == */bin/brew ]]; then builtin [ "${BOOTSTRAPPED:-0}" = 1 ]; return; fi; builtin [ "$@"; }
command() { if [ "${1:-}" = -v ] && [ "${2:-}" = brew ]; then [ "${BOOTSTRAPPED:-0}" = 1 ]; return; fi; builtin command "$@"; }
'''
            script += source + '''
is_tty() { [ "$FAKE_INTERACTIVE" = 1 ]; }
bootstrap_macos_homebrew() { echo bootstrap >> "$CALLS"; BOOTSTRAPPED=1; }
macos_formula_ready() { [ "$FAKE_READY" = 1 ]; }
ensure_macos_dependencies
'''
            env = dict(os.environ, FAKE_SYSTEM=system, FAKE_ARCH=arch, FAKE_VERSION=version,
                       FAKE_INTERACTIVE=str(int(interactive)), FAKE_PREFIX=prefix, FAKE_READY=str(int(ready)), DRY_RUN=str(int(dry)), CALLS=str(calls))
            result = subprocess.run(['/bin/bash', '-c', script], env=env, capture_output=True, text=True, timeout=10)
            return result, calls.read_text().splitlines() if calls.exists() else []

    def test_missing_formulas_are_installed(self):
        result, calls = self.run_bootstrap(ready=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(c.startswith('install ') for c in calls), calls)

    def test_complete_installation_does_not_mutate(self):
        result, calls = self.run_bootstrap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(c.startswith('install ') for c in calls), calls)

    def test_dry_run_does_not_mutate(self):
        result, calls = self.run_bootstrap(ready=False, dry=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(c.startswith('install ') for c in calls), calls)

    def test_wrong_homebrew_prefix_is_rejected(self):
        result, calls = self.run_bootstrap(prefix='/usr/local', ready=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('/opt/homebrew', result.stdout + result.stderr)
        self.assertFalse(any(c.startswith('install ') for c in calls))

    def test_old_macos_is_rejected_before_install(self):
        result, calls = self.run_bootstrap(version='13.6', ready=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c.startswith('install ') for c in calls))

    def test_linux_does_not_call_brew(self):
        result, calls = self.run_bootstrap(system='Linux', ready=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])

    def test_missing_homebrew_interactive_bootstraps(self):
        result, calls = self.run_bootstrap(brew=False, ready=False, interactive=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.count('bootstrap'), 1)
        self.assertTrue(any(c.startswith('install ') for c in calls))

    def test_missing_homebrew_dry_run_never_bootstraps(self):
        result, calls = self.run_bootstrap(brew=False, ready=False, dry=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])

    def test_missing_homebrew_has_actionable_error(self):
        result, calls = self.run_bootstrap(brew=False, ready=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('brew.sh', result.stdout + result.stderr)
        self.assertEqual(calls, [])


if __name__ == '__main__':
    unittest.main()
