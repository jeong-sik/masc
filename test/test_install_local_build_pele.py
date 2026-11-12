#!/usr/bin/env python3
"""A local install refreshes the Pele helper its prefix already holds (#47301)."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import test_install_local_build as local_build

# Stands in for scripts/install-pele.sh, which needs Node.js and pnpm: it
# records its arguments as one line in pele-calls at the checkout root and
# exits with the status the case names.
FAKE_INSTALLER = ('#!/bin/sh\n'
                  'printf "%s\\n" "$*" >> "$(dirname "$0")/../pele-calls"\n'
                  'exit {status}\n')


# A checkout that holds the real install-local-build.sh and the stand-in
# installer, and a build whose helper accepts the workspace.
def checkout(root, installer_status):
    repo = root / "checkout"
    scripts = repo / "scripts"
    (scripts / "lib").mkdir(parents=True)
    shutil.copy2(local_build.SCRIPT, scripts / local_build.SCRIPT.name)
    shutil.copy2(local_build.REPO / "scripts/lib/install-workspace-dashboard.sh", scripts / "lib")
    local_build.executable(scripts / "check-runtime-deployment-preflight.sh", "fixture-preflight")
    installer = scripts / "install-pele.sh"
    installer.write_text(FAKE_INSTALLER.format(status=installer_status))
    installer.chmod(0o755)
    build = root / "build"
    build.mkdir()
    local_build.binaries(build)
    local_build.preflight_helper(build)
    return repo, build


def install(root, repo, build, prefix):
    return subprocess.run(
        ["bash", str(repo / "scripts" / local_build.SCRIPT.name), "--skip-build",
         "--build-dir", str(build), "--prefix", str(prefix),
         "--base-path", str(local_build.workspace(root))],
        env=local_build.unnamed_env(root), capture_output=True, text=True)


def installer_calls(repo):
    calls = repo / "pele-calls"
    return calls.read_text().splitlines() if calls.exists() else []


def prefix_with_pele(root):
    prefix = root / "prefix"
    prefix.mkdir()
    local_build.executable(prefix / "masc-pele", "older-pele")
    return prefix


class PeleRefresh(unittest.TestCase):
    def test_a_prefix_with_pele_gets_the_pele_of_the_checkout(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            repo, build = checkout(root, installer_status=0)
            prefix = prefix_with_pele(root)
            result = install(root, repo, build, prefix)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(installer_calls(repo), [f"--prefix {prefix}"])

    def test_a_prefix_without_pele_is_given_none(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            repo, build = checkout(root, installer_status=0)
            prefix = root / "prefix"
            result = install(root, repo, build, prefix)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(installer_calls(repo), [])
            self.assertFalse((prefix / "masc-pele").exists())

    # The binaries are installed before the Pele step, so its failure is
    # reported and the install still succeeds.
    def test_a_failed_pele_install_is_reported_and_keeps_the_binaries(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            repo, build = checkout(root, installer_status=7)
            prefix = prefix_with_pele(root)
            result = install(root, repo, build, prefix)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(installer_calls(repo), [f"--prefix {prefix}"])
            self.assertEqual((prefix / "masc-tui").read_bytes(), (build / "masc_tui.exe").read_bytes())
            self.assertIn("status 7", result.stderr)


if __name__ == "__main__":
    unittest.main()
