"""CLI must return after a keep-alive HTTP response, on success and refusal.

Run with an already-built masc binary; no model or daemon. The only workspace
is a temporary one that masc login signs in, as an operator does.
Usage: python3 test/test_keeper_create_cli_exit.py /path/to/masc
"""
import contextlib
import http.server
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest

BINARY = str(Path(sys.argv.pop(1)).resolve())

# cmdliner's exit status for a command line it could not parse.
CLI_ERROR = 124


@contextlib.contextmanager
def fixture_server(status, body):
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
        yield server.server_port, received
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def keeper_create(base, port, *extra):
    return subprocess.run(
        [BINARY, 'keeper-create', '--base-path', base, '--host', '127.0.0.1',
         '--port', str(port), '--name', 'fixture', '--network-mode', 'none',
         '--instructions', 'Read the fixture.', *extra],
        text=True, capture_output=True, timeout=15)


class KeeperCreateExitTest(unittest.TestCase):
    def login(self, base):
        """Sign the workspace in with masc login's defaults and return the
        bearer it persisted, which keeper-create has to present."""
        result = subprocess.run(
            [BINARY, 'login', '--base-path', base, '--client-env', 'MASC_TOKEN', '--json'],
            text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)['bearer_token']

    def exercise(self, status, body, expected_text, backend=None):
        with fixture_server(status, body) as (port, received):
            with tempfile.TemporaryDirectory() as base:
                bearer = self.login(base)
                result = keeper_create(
                    base, port, '--sandbox-profile', 'microvm' if backend else 'docker',
                    *(['--microvm-backend', backend] if backend else []))
        self.assertEqual(result.returncode == 0, status == 200, result.stdout + result.stderr)
        self.assertIn(expected_text, result.stdout + result.stderr)
        self.assertEqual(len(received), 1)
        self.assertEqual(received[0][0], '/api/v1/keepers/fixture/up')
        self.assertTrue(received[0][1] == 'Bearer ' + bearer,
                        'the request did not present the bearer masc login persisted')
        self.assertEqual(received[0][2]['name'], 'fixture')
        self.assertEqual(received[0][2].get('microvm_backend'), backend)

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

    def test_bearer_on_the_command_line_is_refused_before_any_request(self):
        # A value in argv shows in ps and shell history, so the bearer comes
        # only from what masc login persisted. An option that took one would
        # send this request; cmdliner refuses the unknown option instead.
        with fixture_server(200, {'name': 'fixture'}) as (port, received):
            with tempfile.TemporaryDirectory() as base:
                result = keeper_create(base, port, '--sandbox-profile', 'docker',
                                       '--token', 'fixture-token')
        self.assertEqual(result.returncode, CLI_ERROR, result.stdout + result.stderr)
        self.assertIn("unknown option '--token'", result.stderr)
        self.assertNotIn('fixture-token', result.stdout + result.stderr)
        self.assertEqual(received, [])


if __name__ == '__main__':
    unittest.main()
