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
import shlex
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
                     "masc-check-runtime-deployment-preflight-" + self.arch,
                     "masc-exec-ssh-bootstrap-" + self.arch]:
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

    def run_installer(self, mirror, extra=(), env_override=None, guest_shim=False):
        env = os.environ.copy()
        env.update(MASC_RELEASE_BASE_URL=mirror.parent.as_uri(), MASC_WIZARD="0")
        if env_override:
            env.update(env_override)
        shim_options = [] if guest_shim else ["--no-guest-shim"]
        return subprocess.run(["bash", str(ROOT / "scripts/install.sh"), "--version", "v9.9.9", "--prefix", str(self.prefix),
                               "--base-path", str(self.root / "base"), "--no-seed", "--no-wizard", *shim_options, *extra],
                              env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def test_real_installer_downloads_pair_and_keeps_it_outside_checkout(self):
        mirror = self.mirror()
        result = self.run_installer(mirror)
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = (self.prefix / "masc").resolve()
        self.assertEqual((self.prefix / "masc-exec-ssh-bootstrap").read_bytes(),
                         (mirror / ("masc-exec-ssh-bootstrap-" + self.arch)).read_bytes())
        bundle.verify_tree(installed.parent, self.asset)
        command = next(line.strip() for line in result.stdout.splitlines()
                       if line.startswith('  env '))
        arguments = shlex.split(command)
        self.assertIn('MASC_ASSETS_DIR=' + str(installed.parent / 'assets'), arguments)
        self.assertEqual(arguments[-5:], ['setup', '--base-path', str(self.root / 'base'),
                                         '--port', '8935'])
        self.assertFalse((self.prefix / bundle.TRANSACTION).exists())
        again = self.run_installer(mirror)
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual((self.prefix / "masc").resolve(), installed)

    def test_real_installer_refuses_foreign_version_without_executing_it(self):
        mirror = self.mirror()
        target = self.prefix / "masc"
        marker = self.root / "foreign-executed"
        for reported in ("0.34.0", "9.9.9"):
            with self.subTest(reported=reported):
                target.write_text("#!/bin/sh\necho called >> " + shlex.quote(str(marker)) +
                                  "\necho " + reported + "\n")
                target.chmod(0o755)
                previous = target.read_bytes()
                result = self.run_installer(mirror)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("pass --force", result.stderr)
                self.assertEqual(target.read_bytes(), previous)
                self.assertFalse(marker.exists(), "unknown executable was started")
                self.assertFalse((self.prefix / bundle.TRANSACTION).exists())

    def test_matching_unmanaged_binary_requires_force_in_dry_run_and_install(self):
        mirror = self.mirror()
        target = self.prefix / "masc"
        shutil.copy2(self.binary, target)
        previous = target.read_bytes()
        for extra in ([], ["--dry-run"]):
            with self.subTest(extra=extra):
                result = self.run_installer(mirror, extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("not a managed release pointer", result.stderr)
                self.assertEqual(target.read_bytes(), previous)

    def test_older_bundle_helper_fails_closed_without_no_replace(self):
        mirror = self.mirror()
        helper = mirror / ("masc-release-dashboard-bundle-" + self.arch + ".py")
        old = helper.read_text().replace('    inst.add_argument("--no-replace", action="store_true")\n', '')
        old = old.replace('args.runtime_archive, args.no_replace)', 'args.runtime_archive)')
        helper.write_text(old)
        checksum_path = mirror / "SHA256SUMS"
        checksum_path.write_text("".join(
            f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n"
            for path in mirror.iterdir() if path.name != "SHA256SUMS"))
        result = self.run_installer(mirror)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--no-replace", result.stderr)
        self.assertFalse((self.prefix / "masc").exists())
        forced = self.run_installer(mirror, ["--force"])
        self.assertEqual(forced.returncode, 0, forced.stderr)
        self.assertEqual((self.prefix / "masc").read_bytes(), self.binary.read_bytes())

    def test_installer_leaves_an_unrelated_companion_partial_untouched(self):
        mirror = self.mirror()
        outside = self.root / "outside"
        outside.write_text("keep my file")
        partial = self.prefix / "masc-tui.partial"
        partial.symlink_to(outside)
        result = self.run_installer(mirror)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(partial.is_symlink())
        self.assertEqual(outside.read_text(), "keep my file")

    def test_installer_leaves_an_unrelated_guest_shim_partial_untouched(self):
        mirror = self.mirror()
        shim_name = "masc-exec-shim-linux-" + ("arm64" if self.arch.endswith("arm64") else "amd64")
        shim = mirror / shim_name
        shutil.copy2(self.binary, shim)
        with (mirror / "SHA256SUMS").open("a") as checksums:
            checksums.write(f"{hashlib.sha256(shim.read_bytes()).hexdigest()}  {shim_name}\n")
        shim_dir = self.root / "base/.masc/microvm/shim"
        shim_dir.mkdir(parents=True)
        outside = self.root / "outside-shim"
        outside.write_text("keep my file")
        partial = shim_dir / "masc-exec-shim.partial"
        partial.symlink_to(outside)
        result = self.run_installer(mirror, guest_shim=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(partial.is_symlink())
        self.assertEqual(outside.read_text(), "keep my file")
        self.assertEqual((shim_dir / "masc-exec-shim").read_bytes(), self.binary.read_bytes())

    def test_real_installer_explicit_force_replaces_foreign_file(self):
        previous = self.old()
        mirror = self.mirror()
        result = self.run_installer(mirror, ["--force"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual((self.prefix / "masc").read_bytes(), previous)
        bundle.verify_tree((self.prefix / "masc").resolve().parent, self.asset)

    def test_no_replace_does_not_erase_a_file_created_at_publication(self):
        target = self.prefix / "masc"
        original_link = os.link
        def race(source, destination, **options):
            if Path(destination) == self.prefix.resolve() / "masc":
                target.write_text("another program appeared")
            return original_link(source, destination, **options)
        runtime = self.runtime_archive if self.arch.startswith("macos-") else None
        with patch.object(bundle.os, "link", side_effect=race):
            with self.assertRaisesRegex(ValueError, "appeared during installation"):
                bundle.install(self.binary, self.archive, self.prefix, self.asset,
                               runtime_archive=runtime, no_replace=True)
        self.assertEqual(target.read_text(), "another program appeared")
        self.assertFalse((self.prefix / bundle.TRANSACTION).exists())

    def test_transaction_parent_sync_precedes_publication(self):
        runtime = self.runtime_archive if self.arch.startswith("macos-") else None
        original_sync = bundle.fsync_dir
        failed = False
        def fail_first_prefix_sync(directory):
            nonlocal failed
            if Path(directory) == self.prefix.resolve() and not failed:
                failed = True
                self.assertTrue((self.prefix / bundle.TRANSACTION).is_dir())
                self.assertFalse((self.prefix / "masc").exists())
                raise OSError("injected pre-publication sync failure")
            return original_sync(directory)
        with patch.object(bundle, "fsync_dir", side_effect=fail_first_prefix_sync):
            with self.assertRaisesRegex(OSError, "pre-publication sync"):
                bundle.install(self.binary, self.archive, self.prefix, self.asset,
                               runtime_archive=runtime, no_replace=True)
        self.assertTrue(failed)
        self.assertFalse((self.prefix / "masc").exists())
        self.assertFalse((self.prefix / bundle.TRANSACTION).exists())

    def test_no_replace_rollback_preserves_a_concurrently_replaced_file(self):
        runtime = self.runtime_archive if self.arch.startswith("macos-") else None
        with patch("builtins.print"):
            bundle.install(self.binary, self.archive, self.prefix, self.asset,
                           runtime_archive=runtime, no_replace=True)
        target = self.prefix.resolve() / "masc"
        foreign = self.root / "incoming"
        foreign.write_text("another program")
        original_rename = os.rename
        def race(source, destination):
            if Path(source) == target:
                os.replace(foreign, target)
            return original_rename(source, destination)
        with patch.object(bundle.os, "rename", side_effect=race):
            bundle.rollback(self.prefix.resolve())
        self.assertEqual(target.read_text(), "another program")
        self.assertFalse((self.prefix / bundle.TRANSACTION).exists())

    def test_no_replace_rollback_restores_a_concurrently_replaced_directory(self):
        runtime = self.runtime_archive if self.arch.startswith("macos-") else None
        with patch("builtins.print"):
            bundle.install(self.binary, self.archive, self.prefix, self.asset,
                           runtime_archive=runtime, no_replace=True)
        target = self.prefix.resolve() / "masc"
        original_rename = os.rename
        def race(source, destination):
            if Path(source) == target:
                target.unlink()
                target.mkdir()
                (target / "data").write_text("another program")
            return original_rename(source, destination)
        with patch.object(bundle.os, "rename", side_effect=race):
            bundle.rollback(self.prefix.resolve())
        self.assertTrue(target.is_dir())
        self.assertEqual((target / "data").read_text(), "another program")
        self.assertFalse((self.prefix / bundle.TRANSACTION).exists())

    def test_rollback_preserves_both_directories_when_restore_name_is_taken(self):
        runtime = self.runtime_archive if self.arch.startswith("macos-") else None
        with patch("builtins.print"):
            bundle.install(self.binary, self.archive, self.prefix, self.asset,
                           runtime_archive=runtime, no_replace=True)
        target = self.prefix.resolve() / "masc"
        original_rename, exclusive = os.rename, bundle.rename_directory_no_replace
        def replace_with_directory(source, destination):
            if Path(source) == target:
                target.unlink()
                target.mkdir()
                (target / "data").write_text("first program")
            return original_rename(source, destination)
        def occupy_restore_name(source, destination):
            Path(destination).write_text("second program")
            return exclusive(source, destination)
        with patch.object(bundle.os, "rename", side_effect=replace_with_directory), \
             patch.object(bundle, "rename_directory_no_replace", side_effect=occupy_restore_name):
            with self.assertRaisesRegex(ValueError, "could not confirm the changed destination"):
                bundle.rollback(self.prefix.resolve())
        self.assertEqual(target.read_text(), "second program")
        journal = self.prefix / bundle.TRANSACTION
        captured = list(journal.glob('.rollback-*/entry/data'))
        self.assertEqual([path.read_text() for path in captured], ["first program"])
        with self.assertRaisesRegex(ValueError, "interrupted rollback preserved"):
            bundle.commit(self.prefix.resolve())

    def test_interrupted_no_replace_rollback_is_never_discarded(self):
        runtime = self.runtime_archive if self.arch.startswith("macos-") else None
        with patch("builtins.print"):
            bundle.install(self.binary, self.archive, self.prefix, self.asset,
                           runtime_archive=runtime, no_replace=True)
        journal = self.prefix / bundle.TRANSACTION
        captured = journal / ".rollback-interrupted" / "entry"
        captured.parent.mkdir()
        captured.write_text("preserved other program")
        for recover in (bundle.rollback, bundle.commit):
            with self.subTest(recover=recover.__name__):
                with self.assertRaisesRegex(ValueError, "interrupted rollback preserved"):
                    recover(self.prefix.resolve())
                self.assertEqual(captured.read_text(), "preserved other program")

    def test_rollback_sync_failure_keeps_the_captured_file_for_inspection(self):
        runtime = self.runtime_archive if self.arch.startswith("macos-") else None
        with patch("builtins.print"):
            bundle.install(self.binary, self.archive, self.prefix, self.asset,
                           runtime_archive=runtime, no_replace=True)
        target = self.prefix.resolve() / "masc"
        foreign = self.root / "incoming"
        foreign.write_text("another program")
        original_rename, original_sync = os.rename, bundle.fsync_dir
        def race(source, destination):
            if Path(source) == target:
                os.replace(foreign, target)
            return original_rename(source, destination)
        def fail_holder_sync(directory):
            if Path(directory).name.startswith('.rollback-'):
                raise OSError("injected rollback sync failure")
            return original_sync(directory)
        with patch.object(bundle.os, "rename", side_effect=race), \
             patch.object(bundle, "fsync_dir", side_effect=fail_holder_sync):
            with self.assertRaisesRegex(OSError, "rollback sync"):
                bundle.rollback(self.prefix.resolve())
        journal = self.prefix / bundle.TRANSACTION
        captured = list(journal.glob('.rollback-*/entry'))
        self.assertEqual([path.read_text() for path in captured], ["another program"])
        with self.assertRaisesRegex(ValueError, "interrupted rollback preserved"):
            bundle.commit(self.prefix.resolve())

    def test_real_installer_preserves_a_file_created_after_its_initial_check(self):
        mirror = self.mirror()
        target = self.prefix / "masc"
        commands = self.root / "commands"
        commands.mkdir()
        curl = commands / "curl"
        curl.write_text("#!/bin/sh\ncase \"$*\" in *" + shlex.quote('/v9.9.9/' + self.asset) +
                        "*) echo another-program > " + shlex.quote(str(target)) +
                        " ;; esac\nexec " + shlex.quote(shutil.which('curl')) + ' "$@"\n')
        curl.chmod(0o755)
        result = self.run_installer(mirror, env_override={"PATH": str(commands) + os.pathsep + os.environ['PATH']})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("pass --force", result.stderr)
        self.assertEqual(target.read_text(), "another-program\n")
        self.assertFalse((self.prefix / bundle.TRANSACTION).exists())

    def test_missing_ssh_bootstrap_asset_does_not_replace_installed_binary(self):
        previous = self.old()
        mirror = self.mirror()
        (mirror / ("masc-exec-ssh-bootstrap-" + self.arch)).unlink()
        result = self.run_installer(mirror, ["--force"])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.prefix / "masc").read_bytes(), previous)
        self.assertFalse((self.prefix / "masc-exec-ssh-bootstrap").exists())

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

    def test_no_replace_smoke_failure_rolls_back_its_own_publications(self):
        self.binary.write_text(self.binary.read_text().replace("--version) echo 9.9.9", "--version) exit 9"))
        mirror = self.mirror()
        result = self.run_installer(mirror)
        self.assertNotEqual(result.returncode, 0)
        for name in ("masc", *bundle.COMPANIONS):
            self.assertFalse((self.prefix / name).exists(), name)
            self.assertFalse((self.prefix / name).is_symlink(), name)
        self.assertFalse((self.prefix / bundle.TRANSACTION).exists())

    def test_real_installer_exposes_startup_error_after_verified_assembly(self):
        previous = self.old()
        mirror = self.mirror()
        binary = mirror / self.asset
        binary.write_text("#!/bin/sh\nulimit -c 0\n"
                          "echo 'dyld: Library not loaded: /missing/libssl.3.dylib' >&2\n"
                          "kill -ABRT $$\n")
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
