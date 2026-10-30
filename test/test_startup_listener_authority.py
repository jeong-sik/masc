"""Exercise the actual start command in private workspaces, without credentials."""
import argparse
import contextlib
import errno
import http.client
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

BINARY = None


def stop_owned_process(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
    else:
        process.wait()


def start_token(pid):
    if Path('/proc/self/stat').exists():
        raw = Path(f'/proc/{pid}/stat').read_text()
        ticks = raw[raw.rindex(')') + 2:].split()[19]
        return 'proc:' + Path('/proc/sys/kernel/random/boot_id').read_text().strip() + ':' + ticks
    env = dict(os.environ, LC_ALL='C', TZ='UTC')
    started = subprocess.check_output(['ps', '-p', str(pid), '-o', 'lstart='], env=env, text=True).strip()
    if not started:
        raise AssertionError('fixture owner has no start identity')
    return 'ps:' + started


class StartupListenerAuthority(unittest.TestCase):
    @contextlib.contextmanager
    def workspace(self):
        with tempfile.TemporaryDirectory(prefix='masc-listener-authority-') as directory:
            base = Path(directory).resolve()
            config = base / '.masc/config'
            config.mkdir(parents=True)
            fixture = Path(__file__).resolve().parent.parent / 'scripts/fixtures/release-evidence/runtime.toml'
            shutil.copyfile(fixture, config / 'runtime.toml')
            assets = base / 'assets/dashboard/assets'
            assets.mkdir(parents=True)
            (assets / 'fixture.js').write_text('/* isolated startup fixture */\n')
            run = base / 'host-run'
            run.mkdir(mode=0o700)
            lease = base / 'host-leases'
            lease.mkdir(mode=0o700)
            token = secrets.token_hex(32)
            env = {k: v for k, v in os.environ.items()
                   if k in ('PATH', 'LANG', 'LC_ALL', 'USER', 'SHELL', 'CAML_LD_LIBRARY_PATH')}
            env.update(HOME=str(base), XDG_CONFIG_HOME=str(base / 'xdg'), TMPDIR=str(run),
                       MASC_BASE_PATH=str(base), MASC_BASE_PATH_LEASE_DIR=str(lease),
                       MASC_ADMIN_TOKEN=token, MASC_ASSETS_DIR=str(base / 'assets'),
                       MASC_HTTP_AUTH_STRICT='true', MASC_GRPC_ENABLED='0', MASC_WS_ENABLED='0',
                       MASC_KEEPER_AUTONOMOUS_ENABLED='false')
            yield base, run, env, token

    @contextlib.contextmanager
    def server(self, base, env, port):
        log_path = base / 'server.log'
        with log_path.open('wb') as log:
            process = subprocess.Popen([str(BINARY), 'start', '--base-path', str(base),
                                        '--host', '127.0.0.1', '--port', str(port)],
                                       cwd=base, env=env, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                yield process, log_path
            finally:
                stop_owned_process(process)

    @contextlib.contextmanager
    def unrelated_listener(self):
        owner = subprocess.Popen([sys.executable, '-u', str(Path(__file__).resolve()), '--fixture-owner'],
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                 text=True, start_new_session=True)
        try:
            line = owner.stdout.readline()
            self.assertTrue(line, 'fixture listener failed before binding')
            yield owner, int(line)
        finally:
            stop_owned_process(owner)
            owner.stdout.close()

    def wait_ready(self, process, log, port, token, sentinel):
        deadline = time.monotonic() + 60  # Contain an owned fixture that cannot finish startup.
        while True:
            self.assertEqual(sentinel.read_text(), 'outside fixture remains intact\n',
                             'startup mutated the file behind the PID observation')
            self.assertIsNone(process.poll(), log.read_text()[-4000:])
            connection = http.client.HTTPConnection('127.0.0.1', port, timeout=0.2)
            try:
                connection.request('GET', '/health/ready', headers={'Authorization': 'Bearer ' + token})
                response = connection.getresponse()
                body = response.read()
                if response.status == 200 and json.loads(body).get('ready') is True:
                    return
            except (OSError, http.client.HTTPException):
                pass
            finally:
                connection.close()
            self.assertLess(time.monotonic(), deadline, 'owned fixture did not become ready')
            time.sleep(0.02)

    def leftover_observation(self, kind):
        with self.workspace() as (base, run, env, token):
            with socket.socket() as probe:
                probe.bind(('127.0.0.1', 0))
                port = probe.getsockname()[1]
            sentinel = base / 'outside-observation'
            sentinel.write_text('outside fixture remains intact\n')
            observation = run / f'masc-{port}.pid'
            if kind == 'symlink':
                observation.symlink_to(sentinel)
            else:
                os.link(sentinel, observation)
            identity = observation.lstat()
            with self.server(base, env, port) as (process, log):
                self.wait_ready(process, log, port, token, sentinel)
                self.assertEqual(sentinel.read_text(), 'outside fixture remains intact\n')
                self.assertEqual((observation.lstat().st_dev, observation.lstat().st_ino),
                                 (identity.st_dev, identity.st_ino))
            self.assertEqual(sentinel.read_text(), 'outside fixture remains intact\n')
            self.assertEqual((observation.lstat().st_dev, observation.lstat().st_ino),
                             (identity.st_dev, identity.st_ino))

    def test_start_ignores_symlink_pid_observation(self):
        self.leftover_observation('symlink')

    def test_start_ignores_hardlink_pid_observation(self):
        self.leftover_observation('hardlink')

    def occupied_port(self, recorded):
        with self.workspace() as (base, run, env, _token), self.unrelated_listener() as (owner, port):
            observation = run / f'masc-{port}.pid'
            original = None
            if recorded:
                original = f'{owner.pid}\n{start_token(owner.pid)}\n'
                observation.write_text(original)
            with self.server(base, env, port) as (process, log):
                deadline = time.monotonic() + 15
                while process.poll() is None:
                    self.assertIsNone(owner.poll(), 'startup terminated the unrelated listener')
                    if original is None:
                        self.assertFalse(observation.exists(), 'startup created PID authority for an occupied port')
                    self.assertLess(time.monotonic(), deadline, 'occupied-port startup did not return')
                    time.sleep(0.02)
                self.assertNotEqual(process.returncode, 0, 'occupied port was accepted')
                diagnostic = log.read_text()
                self.assertTrue('EADDRINUSE' in diagnostic or os.strerror(errno.EADDRINUSE) in diagnostic,
                                'startup did not reach the actual bind refusal: ' + diagnostic[-4000:])
                self.assertIsNone(owner.poll(), 'startup terminated the unrelated listener')
                if original is None:
                    self.assertFalse(observation.exists())
                else:
                    self.assertEqual(observation.read_text(), original)
                connection = http.client.HTTPConnection('127.0.0.1', port, timeout=1)
                try:
                    connection.request('GET', '/health')
                    self.assertEqual(connection.getresponse().status, 503,
                                     'the original unrelated listener no longer owns the port')
                finally:
                    connection.close()

    def test_occupied_port_preserves_recorded_unrelated_process(self):
        self.occupied_port(True)

    def test_occupied_port_does_not_create_pid_authority(self):
        self.occupied_port(False)


def fixture_owner():
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen()
        print(listener.getsockname()[1], flush=True)
        while True:
            stream, _ = listener.accept()
            with stream:
                stream.recv(4096)
                stream.sendall(b'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')


if __name__ == '__main__':
    if sys.argv[1:] == ['--fixture-owner']:
        fixture_owner()
    else:
        parser = argparse.ArgumentParser()
        parser.add_argument('--binary', type=Path, required=True)
        args, remaining = parser.parse_known_args()
        BINARY = args.binary.resolve()
        unittest.main(argv=[sys.argv[0], *remaining], verbosity=2)
