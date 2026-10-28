import json
import os
from pathlib import Path
import shutil
import ssl
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
             "active_streams": [{"stream_id": 4, "task_id": "task-a", "command": "echo hello"}],
             "lines": [{"seq": 7, "stream_id": 4, "task_id": "task-a", "stream": "stdout", "text": "already running"}]},
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


class RedirectFixture(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.server.requests.append((self.path, self.headers.get("Authorization"), self.headers.get("X-MASC-Agent")))
        self.send_response(self.server.redirect_code)
        self.send_header("Location", self.server.redirect_target)
        self.send_header("Content-Length", "0")
        self.end_headers()


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
            self.assertIn("already running", result.stdout)
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

    def test_redirects_never_forward_credentials_to_another_origin(self):
        destination = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
        destination.requests = []
        origin = ThreadingHTTPServer(("127.0.0.1", 0), RedirectFixture)
        origin.requests = []
        origin.redirect_target = f"http://127.0.0.1:{destination.server_port}/target"
        threads = [threading.Thread(target=server.serve_forever, daemon=True) for server in (origin, destination)]
        for thread in threads:
            thread.start()
        try:
            for code in (301, 302, 303, 307, 308):
                with self.subTest(code=code):
                    origin.redirect_code = code
                    result = subprocess.run(
                        [sys.executable, str(SCRIPT), "--server", f"http://127.0.0.1:{origin.server_port}",
                         "--agent", "fixture-operator", "--no-reconnect", "alpha"],
                        capture_output=True, text=True, timeout=5,
                        env=dict(os.environ, MASC_TOKEN="fixture-token"),
                    )
                    self.assertEqual(result.returncode, 1)
                    self.assertIn("redirects are not followed", result.stdout)
                    self.assertNotIn("fixture-token", result.stdout)
                    self.assertEqual(destination.requests, [])
            self.assertEqual(len(origin.requests), 5)
            self.assertTrue(all(auth == "Bearer fixture-token" and agent == "fixture-operator"
                                for _, auth, agent in origin.requests))
        finally:
            for server in (origin, destination):
                server.shutdown()
                server.server_close()
            for thread in threads:
                thread.join()

    def test_https_to_http_redirect_is_rejected_before_contacting_destination(self):
        openssl = shutil.which("openssl")
        if openssl is None:
            self.skipTest("openssl is needed to make a local HTTPS fixture")
        with tempfile.TemporaryDirectory() as directory:
            certificate = Path(directory) / "fixture.pem"
            key = Path(directory) / "fixture-key.pem"
            generated = subprocess.run(
                [openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key),
                 "-out", str(certificate), "-days", "1", "-subj", "/CN=localhost",
                 "-addext", "subjectAltName=IP:127.0.0.1"],
                capture_output=True, timeout=10,
            )
            if generated.returncode != 0:
                self.skipTest("openssl cannot make the HTTPS fixture certificate")
            destination = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
            destination.requests = []
            origin = ThreadingHTTPServer(("127.0.0.1", 0), RedirectFixture)
            origin.requests = []
            origin.redirect_code = 302
            origin.redirect_target = f"http://127.0.0.1:{destination.server_port}/target"
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(certificate, key)
            origin.socket = context.wrap_socket(origin.socket, server_side=True)
            threads = [threading.Thread(target=server.serve_forever, daemon=True) for server in (origin, destination)]
            for thread in threads:
                thread.start()
            try:
                result = subprocess.run(
                    [sys.executable, str(SCRIPT), "--server", f"https://127.0.0.1:{origin.server_port}",
                     "--agent", "fixture-operator", "--no-reconnect", "alpha"],
                    capture_output=True, text=True, timeout=5,
                    env=dict(os.environ, MASC_TOKEN="fixture-token", SSL_CERT_FILE=str(certificate)),
                )
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("redirects are not followed", result.stdout)
                self.assertEqual(len(origin.requests), 1)
                self.assertEqual(origin.requests[0][1], "Bearer fixture-token")
                self.assertEqual(destination.requests, [])
            finally:
                for server in (origin, destination):
                    server.shutdown()
                    server.server_close()
                for thread in threads:
                    thread.join()


if __name__ == "__main__":
    unittest.main()
