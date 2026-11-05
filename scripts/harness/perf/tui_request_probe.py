#!/usr/bin/env python3
# pyright: strict
"""Count the HTTP requests one TUI binary sends while each screen rests.

No build is run. A relay on 127.0.0.1 (`tui_request_proxy.py`) sits between
one TUI child and an already running server. The probe sends only the keys
each step names, waits the step's seconds, and finally sends SIGTERM so the
TUI exits. For every window it reports the requests that started in it, by
method, path and query names, and the server-sent events that arrived in it,
by name. Header values, query values and bodies are not kept.

It counts requests, not frames, and does not measure input or display
latency. Reads the TUI makes from base-path files on local disk do not pass
through the relay and are not counted. `tui_request_summary.py` turns the
relay's log into the per-window summaries.
"""
import argparse
from collections.abc import Mapping, Sequence
import codecs
from dataclasses import asdict, dataclass, replace
import errno
import fcntl
import hashlib
import http.client
from http import HTTPStatus
import json
import math
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import sys
import termios
import time

import tui_request_events as events
import tui_request_log as record
import tui_request_proxy as proxy
from tui_request_summary import (
    FaultRow, Window, index_entries, print_table, stream_rows, summarize_window,
)

DEFAULT_PORT = 8935
DEFAULT_ROWS = 45
DEFAULT_COLUMNS = 150
DEFAULT_SETTLE_S = 5.0
DEFAULT_READY_TIMEOUT_S = 30.0
DEFAULT_TERMINATION_GRACE_S = 5.0
DEFAULT_STEP = 'rest::30'
MAX_PORT = 65535
MAX_TERMINAL_SIDE = 65535
HEALTH_PATH = '/health?full=1'
HEALTH_TIMEOUT_S = 10.0
POLL_INTERVAL_S = 0.05
READ_BYTES = 65536
READY_MARKER = b'MASC Dashboard'
READY_SUFFIX = b'\x1b[?7h'
GO = b'g'
EXEC_FAILED = 127
# The signals Python sets to SIG_IGN at start, which `subprocess` restores
# before exec by default (restore_signals); an ignored signal stays ignored
# across exec.
RESTORED_SIGNALS = (signal.SIGPIPE, signal.SIGXFSZ)
TERM = 'xterm-256color'
RESULT_FILE = 'result.json'
SCREEN_FILE = 'screen.ansi'
STARTUP = 'startup'
STEP_LABEL = re.compile(r'[A-Za-z0-9_.-]+')
SCOPE = ('requests the TUI child sent through the relay and server-sent events it received, '
         'per window; not input or display latency, not other clients, and not reads of '
         'base-path files on local disk')


@dataclass(frozen=True, slots=True)
class Step:
    """A step as given (`keys` keeps its escapes) and the bytes it sends."""
    label: str
    keys: str
    sent: bytes
    seconds: float

    def report(self) -> dict[str, object]:
        return {'label': self.label, 'keys': self.keys, 'seconds': self.seconds}


def parse_step(text: str) -> Step | str:
    """LABEL:KEYS:SECONDS, or why the text is not one.

    KEYS is ASCII text with Python escapes such as \\t, \\r and \\x1b, and must
    decode to text that UTF-8 can encode; the probe sends those UTF-8 bytes.
    It may be empty, so that a window measures the screen at rest."""
    label, sep, rest = text.partition(':')
    keys, sep_seconds, seconds_text = rest.rpartition(':')
    if not (sep and sep_seconds and STEP_LABEL.fullmatch(label)):
        return f'step must be LABEL:KEYS:SECONDS with LABEL in [A-Za-z0-9_.-]: {text!r}'
    if label == STARTUP:
        return f'step label {STARTUP!r} names the window before the first step: {text!r}'
    if not keys.isascii():
        return f'step keys must be ASCII, with escapes for other characters: {text!r}'
    try:
        seconds = float(seconds_text)
        sent = codecs.decode(keys.encode('ascii'), 'unicode_escape').encode('utf-8')
    except ValueError:
        return f'step seconds must be a number and its keys escapes of UTF-8 text: {text!r}'
    if not (math.isfinite(seconds) and seconds > 0):
        return f'step seconds must be positive: {text!r}'
    return Step(label, keys, sent, seconds)


