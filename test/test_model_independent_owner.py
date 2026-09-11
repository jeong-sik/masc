#!/usr/bin/env python3
"""Native owner/settings boot without a usable model. No provider or guest calls."""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import unittest
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

BINARY = None

class OwnerWithoutModel(unittest.TestCase):
    def test_owner_auth_and_settings_survive_missing_or_invalid_runtime(self):
        for contents, reason in [(None, 'config_missing'), ('[runtime]\ndefault = "missing.model"\n', 'config_invalid'), ('seed_without_lanes', None)]:
            with self.subTest(reason=reason), tempfile.TemporaryDirectory(prefix='masc-owner-no-model-') as tmp:
                base = Path(tmp)
                env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': tmp,
                       'MASC_CONFIG_BOOTSTRAP': 'skip', 'MASC_KEEPER_AUTONOMOUS_ENABLED': 'false'}
                subprocess.run([BINARY, 'init', '--base-path', tmp], env=env, check=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=30)
                runtime = base/'.masc/config/runtime.toml'
                kept, skip = [], False
                for line in runtime.read_text().splitlines(keepends=True):
                    if line.lstrip().startswith('['):
                        skip = line.lstrip().startswith('[runtime.exact_output_lanes.')
                    if not skip: kept.append(line)
                seed_without_lanes = ''.join(kept)
                if contents == 'seed_without_lanes': contents = seed_without_lanes
                if contents is None: runtime.unlink()
                else: runtime.write_text(contents)
                with socket.socket() as sock:
                    sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
                url = f'http://127.0.0.1:{port}'
                def get(path, headers=None):
                    try:
                        with urlopen(Request(url+path, headers=headers or {}), timeout=2) as response:
                            return response.status, json.load(response)
                    except HTTPError as error:
                        return error.code, None
                with (base/'server.log').open('wb') as log:
                    process = subprocess.Popen([BINARY, 'start', '--base-path', tmp, '--port', str(port)],
                                               env=env, stdout=log, stderr=log, start_new_session=True)
                    try:
                        deadline = time.monotonic()+60
                        while True:
                            self.assertIsNone(process.poll(), 'owner server exited before settings became available')
                            try:
                                status, health = get('/health?full=1')
                                if status == 200 and health.get('startup', {}).get('state_ready'):
                                    break
                            except (URLError, TimeoutError, OSError):
                                pass
                            self.assertLess(time.monotonic(), deadline, 'owner readiness deadline exceeded')
                            time.sleep(.1)
                        observation = health['startup']['model_runtime']
                        self.assertEqual(observation['status'], 'setup_required' if reason else 'available')
                        self.assertEqual(observation['reason'], reason)
                        self.assertIn(get('/api/v1/runtime/config/raw')[0], (401, 403))
                        subprocess.run([BINARY, 'login', '--base-path', tmp, '--port', str(port),
                                        '--agent', 'local-admin', '--role', 'admin',
                                        '--client-env', 'FIXTURE_MASC_TOKEN'],
                                       env=env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=30)
                        token = (base/'.masc/auth/local-admin.token').read_text().strip()
                        status, _ = get('/api/v1/runtime/config/raw', {'Authorization': 'Bearer '+token,
                                                                    'X-MASC-Agent': 'local-admin'})
                        self.assertEqual(status, 404 if contents is None else 200)
                        if reason:
                            request = Request(url+'/api/v1/keepers/imp/boot', data=b'{}',
                                              headers={'Authorization': 'Bearer '+token, 'X-MASC-Agent': 'local-admin',
                                                       'Content-Type': 'application/json'})
                            with self.assertRaises(HTTPError) as rejected:
                                urlopen(request, timeout=5)
                            self.assertEqual(rejected.exception.code, 503)
                            self.assertIn('setup required', rejected.exception.read().decode())
                        self.assertFalse((base/'.masc/keepers/imp.json').exists())
                        self.assertEqual(runtime.read_text() if runtime.exists() else None, contents)
                        with self.assertRaises(HTTPError) as rejected:
                            urlopen(Request(url+'/api/v1/runtime/setup/resume', data=b'{}'), timeout=5)
                        self.assertIn(rejected.exception.code, (401, 403))
                        # Model settings are saved by another process, exactly as the CLI
                        # wizard does. Resume must affect this same existing owner.
                        runtime.write_text(seed_without_lanes)
                        for _ in range(2):
                            request = Request(url+'/api/v1/runtime/setup/resume', data=b'{}',
                                              headers={'Authorization': 'Bearer '+token, 'X-MASC-Agent': 'local-admin',
                                                       'Content-Type': 'application/json'})
                            with urlopen(request, timeout=10) as response: resumed = json.load(response)
                            self.assertTrue(resumed['runtime_ready'])
                            self.assertFalse(resumed['exact_output_authority_available'])
                            self.assertEqual(resumed['model_setup']['status'], 'available')
                        self.assertIsNone(process.poll(), 'resume must preserve the running workspace owner')
                        self.assertEqual((base/'.masc/auth/local-admin.token').read_text().strip(), token)
                        self.assertEqual(get('/health?full=1')[1]['startup']['model_runtime']['status'], 'available')
                    finally:
                        if process.poll() is None:
                            os.killpg(process.pid, signal.SIGTERM)
                            try: process.wait(timeout=10)
                            except subprocess.TimeoutExpired:
                                os.killpg(process.pid, signal.SIGKILL); process.wait(timeout=5)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--binary', required=True)
    args, extra = parser.parse_known_args(); BINARY = str(Path(args.binary).resolve())
    unittest.main(argv=[__file__]+extra)
