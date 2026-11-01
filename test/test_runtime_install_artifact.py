#!/usr/bin/env python3
"""Exercise the downloaded payload with the canonical installer, using fake binaries."""
import argparse
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

import test_install_local_build as installer


REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("runtime_artifact", REPO / "scripts/ci/runtime-install-artifact.py")
artifact = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifact)


class RuntimeInstallArtifact(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "source"
        self.repo.mkdir()
        for name in artifact.SOURCES:
            destination = self.repo / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / name, destination)
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        subprocess.run(["git", "-C", str(self.repo), "add", "scripts"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "-c", "core.hooksPath=/dev/null", "-c", "user.name=Fixture",
                        "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"], check=True)
        source = subprocess.check_output(["git", "-C", str(self.repo), "rev-parse", "HEAD"], text=True).strip()
        build = self.repo / "_build/default/bin"
        build.mkdir(parents=True)
        installer.binaries(build)
        installer.fake_masc(build / "main_eio.exe")
        installer.preflight_helper(build)
        records = self.root / "records"
        records.mkdir()
        (records / "build-targets.txt").write_text("\n".join(artifact.targets(self.repo)) + "\n")
        (records / "dependencies.txt").write_text("synthetic executables; no native build or runtime proof\n")
        self.args = argparse.Namespace(repo=self.repo, records=records, directory=self.root / "bundle",
                                       source=source, workflow_head="a" * 40, run_id="17", attempt="2")

    def test_archive_preserves_inputs_and_installs_without_a_checkout_or_build(self):
        result = artifact.pack(self.args)
        self.assertFalse(result["candidate_executed"])
        archive = self.root / "runtime.tar.gz"
        with tarfile.open(archive, "w:gz") as output:
            output.add(self.args.directory, arcname=".")
        extracted = self.root / "download"
        extracted.mkdir()
        with tarfile.open(archive) as source:
            source.extractall(extracted, filter="data")
        self.args.directory = extracted
        artifact.verify(self.args)
        prefix = self.root / "installed"
        env = installer.unnamed_env(self.root)
        env["MASC_DUNE_LOCK_HELD"] = "1"
        installed = subprocess.run(["bash", str(extracted / artifact.SOURCES[0]),
                                   "--skip-build", "--build-dir", str(extracted / "bin"),
                                   "--prefix", str(prefix), "--manifest-dir", str(self.root / "manifests"),
                                   "--base-path", str(self.root / "new-workspace"), "--no-guest-shim"],
                                  env=env, capture_output=True, text=True)
        self.assertEqual(installed.returncode, 0, installed.stdout + installed.stderr)
        inputs = [extracted / name for name in artifact.targets(extracted)]
        inputs.append(extracted / "scripts/check-runtime-deployment-preflight.sh")
        programs = list(prefix.iterdir())
        self.assertEqual(sorted(path.read_bytes() for path in programs),
                         sorted(path.read_bytes() for path in inputs))
        self.assertTrue(all(os.access(path, os.X_OK) for path in programs))

    def test_changed_downloads_and_wrong_run_identity_are_rejected(self):
        artifact.pack(self.args)
        binary = self.args.directory / artifact.targets(self.args.directory)[0]
        original = binary.read_bytes()
        binary.write_bytes(original + b"changed")
        with self.assertRaisesRegex(ValueError, "changed"):
            artifact.verify(self.args)
        binary.write_bytes(original)
        binary.chmod(0o644)
        with self.assertRaisesRegex(ValueError, "mode changed"):
            artifact.verify(self.args)
        binary.chmod(0o755)
        extra = self.args.directory / "undeclared"
        extra.write_text("undeclared")
        with self.assertRaisesRegex(ValueError, "membership"):
            artifact.verify(self.args)
        extra.unlink()
        binary.unlink()
        with self.assertRaisesRegex(ValueError, "membership"):
            artifact.verify(self.args)
        binary.write_bytes(original)
        binary.chmod(0o755)
        self.args.attempt = "3"
        with self.assertRaisesRegex(ValueError, "run/attempt"):
            artifact.verify(self.args)

    def test_pack_refuses_a_partial_build_before_creating_a_bundle(self):
        (self.args.records / "build-targets.txt").write_text("bin/main_eio.exe\n")
        with self.assertRaisesRegex(ValueError, "installer contract"):
            artifact.pack(self.args)
        self.assertFalse(self.args.directory.exists())

    def test_installer_target_query_cannot_take_a_transaction_lock(self):
        env = dict(os.environ, MASC_DUNE_LOCK_HELD="0", DUNE_LOCAL_LOCK=str(self.root / "absent/lock"))
        result = subprocess.run(["bash", str(self.repo / artifact.SOURCES[0]), "--print-build-targets"],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([name.removeprefix("./") for name in result.stdout.splitlines()],
                         artifact.targets(self.repo))


if __name__ == "__main__":
    unittest.main()
