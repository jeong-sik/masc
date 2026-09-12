"""scripts/check-glibc-floor.sh, exercised against a stub objdump.

The check decides whether a release binary may ship, so the cases that matter
are the ones where it could wrongly say yes: a version comparison that reads
2.10 as older than 2.9, a missing objdump treated as "nothing found", a
binary that is not there at all. Each of those would report a clean floor for
a binary that breaks on the distros the floor exists to cover.

Real ELF binaries are not needed to test any of that — the script's whole
input is objdump's text — so a stub objdump on PATH supplies it, and these
tests run anywhere in milliseconds.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'check-glibc-floor.sh'
# Resolved before any test narrows PATH: the missing-objdump case leaves a PATH
# with no interpreter on it, and `bash` has to stay findable regardless.
BASH = shutil.which('bash') or '/bin/bash'

# Copied from real `objdump -T` output (binutils 2.42, Ubuntu 24.04) rather
# than invented: an imported symbol's version comes in parentheses, and an
# earlier version of this fixture that left them out let the script ship
# unable to name the offending symbols while still reporting the right verdict.
SYMBOL_LINE = ('0000000000000000      DF *UND*\t0000000000000000 '
               '({version}) {symbol}')
# A symbol defined by the binary is written without the parentheses.
DEFINED_LINE = ('0000000000000000  w   DF .text\t0000000000000000  '
                '{version} {symbol}')


def objdump_output(*symbols: tuple[str, str], template: str = SYMBOL_LINE) -> str:
    header = 'DYNAMIC SYMBOL TABLE:'
    lines = [template.format(version=version, symbol=symbol)
             for version, symbol in symbols]
    return '\n'.join([header, *lines]) + '\n'


class GlibcFloorCheckTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.binary = self.root / 'masc'
        self.binary.write_bytes(b'\x7fELF not really')

    def stub_objdump(self, output: str, *, present: bool = True,
                     exit_code: int = 0, stderr: str = '') -> dict[str, str]:
        """A PATH holding only our objdump, so the real one cannot answer."""
        bin_dir = self.root / 'stub-bin'
        bin_dir.mkdir(exist_ok=True)
        if present:
            stub = bin_dir / 'objdump'
            script = ['#!/bin/sh', 'cat <<"OUT"', output + 'OUT']
            if stderr:
                script.append('cat >&2 <<"ERR"\n' + stderr + 'ERR')
            script.append(f'exit {exit_code}')
            stub.write_text('\n'.join(script) + '\n')
            stub.chmod(0o755)
        env = dict(os.environ)
        # Keep a real PATH for the shell's own utilities (grep, sort, awk) but
        # put the stub first; for the missing-objdump case the stub is absent
        # and PATH is narrowed to a directory that has none.
        env['PATH'] = f'{bin_dir}:/usr/bin:/bin' if present else str(bin_dir)
        return env

    def run_check(self, floor: str, *args: str, env: dict[str, str] | None = None):
        return subprocess.run(
            [BASH, str(SCRIPT), floor, *(args or (str(self.binary),))],
            capture_output=True, text=True, env=env,
        )

    def test_a_binary_below_the_floor_passes(self):
        env = self.stub_objdump(objdump_output(
            ('GLIBC_2.14', 'memcpy'), ('GLIBC_2.34', '__libc_start_main')))
        result = self.run_check('2.35', env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('needs at most GLIBC_2.34', result.stdout)

    def test_a_binary_exactly_at_the_floor_passes(self):
        env = self.stub_objdump(objdump_output(('GLIBC_2.35', 'arc4random')))
        result = self.run_check('2.35', env=env)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_binary_above_the_floor_fails_and_names_the_symbols(self):
        # The v0.35.x regression itself: two symbols, neither one asked for.
        env = self.stub_objdump(objdump_output(
            ('GLIBC_2.34', '__libc_start_main'),
            ('GLIBC_2.38', 'fmod'),
            ('GLIBC_2.38', '__isoc23_strtol')))
        result = self.run_check('2.35', env=env)
        self.assertEqual(result.returncode, 1)
        self.assertIn('needs GLIBC_2.38', result.stderr)
        self.assertIn('fmod', result.stderr)
        self.assertIn('__isoc23_strtol', result.stderr)
        # The symbol that is fine must not be listed as a cause.
        self.assertNotIn('__libc_start_main', result.stderr)

    def test_a_two_digit_minor_is_newer_than_a_one_digit_minor(self):
        # A lexical comparison puts GLIBC_2.10 below GLIBC_2.9 and passes this
        # binary. Every floor past 2.9 depends on getting this right.
        env = self.stub_objdump(objdump_output(('GLIBC_2.10', 'fallocate')))
        result = self.run_check('2.9', env=env)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('needs GLIBC_2.10', result.stderr)

    def test_a_static_binary_has_no_floor_to_exceed(self):
        # The exec shim is static musl: objdump reports no dynamic glibc
        # references, which is a pass and not an unmeasured result.
        env = self.stub_objdump('DYNAMIC SYMBOL TABLE:\n')
        result = self.run_check('2.35', env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('no dynamic glibc references', result.stdout)

    def test_every_named_binary_is_checked_not_just_the_first(self):
        second = self.root / 'masc-tui'
        second.write_bytes(b'\x7fELF not really')
        env = self.stub_objdump(objdump_output(('GLIBC_2.38', 'fmod')))
        result = self.run_check('2.35', str(self.binary), str(second), env=env)
        self.assertEqual(result.returncode, 1)
        self.assertIn('masc-tui', result.stderr)

    def test_a_version_written_without_parentheses_is_read_too(self):
        env = self.stub_objdump(objdump_output(
            ('GLIBC_2.38', 'fmod'), template=DEFINED_LINE))
        result = self.run_check('2.35', env=env)
        self.assertEqual(result.returncode, 1)
        self.assertIn('needs GLIBC_2.38', result.stderr)
        self.assertIn('fmod', result.stderr)

    def test_a_missing_objdump_refuses_rather_than_reporting_a_clean_floor(self):
        env = self.stub_objdump('', present=False)
        result = self.run_check('2.35', env=env)
        self.assertEqual(result.returncode, 2)
        self.assertIn('objdump not found', result.stderr)

    def test_a_missing_binary_is_a_failure_not_a_pass(self):
        env = self.stub_objdump(objdump_output(('GLIBC_2.34', 'memcpy')))
        result = self.run_check('2.35', str(self.root / 'absent'), env=env)
        self.assertEqual(result.returncode, 1)
        self.assertIn('no such file', result.stderr)

    def test_a_file_objdump_cannot_read_is_a_failure_not_a_static_pass(self):
        # objdump exits 1 on a truncated, foreign-architecture or non-ELF file
        # (measured: binutils/llvm objdump -T on a text file). Discarding that
        # status left an empty symbol list, which this script reads as "static,
        # nothing to exceed" -- so a wrong file would have passed the gate that
        # exists to keep wrong files out of a release.
        env = self.stub_objdump(
            '', exit_code=1,
            stderr="objdump: 'masc': file format not recognized\n")
        result = self.run_check('2.35', env=env)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('objdump could not read', result.stderr)
        self.assertIn('file format not recognized', result.stderr)
        self.assertNotIn('no dynamic glibc references', result.stdout)

    def test_one_unreadable_binary_does_not_stop_the_others(self):
        second = self.root / 'masc-tui'
        second.write_bytes(b'\x7fELF not really')
        env = self.stub_objdump('', exit_code=1, stderr='broken\n')
        result = self.run_check('2.35', str(self.binary), str(second), env=env)
        self.assertEqual(result.returncode, 1)
        self.assertIn(str(self.binary), result.stderr)
        self.assertIn(str(second), result.stderr)

    def test_a_third_version_component_above_the_floor_is_named(self):
        # The verdict compares with sort -V, which reads all three components.
        # A second comparison written in awk read only two and called
        # GLIBC_2.38.1 equal to the floor, so the failure named no symbol at
        # all -- a FAIL nobody could act on.
        env = self.stub_objdump(objdump_output(('GLIBC_2.38.1', 'fmod')))
        result = self.run_check('2.38', env=env)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('needs GLIBC_2.38.1', result.stderr)
        self.assertIn('fmod', result.stderr)

    def test_a_malformed_floor_is_refused_before_anything_is_compared(self):
        # sort -V places GLIBC_2..35 after GLIBC_2.38 (measured, GNU coreutils
        # 9.x), so a floor with a doubled dot would have passed every binary.
        # build-linux-release.sh --floor reaches the check unchanged.
        env = self.stub_objdump(objdump_output(('GLIBC_2.38', 'fmod')))
        result = self.run_check('2..35', env=env)
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn('floor must look like', result.stderr)

    def test_a_floor_with_no_minor_version_is_refused(self):
        env = self.stub_objdump(objdump_output(('GLIBC_2.38', 'fmod')))
        result = self.run_check('2', env=env)
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn('floor must look like', result.stderr)

    def test_a_floor_that_is_not_a_version_is_refused(self):
        env = self.stub_objdump(objdump_output(('GLIBC_2.34', 'memcpy')))
        result = self.run_check('latest', env=env)
        self.assertEqual(result.returncode, 2)
        self.assertIn('floor must look like', result.stderr)

    def test_no_arguments_is_refused(self):
        result = subprocess.run([BASH, str(SCRIPT)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('usage:', result.stderr)


if __name__ == '__main__':
    unittest.main()
