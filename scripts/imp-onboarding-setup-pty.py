#!/usr/bin/env python3
"""Measure setup-owned startup, real TUI rendering, and owned-server shutdown.

Use a preinitialized, model-configured disposable workspace. Supply model CLI
authentication and Docker access through the environment. No model or server
fixtures are installed. This check complements real conversation/tool acceptance.
"""
import argparse
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import socket
import struct
import subprocess
import termios
import time
import urllib.request


def configure_terminal():
    # Same controlling-terminal protocol as test_tui_keyboard_input.py.
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    os.tcsetpgrp(0, os.getpgrp())


def http_json(url, token=None, body=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    data = None if body is None else json.dumps(body).encode()
    with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=headers), timeout=2) as response:
        return json.load(response)


def listening(port):
    try:
        with socket.create_connection(('127.0.0.1', port), timeout=.5):
            return True
    except OSError:
        return False


def measure(args):
    binary = str(Path(args.binary).absolute())
    base = Path(args.base_path).resolve(strict=True)
    manifest = base / '.masc/config/keepers/imp.toml'
    original = manifest.read_bytes()
    output = Path(args.output).absolute()
    output.mkdir(parents=True, exist_ok=False)
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    if listening(port):
        raise RuntimeError('selected port was occupied before setup')
    url = f'http://127.0.0.1:{port}'
    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 140, 0, 0))
    os.set_blocking(master, False)
    environment = os.environ.copy()
    for key in ('LINES', 'COLUMNS', 'NO_COLOR', 'MASC_TUI_FORCE_COLOR', 'MASC_TOKEN'):
        environment.pop(key, None)
    environment.update(TERM='xterm-256color', MASC_TUI_SYNC='off')
    captured = bytearray()
    process = None
    receipt = None

    def drain(wait=.1):
        ready, _, _ = select.select([master], [], [], wait)
        if not ready:
            return
        while True:
            try:
                chunk = os.read(master, 65536)
                if not chunk:
                    return
                captured.extend(chunk)
            except BlockingIOError:
                return
            except OSError as error:
                if error.errno == errno.EIO:
                    return
                raise

    def wait_until(condition, timeout, description, require_running=True):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            drain()
            if condition():
                return
            if require_running and process.poll() is not None:
                raise RuntimeError(f'setup exited with {process.returncode} before {description}')
        raise RuntimeError('timed out waiting for ' + description)

    health = None
    def ready():
        nonlocal health
        try:
            observed = http_json(url + '/health?full=1')
        except OSError:
            return False
        actual = observed.get('paths', {}).get('effective_base_path')
        if not isinstance(actual, str) or Path(actual).resolve() != base:
            raise RuntimeError('server health belongs to a different workspace')
        if observed.get('startup', {}).get('state_ready') is True:
            health = observed
            return True
        return False

    try:
        process = subprocess.Popen(
            [binary, 'setup', '--base-path', str(base), '--port', str(port)],
            stdin=slave, stdout=slave, stderr=slave, cwd=base, env=environment,
            preexec_fn=configure_terminal, close_fds=True)
        wait_until(ready, 360, 'setup-owned server readiness')
        # A rendered screen title and raw terminal mode distinguish the TUI
        # from setup's own textual instructions mentioning Keepers.
        marker = b'MASC Overview'
        wait_until(lambda: marker in captured and
                   not (termios.tcgetattr(slave)[3] & (termios.ICANON | termios.ECHO)),
                   120, 'real TUI frame and raw terminal mode')
        token = (base / '.masc/auth/local-admin.token').read_text().strip()
        boot = http_json(url + '/api/v1/keepers/imp/boot', token, {'name': 'imp'})
        if boot.get('ok') is not True or boot.get('already_live') is not True:
            raise RuntimeError('repeated imp boot did not preserve an already-live Keeper')
        if manifest.read_bytes() != original:
            raise RuntimeError('setup or repeated boot changed the imp manifest')
        # Two separate q presses are the supported TUI exit confirmation.
        os.write(master, b'q')
        drain(.2)
        os.write(master, b'q')
        wait_until(lambda: process.poll() is not None, 30, 'clean setup exit', False)
        drain(0)
        if process.returncode != 0 or b'Goodbye!' not in captured:
            raise RuntimeError('TUI/setup did not exit cleanly with Goodbye and status zero')
        wait_until(lambda: not listening(port), 15, 'owned server to stop', False)
        if manifest.read_bytes() != original:
            raise RuntimeError('shutdown changed the imp manifest')
        receipt = dict(
            base_path=str(base), port=port, port_initially_unused=True,
            setup_owned_server_ready=True, tui_frame_marker=marker.decode(),
            tui_raw_mode=True, repeated_boot_already_live=True,
            manifest_sha256=hashlib.sha256(original).hexdigest(), manifest_preserved=True,
            exit_input='q followed by q', setup_exit_code=process.returncode,
            owned_server_stopped=True, fixture_server=False,
            conversation_verified=False)
    finally:
        if process is not None and process.poll() is None:
            # Give the normal TUI exit path a chance on assertion failure too.
            try:
                os.write(master, b'qq')
                deadline = time.monotonic() + 10
                while process.poll() is None and time.monotonic() < deadline:
                    drain()
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=10)
            except (OSError, subprocess.TimeoutExpired):
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
        drain(0)
        os.close(master)
        os.close(slave)
        # Never persist bearer values even if a diagnostic unexpectedly prints
        # one. Authentication files themselves are never evidence artifacts.
        safe_log = bytes(captured)
        for token_path in (base / '.masc/auth').glob('*.token'):
            raw = token_path.read_bytes().strip()
            if raw:
                safe_log = safe_log.replace(raw, b'[REDACTED_BEARER]')
        (output / 'setup-pty.log').write_bytes(safe_log)
        if receipt is not None:
            (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
        else:
            (output / 'failure-state.json').write_text(json.dumps(
                {'port': port, 'server_still_listening': listening(port),
                 'setup_exit_code': None if process is None else process.returncode}, indent=2) + '\n')
    print('Setup PTY evidence:', output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True)
    parser.add_argument('--base-path', required=True)
    parser.add_argument('--output', required=True, help='New evidence directory; must not already exist')
    measure(parser.parse_args())
