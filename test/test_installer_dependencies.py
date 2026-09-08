"""Hermetic tests of the installer's native dependency bootstrap (no real brew)."""
import os
from pathlib import Path
import subprocess
import sys
import shlex
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



class PythonActivation(unittest.TestCase):
    def exercise(self, unlinked):
        source = INSTALLER.read_text().split('# --- macOS dependency bootstrap ---', 1)[1].split(
            '# --- end macOS dependency bootstrap ---', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prefix = root / 'brew'
            old = root / 'old'
            old.mkdir()
            (prefix / 'bin').mkdir(parents=True)
            formula = prefix / 'opt/python'
            destination = formula / 'libexec/bin' if unlinked else prefix / 'bin'
            destination.mkdir(parents=True, exist_ok=True)
            stale = old / 'python3'
            stale.write_text('#!/bin/sh\nexit 1\n')
            stale.chmod(0o755)
            good = root / 'good-python'
            good.write_text('#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' "$@"\n')
            good.chmod(0o755)
            # Map only the platform installation root into this fixture. The
            # Python readiness body and activation logic remain production code.
            source = source.replace('/opt/homebrew', str(prefix))
            source = source.replace('macos_formula_ready() {', 'actual_formula_ready() {', 1)
            script = source + r"""
log() { :; }
die() { echo "$*" >&2; exit 1; }
is_tty() { return 1; }
uname() { if [ "${1:-}" = -m ]; then echo arm64; else echo Darwin; fi; }
sw_vers() { echo 14.0; }
macos_formula_ready() {
  if [ "$2" = python ]; then actual_formula_ready "$@"; else return 0; fi
}
brew() {
  case "$1" in
    --prefix) if [ "${2:-}" = python ]; then echo "$FORMULA"; else echo "$PREFIX_FIXTURE"; fi ;;
    install)
      [ "$2" = python ] || exit 91
      # The failed readiness probe executed the stale interpreter. Prove the
      # shell cache is populated before installing the new executable.
      [ "$(hash -t python3)" = "$OLD_PYTHON" ] || exit 92
      /bin/cp "$GOOD_PYTHON" "$DESTINATION/python3"
      ;;
    *) exit 93 ;;
  esac
}
ensure_macos_dependencies
actual_formula_ready "$PREFIX_FIXTURE" python
[ "$(command -v python3)" = "$DESTINATION/python3" ]
"""
            env = dict(os.environ, PATH=str(prefix / 'bin') + ':' + str(old) + ':/usr/bin:/bin',
                       DRY_RUN='0', FORMULA=str(formula), PREFIX_FIXTURE=str(prefix),
                       OLD_PYTHON=str(stale), GOOD_PYTHON=str(good), DESTINATION=str(destination))
            result = subprocess.run(['/bin/bash', '-eu', '-c', script], env=env,
                                    text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_readiness_does_not_require_unused_tomllib(self):
        source = INSTALLER.read_text().split('# --- macOS dependency bootstrap ---', 1)[1].split(
            '# --- end macOS dependency bootstrap ---', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            interpreter = Path(directory) / 'python3'
            interpreter.write_text('#!/bin/sh\ncase "$*" in *tomllib*) exit 42 ;; esac\nexec ' +
                                   shlex.quote(sys.executable) + ' "$@"\n')
            interpreter.chmod(0o755)
            result = subprocess.run(['/bin/bash', '-eu', '-c', source +
                                     '\nmacos_formula_ready /unused python\n'],
                env=dict(os.environ, PATH=directory + ':/usr/bin:/bin'),
                capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_newly_linked_python_replaces_cached_old_interpreter(self):
        self.exercise(unlinked=False)

    def test_unlinked_formula_libexec_python_is_selected(self):
        self.exercise(unlinked=True)

if __name__ == '__main__':
    unittest.main()
