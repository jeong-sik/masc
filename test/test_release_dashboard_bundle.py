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
        self.arch = {("Darwin", "arm64"): "macos-arm64", ("Darwin", "x86_64"): "macos-x64", ("Linux", "x86_64"): "linux-x64", ("Linux", "aarch64"): "linux-arm64"}[(system.sysname, system.machine)]
        self.asset = "masc-" + self.arch
        self.archive = self.root / "bundle.tar.gz"
        self.package(self.binary, self.assets, COMMIT, self.asset, self.archive)

    def package(self, binary, assets, commit, asset, archive, companions=(), runtime=None, stage=None):
        if self.arch.startswith("macos-") and runtime is None:
            runtime, stage = self.runtime_fixture()
        self.runtime_archive = runtime
        bundle.package(binary, assets, commit, asset, archive, companions, runtime, stage)

    def install_bundle(self, binary, archive, prefix, asset, companions=(), runtime=None):
        if self.arch.startswith("macos-") and runtime is None:
            runtime = self.runtime_archive
        return bundle.install(binary, archive, prefix, asset, companions, runtime)

    def old(self):
        target = self.prefix / "masc"
        target.write_text("#!/bin/sh\necho old-binary\n")
        target.chmod(0o755)
        return target.read_bytes()

    def install(self):
        with patch("builtins.print"):
            self.install_bundle(self.binary, self.archive, self.prefix, self.asset)

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

    def test_binary_startup_failure_exposes_loader_diagnostic(self):
        for termination, expected in [("exit 127", "exit status 127"),
                                      ("kill -ABRT $$", "signal SIGABRT")]:
            with self.subTest(termination=termination):
                self.binary.write_text(
                    "#!/bin/sh\nulimit -c 0\n"
                    "echo 'dyld: Library not loaded: /missing/libssl.3.dylib' >&2\n"
                    + termination + "\n")
                result = subprocess.run(
                    ["python3", str(HELPER), "package", "--binary", str(self.binary),
                     "--assets", str(self.assets), "--source-commit", COMMIT,
                     "--binary-asset", self.asset, "--archive", str(self.archive)],
                    text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)
                self.assertIn("dyld: Library not loaded: /missing/libssl.3.dylib", result.stderr)
                self.assertIn(str(self.binary), result.stderr)

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

    def test_companion_publication_failure_restores_all_previous_executables(self):
        previous = self.old()
        tui = self.prefix / "masc-tui"
        tui.write_text("old tui")
        original = os.replace
        def reject_browser(source, target):
            if Path(source).name == "next" and Path(target).name == "masc-browser-host":
                raise OSError("injected companion publication failure")
            return original(source, target)
        self.package(self.binary, self.assets, COMMIT, self.asset, self.archive,
                       [("masc-tui", self.binary), ("masc-browser-host", self.binary)])
        with patch.object(bundle.os, "replace", side_effect=reject_browser):
            with self.assertRaisesRegex(OSError, "companion publication"):
                self.install_bundle(self.binary, self.archive, self.prefix, self.asset,
                               [("masc-tui", self.binary), ("masc-browser-host", self.binary)])
        self.assertEqual(tui.read_text(), "old tui")
        self.assertEqual((self.prefix / "masc").read_bytes(), previous)
        self.assertFalse((self.prefix / "masc-browser-host").exists())
        self.assertFalse((self.prefix / bundle.TRANSACTION).exists())

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
        for name in [self.asset, "masc-tui-" + self.arch, "masc-browser-host-" + self.arch, "masc-deployment-preflight-helper-" + self.arch,
                     "masc-check-runtime-deployment-preflight-" + self.arch]:
            shutil.copy2(self.binary, mirror / name)
        companions = [(name, self.binary) for name in sorted(bundle.COMPANIONS)]
        runtime = None
        stage = None
        runtime, stage = self.runtime_fixture()
        shutil.copy2(runtime, mirror / runtime.name)
        self.package(self.binary, self.assets, COMMIT, self.asset, self.archive,
                       companions, runtime, stage)
        shutil.copy2(self.archive, mirror / ("masc-dashboard-" + self.arch + ".tar.gz"))
        shutil.copy2(HELPER, mirror / ("masc-release-dashboard-bundle-" + self.arch + ".py"))
        (mirror / "SHA256SUMS").write_text("".join(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n" for p in mirror.iterdir()))
        return mirror

    def runtime_fixture(self):
        import sys
        stage = self.root / "runtime-stage"
        stage.mkdir(exist_ok=True)
        shutil.copy2(self.binary, stage / "masc")
        runtime = self.root / ("masc-runtime-" + self.arch + ".tar.gz")
        provenance = json.dumps(dict(source_commit=COMMIT, platform=self.arch)).encode()
        python = ("#!/bin/sh\nexec " + __import__('shlex').quote(sys.executable) + ' "$@"\n').encode()
        with tarfile.open(runtime, "w:gz") as output:
            for name, data, mode in [("runtime-provenance.json", provenance, 0o644),
                                     ("python/bin/python3", python, 0o755),
                                     ("lib/libfixture.dylib", b"fixture library", 0o644)]:
                info = tarfile.TarInfo(name)
                info.size, info.mode = len(data), mode
                output.addfile(info, io.BytesIO(data))
        return runtime, stage

    def test_portable_release_binds_runtime_and_companions_and_rolls_back_links(self):
        previous = self.old()
        runtime, stage = self.runtime_fixture()
        companions = [("masc-tui", self.binary)]
        self.package(self.binary, self.assets, COMMIT, self.asset, self.archive, companions, runtime, stage)
        with patch("builtins.print"):
            self.install_bundle(self.binary, self.archive, self.prefix, self.asset, companions, runtime)
        installed = (self.prefix / "masc").resolve().parent
        self.assertEqual((self.prefix / "masc-tui").resolve().parent, installed)
        self.assertEqual((installed / "lib/libfixture.dylib").read_bytes(), b"fixture library")
        bundle.verify_tree(installed, self.asset)
        (installed / "lib/libfixture.dylib").write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "runtime digest"):
            bundle.verify_tree(installed, self.asset)
        bundle.rollback(self.prefix)
        self.assertEqual((self.prefix / "masc").read_bytes(), previous)
        self.assertFalse((self.prefix / "masc-tui").exists())

    def test_portable_archive_tampering_never_publishes(self):
        previous = self.old()
        runtime, stage = self.runtime_fixture()
        self.package(self.binary, self.assets, COMMIT, self.asset, self.archive, (), runtime, stage)
        runtime.write_bytes(runtime.read_bytes() + b"changed")
        with self.assertRaisesRegex(ValueError, "runtime archive digest"):
            self.install_bundle(self.binary, self.archive, self.prefix, self.asset, (), runtime)
        self.assertEqual((self.prefix / "masc").read_bytes(), previous)
        self.assertFalse((self.prefix / bundle.TRANSACTION).exists())

    def test_macos_runtime_and_executable_python_are_required(self):
        runtime, stage = self.runtime_fixture()
        self.package(self.binary, self.assets, COMMIT, self.asset, self.archive, (), runtime, stage)
        with tarfile.open(self.archive) as source:
            original = json.loads(source.extractfile(bundle.RECEIPT).read())
        for arch in ("macos-arm64", "macos-x64"):
            receipt = dict(original, binary_asset="masc-" + arch, runtime=None)
            with self.assertRaisesRegex(ValueError, "macOS receipt requires"):
                bundle.validate_receipt(receipt, receipt["binary_asset"])
        for entry in original["runtime"]["files"]:
            if entry["path"] == "python/bin/python3":
                entry["mode"] = 0o644
        with self.assertRaisesRegex(ValueError, "interpreter must be executable"):
            bundle.validate_receipt(original, self.asset)

    def test_runtime_float_mode_is_not_an_integer_receipt(self):
        runtime, stage = self.runtime_fixture()
        self.package(self.binary, self.assets, COMMIT, self.asset, self.archive, (), runtime, stage)
        def change(entries):
            for info, data in entries:
                if info.name == bundle.RECEIPT:
                    receipt = json.loads(data)
                    receipt["runtime"]["files"][0]["mode"] = 420.0
                    data = json.dumps(receipt).encode()
                    info.size = len(data)
                yield info, data
        self.mutate_archive(change)
        with self.assertRaisesRegex(ValueError, "runtime receipt metadata"):
            self.install_bundle(self.binary, self.archive, self.prefix, self.asset, (), runtime)
        self.assertFalse((self.prefix / "masc").exists())

    def test_companion_tampering_never_publishes(self):
        previous = self.old()
        companion = self.root / "tui"
        shutil.copy2(self.binary, companion)
        companions = [("masc-tui", companion)]
        self.package(self.binary, self.assets, COMMIT, self.asset, self.archive, companions)
        companion.write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "companion digest"):
            self.install_bundle(self.binary, self.archive, self.prefix, self.asset, companions)
        self.assertEqual((self.prefix / "masc").read_bytes(), previous)

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
        tui = self.prefix / "masc-tui"
        tui.write_text("old tui")
        self.binary.write_text(self.binary.read_text().replace("--version) echo 9.9.9", "--version) exit 9"))
        self.package(self.binary, self.assets, COMMIT, self.asset, self.archive)
        mirror = self.mirror()
        result = self.run_installer(mirror, ["--force"])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.prefix / "masc").read_bytes(), previous)
        self.assertEqual(tui.read_text(), "old tui")
        self.assertFalse((self.prefix / "masc-browser-host").exists())
        self.assertFalse((self.prefix / bundle.TRANSACTION).exists())

    def test_real_installer_exposes_startup_error_before_dashboard_download(self):
        previous = self.old()
        mirror = self.mirror()
        binary = mirror / self.asset
        binary.write_text("#!/bin/sh\nulimit -c 0\n"
                          "echo 'dyld: Library not loaded: /missing/libssl.3.dylib' >&2\n"
                          "kill -ABRT $$\n")
        if self.arch.startswith("macos-"):
            # Bind the intentionally non-starting bytes without executing them
            # during fixture packaging; install must expose the loader failure
            # only after assembling the verified portable tree.
            def update_digest(entries):
                for info, data in entries:
                    if info.name == bundle.RECEIPT:
                        receipt = json.loads(data)
                        receipt["binary_sha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
                        data = json.dumps(receipt).encode()
                        info.size = len(data)
                    yield info, data
            self.mutate_archive(update_digest)
            shutil.copy2(self.archive, mirror / ("masc-dashboard-" + self.arch + ".tar.gz"))
        else:
            (mirror / ("masc-dashboard-" + self.arch + ".tar.gz")).unlink()
        (mirror / "SHA256SUMS").write_text("".join(
            f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n"
            for p in mirror.iterdir() if p.name != "SHA256SUMS"))
        result = self.run_installer(mirror, ["--force"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("dyld: Library not loaded: /missing/libssl.3.dylib", result.stderr)
        self.assertNotIn("download failed", result.stderr)
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
        tui = self.prefix / "masc-tui"
        tui.write_text("old tui")
        mirror = self.mirror()
        (mirror / ("masc-dashboard-" + self.arch + ".tar.gz")).unlink()
        result = self.run_installer(mirror, ["--force"])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.prefix / "masc").read_bytes(), previous)
        self.assertEqual(tui.read_text(), "old tui")
        self.assertFalse((self.prefix / "masc-browser-host").exists())


if __name__ == "__main__":
    unittest.main()
