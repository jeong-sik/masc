#!/usr/bin/env python3
"""Exercise the installed setup command against a workspace-bound HTTP peer.

Model inference and guest execution are measured separately with the real
onboarding acceptance; this checks ownership and preserves the imp manifest.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = None


@unittest.skipUnless(BINARY, 'pass --binary for native setup checks')
class Setup(unittest.TestCase):
    def scenario(self, foreign=False, missing_key=False, stale_token=False):
        with tempfile.TemporaryDirectory(prefix='masc-setup-') as tmp:
            base = Path(tmp)
            commands = base / 'commands'
            commands.mkdir()
            docker = commands / 'docker'
            docker.write_text('#!/bin/sh\nexit 0\n')
            docker.chmod(0o755)
            env = {key: value for key, value in os.environ.items()
                   if key in ('PATH', 'HOME', 'LANG', 'TMPDIR')}
            env['PATH'] = str(commands) + os.pathsep + env['PATH']
            def run(*args):
                return subprocess.run([BINARY, *args, '--base-path', str(base)],
                                      env=env, text=True, capture_output=True, timeout=30)
            initialized = run('init')
            self.assertEqual(initialized.returncode, 0, initialized.stderr)
            config = base / '.masc/config'
            for name in ('runtime.toml', 'agent-core-models-overlay.toml'):
                (config / name).write_bytes((ROOT / 'scripts/fixtures/release-evidence' / name).read_bytes())
            if missing_key:
                runtime = config / 'runtime.toml'
                runtime.write_text(runtime.read_text() + '\n[providers.ollama_cloud.credentials]\ntype = "env"\nkey = "MASC_SETUP_TEST_KEY"\n')
            manifest = config / 'keepers/imp.toml'
            original = manifest.read_bytes()
            if stale_token:
                token = base / '.masc/auth/local-admin.token'
                token.parent.mkdir(parents=True, exist_ok=True)
                token.write_text('revoked-operator-token')
            posted = []
            class Handler(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    self.send({'paths': {'effective_base_path': str(base.parent if foreign else base)},
                               'startup': {'state_ready': True}})
                def do_POST(self):
                    token = base / '.masc/auth/local-admin.token'
                    expected = token.read_text().strip() if token.exists() else ''
                    if not expected or expected == 'revoked-operator-token' or self.headers.get('Authorization') != 'Bearer ' + expected:
                        self.send_response(401)
                        self.end_headers()
                        return
                    posted.append((self.path, json.loads(self.rfile.read(int(self.headers['Content-Length'])))))
                    self.send({'ok': True, 'action': 'up', 'name': 'imp',
                               'detail': {'name': 'imp'}})
                def send(self, body):
                    data = json.dumps(body).encode()
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                def log_message(self, *args):
                    pass
            with http.server.HTTPServer(('127.0.0.1', 0), Handler) as server:
                thread = threading.Thread(target=server.serve_forever)
                thread.start()
                try:
                    result = run('setup', '--no-tui', '--port', str(server.server_port))
                finally:
                    server.shutdown()
                    thread.join()
            self.assertEqual(manifest.read_bytes(), original)
            if foreign or missing_key:
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(posted, [])
                self.assertFalse((base / '.masc/auth/local-admin.token').exists())
                self.assertIn('MASC_SETUP_TEST_KEY' if missing_key else 'Port belongs to workspace', result.stderr)
            else:
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(posted, [('/api/v1/keepers/imp/boot', {'name': 'imp'})])
                self.assertIn('Model replies are verified by your first conversation', result.stdout)
                self.assertNotIn((base / '.masc/auth/local-admin.token').read_text().strip(), result.stdout)

    def test_preserves_default_imp_and_starts_by_name(self):
        self.scenario()

    def test_refuses_another_workspace_before_minting_or_starting(self):
        self.scenario(foreign=True)

    def test_recovers_a_revoked_operator_token(self):
        self.scenario(stale_token=True)

    def test_missing_model_key_has_actionable_error(self):
        self.scenario(missing_key=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True)
    args, remaining = parser.parse_known_args()
    BINARY = str(Path(args.binary).resolve())
    Setup.__unittest_skip__ = False
    unittest.main(argv=[__file__, *remaining])
