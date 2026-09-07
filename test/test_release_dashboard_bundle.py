#!/usr/bin/env python3
"""Hermetic distribution tests: fake executable, actual tar/filesystem/installer.
No OCaml or dashboard build, runtime daemon, provider call, or deployment.
"""
import hashlib
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
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts/release-dashboard-bundle.py"
spec = importlib.util.spec_from_file_location("bundle", HELPER)
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)
COMMIT = "a" * 40


class Distribution(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="masc install spaces '")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.prefix = self.root / "prefix"
        self.prefix.mkdir()
        self.binary = self.root / "new-binary"
        self.binary.write_text(f"#!/bin/sh\ncase \"$1\" in build-commit) echo {COMMIT} ;; --version) echo 9.9.9 ;; *) exit 0 ;; esac\n")
        self.binary.chmod(0o755)
        self.assets = self.root / "dashboard"
        self.assets.mkdir()
        (self.assets / "index.html").write_text('<script type="module" src="/dashboard/assets/main.js"></script>')
        (self.assets / "assets").mkdir()
        (self.assets / "assets/main.js").write_text("window.fixture = true;")
        (self.assets / ".build-stamp").write_text("2026-09-07T00:00:00Z\n")
        os.utime(self.assets / ".build-stamp", (1788739200, 1788739200))
        system = os.uname()
        self.arch = {("Darwin", "arm64"): "macos-arm64", ("Linux", "x86_64"): "linux-x64", ("Linux", "aarch64"): "linux-arm64"}[(system.sysname, system.machine)]
        self.asset = "masc-" + self.arch
        self.archive = self.root / "bundle.tar.gz"
        bundle.package(self.binary, self.assets, COMMIT, self.asset, self.archive)

    def old(self):
        target = self.prefix / "masc"
        target.write_text("#!/bin/sh\necho old-binary\n")
        target.chmod(0o755)
        return target.read_bytes()

    def install(self):
        with patch("builtins.print"):
            bundle.install(self.binary, self.archive, self.prefix, self.asset)

    def mutate_archive(self, change):
        with tarfile.open(self.archive) as source:
            entries = [(m, source.extractfile(m).read()) for m in source.getmembers()]
        with tarfile.open(self.archive, "w:gz") as output:
            for info, data in change(entries):
                output.addfile(info, io.BytesIO(data) if info.isfile() else None)

    def test_round_trip_keeps_exact_pair_and_build_time_after_source_removal(self):
        self.old()
        self.install()
        binary = (self.prefix / "masc").resolve()
        bundle.commit(self.prefix)
        shutil.rmtree(self.assets)
        self.binary.unlink()
        receipt = bundle.verify_tree(binary.parent, self.asset)
        self.assertEqual(receipt["source_commit"], COMMIT)
        self.assertEqual(bundle.binary_commit(binary), COMMIT)
        self.assertEqual((binary.parent / "assets/dashboard/.build-stamp").stat().st_mtime, 1788739200)
        self.assertFalse((self.prefix / bundle.TRANSACTION).exists())

    def test_rollback_restores_previous_regular_binary_or_symlink(self):
        for kind in ("regular", "symlink"):
            with self.subTest(kind=kind):
                target = self.prefix / "masc"
                target.unlink(missing_ok=True)
                previous = self.old()
                if kind == "symlink":
                    old_path = self.root / "old-target"
                    os.replace(target, old_path)
                    target.symlink_to(old_path)
                self.install()
                bundle.rollback(self.prefix)
                self.assertEqual(target.read_bytes(), previous)
                self.assertEqual(target.is_symlink(), kind == "symlink")

    def test_publication_io_failure_rolls_back(self):
        previous = self.old()
        original = os.replace
        def reject_next(source, target):
            if Path(source).name == "next":
                raise OSError("injected publication failure")
            return original(source, target)
        with patch.object(bundle.os, "replace", side_effect=reject_next):
            with self.assertRaises(OSError):
                self.install()
        self.assertEqual((self.prefix / "masc").read_bytes(), previous)
        self.assertFalse((self.prefix / bundle.TRANSACTION).exists())

    def test_commit_sync_failure_preserves_undo_for_installer_rollback(self):
        previous = self.old()
        self.install()
        with patch.object(bundle, "fsync_dir", side_effect=OSError("injected commit sync")):
            with self.assertRaisesRegex(OSError, "commit sync"):
                bundle.commit(self.prefix)
        self.assertTrue((self.prefix / bundle.TRANSACTION / "previous").exists())
        bundle.rollback(self.prefix)
        self.assertEqual((self.prefix / "masc").read_bytes(), previous)

    def test_missing_undo_never_claims_successful_rollback(self):
        self.old()
        self.install()
        bundle.commit(self.prefix)
        with self.assertRaisesRegex(ValueError, "rollback cannot be confirmed"):
            bundle.rollback(self.prefix)

    def test_wrong_binary_does_not_replace_old_install(self):
        previous = self.old()
        self.binary.write_text(self.binary.read_text() + "# changed bytes\n")
        with self.assertRaisesRegex(ValueError, "binary digest"):
            self.install()
        self.assertEqual((self.prefix / "masc").read_bytes(), previous)

    def test_untrusted_tar_names_links_duplicates_and_extra_members_are_refused(self):
        original = self.archive.read_bytes()
        for name, kind in [("../escape", "file"), ("/absolute", "file"), ("dashboard/../escape", "file"),
                           ("dashboard/link", "symlink"), ("dashboard/hard", "hardlink"),
                           ("dashboard/index.html", "file"), ("dashboard/extra", "file")]:
            with self.subTest(name=name, kind=kind):
                self.archive.write_bytes(original)
                def change(entries):
                    info = tarfile.TarInfo(name)
                    info.type = tarfile.SYMTYPE if kind == "symlink" else tarfile.LNKTYPE if kind == "hardlink" else tarfile.REGTYPE
                    info.linkname = "../../escape" if kind != "file" else ""
                    return entries + [(info, b"")]
                self.mutate_archive(change)
                with self.assertRaises(ValueError):
                    self.install()
                self.assertFalse((self.prefix / "masc").exists())
                self.assertFalse((self.root / "escape").exists())

    def mirror(self):
        mirror = self.root / "release" / "v9.9.9"
        mirror.mkdir(parents=True)
        for name in [self.asset, "masc-tui-" + self.arch, "masc-deployment-preflight-helper-" + self.arch,
                     "masc-check-runtime-deployment-preflight-" + self.arch]:
            shutil.copy2(self.binary, mirror / name)
        shutil.copy2(self.archive, mirror / ("masc-dashboard-" + self.arch + ".tar.gz"))
        shutil.copy2(HELPER, mirror / ("masc-release-dashboard-bundle-" + self.arch + ".py"))
        (mirror / "SHA256SUMS").write_text("".join(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n" for p in mirror.iterdir()))
        return mirror

    def run_installer(self, mirror, extra=()):
        env = os.environ.copy()
        env.update(MASC_RELEASE_BASE_URL=mirror.parent.as_uri(), MASC_WIZARD="0")
        return subprocess.run(["bash", str(ROOT / "scripts/install.sh"), "--version", "v9.9.9", "--prefix", str(self.prefix),
                               "--base-path", str(self.root / "base"), "--no-seed", "--no-guest-shim", "--no-wizard", *extra],
                              env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def test_real_installer_downloads_pair_and_keeps_it_outside_checkout(self):
        mirror = self.mirror()
        result = self.run_installer(mirror)
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = (self.prefix / "masc").resolve()
        bundle.verify_tree(installed.parent, self.asset)
        self.assertIn(str(installed.parent / "assets"), result.stdout)
        self.assertIn("MASC_ASSETS_DIR=", result.stdout)
        self.assertFalse((self.prefix / bundle.TRANSACTION).exists())
        again = self.run_installer(mirror)
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual((self.prefix / "masc").resolve(), installed)

    def test_real_installer_later_smoke_failure_restores_previous_binary(self):
        previous = self.old()
        self.binary.write_text(self.binary.read_text().replace("--version) echo 9.9.9", "--version) exit 9"))
        bundle.package(self.binary, self.assets, COMMIT, self.asset, self.archive)
        mirror = self.mirror()
        result = self.run_installer(mirror, ["--force"])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.prefix / "masc").read_bytes(), previous)
        self.assertFalse((self.prefix / bundle.TRANSACTION).exists())

    def test_wrong_source_commit_is_rejected_even_when_binary_hash_matches(self):
        previous = self.old()
        def change(entries):
            result = []
            for info, data in entries:
                if info.name == bundle.RECEIPT:
                    receipt = json.loads(data)
                    receipt["source_commit"] = "b" * 40
                    data = json.dumps(receipt).encode()
                    info.size = len(data)
                result.append((info, data))
            return result
        self.mutate_archive(change)
        with self.assertRaisesRegex(ValueError, "embedded commit"):
            self.install()
        self.assertEqual((self.prefix / "masc").read_bytes(), previous)

    def test_real_installer_missing_archive_keeps_old_binary(self):
        previous = self.old()
        mirror = self.mirror()
        (mirror / ("masc-dashboard-" + self.arch + ".tar.gz")).unlink()
        result = self.run_installer(mirror, ["--force"])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.prefix / "masc").read_bytes(), previous)


if __name__ == "__main__":
    unittest.main()
