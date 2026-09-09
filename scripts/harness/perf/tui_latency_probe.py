#!/usr/bin/env python3
"""Observe an existing TUI binary in a PTY; retain identity and frame timings.

Runs no build. Sends only Tab navigation, then SIGTERM to its own child so the
TUI flushes its timing report. These are TUI build/present timings and output
readiness, not physical terminal-display or end-to-end input latency.
"""
import argparse
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import termios
import time
from urllib.request import urlopen


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def health(port):
    with urlopen(f'http://127.0.0.1:{port}/health?full=1', timeout=10) as response:
        value = json.load(response)
    return {key: value.get(key) for key in ('build', 'paths', 'scheduler', 'gc')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--base-path', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--port', type=int, default=8935)
    parser.add_argument('--rows', type=int, default=45)
    parser.add_argument('--columns', type=int, default=150)
    parser.add_argument('--tabs', type=int, default=4)
    parser.add_argument('--tab-interval', type=float, default=1)
    parser.add_argument('--settle', type=float, default=2)
    parser.add_argument('--ready-timeout', type=float, default=30)
    parser.add_argument('--termination-grace', type=float, default=5)
    parser.add_argument('--capture-screen', action='store_true',
                        help='also retain raw terminal output, which may include live content')
    args = parser.parse_args()
    if not (1 <= args.port <= 65535 and 1 <= args.rows <= 65535
            and 1 <= args.columns <= 65535 and args.tabs >= 0
            and all(0 < x < float('inf') for x in
                    (args.tab_interval, args.settle, args.ready_timeout, args.termination_grace))):
        parser.error('invalid port, geometry, tab count, or observation duration')
    binary = args.binary.resolve(strict=True)
    base = args.base_path.resolve(strict=True)
    before = health(args.port)
    before_build = before.get('build')
    if not (isinstance(before_build, dict)
            and isinstance(before_build.get('runtime_instance_id'), str)
            and before_build['runtime_instance_id']):
        parser.error('existing server must report its runtime instance')
    reported_base = (before.get('paths') or {}).get('effective_base_path')
    if not isinstance(reported_base, str) or not reported_base.strip():
        parser.error('existing server must report its effective base path')
    if Path(reported_base).resolve() != base:
        parser.error('existing server base path differs from requested base path')
    args.output_dir.mkdir(parents=True, exist_ok=False)
    out = args.output_dir.resolve()
    timing_path = out / 'frame-timing.txt'
    sha_before = digest(binary)
    env = os.environ.copy()
    env.update(TERM='xterm-256color', MASC_TUI_FRAME_TIMING=str(timing_path))
    argv = [str(binary), '--base-path', str(base), '--port', str(args.port)]
    started = time.monotonic()
    pid, master = pty.fork()
    if pid == 0:
        try:
            fcntl.ioctl(1, termios.TIOCSWINSZ,
                        struct.pack('HHHH', args.rows, args.columns, 0, 0))
            os.execve(binary, argv, env)
        finally:
            os._exit(127)
    raw = bytearray()
    ready = None
    sent = []
    terminated = None
    status = None
    forced = False
    error = None
    try:
        while status is None:
            readable, _, _ = select.select([master], [], [], .05)
            if readable:
                try:
                    chunk = os.read(master, 65536)
                except OSError as exc:
                    if exc.errno != errno.EIO:
                        raise
                    chunk = b''
                raw.extend(chunk)
            now = time.monotonic()
            if ready is None:
                marker = raw.find(b'MASC Overview')
                if marker >= 0 and raw.find(b'\x1b[?7h', marker) >= 0:
                    ready = now
            if ready is not None and terminated is None:
                if len(sent) < args.tabs and now - ready >= (len(sent) + 1) * args.tab_interval:
                    os.write(master, b'\t')
                    sent.append(now - started)
                if len(sent) == args.tabs and now - ready >= args.tabs * args.tab_interval + args.settle:
                    os.kill(pid, signal.SIGTERM)
                    terminated = now
            elif ready is None and terminated is None and now - started >= args.ready_timeout:
                os.kill(pid, signal.SIGTERM)
                terminated = now
            if terminated is not None and now - terminated >= args.termination_grace and not forced:
                os.kill(pid, signal.SIGKILL)
                forced = True
            reaped, child_status = os.waitpid(pid, os.WNOHANG)
            if reaped:
                status = child_status
    except Exception as exc:
        error = f'{type(exc).__name__}: {exc}'
    finally:
        if status is None:
            try:
                os.kill(pid, signal.SIGKILL)
                forced = True
            except ProcessLookupError:
                pass
            _, status = os.waitpid(pid, 0)
        os.close(master)
    duration = time.monotonic() - started
    try:
        after = health(args.port)
    except Exception as exc:
        after = {'error': f'{type(exc).__name__}: {exc}'}
    try:
        sha_after = digest(binary)
    except OSError as exc:
        sha_after = None
        error = f'{error + "; " if error else ""}final binary hash: {exc}'
    after_build = after.get('build')
    same_runtime = (isinstance(after_build, dict) and before_build['runtime_instance_id']
                    == after_build.get('runtime_instance_id'))
    try:
        timing = timing_path.read_text() if timing_path.exists() else ''
    except (OSError, UnicodeError) as exc:
        timing = ''
        error = f'{error + "; " if error else ""}frame timing read: {exc}'
    exit_code = os.waitstatus_to_exitcode(status)
    observed = (ready is not None and len(sent) == args.tabs and exit_code == 0
                and not forced and error is None and same_runtime
                and sha_before == sha_after and bool(timing.strip()))
    result = dict(binary=str(binary), sha256_before=sha_before, sha256_after=sha_after,
                  server_before=before, server_after=after, same_runtime=same_runtime,
                  rows=args.rows, columns=args.columns, tab_sent_at_s=sent,
                  ready_after_s=None if ready is None else ready - started,
                  duration_s=duration, exit_code=exit_code, forced_kill=forced,
                  error=error, observation_complete=observed,
                  argv=argv, term=env['TERM'],
                  observation_options={key: value for key, value in vars(args).items()
                                       if not isinstance(value, Path)},
                  observed_surfaces=re.findall(r'^  build\[([^\]]+)\]', timing, re.MULTILINE),
                  navigation_scope='Tab writes recorded; individual transitions are not acknowledged',
                  server_lifecycle='normal TUI behavior; connection failure can trigger its auto-start',
                  scope='PTY navigation and TUI frame timing; not display latency or target acceptance')
    (out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    if args.capture_screen:
        (out / 'screen.ansi').write_bytes(raw)
    print(json.dumps({'output_dir': str(out), 'observation_complete': observed,
                      'ready_after_s': result['ready_after_s'], 'exit_code': exit_code,
                      'forced_kill': forced}))
    print(timing, end='')
    return 0 if observed else 1


if __name__ == '__main__':
    raise SystemExit(main())