@dataclass(frozen=True, slots=True)
class Options:
    binary: Path
    base_path: Path
    output_dir: Path
    port: int
    rows: int
    columns: int
    settle: float
    steps: tuple[Step, ...]
    ready_timeout: float
    termination_grace: float
    capture_screen: bool


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--binary', type=Path, required=True, help='the TUI executable')
    parser.add_argument('--base-path', type=Path, required=True,
                        help='the base path the running server serves')
    parser.add_argument('--output-dir', type=Path, required=True,
                        help='a directory that does not exist yet')
    parser.add_argument('--port', type=int, default=DEFAULT_PORT, help='the running server')
    parser.add_argument('--rows', type=int, default=DEFAULT_ROWS)
    parser.add_argument('--columns', type=int, default=DEFAULT_COLUMNS)
    parser.add_argument('--settle', type=float, default=DEFAULT_SETTLE_S,
                        help='seconds after the first complete frame before the first step')
    parser.add_argument('--step', action='append', default=[], metavar='LABEL:KEYS:SECONDS',
                        help=f'send KEYS, then count for SECONDS; repeatable, in order '
                             f'(default {DEFAULT_STEP})')
    parser.add_argument('--ready-timeout', type=float, default=DEFAULT_READY_TIMEOUT_S)
    parser.add_argument('--termination-grace', type=float, default=DEFAULT_TERMINATION_GRACE_S)
    parser.add_argument('--capture-screen', action='store_true',
                        help='also keep the raw terminal output, which can include live content')
    return parser


def parse_options(parser: argparse.ArgumentParser, argv: Sequence[str] | None) -> Options:
    args = parser.parse_args(argv)
    texts: list[str] = args.step or [DEFAULT_STEP]
    steps: list[Step] = []
    for text in texts:
        step = parse_step(text)
        if isinstance(step, str):
            parser.error(step)
        steps.append(step)
    if len({step.label for step in steps}) != len(steps):
        parser.error('step labels must be unique')
    port: int = args.port
    rows: int = args.rows
    columns: int = args.columns
    settle: float = args.settle
    ready_timeout: float = args.ready_timeout
    grace: float = args.termination_grace
    if not 1 <= port <= MAX_PORT:
        parser.error(f'--port must be in 1..{MAX_PORT}')
    if not (1 <= rows <= MAX_TERMINAL_SIDE and 1 <= columns <= MAX_TERMINAL_SIDE):
        parser.error(f'--rows and --columns must be in 1..{MAX_TERMINAL_SIDE}')
    if not all(math.isfinite(value) and value > 0 for value in (settle, ready_timeout, grace)):
        parser.error('--settle, --ready-timeout and --termination-grace must be positive seconds')
    binary_arg: Path = args.binary
    base_arg: Path = args.base_path
    output_arg: Path = args.output_dir
    try:
        binary = binary_arg.resolve(strict=True)
        base = base_arg.resolve(strict=True)
    except OSError as exc:
        parser.error(str(exc))
    if not os.access(binary, os.X_OK):
        parser.error(f'{binary} is not executable')
    capture: bool = args.capture_screen
    return Options(binary, base, output_arg.resolve(), port, rows, columns, settle,
                   tuple(steps), ready_timeout, grace, capture)


@dataclass(frozen=True, slots=True)
class Health:
    runtime: str | None
    base_path: str | None
    build: dict[str, object]
    paths: dict[str, object]

    def report(self) -> dict[str, object]:
        return {'build': self.build, 'paths': self.paths}


def text_field(fields: Mapping[str, object], name: str) -> str | None:
    value = fields.get(name)
    return value if isinstance(value, str) and value.strip() else None


def read_health(port: int) -> Health | str:
    """The server's /health on `port`, or why it could not be read.

    http.client never reads proxy settings. urllib's urlopen does, and on macOS
    that starts threads, so the probe would fork its child with threads alive."""
    connection = http.client.HTTPConnection(proxy.LOOPBACK, port, timeout=HEALTH_TIMEOUT_S)
    try:
        connection.request('GET', HEALTH_PATH)
        response = connection.getresponse()
        status, raw = response.status, response.read()
    except (OSError, http.client.HTTPException) as exc:
        return f'{type(exc).__name__}: {exc}'
    finally:
        connection.close()
    if status != HTTPStatus.OK:
        return f'status {status}'
    try:
        body: object = json.loads(raw)
    except (ValueError, RecursionError) as exc:
        return f'not JSON: {type(exc).__name__}'
    fields = events.json_fields(body)
    build = events.json_fields(fields.get('build'))
    paths = events.json_fields(fields.get('paths'))
    return Health(text_field(build, 'runtime_instance_id'),
                  text_field(paths, 'effective_base_path'), build, paths)


