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
import urllib.error
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "check-installed-dashboard.py"


class DashboardMismatchDiagnostics(unittest.TestCase):
    def test_read_only_checks_binding_without_mutating_install_or_cwd(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            release = root / "release"
            release.mkdir()
            binary = release / "masc"
            binary.write_bytes(b"installed binary")
            index = b'<script src="/dashboard/assets/app.js"></script>'
            asset = b"actual installed script"
            digest = lambda data: hashlib.sha256(data).hexdigest()
            receipt = {"source_commit": "a" * 40,
                       "binary_sha256": digest(binary.read_bytes()),
                       "files": [{"path": name, "size": len(data), "sha256": digest(data)}
                                 for name, data in [("index.html", index), ("assets/app.js", asset)]]}
            receipt_path = release / "release.json"
            receipt_path.write_text(json.dumps(receipt))
            health = {"build": {"binary_commit": receipt["source_commit"],
                                "executable_path": str(binary)},
                      "dashboard_surface": {"status": "ok", "installed_release": {
                          "kind": "installed_release", "status": "verified",
                          "release_root": str(release.resolve()),
                          "receipt_sha256": digest(receipt_path.read_bytes())}}}
            before = {str(p.relative_to(root)): p.read_bytes() for p in root.rglob("*") if p.is_file()}

            class Response(io.BytesIO):
                status = 200
                headers = {}

            for expected_source, served_asset, error in [
                ("a" * 40, asset, None),
                ("b" * 40, asset, "installed receipt differs from expected source"),
                ("a" * 40, b"wrong asset", "served dashboard resource differs"),
            ]:
                with self.subTest(expected_source=expected_source, error=error):
                    responses = [Response(b'{"ready":true}'), Response(json.dumps(health).encode()),
                                 Response(index), Response(served_asset)]
                    stdout = io.StringIO()
                    with patch("urllib.request.urlopen", side_effect=responses) as urlopen, \
                         patch.object(sys, "argv", ["check-installed-dashboard.py", "--binary", str(binary),
                                                   "--base-url", "http://fixture",
                                                   "--expected-source", expected_source]), \
                         patch.object(Path, "cwd", return_value=root), contextlib.redirect_stdout(stdout):
                        with self.assertRaises(SystemExit) as exit_result:
                            runpy.run_path(str(SCRIPT), run_name="__main__")
                    if error is None:
                        self.assertEqual(exit_result.exception.code, 0)
                        evidence = json.loads(stdout.getvalue())
                        self.assertTrue(evidence["passed"])
                        self.assertEqual(evidence["source_commit"], receipt["source_commit"])
                        self.assertEqual(evidence["referenced_assets_checked"], 1)
                        self.assertEqual(urlopen.call_count, 4)
                    else:
                        self.assertIn(error, str(exit_result.exception))
                        self.assertEqual(stdout.getvalue(), "")
                        if expected_source != receipt["source_commit"]:
                            self.assertEqual(urlopen.call_count, 0)
                    after = {str(p.relative_to(root)): p.read_bytes() for p in root.rglob("*") if p.is_file()}
                    self.assertEqual(after, before)
                    self.assertFalse((root / "assets").exists())

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
                        "release_root": str(release.resolve()),
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
                Response(b'{"ready":true}', 200, {}),
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
            self.assertEqual(urlopen.call_count, 3)
            self.assertEqual([call.args[0] for call in urlopen.call_args_list],
                             ["http://fixture/health/ready", "http://fixture/health?full=1",
                              "http://fixture/dashboard"])

            # A healthy liveness endpoint or a truthy string/number must not
            # allow dashboard byte checks before startup publishes readiness.
            for readiness in ({"ready": False}, {"status": "ok"},
                              {"ready": "true"}, {"ready": 1}, None):
                with self.subTest(readiness=readiness), \
                     patch("urllib.request.urlopen", return_value=Response(
                         json.dumps(readiness).encode(), 200, {})) as urlopen, \
                     patch.object(sys, "argv", ["check-installed-dashboard.py",
                                                "--binary", str(binary),
                                                "--base-url", "http://fixture"]):
                    with self.assertRaisesRegex(SystemExit, "installed server is not ready"):
                        runpy.run_path(str(SCRIPT), run_name="__main__")
                    self.assertEqual(urlopen.call_count, 1)
                    self.assertEqual(urlopen.call_args.args[0], "http://fixture/health/ready")


            unavailable = urllib.error.HTTPError("http://fixture/health/ready", 503,
                                                 "Service Unavailable", {}, None)
            with patch("urllib.request.urlopen", side_effect=unavailable) as urlopen, \
                 patch.object(sys, "argv", ["check-installed-dashboard.py",
                                            "--binary", str(binary),
                                            "--base-url", "http://fixture"]):
                with self.assertRaises(urllib.error.HTTPError):
                    runpy.run_path(str(SCRIPT), run_name="__main__")
                self.assertEqual(urlopen.call_count, 1)
                self.assertEqual(urlopen.call_args.args[0], "http://fixture/health/ready")


if __name__ == "__main__":
    unittest.main()
