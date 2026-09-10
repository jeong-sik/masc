"""Exercise operator tooling against owned fixtures, not a production runtime."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from urllib.request import Request, urlopen

import fixture


ROOT = Path(__file__).resolve().parent


class OperatorHarness(unittest.TestCase):
    def exercise(self, *, fail_observation=False):
        calls = []
        state = {"phase": "attached", "seq": 1}
        rows = [{"id": "owned/1/row", "lane_id": "owned/web/revision", "kind": "relation"}]

        class Handler(BaseHTTPRequestHandler):
            def reply(self, body, status=200):
                data = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def instance(self):
                return {"instance_id": "owned", "addon_id": "web-project",
                        "phase": {"kind": state["phase"]}, "observation_seq": state["seq"],
                        "container_id": "a" * 64}

            def do_GET(self):
                calls.append(("GET", self.path))
                if self.path.startswith("/health"):
                    return self.reply({"status": "ok", "fixture": True})
                if self.path.startswith("/api/v1/lane-addons/slice?"):
                    return self.reply({"rows": rows, "coverage": []})
                if self.path.startswith("/api/v1/lane-addons?"):
                    return self.reply({"instances": [self.instance()], "rows": rows, "coverage": []})
                self.reply({"error": "unexpected endpoint"}, 404)

            def do_POST(self):
                calls.append(("POST", self.path))
                self.assert_auth = self.headers.get("Authorization")
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                if self.assert_auth != "Bearer private-fixture-token":
                    return self.reply({"error": "missing auth"}, 401)
                if self.path == "/api/v1/lane-addons/attach":
                    if fail_observation:
                        state["phase"], state["seq"] = "failed", 0
                    return self.reply(self.instance())
                if self.path == "/api/v1/lane-addons/observe":
                    state["seq"] += 1
                    return self.reply(self.instance())
                if self.path == "/api/v1/lane-addons/detach":
                    state["phase"] = "detached"
                    return self.reply(self.instance())
                if self.path == "/api/v1/lane-addons/evidence":
                    assert "keeper_name" not in body, "default tooling must not contact a Keeper"
                    return self.reply({"evidence": {"uri": "lane-evidence:" + "b" * 64,
                                                   "sha256": "b" * 64}, "row_count": 1})
                self.reply({"error": "unexpected endpoint"}, 404)

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as directory:
                base = Path(directory)
                binding = base / "binding.json"
                binding.write_text('{"sources":[]}')
                token = base / "token"
                token.write_text("private-fixture-token\n")
                result = subprocess.run([sys.executable, str(ROOT / "qualify.py"),
                    "--base-url", f"http://127.0.0.1:{server.server_port}",
                    "--manifest", str(base / "server-package/lane.toml"), "--binding", str(binding),
                    "--output-dir", str(base / "measurements"), "--token-file", str(token),
                    "--health-samples", "2", "--health-interval", ".01", "--poll-interval", ".01",
                    "--http-timeout", "1", "--wait-seconds", "1"],
                    text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 1 if fail_observation else 0, result.stderr + result.stdout)
                summary = json.loads((base / "measurements/summary.json").read_text())
                self.assertFalse(summary["full_v0_qualification"])
                self.assertTrue(summary["instances"][0]["detached"])
                self.assertEqual(summary["status"], "incomplete" if fail_observation else "measurements_collected")
                self.assertEqual(summary["health_latency"]["baseline"]["samples"], 2)
                self.assertNotIn("private-fixture-token", result.stdout + result.stderr)
                for file in (base / "measurements").iterdir():
                    self.assertNotIn(b"private-fixture-token", file.read_bytes())
                self.assertTrue(all(path.startswith(("/health", "/api/v1/lane-addons")) for _, path in calls))
                self.assertIn(("POST", "/api/v1/lane-addons/detach"), calls)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_records_real_http_lifecycle_and_preserves_partial_status(self):
        self.exercise()

    def test_failed_observer_still_detaches_owned_instance(self):
        self.exercise(fail_observation=True)

    def test_owned_fixture_changes_atomically_and_labels_http_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            state = fixture.State(Path(directory), "namespace", "A", "B")
            server = fixture.make_server(state, "127.0.0.1", 0)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base = f"http://127.0.0.1:{server.server_port}"
            try:
                with urlopen(base + "/") as response:
                    initial = response.read().decode()
                self.assertIn('name="masc-revision" content="B"', initial)
                with urlopen(Request(base + "/state", method="POST",
                    data=b'{"revision":"A","feature_ok":true}', headers={"Content-Type": "application/json"})) as response:
                    self.assertEqual(json.load(response)["revision"], "A")
                with urlopen(base + "/") as response:
                    corrected = response.read()
                self.assertEqual(corrected, (Path(directory) / "expected.html").read_bytes())
                with urlopen(base + "/probe") as response:
                    probe = json.load(response)
                self.assertTrue(probe["feature_ok"])
                self.assertIn("no browser", probe["evidence_scope"])
                self.assertNotIn("document_id", probe)
            finally:
                server.shutdown()
                server.server_close()
                thread.join()


if __name__ == "__main__":
    unittest.main()
