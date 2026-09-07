#!/usr/bin/env python3
"""Executable installation survives removal of its source checkout."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

INSTALLER = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "connectors/browser/install-host.sh"


class Installation(unittest.TestCase):
    def test_durable_paths_and_token_preservation(self):
        with tempfile.TemporaryDirectory(prefix="browser host ' ") as temporary:
            root = Path(temporary).resolve()
            source = root / "scratch-host"
            source.write_text("#!/bin/sh\nprintf '%s\\n' \"$@\"\n")
            source.chmod(0o755)
            base = root / "workspace"
            manifests = root / "native manifests"
            argv = ["bash", str(INSTALLER), "--binary", str(source), "--base-path", str(base), "--server", "http://127.0.0.1:18935", "--manifest-dir", str(manifests)]
            subprocess.run(argv, check=True, capture_output=True)
            token = base / ".masc/browser-lane/token"
            original = token.read_text()
            self.assertEqual(token.stat().st_mode & 0o777, 0o600)
            subprocess.run(argv, check=True, capture_output=True)
            self.assertEqual(token.read_text(), original)
            source.unlink()
            manifest = json.loads((manifests / "masc_browser_host.json").read_text())
            launcher = Path(manifest["path"])
            self.assertNotIn(original.strip(), launcher.read_text())
            result = subprocess.run([str(launcher), str(manifests / "masc_browser_host.json"), "browser-lane@masc.local"], check=True, capture_output=True, text=True)
            self.assertEqual(result.stdout.splitlines(), ["--base-path", str(base), "--token-file", str(token), "--server", "http://127.0.0.1:18935", str(manifests / "masc_browser_host.json"), "browser-lane@masc.local"])

    def test_missing_base_path_is_explicit(self):
        env = {k: v for k, v in os.environ.items() if k != "MASC_BASE_PATH"}
        result = subprocess.run(["bash", str(INSTALLER), "--binary", "/bin/true"], env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--base-path or MASC_BASE_PATH is required", result.stderr)

    def test_custom_token_is_provisioned_and_matches_server(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            base = root / "workspace"
            token = root / "provisioned-token"
            argv = ["bash", str(INSTALLER), "--binary", shutil.which("true"), "--base-path", str(base), "--manifest-dir", str(root / "manifests"), "--token-file", str(token)]
            missing = subprocess.run(argv, capture_output=True, text=True)
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("existing provisioned lane token", missing.stderr)
            self.assertFalse((base / ".masc/browser-lane/token").exists())
            token.write_text("provisioned-browser-lane-test-token\n")
            subprocess.run(argv, check=True, capture_output=True)
            canonical = base / ".masc/browser-lane/token"
            self.assertEqual(canonical.read_text(), token.read_text())
            token.write_text("different-browser-lane-test-token\n")
            mismatched = subprocess.run(argv, capture_output=True, text=True)
            self.assertNotEqual(mismatched.returncode, 0)
            self.assertIn("does not match", mismatched.stderr)
            self.assertEqual(canonical.read_text(), "provisioned-browser-lane-test-token\n")


if __name__ == "__main__":
    unittest.main()
