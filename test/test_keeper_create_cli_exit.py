"""CLI must return after a keep-alive HTTP response, on success and refusal.

Run with an already-built masc binary; no model, daemon, or workspace mutation.
Usage: python3 test/test_keeper_create_cli_exit.py /path/to/masc
"""
import http.server
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest

BINARY = str(Path(sys.argv.pop(1)).resolve())


class KeeperCreateExitTest(unittest.TestCase):
    def exercise(self, status, body, expected_text, backend=None):
        received = []

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def do_POST(self):
                request = self.rfile.read(int(self.headers['Content-Length']))
                received.append((self.path, self.headers.get('Authorization'), json.loads(request)))
                payload = json.dumps(body).encode()
                self.send_response(status)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(payload)))
                # Leave the connection alive: client scope must close it before
                # joining its switch; waiting for server EOF masks the bug.
                self.send_header('Connection', 'keep-alive')
                self.end_headers()
                self.wfile.write(payload)
                self.wfile.flush()

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as base:
                result = subprocess.run(
                    [BINARY, 'keeper-create', '--base-path', base, '--host', '127.0.0.1',
                     '--port', str(server.server_port), '--token', 'fixture-token',
                     '--name', 'fixture', '--sandbox-profile', 'microvm' if backend else 'docker',
                     '--network-mode', 'none', '--instructions', 'Read the fixture.']
                    + (['--microvm-backend', backend] if backend else []),
                    text=True, capture_output=True, timeout=15)
            self.assertEqual(result.returncode == 0, status == 200, result.stdout + result.stderr)
            self.assertIn(expected_text, result.stdout + result.stderr)
            self.assertEqual(len(received), 1)
            self.assertEqual(received[0][0], '/api/v1/keepers/fixture/up')
            self.assertEqual(received[0][1], 'Bearer fixture-token')
            self.assertEqual(received[0][2]['name'], 'fixture')
            self.assertEqual(received[0][2].get('microvm_backend'), backend)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_success_response_exits_with_idle_connection(self):
        self.exercise(200, {'name': 'fixture'}, 'already existed')

    def test_explicit_linux_backend_reaches_server(self):
        self.exercise(200, {'name': 'fixture'}, 'already existed', backend='nerdctl_kata')

    def test_backend_flag_conflicts_with_editor(self):
        with tempfile.TemporaryDirectory() as base:
            result = subprocess.run([BINARY, 'keeper-create', '--base-path', base, '--edit',
                                     '--microvm-backend', 'nerdctl_kata'],
                                    text=True, capture_output=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('cannot be combined', result.stderr)

    def test_unauthorized_response_exits_with_idle_connection(self):
        self.exercise(401, {'error': 'fixture refusal'}, 'fixture refusal')


if __name__ == '__main__':
    unittest.main()
