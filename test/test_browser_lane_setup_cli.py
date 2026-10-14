#!/usr/bin/env python3
"""`masc browser-lane-setup`, run as the install script and the docs run it.

test_browser_lane_setup.ml proves the library; this runs the real executable,
so a flag that is renamed, a mode that is dropped or an argument that is not
passed on fails here. Every case works in a scratch workspace and a scratch
manifest directory under a scratch HOME.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

MASC = Path(sys.argv.pop(1)).resolve()
HOST = Path(sys.argv.pop(1)).resolve()
EXTENSION_ID = "browser-lane@masc.local"


def masc(root, *args):
    environment = {"HOME": str(root / "home"), "PATH": "/usr/bin:/bin"}
    return subprocess.run([str(MASC), "browser-lane-setup", *args], env=environment,
                          capture_output=True, text=True)


def lane(base):
    return base / ".masc/browser-lane"


class BrowserLaneSetupCommand(unittest.TestCase):
    def scratch(self):
        temporary = tempfile.TemporaryDirectory(prefix="lane cli ' ")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name).resolve()
        (root / "home").mkdir()
        return root

    # The flags install-local-build.sh passes, and the ones the docs show.
    def test_install_with_the_flags_the_script_and_the_docs_use(self):
        root = self.scratch()
        base, manifests = root / "workspace ' one", root / "native manifests"
        token = root / "provisioned-token"
        token.write_text("provisioned-browser-lane-test-token\n")
        result = masc(root, "--mode", "extension", "--binary", str(HOST), "--base-path", str(base),
                      "--host-name", "masc.cli_test", "--manifest-dir", str(manifests),
                      "--token-file", str(token))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((lane(base) / "host/masc-browser-host").read_bytes(), HOST.read_bytes())
        self.assertEqual(os.stat(lane(base) / "host/launch").st_mode & 0o777, 0o755)
        self.assertEqual((lane(base) / "token").read_text(), token.read_text())
        self.assertEqual(os.stat(lane(base) / "token").st_mode & 0o777, 0o600)
        for name in ("manifest.json", "background.js"):
            self.assertTrue((lane(base) / "extension" / name).is_file(), name)
        registration = json.loads((manifests / "masc.cli_test.json").read_text())
        self.assertEqual(registration["name"], "masc.cli_test")
        self.assertEqual(registration["path"], str(lane(base) / "host/launch"))
        self.assertEqual(registration["allowed_extensions"], [EXTENSION_ID])
        # What the operator is told to load is the file that was written.
        self.assertIn(str(lane(base) / "extension/manifest.json"), result.stdout)

    def test_without_a_mode_nothing_is_written_and_the_state_is_printed(self):
        root = self.scratch()
        base = root / "workspace"
        before = masc(root, "--base-path", str(base))
        self.assertEqual(before.returncode, 0, before.stderr)
        self.assertIn("masc browser-lane-setup --mode extension --base-path", before.stdout)
        self.assertFalse(base.exists())
        installed = masc(root, "--mode", "extension", "--binary", str(HOST), "--base-path", str(base),
                         "--manifest-dir", str(root / "manifests"))
        self.assertEqual(installed.returncode, 0, installed.stderr)
        after = masc(root, "--base-path", str(base))
        self.assertEqual(after.returncode, 0, after.stderr)
        self.assertIn("follows the workspace connection port", after.stdout)
        self.assertNotIn("masc browser-lane-setup --mode extension", after.stdout)

    def test_installing_again_keeps_the_token(self):
        root = self.scratch()
        base = root / "workspace"
        arguments = ("--mode", "extension", "--binary", str(HOST), "--base-path", str(base),
                     "--manifest-dir", str(root / "manifests"))
        self.assertEqual(masc(root, *arguments).returncode, 0)
        token = (lane(base) / "token").read_text()
        self.assertEqual(masc(root, *arguments).returncode, 0)
        self.assertEqual((lane(base) / "token").read_text(), token)

    def test_a_refusal_exits_with_one_and_leaves_nothing_behind(self):
        root = self.scratch()
        base, manifests = root / "workspace", root / "manifests"
        short_token = root / "short-token"
        short_token.write_text("short\n")
        for label, arguments in (
            ("a host name that names a path", ("--host-name", "../owned")),
            ("a binary that is not there", ("--binary", str(root / "absent"))),
            ("a token that is too short", ("--token-file", str(short_token))),
        ):
            with self.subTest(label):
                full = {"--binary": str(HOST), "--base-path": str(base), "--manifest-dir": str(manifests)}
                full.update(dict(zip(arguments[0::2], arguments[1::2])))
                result = masc(root, "--mode", "extension",
                              *[part for item in full.items() for part in item])
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertFalse(base.exists(), "nothing was written to the workspace")
                self.assertFalse(manifests.exists(), "nothing was registered")

    def test_only_the_extension_mode_exists(self):
        root = self.scratch()
        result = masc(root, "--mode", "bidi", "--base-path", str(root / "workspace"))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((root / "workspace").exists())

    # --base-path names the workspace that holds .masc, as for every command.
    def test_a_trailing_dot_masc_in_the_workspace_path_is_dropped(self):
        root = self.scratch()
        base = root / "workspace"
        result = masc(root, "--mode", "extension", "--binary", str(HOST),
                      "--base-path", str(base / ".masc"), "--manifest-dir", str(root / "manifests"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((lane(base) / "host/launch").is_file())
        self.assertFalse((base / ".masc/.masc").exists())


if __name__ == "__main__":
    unittest.main()
