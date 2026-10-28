import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "masc-keeper-output.py"


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.server.requests.append((self.path, self.headers.get("Authorization"), self.headers.get("X-MASC-Agent")))
        keeper = self.path.rsplit("/", 1)[-1]
        events = [
            {"type": "snapshot", "keeper": keeper, "first_retained_seq": 7, "active_count": 1, "closed": False,
             "lines": [{"seq": 7, "stream_id": 4, "task_id": "task-a", "stream": "cmd", "text": "echo hello"}]},
            {"type": "line", "keeper": keeper, "line": {"seq": 8, "stream_id": 4, "task_id": "task-a", "stream": "stdout", "text": "hi\u001b[2J"}},
            {"type": "gap", "keeper": keeper, "missing_from_seq": 9, "missing_to_seq": 10},
            {"type": "task_closed", "keeper": keeper, "stream_id": 4, "active_count": 0, "status": {"outcome": "unknown"}},
        ]
        body = "".join("event: output\ndata: " + json.dumps(event) + "\n\n" for event in events).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class WatchCliTest(unittest.TestCase):
    def test_multiple_keepers_and_private_log(self):
        with tempfile.TemporaryDirectory() as directory:
            server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
            server.requests = []
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                logfile = Path(directory) / "keeper-output.jsonl"
                env = dict(os.environ, MASC_TOKEN="fixture-token")
                result = subprocess.run(
                    [sys.executable, str(SCRIPT), "--server", f"http://127.0.0.1:{server.server_port}",
                     "--agent", "fixture-operator", "--jsonl", str(logfile), "--no-reconnect", "wkbl-data", "wkbl-front"],
                    capture_output=True, text=True, timeout=10, env=env,
                )
            finally:
                server.shutdown()
                server.server_close()
                thread.join()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(server.requests), 2)
            self.assertTrue(all(auth == "Bearer fixture-token" and agent == "fixture-operator" for _, auth, agent in server.requests))
            self.assertIn("echo hello", result.stdout)
            self.assertIn("missing output events 9–10", result.stdout)
            self.assertIn('"outcome":"unknown"', result.stdout)
            self.assertIn("before seq 7", result.stdout)
            self.assertNotIn("\x1b", result.stdout)
            self.assertNotIn("fixture-token", result.stdout)
            records = [json.loads(line) for line in logfile.read_text().splitlines()]
            self.assertEqual(len(records), 8)
            self.assertEqual({record["keeper"] for record in records}, {"wkbl-data", "wkbl-front"})
            self.assertEqual(stat.S_IMODE(logfile.stat().st_mode), 0o600)

    def test_rejects_shared_log_file(self):
        with tempfile.TemporaryDirectory() as directory:
            logfile = Path(directory) / "shared.jsonl"
            logfile.write_text("")
            logfile.chmod(0o644)
            result = subprocess.run([sys.executable, str(SCRIPT), "--server", "http://127.0.0.1:1", "--jsonl", str(logfile), "alpha"], capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("private regular file", result.stderr)


if __name__ == "__main__":
    unittest.main()
