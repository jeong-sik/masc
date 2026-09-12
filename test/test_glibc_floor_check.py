"""scripts/check-glibc-floor.sh, exercised against a stub objdump.

The check decides whether a release binary may ship, so the cases that matter
are the ones where it could wrongly say yes: a version comparison that reads
2.10 as older than 2.9, a missing objdump treated as "nothing found", a
binary that is not there at all. Each of those would report a clean floor for
a binary that breaks on the distros the floor exists to cover.

Stub output covers version comparisons on any host. Linux also links tiny
real ELF fixtures so inspection failures and ABI requirements are measured
with the binutils used by the release jobs.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
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

    def test_a_recognized_non_elf_format_is_not_a_static_pass(self):
        self.binary.write_bytes(b'MZ\x00\x00PE fixture')
        env = self.stub_objdump('masc: file format pei-x86-64\n')
        inspection = subprocess.run(['objdump', '-p', str(self.binary)],
                                    env=env, capture_output=True, text=True)
        self.assertEqual(inspection.returncode, 0)
        result = self.run_check('2.35', env=env)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('not an ELF file', result.stderr)
        self.assertNotIn('no dynamic glibc references', result.stdout)

    def test_a_named_abi_requirement_is_not_ignored(self):
        env = self.stub_objdump('Version References:\n  GLIBC_ABI_DT_RELR\n')
        result = self.run_check('2.35', env=env)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('GLIBC_ABI_DT_RELR needs GLIBC_2.36', result.stderr)
        result = self.run_check('2.36', env=env)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_an_unknown_glibc_requirement_is_refused(self):
        env = self.stub_objdump('Version References:\n  GLIBC_FUTURE_ABI\n')
        result = self.run_check('2.35', env=env)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('unknown glibc requirement GLIBC_FUTURE_ABI', result.stderr)

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


@unittest.skipUnless(sys.platform.startswith('linux'), 'real ELF fixtures require Linux')
class GlibcFloorRealElfTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.compiler = shutil.which(os.environ.get('CC', 'cc'))
        self.assertIsNotNone(self.compiler, 'Linux checker tests require a C compiler')
        source = self.root / 'fixture.c'
        source.write_text('static int value; int *pointer = &value;\n'
                          'int main(void) { return *pointer; }\n')
        self.source = source

    def link(self, name: str, *flags: str) -> Path:
        binary = self.root / name
        subprocess.run([str(self.compiler), str(self.source), '-o', str(binary), *flags],
                       check=True, capture_output=True, text=True)
        return binary

    def check_binary(self, floor: str, binary: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run([BASH, str(SCRIPT), floor, str(binary)],
                              capture_output=True, text=True)

    def test_real_static_elf_passes_without_a_dynamic_symbol_table(self) -> None:
        binary = self.link('static', '-static')
        dynamic = subprocess.run(['objdump', '-T', str(binary)],
                                 capture_output=True, text=True)
        self.assertNotEqual(dynamic.returncode, 0, 'fixture exercises objdump -T refusal')
        result = self.check_binary('2.35', binary)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('no dynamic glibc references', result.stdout)

    def test_real_relr_requirement_obeys_its_glibc_236_floor(self) -> None:
        target = subprocess.run([str(self.compiler), '-dumpmachine'],
                                check=True, capture_output=True, text=True).stdout.strip()
        architecture = target.split('-', 1)[0]
        # GNU ld 2.42 ignores pack-relative-relocs on AArch64. The PR lint
        # job uses ubuntu-latest x86_64, where this fixture must never skip.
        if os.uname().machine == 'x86_64':
            self.assertEqual(architecture, 'x86_64', 'CI requires its native RELR fixture')
        if architecture != 'x86_64':
            self.skipTest(f'DT_RELR fixture requires x86_64 GNU ld; compiler targets {target}')
        binary = self.link('relr', '-fPIE', '-pie', '-Wl,-z,pack-relative-relocs')
        versions = subprocess.run(['objdump', '-p', str(binary)],
                                  check=True, capture_output=True, text=True)
        self.assertIn('GLIBC_ABI_DT_RELR', versions.stdout)
        result = self.check_binary('2.35', binary)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('GLIBC_ABI_DT_RELR', result.stderr)
        result = self.check_binary('2.36', binary)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_real_non_elf_file_is_refused(self) -> None:
        result = self.check_binary('2.35', self.source)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('not an ELF file', result.stderr)


if __name__ == '__main__':
    unittest.main()
