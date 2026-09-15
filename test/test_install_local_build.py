#!/usr/bin/env python3
"""A local install brings every registered browser lane host to the new build."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts/install-local-build.sh"
HOST_INSTALLER = REPO / "connectors/browser/install-host.sh"


def executable(path, text):
    path.write_text("#!/bin/sh\necho " + text + "\n")
    path.chmod(0o755)
    return path


class LocalBuildInstall(unittest.TestCase):
    def test_every_registered_host_gets_the_new_copy_under_its_own_name(self):
        with tempfile.TemporaryDirectory(prefix="local build ' ") as temporary:
            root = Path(temporary).resolve()
            manifests = root / "native manifests"
            old_host = executable(root / "old-host", "old")
            # Two workspaces registered the way install-host.sh registers them,
            # one under the default host name and one under an isolated name.
            first, second = root / "workspace one", root / "workspace two"
            for base, name in ((first, "masc_browser_host"), (second, "masc_browser_host_second")):
                subprocess.run(["bash", str(HOST_INSTALLER), "--binary", str(old_host), "--base-path", str(base),
                                "--host-name", name, "--manifest-dir", str(manifests)],
                               check=True, capture_output=True)
            # A host that is not a workspace browser lane must be left alone.
            unrelated = manifests / "com.example.password.json"
            unrelated.write_text(json.dumps({"name": "com.example.password", "path": str(root / "elsewhere/launch")}))
            before_unrelated = unrelated.read_text()

            build = root / "build"
            build.mkdir()
            executable(build / "main_eio.exe", "masc")
            executable(build / "masc_tui.exe", "tui")
            executable(build / "masc_browser_host.exe", "new")
            prefix = root / "prefix"

            result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                                     "--prefix", str(prefix), "--manifest-dir", str(manifests)],
                                    check=True, capture_output=True, text=True)

            for name, marker in (("masc", "masc"), ("masc-tui", "tui"), ("masc-browser-host", "new")):
                self.assertIn(marker, (prefix / name).read_text())
            for base, name in ((first, "masc_browser_host"), (second, "masc_browser_host_second")):
                copy = base / ".masc/browser-lane/host/masc-browser-host"
                self.assertIn("new", copy.read_text(), f"{base} still starts the old host")
                manifest = json.loads((manifests / f"{name}.json").read_text())
                self.assertEqual(manifest["name"], name)
                self.assertEqual(Path(manifest["path"]), base / ".masc/browser-lane/host/launch")
                self.assertTrue((base / ".masc/browser-lane/host/launch.json").is_file())
                self.assertIn(f"refreshed browser lane host {name} for {base}", result.stdout)
            self.assertEqual(unrelated.read_text(), before_unrelated)
            self.assertFalse((root / "elsewhere").exists())

    def test_no_registered_host_installs_binaries_and_says_so(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            for exe in ("main_eio.exe", "masc_tui.exe", "masc_browser_host.exe"):
                executable(build / exe, exe)
            result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                                     "--prefix", str(root / "prefix"), "--manifest-dir", str(root / "absent")],
                                    check=True, capture_output=True, text=True)
            self.assertTrue((root / "prefix/masc-browser-host").is_file())
            self.assertIn("no browser lane host is registered", result.stdout)

    def test_unknown_option_is_refused_before_anything_is_installed(self):
        with tempfile.TemporaryDirectory() as temporary:
            prefix = Path(temporary) / "prefix"
            result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--prefix", str(prefix), "--bogus"],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("unknown option: --bogus", result.stderr)
            self.assertFalse(prefix.exists())


if __name__ == "__main__":
    unittest.main()
