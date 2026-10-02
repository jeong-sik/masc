"""Real Dune safety checks (Linux) and isolated background service lifecycle."""

import fcntl
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
SPEC = importlib.util.spec_from_file_location(
    "vm_cleanup", SCRIPTS / "cleanup-keeper-vm-builds.py"
)
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
        self.root = Path(self.temporary.name)
        self.repo = self.root / "checkout"
        self.build = self.repo / "_build"
        self.build.mkdir(parents=True)
        (self.repo / "dune-project").write_text("(lang dune 3.20)\n")
        (self.repo / "source.ml").write_text("let retained = true\n")
        (self.build / "artifact").write_text("generated output\n")

    def test_recent_output_retained_then_only_generated_targets_cleaned(self) -> None:
        report = cleaner.guest_sweep(self.root, 24, True)
        self.assertEqual(report["entries"][0]["skip"], "recent build output")
        report = cleaner.guest_sweep(self.root, 0, True)
        self.assertEqual(report["entries"][0]["action"], "cleaned")
        self.assertFalse((self.build / "artifact").exists())
        self.assertTrue((self.build / ".lock").is_file())
        self.assertTrue((self.repo / "source.ml").is_file())

    def test_native_dune_lock_preserves_output(self) -> None:
        with (self.build / ".lock").open("w") as lease:
            lease.write(str(os.getpid()))
            lease.flush()
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            report = cleaner.guest_sweep(self.root, 0, True)
        self.assertEqual(report["entries"][0]["action"], "clean failed")
        self.assertTrue((self.build / "artifact").exists())

    def test_wrapper_lock_override_preserves_output(self) -> None:
        lock = self.root / "explicit.lock"
        with (
            lock.open("w") as lease,
            patch.dict(os.environ, {"DUNE_LOCAL_LOCK": str(lock)}),
        ):
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            report = cleaner.guest_sweep(self.root, 0, True)
        self.assertEqual(report["entries"][0]["skip"], "wrapper build lock held")
        self.assertTrue((self.build / "artifact").exists())

    def test_symlinked_build_and_operator_marker_retained(self) -> None:
        linked_repo = self.root / "linked"
        linked_repo.mkdir()
        (linked_repo / "dune-project").write_text("(lang dune 3.20)\n")
        (linked_repo / "_build").symlink_to(self.build, target_is_directory=True)
        (self.repo / ".masc-keep-build").touch()
        report = cleaner.guest_sweep(self.root, 0, True)
        self.assertTrue(all("skip" in entry for entry in report["entries"]))
        self.assertTrue((self.build / "artifact").exists())

    def test_unreadable_process_ownership_fails_closed(self) -> None:
        with patch.object(
            cleaner, "process_paths", side_effect=PermissionError("denied")
        ):
            with self.assertRaises(PermissionError):
                cleaner.guest_sweep(self.root, 0, True)
        self.assertTrue((self.build / "artifact").exists())


class CleanerService(unittest.TestCase):
    def test_start_duplicate_stop_and_restart(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            fake_bin = base / "bin"
            fake_bin.mkdir()
            container = fake_bin / "container"
            container.write_text("#!/bin/sh\nprintf '[]\\n'\n")
            container.chmod(0o755)
            env = {**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}"}
            state = base / ".masc/maintenance/keeper-vm-cleaner"

            def command(action: str) -> subprocess.CompletedProcess[str]:
                return subprocess.run(
                    [
                        sys.executable,
                        str(SCRIPTS / "keeper-vm-cleaner.py"),
                        action,
                        "--base-path",
                        str(base),
                        "--interval-seconds",
                        "60",
                    ],
                    env=env,
                    text=True,
                    capture_output=True,
                    check=True,
                )

            def await_stopped() -> None:
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    if not json.loads(command("status").stdout)["running"]:
                        return
                    time.sleep(0.1)
                self.fail("service did not stop")

            try:
                command("start")
                original = json.loads((state / "config.json").read_text())["pid"]
                command("start")
                self.assertEqual(
                    json.loads((state / "config.json").read_text())["pid"], original
                )
                command("stop")
                await_stopped()
                command("start")
                self.assertNotEqual(
                    json.loads((state / "config.json").read_text())["pid"], original
                )
                self.assertTrue(json.loads(command("status").stdout)["running"])
            finally:
                command("stop")
                await_stopped()


if __name__ == "__main__":
    unittest.main()