def server_mismatch(health: Health, base_path: Path) -> str | None:
    if health.runtime is None:
        return 'the server did not report its runtime instance'
    if health.base_path is None:
        return 'the server did not report its effective base path'
    if Path(health.base_path).resolve() != base_path:
        return f'the server serves {health.base_path}, not {base_path}'
    return None


@dataclass(frozen=True, slots=True)
class Gated:
    """A PTY child that execs the TUI only after `release`."""
    pid: int
    master: int
    gate: int


def spawn_gated(argv: Sequence[str], env: Mapping[str, str], rows: int, columns: int) -> Gated:
    """Fork the PTY child while this process has one thread; it waits on a pipe to exec."""
    gate_read, gate_write = os.pipe()
    pid, master = pty.fork()
    if pid == 0:
        os.close(gate_write)
        try:
            if os.read(gate_read, len(GO)) == GO:
                fcntl.ioctl(1, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))
                for restored in RESTORED_SIGNALS:
                    signal.signal(restored, signal.SIG_DFL)
                os.execve(argv[0], list(argv), env)
        finally:
            os._exit(EXEC_FAILED)
    os.close(gate_read)
    return Gated(pid, master, gate_write)


def release(child: Gated) -> None:
    os.write(child.gate, GO)
    os.close(child.gate)


def abort(child: Gated) -> None:
    """Let a child that was never released exit without running the TUI."""
    os.close(child.gate)
    os.waitpid(child.pid, 0)
    os.close(child.master)


@dataclass(frozen=True, slots=True)
class Run:
    started: float
    ready: float | None
    steps: tuple[Window, ...]
    terminated: float | None
    exited: float
    status: int
    forced_kill: bool
    error: str | None
    screen: bytes


def drain(master: int, timeout: float) -> tuple[bytes, bool]:
    """What the child wrote within `timeout`, read until nothing waits, and whether
    its terminal has closed."""
    output = bytearray()
    wait = timeout
    while select.select([master], [], [], wait)[0]:
        try:
            chunk = os.read(master, READ_BYTES)
        except OSError as exc:
            if exc.errno != errno.EIO:
                raise
            return bytes(output), True
        if not chunk:
            return bytes(output), True
        output.extend(chunk)
        wait = 0
    return bytes(output), False


def frame_complete(screen: bytes | bytearray) -> bool:
    marker = screen.find(READY_MARKER)
    return marker >= 0 and screen.find(READY_SUFFIX, marker) >= 0


def terminate(pid: int) -> float:
    os.kill(pid, signal.SIGTERM)
    return time.monotonic()


def drive(child: Gated, options: Options) -> Run:
    """Release the child, send each step's keys on schedule, then SIGTERM it.

    A window closes when the next one opens, so the windows leave no gap."""
    started = time.monotonic()
    screen = bytearray()
    ready: float | None = None
    first_step_at = math.inf
    pending = list(options.steps)
    steps: list[Window] = []
    current: Window | None = None
    terminated: float | None = None
    forced = False
    closed = False
    error: str | None = None
    status: int | None = None
    try:
        release(child)
        while status is None:
            if closed:
                time.sleep(POLL_INTERVAL_S)
            else:
                output, closed = drain(child.master, POLL_INTERVAL_S)
                if ready is None or options.capture_screen:
                    screen.extend(output)
            now = time.monotonic()
            if terminated is None:
                if ready is None and frame_complete(screen):
                    ready = now
                    first_step_at = now + options.settle
                elif ready is None and now - started >= options.ready_timeout:
                    terminated = terminate(child.pid)
                if current is not None and now >= current.end:
                    steps.append(replace(current, end=now))
                    current = None
                if terminated is None and current is None and now >= first_step_at:
                    if pending:
                        step = pending.pop(0)
                        if step.sent:
                            os.write(child.master, step.sent)
                        current = Window(step.label, step.keys, now, now + step.seconds, True)
                    else:
                        terminated = terminate(child.pid)
            elif not forced and now - terminated >= options.termination_grace:
                os.kill(child.pid, signal.SIGKILL)
                forced = True
            reaped, wait_status = os.waitpid(child.pid, os.WNOHANG)
            if reaped:
                status = wait_status
    except OSError as exc:
        error = f'{type(exc).__name__}: {exc}'
    finally:
        if status is None:
            os.kill(child.pid, signal.SIGKILL)
            forced = True
            _, status = os.waitpid(child.pid, 0)
        os.close(child.master)
    exited = time.monotonic()
    if current is not None:
        steps.append(replace(current, end=min(current.end, exited), finished=False))
    return Run(started, ready, tuple(steps), terminated, exited, status, forced, error,
               bytes(screen))


