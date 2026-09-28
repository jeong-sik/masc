import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import runpy
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "check-installed-dashboard.py"


class DashboardMismatchDiagnostics(unittest.TestCase):
    def test_mismatch_prints_response_evidence_and_keeps_failing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            release = root / "release"
            release.mkdir()
            binary = release / "masc"
            binary.write_bytes(b"installed binary")
            served = b"<html>unexpected dashboard body</html>"
            expected = b"<html>packaged dashboard body</html>"
            receipt = {
                "source_commit": "a" * 40,
                "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                "files": [
                    {"path": "index.html", "size": len(expected),
                     "sha256": hashlib.sha256(expected).hexdigest()}
                ],
            }
            receipt_bytes = json.dumps(receipt).encode()
            (release / "release.json").write_bytes(receipt_bytes)
            health = {
                "build": {"binary_commit": receipt["source_commit"],
                          "executable_path": str(binary)},
                "dashboard_surface": {
                    "installed_release": {
                        "kind": "installed_release",
                        "status": "verified",
                        "release_root": str(release),
                        "receipt_sha256": hashlib.sha256(receipt_bytes).hexdigest(),
                    }
                },
            }

            class Response:
                def __init__(self, body, status, headers):
                    self.body = body
                    self.status = status
                    self.headers = headers

                def __enter__(self):
                    return self

                def __exit__(self, *_):
                    return False

                def read(self):
                    return self.body

            responses = [
                Response(json.dumps(health).encode(), 200, {}),
                Response(served, 200, {"Content-Type": "text/html",
                                      "X-Dashboard-Generation": "fixture-7"}),
            ]
            stderr = io.StringIO()
            with patch("urllib.request.urlopen", side_effect=responses) as urlopen, \
                 patch.object(sys, "argv", ["check-installed-dashboard.py",
                                            "--binary", str(binary),
                                            "--base-url", "http://fixture"]), \
                 patch.object(Path, "cwd", return_value=root), \
                 contextlib.redirect_stderr(stderr):
                with self.assertRaisesRegex(SystemExit,
                                            "served dashboard index differs from installed bundle"):
                    runpy.run_path(str(SCRIPT), run_name="__main__")

            diagnostic = stderr.getvalue()
            self.assertIn("HTTP status: 200", diagnostic)
            self.assertIn('"X-Dashboard-Generation": "fixture-7"', diagnostic)
            self.assertIn(f"served body: length={len(served)} sha256={hashlib.sha256(served).hexdigest()}",
                          diagnostic)
            self.assertIn(f"expected body: length={len(expected)} sha256={hashlib.sha256(expected).hexdigest()}",
                          diagnostic)
            self.assertIn(f"served body first 200 bytes: {served[:200]!r}", diagnostic)
            self.assertEqual(urlopen.call_count, 2)


if __name__ == "__main__":
    unittest.main()
