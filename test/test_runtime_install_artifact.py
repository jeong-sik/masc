#!/usr/bin/env python3
"""Exercise the downloaded payload with the canonical installer, using fake binaries."""
import argparse
import importlib.util
import io
import json
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
        self.args = argparse.Namespace(repo=self.repo, trusted_repo=self.repo,
                                       records=records, directory=self.root / "bundle",
                                       source=source, workflow_head="a" * 40, run_id="17", attempt="2")

    def test_archive_preserves_inputs_and_installs_without_a_checkout_or_build(self):
        result = artifact.pack(self.args)
        self.assertFalse(result["candidate_binaries_executed"])
        self.assertFalse(result["downloaded_code_executed"])
        self.assertTrue(result["trusted_candidate_installer_queried"])
        archive = self.root / "runtime.tar.gz"
        with tarfile.open(archive, "w:gz") as output:
            output.add(self.args.directory, arcname=".")
        extracted = self.root / "download"
        self.args.directory = extracted
        self.args.archive = archive
        self.assertTrue(artifact.extract(self.args)["archive_safely_extracted"])
        prefix = self.root / "installed"
        env = installer.unnamed_env(self.root)
        env["MASC_DUNE_LOCK_HELD"] = "1"
        installed = subprocess.run(["bash", str(extracted / artifact.SOURCES[0]),
                                   "--skip-build", "--build-dir", str(extracted / "bin"),
                                   "--prefix", str(prefix), "--manifest-dir", str(self.root / "manifests"),
                                   "--base-path", str(self.root / "new-workspace"), "--no-guest-shim"],
                                  env=env, capture_output=True, text=True)
        self.assertEqual(installed.returncode, 0, installed.stdout + installed.stderr)
        inputs = [extracted / name for name in artifact.targets(self.repo)]
        inputs.append(extracted / "scripts/check-runtime-deployment-preflight.sh")
        programs = list(prefix.iterdir())
        self.assertEqual(sorted(path.read_bytes() for path in programs),
                         sorted(path.read_bytes() for path in inputs))
        self.assertTrue(all(os.access(path, os.X_OK) for path in programs))

    def test_changed_downloads_and_wrong_run_identity_are_rejected(self):
        artifact.pack(self.args)
        binary = self.args.directory / artifact.targets(self.repo)[0]
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

    def test_self_consistent_forged_source_never_executes_the_downloaded_installer(self):
        artifact.pack(self.args)
        receipt_path = self.args.directory / "build-receipt.json"
        receipt = json.loads(receipt_path.read_text())
        marker = self.root / "downloaded-installer-ran"
        bundled = self.args.directory / artifact.SOURCES[0]
        target_list = "\n".join(artifact.targets(self.repo))
        bundled.write_text(f"#!/bin/sh\ntouch '{marker}'\ncat <<'TARGETS'\n{target_list}\nTARGETS\n")
        receipt["files"][artifact.SOURCES[0]] = artifact.describe(bundled)
        receipt["source_tree"] = "f" * 40
        receipt_path.write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError, "source tree"):
            artifact.verify(self.args)
        self.assertFalse(marker.exists())
        receipt["source_tree"] = subprocess.check_output(
            ["git", "-C", str(self.repo), "rev-parse", "HEAD^{tree}"], text=True).strip()
        receipt_path.write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError, "bundled source"):
            artifact.verify(self.args)
        self.assertFalse(marker.exists())

    def test_every_bundled_source_and_git_mode_are_bound_before_any_query(self):
        marker = self.root / "trusted-installer-query-ran"
        trusted_installer = self.repo / artifact.SOURCES[0]
        trusted_installer.write_text(trusted_installer.read_text().replace(
            "set -euo pipefail", f"set -euo pipefail\ntouch '{marker}'", 1))
        subprocess.run(["git", "-C", str(self.repo), "add", artifact.SOURCES[0]], check=True)
        subprocess.run(["git", "-C", str(self.repo), "-c", "core.hooksPath=/dev/null",
                        "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                        "commit", "-qm", "fixture query observation"], check=True)
        self.args.source = subprocess.check_output(
            ["git", "-C", str(self.repo), "rev-parse", "HEAD"], text=True).strip()
        artifact.pack(self.args)
        marker.unlink()
        receipt_path = self.args.directory / "build-receipt.json"
        original_receipt = receipt_path.read_text()
        for name in artifact.SOURCES:
            path = self.args.directory / name
            data, mode = path.read_bytes(), path.stat().st_mode & 0o777
            for mutation in ("bytes", "mode"):
                with self.subTest(name=name, mutation=mutation):
                    receipt = json.loads(original_receipt)
                    if mutation == "bytes":
                        path.write_bytes(data + b"\n# forged candidate source\n")
                    else:
                        path.chmod(mode ^ 0o100)
                    receipt["files"][name] = artifact.describe(path)
                    receipt_path.write_text(json.dumps(receipt))
                    with self.assertRaisesRegex(ValueError, "bundled source"):
                        artifact.verify(self.args)
                    self.assertFalse(marker.exists(), "query ran before all bundled source was bound")
                    path.write_bytes(data)
                    path.chmod(mode)
        receipt_path.write_text(original_receipt)
        artifact.verify(self.args)
        self.assertTrue(marker.exists(), "valid source should permit the trusted query")

    def test_modified_or_wrong_trusted_checkout_never_runs_its_installer_query(self):
        artifact.pack(self.args)
        marker = self.root / "modified-trusted-installer-ran"
        path = self.repo / artifact.SOURCES[0]
        data = path.read_bytes()
        path.write_text(f"#!/bin/sh\ntouch '{marker}'\n")
        with self.assertRaisesRegex(ValueError, "trusted checkout source"):
            artifact.verify(self.args)
        self.assertFalse(marker.exists())
        path.write_bytes(data)
        self.args.source = "b" * 40
        with self.assertRaisesRegex(ValueError, "checkout HEAD"):
            artifact.verify(self.args)
        self.assertFalse(marker.exists())

    def test_archive_rejects_unsafe_members_before_writing_any_file(self):
        for kind in ("traversal", "absolute", "symlink", "hardlink", "fifo", "duplicate", "file-parent"):
            with self.subTest(kind=kind):
                archive = self.root / (kind + ".tar.gz")
                self.args.archive = archive
                self.args.directory = self.root / (kind + "-output")
                with tarfile.open(archive, "w:gz") as output:
                    good = tarfile.TarInfo("first-regular-file")
                    good.size = 1
                    output.addfile(good, io.BytesIO(b"x"))
                    name = {"traversal": "../escape", "absolute": "/escape",
                            "duplicate": "first-regular-file"}.get(kind, "unsafe")
                    invalid = tarfile.TarInfo(name)
                    if kind == "symlink":
                        invalid.type, invalid.linkname = tarfile.SYMTYPE, "../outside"
                    elif kind == "hardlink":
                        invalid.type, invalid.linkname = tarfile.LNKTYPE, "first-regular-file"
                    elif kind == "fifo":
                        invalid.type = tarfile.FIFOTYPE
                    output.addfile(invalid)
                    if kind == "file-parent":
                        output.addfile(tarfile.TarInfo("unsafe/child"))
                with self.assertRaises(ValueError):
                    artifact.extract(self.args)
                self.assertFalse(self.args.directory.exists())

    def test_archive_refuses_an_existing_destination_without_overwrite(self):
        artifact.pack(self.args)
        self.args.archive = self.root / "not-opened.tar.gz"
        marker = self.args.directory / "keep"
        marker.write_text("existing output")
        with self.assertRaisesRegex(ValueError, "overwrite"):
            artifact.extract(self.args)
        self.assertEqual(marker.read_text(), "existing output")

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
