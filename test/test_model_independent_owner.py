#!/usr/bin/env python3
"""Native owner/settings boot without a usable model. No provider or guest calls."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import tempfile
import time
import unittest
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

BINARY = None


def runtime_without_exact_output_lanes(text):
    kept, skip, removed_lanes = [], False, 0
    for line in text.splitlines(keepends=True):
        if line.lstrip().startswith('['):
            skip = line.lstrip().startswith('[runtime.exact_output_lanes')
            if skip:
                removed_lanes += 1
        if not skip:
            kept.append(line)
    if removed_lanes == 0:
        raise AssertionError(
            'runtime fixture no longer declares an exact-output lane section; '
            'update test/test_model_independent_owner.py together with '
            'scripts/fixtures/release-evidence/runtime.toml.'
        )
    return ''.join(kept)


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
                seed_without_lanes = runtime_without_exact_output_lanes(runtime.read_text())
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
                        if reason == 'config_invalid':
                            # The operator must see which binding is wrong, not only that one is.
                            self.assertIn('missing.model', observation['message'])
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
                        for attempt in range(2):
                            if attempt == 0:
                                # Same native command invoked by setup after local login.
                                result = subprocess.run([BINARY, 'runtime-resume', '--base-path', tmp,
                                                         '--port', str(port)], env=env,
                                                        capture_output=True, text=True, timeout=30)
                                self.assertEqual(result.returncode, 0, result.stderr)
                                self.assertNotIn(token, result.stdout + result.stderr)
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

    # `masc restart` finds the server it stops, and the replacement it waits
    # for, by what the kernel says: the owner of the workspace lease that
    # announces the port. A real server announces as it boots, so the old one
    # is asked to stop and the new one is reported ready.
    def test_restart_replaces_a_real_server(self):
        with tempfile.TemporaryDirectory(prefix='masc-owner-restart-') as tmp:
            base = Path(tmp)
            env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': tmp,
                   'MASC_CONFIG_BOOTSTRAP': 'skip', 'MASC_KEEPER_AUTONOMOUS_ENABLED': 'false'}
            subprocess.run([BINARY, 'init', '--base-path', tmp], env=env, check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=30)
            runtime = base/'.masc/config/runtime.toml'
            runtime.write_text(runtime_without_exact_output_lanes(runtime.read_text()))
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]

            def ready():
                try:
                    with urlopen(f'http://127.0.0.1:{port}/health/ready', timeout=2) as response:
                        return response.status == 200
                except (HTTPError, URLError, TimeoutError, OSError):
                    return False

            def gone(pid):
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    return True
                return False

            # The replacement is not a child of this process. Restart prints
            # its pid before it waits, so the pid is read from that output
            # whether restart returned or was given up on.
            said = base/'restart.out'

            def replacement():
                started = re.search(r'Started pid (\d+)', said.read_text() if said.exists() else '')
                return int(started.group(1)) if started else None

            with (base/'server.log').open('wb') as log:
                process = subprocess.Popen([BINARY, 'start', '--base-path', tmp, '--port', str(port)],
                                           env=env, stdout=log, stderr=log, start_new_session=True)
                try:
                    deadline = time.monotonic()+60
                    while not ready():
                        self.assertIsNone(process.poll(), 'the server exited before it was ready')
                        self.assertLess(time.monotonic(), deadline, 'readiness deadline exceeded')
                        time.sleep(.1)
                    with said.open('wb') as out:
                        result = subprocess.run([BINARY, 'restart', '--base-path', tmp, '--port', str(port)],
                                                env=env, stdout=out, stderr=subprocess.PIPE, text=True,
                                                timeout=120, stdin=subprocess.DEVNULL)
                    printed = said.read_text()
                    self.assertEqual(result.returncode, 0, printed + result.stderr)
                    self.assertIn(f'(pid {process.pid}) on port {port} to stop', printed)
                    self.assertIn('Ready after', printed)
                    self.assertIsNotNone(replacement(), printed)
                    self.assertNotEqual(replacement(), process.pid)
                    # Ready is said only once the old server let go of the workspace.
                    self.assertIsNotNone(process.wait(timeout=30))
                    self.assertFalse(gone(replacement()), 'the replacement is not running')
                    self.assertTrue(ready())
                finally:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGTERM)
                        try: process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            os.killpg(process.pid, signal.SIGKILL); process.wait(timeout=5)
                    successor = replacement()
                    if successor is not None and not gone(successor):
                        os.kill(successor, signal.SIGTERM)
                        deadline = time.monotonic()+15
                        while not gone(successor) and time.monotonic() < deadline:
                            time.sleep(.1)
                        if not gone(successor):
                            os.kill(successor, signal.SIGKILL)
                            while not gone(successor):
                                time.sleep(.1)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--binary', required=True)
    args, extra = parser.parse_known_args(); BINARY = str(Path(args.binary).resolve())
    unittest.main(argv=[__file__]+extra)
