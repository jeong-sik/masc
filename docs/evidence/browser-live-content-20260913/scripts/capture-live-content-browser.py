"""Own one native TUI throughout an isolated Keeper/browser experiment."""
import base64
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import threading
import time


@contextmanager
def capture(*, repo, executable, base, api_port, token, region, region_index,
            tab_id, url, out, client_id):
    sys.path.insert(0, str(repo / 'test'))
    import test_tui_keyboard_input as h
    master, slave = os.openpty()
    raw = bytearray()
    process = None
    draining = None
    stop = threading.Event()
    timeline = []
    capture_errors = []
    input_events = []
    env = {k: v for k, v in os.environ.items()
           if k in ('HOME', 'PATH', 'LANG', 'LC_ALL', 'TMPDIR', 'USER', 'LOGNAME', 'SHELL')}
    env.update({'MASC_BASE_PATH': str(base), 'MASC_HOST': '127.0.0.1', 'MASC_TOKEN': token,
                'MASC_TUI_SYNC': 'off', 'MASC_TUI_FORCE_COLOR': '1', 'TERM': 'xterm-256color',
                'NO_PROXY': '127.0.0.1,localhost'})
    lifetime = {'columns': 130, 'rows': 35, 'input_events': input_events,
                'refresh_interval': 'unmodified product default'}

    def wait(needle, start=0):
        h.wait_for_output(process, master, raw, needle, start=start, timeout=25)

    def send(keys, needle):
        h.read_available(master, raw)
        start = len(raw)
        input_events.append({'monotonic': time.monotonic(), 'keys_hex': keys.hex()})
        h.write_all(master, raw, keys)
        wait(needle, start)
        return bytes(raw[start:])

    def drain():
        try:
            last = len(raw)
            while not stop.is_set():
                h.read_available(master, raw)
                if len(raw) != last:
                    timeline.append({'monotonic': time.monotonic(), 'offset_start': last,
                                     'offset_end': len(raw), 'tui_exit': process.poll()})
                    last = len(raw)
                if process.poll() is not None:
                    break
                select.select([master], [], [], .05)
        except Exception as error:
            capture_errors.append({'stage': 'drain', 'error': repr(error)})

    try:
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 35, 130, 0, 0))
        os.set_blocking(master, False)
        # Use the shipped cadence, not a probe-only faster refresh interval.
        process = subprocess.Popen([str(executable), '--base-path', str(base),
            '--workspace', base.name, '--port', str(api_port)], cwd=base, env=env,
            stdin=slave, stdout=slave, stderr=slave, preexec_fn=h.configure_child_terminal,
            close_fds=True)
        lifetime.update(pid=process.pid, started_monotonic=time.monotonic(),
                        binary_sha256=hashlib.sha256(executable.read_bytes()).hexdigest())
        wait(b'MASC Overview')
        send(b':go Browser Lane\r', b'Team Channels')
        send(b'v', b'Channels')
        for index in range(region_index):
            send(b'n', ('[>' + str(index + 2) + ' region').encode())
        osc = re.compile(rb'\x1b\]52;c;([A-Za-z0-9+/=]+)\x07')
        copied = send(b'y', osc)
        match = osc.search(copied)
        assert match is not None
        clipboard = base64.b64decode(match.group(1), validate=True)
        context = json.loads(clipboard)
        assert context['lane'] == 'live' and context['clientId'] == client_id
        assert context['tabId'] == tab_id and context['url'] == url
        assert context['documentId'] == region['documentId'] and context['nodeId'] == region['nodeId']
        assert context['view'] == 'regions' and context['scope'] is None
        (out / 'tui-context.json').write_bytes(clipboard)
        (out / 'clipboard-osc52.bin').write_bytes(match.group(0))
        (out / 'tui-initial.pty').write_bytes(raw)
        lifetime.update(copied_monotonic=time.monotonic(), copy_offset=len(raw),
                        alive_at_copy=process.poll() is None)
        send(b's', b' chars')
        send(b's', b'Page content')
        lifetime['display_selected_monotonic'] = time.monotonic()
        lifetime['display_intent'] = 'unscoped content selected before Keeper starts'
        (out / 'tui-initial.pty').write_bytes(raw)
        proof = {'tui_sha256': lifetime['binary_sha256'], 'clipboard_bytes': len(clipboard),
                 'clipboard_sha256': hashlib.sha256(clipboard).hexdigest(),
                 'columns': 130, 'rows': 35, 'selected_region_index': region_index,
                 'lifetime': lifetime}
        draining = threading.Thread(target=drain, daemon=True)
        draining.start()
        yield clipboard, proof
        lifetime.update(keeper_observation_finished_monotonic=time.monotonic(),
                        alive_after_keeper_observation=process.poll() is None)
    finally:
        stop.set()
        try:
            if draining is not None:
                draining.join(timeout=2)
                if draining.is_alive():
                    capture_errors.append({'stage': 'drain-stop', 'error': 'thread still alive'})
            h.read_available(master, raw)
            (out / 'tui-follow.pty').write_bytes(raw)
            (out / 'tui-timeline.json').write_text(json.dumps(timeline))
        except Exception as error:
            capture_errors.append({'stage': 'save-capture', 'error': repr(error)})
        finally:
            try:
                if process is not None and process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    deadline = time.monotonic() + 12
                    while process.poll() is None and time.monotonic() < deadline:
                        h.read_available(master, raw)
                        select.select([master], [], [], .1)
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=5)
            except Exception as error:
                capture_errors.append({'stage': 'terminate', 'error': repr(error)})
                if process is not None and process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
            finally:
                lifetime.update(exit=None if process is None else process.poll(),
                                stopped_monotonic=time.monotonic(), capture_errors=capture_errors)
                try:
                    (out / 'tui-lifetime.json').write_text(json.dumps(lifetime, indent=2))
                finally:
                    os.close(master)
                    os.close(slave)
        if capture_errors:
            raise RuntimeError('TUI capture incomplete: ' + repr(capture_errors))