def startup_window(run: Run) -> Window:
    if run.steps:
        return Window(STARTUP, '', run.started, run.steps[0].start, True)
    end = run.terminated if run.terminated is not None else run.exited
    return Window(STARTUP, '', run.started, end, False)


def digest(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    options = parse_options(parser, argv)
    before = read_health(options.port)
    if isinstance(before, str):
        parser.error(f'the server on port {options.port} did not answer /health: {before}')
    mismatch = server_mismatch(before, options.base_path)
    if mismatch is not None:
        parser.error(mismatch)
    options.output_dir.mkdir(parents=True, exist_ok=False)
    log = record.Log()
    listener = proxy.listen_socket()
    relay_port = proxy.bound_port(listener)
    child_argv = (str(options.binary), '--base-path', str(options.base_path),
                  '--port', str(relay_port))
    env = {**os.environ, 'TERM': TERM}
    sha_before = digest(options.binary)
    child = spawn_gated(child_argv, env, options.rows, options.columns)
    released = False
    try:
        with proxy.serve(listener, options.port, log):
            through = read_health(relay_port)
            if isinstance(through, str):
                parser.error(f'/health through the relay failed: {through}')
            if through.runtime != before.runtime:
                parser.error(f'the relay reached runtime {through.runtime!r}, '
                             f'not {before.runtime!r}')
            released = True
            run = drive(child, options)
    finally:
        if not released:
            abort(child)
        listener.close()
    notes: list[str] = []
    final = read_health(options.port)
    after = final if isinstance(final, Health) else None
    if isinstance(final, str):
        notes.append(f'final /health: {final}')
    try:
        sha_after: str | None = digest(options.binary)
    except OSError as exc:
        sha_after = None
        notes.append(f'final binary hash: {exc}')
    index = index_entries(log.entries())
    windows = (startup_window(run), *run.steps)
    summaries = tuple(summarize_window(index, window, run.started) for window in windows)
    measured_until = run.terminated if run.terminated is not None else run.exited
    faults = tuple(FaultRow(t - run.started, detail) for t, detail in index.faults
                   if run.started <= t < measured_until)
    relayed = sum(1 for sent in index.sent.values() if run.started <= sent.t < measured_until)
    exit_code = os.waitstatus_to_exitcode(run.status)
    same_runtime = after is not None and after.runtime == before.runtime
    complete = (run.ready is not None and len(run.steps) == len(options.steps)
                and all(window.finished for window in run.steps)
                and exit_code == 0 and not run.forced_kill and run.error is None
                and same_runtime and sha_after == sha_before and not faults and not notes
                and relayed > 0)
    result: dict[str, object] = {
        'binary': str(options.binary),
        'sha256_before': sha_before,
        'sha256_after': sha_after,
        'server_before': before.report(),
        'server_after': None if after is None else after.report(),
        'same_runtime': same_runtime,
        'relay_port': relay_port,
        'upstream_port': options.port,
        'argv': list(child_argv),
        'term': TERM,
        'rows': options.rows,
        'columns': options.columns,
        'settle_s': options.settle,
        'steps': [step.report() for step in options.steps],
        'ready_after_s': None if run.ready is None else run.ready - run.started,
        'duration_s': run.exited - run.started,
        'exit_code': exit_code,
        'forced_kill': run.forced_kill,
        'error': run.error,
        'notes': notes,
        'observation_complete': complete,
        'relayed_requests': relayed,
        'windows': [asdict(summary) for summary in summaries],
        'streams': [asdict(row) for row in stream_rows(index, run.started)],
        'faults': [asdict(fault) for fault in faults],
        'faults_after_termination': sum(1 for t, _ in index.faults if t >= measured_until),
        'scope': SCOPE,
    }
    (options.output_dir / RESULT_FILE).write_text(json.dumps(result, indent=2) + '\n')
    if options.capture_screen:
        (options.output_dir / SCREEN_FILE).write_bytes(run.screen)
    print(json.dumps({'output_dir': str(options.output_dir), 'observation_complete': complete,
                      'ready_after_s': result['ready_after_s'], 'exit_code': exit_code,
                      'forced_kill': run.forced_kill, 'faults': len(faults)}))
    print_table(summaries)
    return 0 if complete else 1


if __name__ == '__main__':
    sys.exit(main())
