"""Owned artifact cleanup through native targeted Dune clean, without builds."""

import fcntl
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

PAYLOAD = Path(__file__).resolve().parents[1] / "config/scripts/keeper-build-cleanup.py"
SPEC = importlib.util.spec_from_file_location("keeper_build_cleanup", PAYLOAD)
assert SPEC is not None and SPEC.loader is not None
cleaner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cleaner)

@unittest.skipUnless(
    sys.platform == "linux" and shutil.which("dune"), "needs Linux guest with Dune 3.24"
)
class GuestCleanup(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "work"
        self.root.mkdir()
        self.build_root = Path(self.temporary.name) / "build"
        self.build_root.mkdir()
        self.repo = self.root / "checkout"
        self.build = self.repo / "_build"
        self.build.mkdir(parents=True)
        (self.repo / "dune-project").write_text("(lang dune 3.20)\n")
        (self.repo / "source.ml").write_text("let retained = true\n")
        (self.build / "artifact").write_text("generated output\n")

    def test_recent_output_retained_then_only_generated_targets_cleaned(self) -> None:
        report = cleaner.guest_sweep(self.root, 24, True, build_root=self.build_root)
        self.assertEqual(report["entries"][0]["skip"], "recent build output")
        report = cleaner.guest_sweep(self.root, 0, True, build_root=self.build_root)
        self.assertEqual(report["entries"][0]["action"], "cleaned")
        self.assertFalse((self.build / "artifact").exists())
        self.assertTrue((self.build / ".lock").is_file())
        self.assertTrue((self.repo / "source.ml").is_file())

    def test_live_checkout_process_preserves_output(self) -> None:
        process = subprocess.Popen(["sleep", "30"], cwd=self.repo)
        try:
            report = cleaner.guest_sweep(self.root, 0, True, build_root=self.build_root)
            self.assertEqual(report["entries"][0]["skip"], "live process uses checkout")
            self.assertTrue((self.build / "artifact").exists())
        finally:
            process.terminate()
            process.wait(timeout=5)

    def test_vanished_descriptor_keeps_later_checkout_owner_visible(self) -> None:
        proc = self.root / "proc"
        process = proc / str(os.getpid() + 1)
        descriptors = process / "fd"
        descriptors.mkdir(parents=True)
        (process / "stat").write_text("1 (fixture) S\n")
        (process / "cwd").symlink_to(self.root)
        (process / "exe").symlink_to(self.root / "external-executable")
        vanished = descriptors / "0"
        retained = descriptors / "1"
        vanished.symlink_to(self.root / "closed-file")
        retained.symlink_to(self.build / "artifact")
        readlink = os.readlink
        iterdir = Path.iterdir

        def read_descriptor(path):
            if path == vanished:
                raise FileNotFoundError(path)
            return readlink(path)

        def enumerate_paths(path):
            if path == descriptors:
                return iter([vanished, retained])
            return iterdir(path)

        with (
            patch.object(cleaner.os, "readlink", side_effect=read_descriptor),
            patch.object(Path, "iterdir", enumerate_paths),
        ):
            report = cleaner.guest_sweep(
                self.root, 0, True, build_root=self.build_root, proc=proc
            )
        self.assertEqual(report["entries"][0]["skip"], "live process uses checkout")
        self.assertTrue((self.build / "artifact").exists())

    def test_native_dune_lock_preserves_output(self) -> None:
        with (self.build / ".lock").open("w") as lease:
            lease.write(str(os.getpid()))
            lease.flush()
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            report = cleaner.guest_sweep(self.root, 0, True, build_root=self.build_root)
        self.assertEqual(report["entries"][0]["action"], "clean failed")
        self.assertTrue((self.build / "artifact").exists())

    def test_wrapper_lock_override_preserves_output(self) -> None:
        lock = self.root / "explicit.lock"
        with (
            lock.open("w") as lease,
            patch.dict(os.environ, {"DUNE_LOCAL_LOCK": str(lock)}),
        ):
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            report = cleaner.guest_sweep(self.root, 0, True, build_root=self.build_root)
        self.assertEqual(report["entries"][0]["skip"], "wrapper build lock held")
        self.assertTrue((self.build / "artifact").exists())

    def test_symlinked_build_and_operator_marker_retained(self) -> None:
        linked_repo = self.root / "linked"
        linked_repo.mkdir()
        (linked_repo / "dune-project").write_text("(lang dune 3.20)\n")
        (linked_repo / "_build").symlink_to(self.build, target_is_directory=True)
        (self.repo / ".masc-keep-build").touch()
        report = cleaner.guest_sweep(self.root, 0, True, build_root=self.build_root)
        self.assertTrue(all("skip" in entry for entry in report["entries"]))
        self.assertTrue((self.build / "artifact").exists())

    def test_unreadable_process_ownership_fails_closed(self) -> None:
        with patch.object(
            cleaner, "process_paths", side_effect=cleaner.Unreadable("process 7: denied")
        ):
            report = cleaner.guest_sweep(self.root, 0, True, build_root=self.build_root)
        self.assertEqual(report["skip"], "process 7: denied")
        self.assertTrue((self.build / "artifact").exists())


class LiveProcesses(unittest.TestCase):
    """Which processes the sweep reads, on a fixture /proc. Needs no Dune."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        base = Path(temporary.name).resolve()
        self.root = base / "work"
        self.build_root = base / "build"
        self.repo = self.root / "checkout"
        self.build = self.repo / "_build"
        self.build.mkdir(parents=True)
        self.build_root.mkdir()
        (self.repo / "dune-project").write_text("(lang dune 3.20)\n")
        (self.build / "artifact").write_text("generated output\n")
        self.proc = base / "proc"
        self.proc.mkdir()
        # The wrapper lock stays inside the fixture.
        lock = patch.dict(os.environ, {"DUNE_LOCAL_LOCK": str(base / "wrapper.lock")})
        lock.start()
        self.addCleanup(lock.stop)
        # No Dune on PATH: a build that reaches cleaning says so and stays.
        no_dune = patch.object(cleaner.shutil, "which", return_value=None)
        no_dune.start()
        self.addCleanup(no_dune.stop)

    def process(self, pid: int, *, cwd: Path, state: str = "S") -> Path:
        process = self.proc / str(pid)
        (process / "fd").mkdir(parents=True)
        (process / "stat").write_text(f"{pid} (fixture) {state} 1 1\n")
        (process / "cwd").symlink_to(cwd)
        (process / "exe").symlink_to("/usr/bin/true")
        return process

    def unreadable(self, process: Path, *, owner: int, links: int):
        """Patches under which [process] refuses its links to this user."""
        readlink = os.readlink
        stat_of, lstat_of = Path.stat, Path.lstat

        def denied(path, *args, **kwargs):
            if Path(path).parent == process:
                raise PermissionError(13, "Permission denied", str(path))
            return readlink(path, *args, **kwargs)

        def owned(path, *args, **kwargs):
            if path == process:
                return SimpleNamespace(st_uid=owner)
            return stat_of(path, *args, **kwargs)

        def linked(path, *args, **kwargs):
            if path == process / "cwd":
                return SimpleNamespace(st_uid=links)
            return lstat_of(path, *args, **kwargs)

        return (
            patch.object(cleaner.os, "readlink", side_effect=denied),
            patch.object(Path, "stat", owned),
            patch.object(Path, "lstat", linked),
        )

    def sweep(self) -> dict:
        return cleaner.guest_sweep(
            self.root, 0, True, build_root=self.build_root, proc=self.proc
        )

    def test_inspectable_process_reports_cwd_and_open_files(self) -> None:
        process = self.process(4242, cwd=self.repo)
        (process / "fd" / "3").symlink_to(self.build / "artifact")
        (process / "fd" / "4").symlink_to("pipe:[77]")
        paths = cleaner.process_paths(self.proc)
        self.assertIn(self.repo, paths)
        self.assertIn(self.build / "artifact", paths)
        self.assertNotIn(Path("pipe:[77]"), paths)
        self.assertEqual(self.sweep()["entries"][0]["skip"], "live process uses checkout")

    def test_zombie_and_vanished_processes_are_passed_over(self) -> None:
        self.process(4242, cwd=self.repo, state="Z")
        (self.proc / "4243").mkdir()
        (self.proc / "self").mkdir()
        self.assertEqual(cleaner.process_paths(self.proc), [])

    def test_vanished_descriptor_keeps_later_descriptors(self) -> None:
        process = self.process(4242, cwd=self.root)
        vanished = process / "fd" / "0"
        vanished.symlink_to(self.root / "closed-file")
        (process / "fd" / "1").symlink_to(self.build / "artifact")
        readlink = os.readlink

        def read_descriptor(path, *args, **kwargs):
            if Path(path) == vanished:
                raise FileNotFoundError(path)
            return readlink(path, *args, **kwargs)

        with patch.object(cleaner.os, "readlink", side_effect=read_descriptor):
            self.assertIn(self.build / "artifact", cleaner.process_paths(self.proc))

    @unittest.skipIf(os.getuid() == 0, "root reads every process, so none is unreadable")
    def test_unreadable_process_is_passed_over_only_when_it_gave_up_inspection(self) -> None:
        me = os.getuid()
        other = me + 1
        # (process owner, owner of its /proc links, passed over?)
        cases = [
            (me, 0, True),  # the exec agent after it dropped to the Keeper user
            (me, me, False),  # our own inspectable process we cannot read
            (other, other, False),  # another user's process
            (0, 0, False),  # a root process, such as a root exec in the guest
        ]
        process = self.process(4242, cwd=self.repo)
        for owner, links, passed in cases:
            with self.subTest(owner=owner, links=links):
                readlink, stat, lstat = self.unreadable(process, owner=owner, links=links)
                with readlink, stat, lstat:
                    report = self.sweep()
                entry = report["entries"][0]
                if passed:
                    # The sweep went on to cleaning, which this fixture has no Dune for.
                    self.assertNotIn("skip", report)
                    self.assertEqual(entry["action"], "clean failed")
                    self.assertEqual(entry["error"], "dune unavailable")
                else:
                    self.assertIn("process 4242", report["skip"])
                    self.assertEqual(entry["skip"], "live processes unreadable")
                self.assertTrue((self.build / "artifact").exists())

    def test_unreadable_process_stops_before_later_builds(self) -> None:
        later = self.root / "later" / "_build"
        later.mkdir(parents=True)
        (later.parent / "dune-project").write_text("(lang dune 3.20)\n")
        process = self.process(4242, cwd=self.root)
        readlink, stat, lstat = self.unreadable(process, owner=0, links=0)
        with readlink, stat, lstat:
            report = self.sweep()
        self.assertIn("process 4242", report["skip"])
        self.assertEqual(len(report["entries"]), 1)

    def test_missing_dune_is_silent_until_an_owned_idle_build_needs_it(self) -> None:
        (self.build / "artifact").unlink()
        self.build.rmdir()
        report = self.sweep()
        self.assertNotIn("skip", report)
        self.assertEqual(report["entries"], [])
        # A _build with no dune-project beside it is not Dune's to clean.
        stray = self.root / "notes" / "_build"
        stray.mkdir(parents=True)
        report = self.sweep()
        self.assertNotIn("skip", report)
        self.assertEqual(
            [entry["skip"] for entry in report["entries"]],
            ["not a default Dune build directory"],
        )


@unittest.skipUnless(shutil.which("dune"), "needs native Dune targeted clean")
class ManagedBuildCleanup(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="keeper-owned-cleanup-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.root = self.base / "work"
        self.build_root = self.base / "build"
        self.repo = self.root / "repos" / "checkout"
        self.repo.mkdir(parents=True)
        self.build_root.mkdir()
        self.target = self.build_root / "repos:checkout"
        self.target.mkdir()
        self.link = self.repo / "_build"
        self.link.symlink_to(self.target, target_is_directory=True)
        (self.repo / "dune-project").write_text("(lang dune 3.20)\n")
        (self.repo / "source.ml").write_text("let retained = true\n")
        (self.target / "artifact").write_text("generated output\n")
        self.processes = patch.object(cleaner, "process_paths", return_value=[])
        self.processes.start()
        self.addCleanup(self.processes.stop)

    def sweep(self, apply: bool = True):
        return cleaner.guest_sweep(
            self.root, 0, apply, build_root=self.build_root
        )

    def test_owned_link_cleans_output_and_preserves_source_link_and_lock(self):
        lock = self.target / ".lock"
        lock.touch()
        before = lock.stat().st_ino
        report = self.sweep()
        self.assertEqual(report["entries"][0]["action"], "cleaned")
        self.assertFalse((self.target / "artifact").exists())
        self.assertEqual((self.repo / "source.ml").read_text(), "let retained = true\n")
        self.assertEqual(self.link.readlink(), self.target)
        self.assertEqual(lock.stat().st_ino, before)

    def test_foreign_shared_or_escaping_link_is_retained(self):
        for target in [self.base / "foreign", self.build_root / "another-checkout"]:
            with self.subTest(target=target):
                target.mkdir()
                artifact = target / "artifact"
                artifact.write_text("retained\n")
                self.link.unlink()
                self.link.symlink_to(target, target_is_directory=True)
                report = self.sweep()
                self.assertEqual(report["entries"][0]["skip"], "not an owned Dune build target")
                self.assertTrue(artifact.exists())

    def test_target_with_symlink_component_is_retained(self):
        self.target.rename(self.base / "redirected")
        self.target.symlink_to(self.base / "redirected", target_is_directory=True)
        report = self.sweep()
        self.assertEqual(report["entries"][0]["skip"], "not an owned Dune build target")
        self.assertTrue((self.target / "artifact").exists())

    def test_physical_target_process_prevents_cleanup(self):
        for path in [self.target, self.target / "artifact", self.repo / "source.ml"]:
            with self.subTest(path=path), patch.object(cleaner, "process_paths", return_value=[path]):
                report = self.sweep()
                self.assertEqual(report["entries"][0]["skip"], "live process uses checkout")
                self.assertTrue((self.target / "artifact").exists())

    def test_native_lock_and_operator_marker_each_prevent_cleanup(self):
        with (self.target / ".lock").open("w") as lease:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            report = self.sweep()
        self.assertEqual(report["entries"][0]["action"], "clean failed")
        self.assertTrue((self.target / "artifact").exists())
        (self.repo / ".masc-keep-build").touch()
        self.assertEqual(self.sweep()["entries"][0]["skip"], "operator retention marker")
        self.assertTrue((self.target / "artifact").exists())

    def test_dry_run_and_unknown_ownership_do_not_mutate(self):
        self.assertEqual(self.sweep(False)["entries"][0]["action"], "would clean")
        self.assertTrue((self.target / "artifact").exists())
        with patch.object(
            cleaner, "process_paths", side_effect=cleaner.Unreadable("process 7: denied")
        ):
            self.assertEqual(self.sweep()["skip"], "process 7: denied")
        self.assertTrue((self.target / "artifact").exists())

    def test_replaced_target_during_scan_does_not_clean_replacement(self):
        scan = cleaner.tree_stats
        moved = self.base / "retained-original"
        def replace(target):
            result = scan(target)
            target.rename(moved)
            target.mkdir()
            (target / "artifact").write_text("new owner\n")
            return result
        with patch.object(cleaner, "tree_stats", side_effect=replace):
            report = self.sweep()
        self.assertEqual(report["entries"][0]["skip"], "build target changed during inspection")
        self.assertEqual((self.target / "artifact").read_text(), "new owner\n")
        self.assertTrue((moved / "artifact").exists())


if __name__ == "__main__":
    unittest.main()
