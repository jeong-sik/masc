"""driver/deps.sh names why the masc binary would not start.

Three unrelated causes reach the same place in bench_install_deps, and each
needs a different fix from whoever reads the failure:

- the binary is for another architecture   → re-fetch with MASC_LINUX_ARCH
- the container's glibc is older than the binary's floor → a different build
- a shared library really is missing       → install a package

Before this, all three printed "missing shared libraries". On 2026-09-12 that
sent a reader after apt packages while the actual cause was an aarch64 binary
inside an amd64 Terminal-Bench container, and again while the actual cause was
GLIBC_2.38 on a debian 12 image.

Every message below was captured from a real run in this repository, not
invented: a fixture that only resembles loader output would pass while the
classifier failed on the real thing.
"""
from __future__ import annotations

import shutil
import subprocess
import unittest
from pathlib import Path

DEPS = (Path(__file__).resolve().parents[1]
        / 'benchmarks' / 'terminal_bench' / 'driver' / 'deps.sh')
BASH = shutil.which('bash') or '/bin/bash'

# An arm64 masc under an amd64 container: the loader for that architecture is
# not there, so the kernel refuses the exec.
ARCH_MESSAGE = (
    '/opt/masc-bench/driver/deps.sh: line 89: /opt/masc-bench/bin/masc: '
    'cannot execute: required file not found'
)
# The released x86_64 binary on debian 12 (glibc 2.36).
GLIBC_MESSAGE = (
    "/masc: /lib/x86_64-linux-gnu/libm.so.6: version `GLIBC_2.38' not found "
    "(required by /masc)"
)
# The same binary on debian:12-slim, which ships no OpenSSL runtime.
LIBRARY_MESSAGE = (
    '/masc: error while loading shared libraries: libssl.so.3: '
    'cannot open shared object file: No such file or directory'
)


class DepsDiagnosisTest(unittest.TestCase):
    def reason(self, message: str) -> str:
        result = subprocess.run(
            [BASH, '-c',
             f'. "{DEPS}"; bench_masc_failure_reason "$1"', '_', message],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_an_exec_refusal_is_named_an_architecture_mismatch(self):
        self.assertEqual(self.reason(ARCH_MESSAGE), 'arch')

    def test_an_exec_format_error_is_also_an_architecture_mismatch(self):
        # Some shells phrase the same refusal this way.
        self.assertEqual(
            self.reason('/masc: Exec format error'), 'arch')

    def test_a_symbol_version_miss_is_named_a_glibc_floor(self):
        self.assertEqual(self.reason(GLIBC_MESSAGE), 'glibc')

    def test_a_genuinely_absent_library_stays_a_library_problem(self):
        self.assertEqual(self.reason(LIBRARY_MESSAGE), 'libraries')

    def test_not_found_without_a_glibc_symbol_is_not_a_floor_problem(self):
        # ldd spells an absent library "=> not found". Only a versioned symbol
        # miss means the floor is too high, and only that is fixed by a
        # different build rather than by installing a package.
        self.assertEqual(self.reason('/masc: libz.so.1 => not found'),
                         'libraries')

    def test_an_unrecognised_message_does_not_claim_a_cause(self):
        # Anything unfamiliar has to fall to the library branch, which prints
        # ldd's own output rather than asserting a diagnosis.
        self.assertEqual(self.reason('killed by signal 9'), 'libraries')

    def test_a_glibc_message_is_not_mistaken_for_a_missing_library(self):
        # Both mention a .so file; only one is fixed by installing a package.
        self.assertNotEqual(self.reason(GLIBC_MESSAGE),
                            self.reason(LIBRARY_MESSAGE))

    def test_sourcing_deps_runs_nothing(self):
        # bench_install_deps installs packages and can exit; sourcing the file
        # must only define functions, or this test would need a container.
        result = subprocess.run(
            [BASH, '-c', f'. "{DEPS}"; echo sourced'],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'sourced')


if __name__ == '__main__':
    unittest.main()
