#!/usr/bin/env python3
# pyright: strict
"""Idle cost of each TUI screen, measured through the read-only relay.

usage: idle.py --tui BIN --out DIR --base-path DIR --upstream-port PORT
               [--size 160x46] [--idle 20] [--steps a,b] [--relay-port 0]
               [--record DIR] [--probes 0] [--png-font FONT ...]

One fresh TUI process per screen. It starts against readonly_proxy.py, which
forwards reads to --upstream-port (a live server or frozen_server.py), the
step's keys bring it to its screen, and then nothing is pressed for --idle
seconds. In that window the tool counts what the TUI wrote to its terminal
(bytes, and bursts: output separated by at least BURST_GAP_S of silence), the
CPU time `ps` reports for it, its RSS at the end, which screen rows changed
and which cells of them moved, and the frames the TUI itself recorded
(MASC_TUI_FRAME_TIMING) with their build and present times. With --probes N
it then presses Down N times and Up N times, each timed from the write to the
first byte back, skipping a press when the screen was still drawing.

The frame report's times count from the TUI's start, so the window is placed
in it by the time since the fork; the exec delay is the error. The TUI keeps
the first 512 frames of each phase; when the window reaches past them its
frame counts are marked not covered.

The TUI starts a MASC server itself when nothing answers on its port
(bin/masc_tui.ml react_to_server_contact). It looks for `masc` beside its own
binary and then on PATH (bin/masc_tui_server_lifecycle.ml). So the TUI runs
from a copy of --tui in a temporary directory, with every PATH directory that
holds a `masc` left out: if the relay stops answering, the TUI has no server to
start. Besides, the relay must answer GET /health with 200 before the first
TUI starts, and each TUI is stopped before the relay.

The TUI gets only HOME, PATH (as above), LANG and MASC_TOKEN from this
process's environment, plus TERM, COLORTERM and MASC_TUI_FRAME_TIMING, so a
MASC_HTTP_BASE_URL, MASC_BASE_PATH or MASC_CONFIG_DIR here cannot send it past
the relay or to another configuration.

SIGINT, SIGTERM and SIGHUP end the run the same way: the TUI on screen is
stopped, then the relay, the preferences file is put back and idle.json is
written with `aborted`. A signal that arrives while a TUI is being started or
while the run cleans up waits until that step ends. The relay runs in its own
session, so Ctrl-C and a closing terminal reach only this process, and it
stops by itself when this process exits.

`v` on the Keeper list writes <base-path>/.masc/config/tui-keepers.toml. The
tool reads that file before the first TUI and, when the run ends, puts it back
as it was under the lock the TUI takes to write it (bin/masc_tui_config.ml).

Everything under --out and --record holds workspace data. See README.md.
"""
import argparse
from collections.abc import Generator, Mapping, Sequence
import contextlib
from dataclasses import dataclass
import enum
import errno
import fcntl
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from types import FrameType
from typing import IO

from pty_driver import (POLL_S, Child, Exit, Geometry, Jump, Key, Press, Sent, first_frame, press, read_chunk, settle,
                        spawn, stop, take)
from relay_files import json_object
from vte import Vte, png_cell_size, render_png

HERE = Path(__file__).resolve().parent
RELAY_SCRIPT = HERE / 'readonly_proxy.py'
LOOPBACK = '127.0.0.1'
LISTENING = 'listening'
HEALTH_PATH = '/health'
REPORT_NAME = 'idle.json'
RELAY_LOG_NAME = 'relay.jsonl'
RELAY_ERR_NAME = 'relay.err'
PREFERENCES = Path('.masc') / 'config' / 'tui-keepers.toml'
LOCK_SUFFIX = '.lock'
LOCK_MODE = 0o644
LOCK_LIMIT_S = 5.0
LOCK_RETRY_S = 0.05
LOCK_BUSY = frozenset({errno.EACCES, errno.EAGAIN})  # what lockf with LOCK_NB fails with when held
FILE_MODE_BITS = 0o7777
SERVER_BINARY = 'masc'  # what the TUI looks for beside itself and on PATH
COPY_PREFIX = 'masc-tui-idle-'
STOP_SIGNALS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
FRAME_TIMING_ENV = 'MASC_TUI_FRAME_TIMING'
FRAME_SCHEMA = 'masc.tui.frame.v2'
OMITTED_LINE = re.compile(r'\s*(build|present) omitted=(\d+) after first \d+ frames')
PASSED_ENV = ('HOME', 'PATH', 'LANG', 'MASC_TOKEN')
TERM = 'xterm-256color'
COLORTERM = 'truecolor'
DEFAULT_SIZE = '160x46'
DEFAULT_IDLE_S = 20.0
DEFAULT_CELL_WIDTH_PX = 10
DEFAULT_CELL_HEIGHT_PX = 22
USAGE_ERROR = 2
# The run finished, but a screen did not open or reach its keys, or the relay's
# refusals could not be read: the report holds why.
INCOMPLETE = 3
NS_PER_S = 1_000_000_000
MS_PER_S = 1000
KIB = 1024
SECONDS_PER_MINUTE = 60
SECONDS_PER_DAY = 86400
RELAY_START_LIMIT_S = 10.0
RELAY_STOP_GRACE_S = 5.0
HEALTH_TIMEOUT_S = 10.0
START_LIMIT_S = 30.0  # the first frame; a cold start can take seconds
START_QUIET_S = 2.0
# After the first frame. A screen that redraws at least every START_QUIET_S
# never goes quiet and waits this long before its keys.
START_SETTLE_LIMIT_S = 12.0
STEP_QUIET_S = 1.0
STEP_LIMIT_S = 6.0
STOP_GRACE_S = 5.0
BURST_GAP_S = 0.008  # about one frame at the TUI's 60 Hz cap
TOP_ROWS = 3
CHANGED_ROWS = 8
SAMPLE_CHARS = 120
MOVING_CHARS = 40
DOWN = b'\x1b[B'
UP = b'\x1b[A'
PROBE_WAIT_S = 1.0
PROBE_GAP_S = 0.35
PROBE_QUIET_S = 0.2  # silence that counts as a settled screen before a probe key
PROBE_SETTLE_LIMIT_S = 2.0


@dataclass(frozen=True, slots=True)
class Step:
    name: str
    keys: tuple[Key, ...]


def go(target: str) -> Jump:
    return Jump(f'go {target}')


V = Press(b'v')

# One row per screen with the keys that reach it. Every screen runs in a fresh
# TUI, so its keys start from the screen the TUI opens on. Jumps are `go`
# entries of bin/masc_tui_palette.ml; single keys are bindings of
# bin/masc_tui_keys.ml for the screen the jump reached.
STEPS: tuple[Step, ...] = (
    Step('overview', (go('Operations'),)),
    Step('usage_plan', (go('Operations / Usage'),)),
    # Usage opens on Plan; v walks Plan, Trend, Keepers, Calls.
    Step('usage_calls', (go('Operations / Usage'), V, V, V)),
    Step('usage_telemetry', (go('Operations / Usage'), Press(b'p'))),
    Step('work_goals', (go('Work'),)),
    Step('work_tasks', (go('Work'), Press(b't'))),
    Step('work_requests', (go('Work / Requests'),)),
    Step('work_board', (go('Work / Board'),)),
    # The Keeper list opens on the view tui-keepers.toml stores, so a number of
    # `v` presses reaches a different view in each workspace.
    Step('keepers', (go('Keepers'),)),
    Step('features', (go('Features & plugins'),)),
    Step('features_tools', (go('Features & plugins / Tools & Skills'),)),
    Step('workspace', (go('Workspace'),)),
    Step('system', (go('System'),)),
)
STEP_NAMES = {step.name: step for step in STEPS}


@dataclass(frozen=True, slots=True)
class Options:
    tui: Path
    out: Path
    base_path: Path
    geometry: Geometry
    idle_s: float
    steps: tuple[Step, ...]
    upstream_port: int
    relay_port: int
    record: Path | None
    probes: int
    png_fonts: tuple[Path, ...]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description='Idle cost of each TUI screen through the read-only relay.')
    parser.add_argument('--tui', type=Path, required=True, help='masc-tui binary to measure')
    parser.add_argument('--out', type=Path, required=True, help='new directory for the results (workspace data)')
    parser.add_argument('--base-path', type=Path, required=True, help='workspace the TUI opens')
    parser.add_argument('--upstream-port', type=int, required=True,
                        help='port of the server behind the relay: a live server or frozen_server.py')
    parser.add_argument('--size', default=DEFAULT_SIZE, help=f'COLUMNSxROWS (default {DEFAULT_SIZE})')
    parser.add_argument('--idle', type=float, default=DEFAULT_IDLE_S,
                        help=f'seconds without keys per screen (default {DEFAULT_IDLE_S:g})')
    parser.add_argument('--steps', default='',
                        help='comma-separated screen names; default all: ' + ','.join(STEP_NAMES))
    parser.add_argument('--relay-port', type=int, default=0, help='relay port; 0, the default, takes a free one')
    parser.add_argument('--record', type=Path, default=None,
                        help='new directory where the relay keeps every answer for frozen_server.py')
    parser.add_argument('--probes', type=int, default=0, help='Down and Up presses timed after each window')
    parser.add_argument('--png-font', type=Path, action='append', default=[],
                        help='monospace font file; draws each screen to <name>.png at the window start (needs '
                             'Pillow). Repeat it to add fallbacks: the first sets the cell size, and each glyph '
                             'uses the first font that has it')
    return parser


def parse_options(argv: Sequence[str] | None) -> Options | str:
    args = build_parser().parse_args(argv)
    tui: Path = args.tui
    out: Path = args.out
    base_path: Path = args.base_path
    size: str = args.size
    idle_s: float = args.idle
    steps_text: str = args.steps
    upstream_port: int = args.upstream_port
    relay_port: int = args.relay_port
    record: Path | None = args.record
    probes: int = args.probes
    png_fonts: tuple[Path, ...] = tuple(args.png_font)
    if not (tui.is_file() and os.access(tui, os.X_OK)):
        return f'--tui {tui} is not an executable file'
    if tui.resolve().name == SERVER_BINARY:
        return f'--tui names the server binary `{SERVER_BINARY}`; give the masc-tui binary'
    if not base_path.is_dir():
        return f'--base-path {base_path} is not a directory'
    if out.exists():
        return f'--out {out} exists; give a new directory'
    if record is not None and record.exists():
        return f'--record {record} exists; give a new directory'
    sized = re.fullmatch(r'(\d+)x(\d+)', size)
    if sized is None:
        return f'--size {size!r} is not COLUMNSxROWS'
    if idle_s <= 0:
        return '--idle must be positive'
    if probes < 0:
        return '--probes must not be negative'
    names = [name for name in steps_text.split(',') if name]
    unknown = [name for name in names if name not in STEP_NAMES]
    if unknown:
        return f'unknown step {", ".join(unknown)}; known: {", ".join(STEP_NAMES)}'
    cell = (DEFAULT_CELL_WIDTH_PX, DEFAULT_CELL_HEIGHT_PX)
    if png_fonts:
        measured = png_cell_size(png_fonts[0])
        if isinstance(measured, str):
            return f'--png-font: {measured}'
        cell = measured
    geometry = Geometry(int(sized.group(1)), int(sized.group(2)), cell[0], cell[1])
    steps = tuple(STEP_NAMES[name] for name in names) if names else STEPS
    return Options(tui.resolve(), out, base_path.resolve(), geometry, idle_s, steps,
                   upstream_port, relay_port, record, probes, png_fonts)


@dataclass(frozen=True, slots=True)
class Stats:
    n: int
    p50: float | None
    p95: float | None
    p99: float | None
    max: float | None

    def report(self) -> dict[str, object]:
        return {'n': self.n, 'p50': self.p50, 'p95': self.p95, 'p99': self.p99, 'max': self.max}


def stats(values: Sequence[float]) -> Stats:
    """Nearest-rank percentiles, rounded to 0.01."""
    ordered = sorted(values)

    def at(fraction: float) -> float | None:
        if not ordered:
            return None
        return round(ordered[round(fraction * (len(ordered) - 1))], 2)

    return Stats(len(ordered), at(0.5), at(0.95), at(0.99), at(1.0))


@dataclass(frozen=True, slots=True)
class RowChange:
    row: int
    changes: int
    sample: str
    moving: str

    def report(self) -> dict[str, object]:
        return {'row': self.row, 'changes': self.changes, 'sample': self.sample, 'moving': self.moving}


def moving_span(before: str, after: str) -> str:
    """Where two versions of a row differ: the first column and the text there."""
    low = 0
    while low < min(len(before), len(after)) and before[low] == after[low]:
        low += 1
    high_before, high_after = len(before), len(after)
    while high_before > low and high_after > low and before[high_before - 1] == after[high_after - 1]:
        high_before -= 1
        high_after -= 1
    return f'@{low}: {before[low:high_before][:MOVING_CHARS]!r} -> {after[low:high_after][:MOVING_CHARS]!r}'


@dataclass(frozen=True, slots=True)
class Window:
    wall: tuple[float, float]
    since_start_ns: tuple[int, int]
    seconds: float
    pty_bytes: int
    bursts: int
    cpu_s: float | None
    row_changes: tuple[RowChange, ...]
    terminal_closed: bool

    def report(self) -> dict[str, object]:
        seconds = self.seconds
        return {
            'window': {'wall': list(self.wall), 'since_start_ns': list(self.since_start_ns),
                       'seconds': round(seconds, 2), 'terminal_closed': self.terminal_closed},
            'idle': {'pty_bytes': self.pty_bytes, 'bytes_per_s': round(self.pty_bytes / seconds, 1),
                     'bursts': self.bursts, 'bursts_per_s': round(self.bursts / seconds, 2),
                     'cpu_pct': None if self.cpu_s is None else round(100 * self.cpu_s / seconds, 2)},
            'row_changes': [change.report() for change in self.row_changes],
        }


def parse_cpu_time(text: str) -> float | None:
    """`ps -o time=`: [dd-][hh:]mm:ss[.ff]."""
    days_text, _, clock = text.strip().rpartition('-')
    try:
        days = int(days_text) if days_text else 0
        seconds = 0.0
        for part in clock.split(':'):
            seconds = seconds * SECONDS_PER_MINUTE + float(part)
    except ValueError:
        return None
    return days * SECONDS_PER_DAY + seconds


def ps_field(pid: int, field: str) -> str:
    return subprocess.run(['ps', '-o', f'{field}=', '-p', str(pid)],
                          capture_output=True, text=True, check=False).stdout.strip()


def cpu_seconds(pid: int) -> float | None:
    text = ps_field(pid, 'time')
    return parse_cpu_time(text) if text else None


def rss_mb(pid: int) -> float | None:
    text = ps_field(pid, 'rss')
    return round(int(text) / KIB, 1) if text.isdigit() else None


def rows_text(vte: Vte) -> list[str]:
    return [vte.row_text(row) for row in range(vte.rows)]


def idle_window(child: Child, vte: Vte, seconds: float) -> Window:
    cpu_before = cpu_seconds(child.pid)
    wall_start = time.time()
    start = time.monotonic()
    last_output = float('-inf')
    total = bursts = 0
    previous = rows_text(vte)
    first_before: dict[int, str] = {}
    latest: dict[int, str] = {}
    counts: dict[int, int] = {}
    closed = False
    while (elapsed := time.monotonic() - start) < seconds:
        chunk = read_chunk(child, min(POLL_S, seconds - elapsed))
        if chunk is None:
            closed = True
            break
        if not chunk:
            continue
        arrived = time.monotonic()
        if arrived - last_output >= BURST_GAP_S:
            bursts += 1
        last_output = arrived
        total += len(chunk)
        take(child, vte, chunk)
        current = rows_text(vte)
        for row, (old, new) in enumerate(zip(previous, current)):
            if old != new:
                first_before.setdefault(row, old)
                counts[row] = counts.get(row, 0) + 1
                latest[row] = new
        previous = current
    end = time.monotonic()
    cpu_after = cpu_seconds(child.pid)
    busiest = sorted(counts.items(), key=lambda item: -item[1])[:CHANGED_ROWS]
    changes = tuple(RowChange(row, count, ' '.join(latest[row].split())[:SAMPLE_CHARS],
                              moving_span(first_before[row], latest[row])) for row, count in busiest)
    cpu = None if cpu_before is None or cpu_after is None else cpu_after - cpu_before
    return Window((wall_start, time.time()),
                  (round((start - child.started) * NS_PER_S), round((end - child.started) * NS_PER_S)),
                  end - start, total, bursts, cpu, changes, closed)


def probe(child: Child, vte: Vte, key: bytes, presses: int) -> tuple[list[float], int]:
    """Milliseconds from writing `key` to the first byte back, for presses made
    on a quiet screen; a busy screen's next frame would answer for the key.
    Also returns how many presses were skipped as busy."""
    latencies: list[float] = []
    busy = 0
    for _ in range(presses):
        if not settle(child, vte, PROBE_QUIET_S, PROBE_SETTLE_LIMIT_S):
            busy += 1
            continue
        os.write(child.fd, key)
        sent = time.monotonic()
        chunk = read_chunk(child, PROBE_WAIT_S)
        if chunk is None:
            break
        if chunk:
            latencies.append((time.monotonic() - sent) * MS_PER_S)
            take(child, vte, chunk)
        time.sleep(PROBE_GAP_S)
    return latencies, busy


@dataclass(frozen=True, slots=True)
class Frames:
    covered: bool
    build_ms: Stats
    present_ms: Stats
    present_bytes: Stats
    surfaces: Mapping[str, int]
    omitted: Mapping[str, int]

    def report(self) -> dict[str, object]:
        return {'covered': self.covered, 'build_ms': self.build_ms.report(),
                'present_ms': self.present_ms.report(), 'present_bytes': self.present_bytes.report(),
                'surfaces': dict(self.surfaces), 'omitted': dict(self.omitted)}


def json_fields(line: str) -> dict[str, object] | None:
    try:
        decoded: object = json.loads(line)
    except (ValueError, RecursionError):
        return None
    return json_object(decoded)


def ns_field(fields: Mapping[str, object], name: str) -> int | None:
    value = fields.get(name)
    return int(value) if isinstance(value, str) and value.isdigit() else None


def frames_in(path: Path, low_ns: int, high_ns: int) -> Frames | str:
    """The frames the TUI recorded as started inside [low_ns, high_ns]."""
    try:
        lines = path.read_text(encoding='utf-8', errors='replace').splitlines()
    except OSError as exc:
        return f'frame report {path.name}: {exc.strerror}'
    build: list[float] = []
    present: list[float] = []
    present_bytes: list[float] = []
    surfaces: dict[str, int] = {}
    omitted: dict[str, int] = {}
    last_build_ns = -1
    for line in lines:
        cap = OMITTED_LINE.match(line)
        if cap is not None:
            omitted[cap.group(1)] = int(cap.group(2))
            continue
        fields = json_fields(line) if line.startswith('{') else None
        if fields is None or fields.get('schema') != FRAME_SCHEMA:
            continue
        started, elapsed = ns_field(fields, 'started_ns'), ns_field(fields, 'elapsed_ns')
        if started is None or elapsed is None:
            continue
        phase = fields.get('phase')
        if phase == 'build':
            last_build_ns = max(last_build_ns, started)
        if not low_ns <= started <= high_ns:
            continue
        if phase == 'build':
            build.append(elapsed / NS_PER_S * MS_PER_S)
            surface = fields.get('surface')
            name = surface if isinstance(surface, str) else 'unknown'
            surfaces[name] = surfaces.get(name, 0) + 1
        elif phase == 'present':
            present.append(elapsed / NS_PER_S * MS_PER_S)
            output = json_object(fields.get('output'))
            written = None if output is None else output.get('bytes')
            if isinstance(written, int):
                present_bytes.append(float(written))
    covered = omitted.get('build', 0) == 0 or last_build_ns >= high_ns
    return Frames(covered, stats(build), stats(present), stats(present_bytes), surfaces, omitted)


@contextlib.contextmanager
def stop_signals_held() -> Generator[None]:
    """A stop signal that arrives inside the block waits until the block ends,
    so the block is not cut in half: a TUI is either not started or recorded in
    `Running`, and a cleanup runs to its end."""
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, STOP_SIGNALS)
    try:
        yield
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


class Running:
    """The TUI that is running, if any, so that the run's cleanup stops it
    before the relay whatever ended the run."""

    def __init__(self) -> None:
        self.tui: Child | None = None

    def start_tui(self, argv: Sequence[str], env: Mapping[str, str], geometry: Geometry) -> Child:
        with stop_signals_held():
            child = spawn(argv, env, geometry)
            self.tui = child
        return child

    def stop_tui(self) -> Exit | None:
        with stop_signals_held():
            child, self.tui = self.tui, None
            return None if child is None else stop(child, STOP_GRACE_S)


def run_screen(step: Step, options: Options, tui: Path, relay_port: int, env: Mapping[str, str],
               running: Running) -> dict[str, object]:
    timing_path = options.out / f'{step.name}.frame-timing.txt'
    argv = [str(tui), '--base-path', str(options.base_path), '--port', str(relay_port)]
    child = running.start_tui(argv, {**env, FRAME_TIMING_ENV: str(timing_path)}, options.geometry)
    vte = Vte(options.geometry.columns, options.geometry.rows)
    # The TUI's stderr goes to <base-path>/.masc/logs/masc-tui-<pid>.log.
    result: dict[str, object] = {'name': step.name, 'pid': child.pid}
    window: Window | None = None
    try:
        result['opened'] = first_frame(child, vte, START_LIMIT_S)
        settle(child, vte, START_QUIET_S, START_SETTLE_LIMIT_S)
        sent: list[Sent] = []
        for key in step.keys:
            sent.append(press(child, vte, key))
        settle(child, vte, STEP_QUIET_S, STEP_LIMIT_S)
        result |= {'keys': [entry.report() for entry in sent], 'keys_ok': all(entry.ok for entry in sent),
                   'top_rows': [vte.row_text(row) for row in range(min(TOP_ROWS, vte.rows))]}
        if options.png_fonts:
            png_path = options.out / f'{step.name}.png'
            failed = render_png(vte, png_path, options.png_fonts)
            result['png'] = png_path.name if failed is None else {'error': failed}
        window = idle_window(child, vte, options.idle_s)
        result |= window.report()
        result['rss_mb'] = rss_mb(child.pid)
        if options.probes:
            down, down_busy = probe(child, vte, DOWN, options.probes)
            up, up_busy = probe(child, vte, UP, options.probes)
            result |= {'key_latency_ms': stats(down + up).report(), 'key_busy_skipped': down_busy + up_busy}
    except OSError as exc:
        result['error'] = f'terminal: {exc}'
    finally:
        exited = running.stop_tui()
        result['exit'] = None if exited is None else exited.report()
    if window is not None:
        frames = frames_in(timing_path, *window.since_start_ns)
        result['frames'] = {'error': frames} if isinstance(frames, str) else frames.report()
    return result


@dataclass(frozen=True, slots=True)
class Relay:
    process: subprocess.Popen[bytes]
    port: int


def start_relay(options: Options, err: IO[bytes]) -> Relay | str:
    argv = [sys.executable, str(RELAY_SCRIPT), '--upstream-port', str(options.upstream_port),
            '--listen-port', str(options.relay_port), '--log', str(options.out / RELAY_LOG_NAME),
            '--until-stdin-closes']
    if options.record is not None:
        argv += ['--record', str(options.record)]
    # Its own session: Ctrl-C and a closing terminal signal this process
    # only, which stops the TUI before the relay. The stdin pipe is never
    # written; it closes when this process exits, and the relay stops then.
    process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err,
                               start_new_session=True)
    stdout = process.stdout
    line = ''
    if stdout is not None and select.select([stdout], [], [], RELAY_START_LIMIT_S)[0]:
        line = stdout.readline().decode('utf-8', 'replace').strip()
    word, _, port = line.partition(' ')
    if word == LISTENING and port.isdigit():
        return Relay(process, int(port))
    stop_relay(process)
    return f'the relay did not start (first line {line!r}); see {RELAY_ERR_NAME}'


def stop_relay(process: subprocess.Popen[bytes]) -> int:
    process.terminate()
    try:
        return process.wait(RELAY_STOP_GRACE_S)
    except subprocess.TimeoutExpired:
        process.kill()
        return process.wait()


def health_status(port: int) -> int | str:
    connection = http.client.HTTPConnection(LOOPBACK, port, timeout=HEALTH_TIMEOUT_S)
    try:
        connection.request('GET', HEALTH_PATH)
        response = connection.getresponse()
        response.read()
        return response.status
    except (OSError, http.client.HTTPException) as exc:
        return f'{type(exc).__name__}: {exc}'
    finally:
        connection.close()


class Restore(enum.Enum):
    UNCHANGED = 'unchanged'
    RESTORED = 'restored'
    REMOVED = 'removed'
    LOCK_HELD = 'lock-held'  # left as the run found it at the end: the lock was not taken


@dataclass(frozen=True, slots=True)
class Content:
    data: bytes
    mode: int


@dataclass(frozen=True, slots=True)
class Snapshot:
    path: Path
    content: Content | None  # None: the file did not exist


def read_or_none(path: Path) -> Content | None:
    try:
        with path.open('rb') as binary:
            return Content(binary.read(), os.fstat(binary.fileno()).st_mode & FILE_MODE_BITS)
    except FileNotFoundError:
        return None


def same(current: Content | None, snapshot: Content | None) -> bool:
    if current is None or snapshot is None:
        return current is snapshot
    return current == snapshot


def acquire(fd: int) -> bool:
    """An exclusive record lock on `fd`, waiting up to LOCK_LIMIT_S."""
    deadline = time.monotonic() + LOCK_LIMIT_S
    while True:
        try:
            fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError as exc:
            if exc.errno not in LOCK_BUSY or time.monotonic() >= deadline:
                return False
        time.sleep(LOCK_RETRY_S)


@contextlib.contextmanager
def file_lock(lock_path: Path) -> Generator[bool]:
    """The lock the TUI holds while it edits the file: a POSIX record lock on
    `<file>.lock` (lib/process/file_lock_eio.ml, Unix.lockf). Yields False when
    it was not taken; closing the descriptor releases it."""
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, LOCK_MODE)
    try:
        yield acquire(fd)
    finally:
        os.close(fd)


def restore(snapshot: Snapshot) -> Restore:
    """Put the file back as the snapshot found it, content and mode. A change
    anyone made to it during the run is undone too."""
    if same(read_or_none(snapshot.path), snapshot.content):
        return Restore.UNCHANGED
    with file_lock(snapshot.path.with_name(snapshot.path.name + LOCK_SUFFIX)) as locked:
        if not locked:
            return Restore.LOCK_HELD
        if same(read_or_none(snapshot.path), snapshot.content):
            return Restore.UNCHANGED
        if snapshot.content is None:
            snapshot.path.unlink(missing_ok=True)
            return Restore.REMOVED
        staged = snapshot.path.with_name(snapshot.path.name + '.idle-restore')
        staged.write_bytes(snapshot.content.data)
        os.chmod(staged, snapshot.content.mode)
        os.replace(staged, snapshot.path)
        return Restore.RESTORED


def path_without_server(path: str) -> str:
    """PATH without the directories that hold a `masc`. The TUI takes any file
    of that name it finds there (bin/masc_tui.ml find_executable_in_path)."""
    return os.pathsep.join(entry for entry in path.split(os.pathsep)
                           if entry and not os.path.lexists(os.path.join(entry, SERVER_BINARY)))


def server_free_copy(tui: Path, directory: Path) -> Path:
    """The TUI binary copied where no `masc` sits beside it."""
    copy = directory / tui.name
    shutil.copy2(tui, copy)
    return copy


def tui_environment(caller: Mapping[str, str]) -> dict[str, str]:
    passed = {name: caller[name] for name in PASSED_ENV if name in caller}
    if 'PATH' in passed:
        passed['PATH'] = path_without_server(passed['PATH'])
    return {**passed, 'TERM': TERM, 'COLORTERM': COLORTERM}


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as binary:
        while block := binary.read(1 << 20):
            digest.update(block)
    return digest.hexdigest()


def refused_requests(log_path: Path) -> list[dict[str, object]] | str:
    """The relay's refusals, or why they cannot be counted. The count is the
    evidence that only reads went through, so an unreadable log is not zero."""
    try:
        lines = log_path.read_text(encoding='utf-8').splitlines()
    except OSError as exc:
        return f'{log_path}: {exc.strerror}'
    refused: list[dict[str, object]] = []
    for lineno, line in enumerate(lines, 1):
        fields = json_fields(line)
        if fields is None:
            return f'{log_path}:{lineno}: not a JSON object'
        if fields.get('decision') == 'refused':
            refused.append({name: fields.get(name) for name in ('t', 'verb', 'path', 'why')})
    return refused


def screen_failed(result: Mapping[str, object]) -> bool:
    return 'error' in result or result.get('opened') is False or result.get('keys_ok') is False


def restore_or_why(snapshot: Snapshot) -> str:
    """restore(), with a failure written down instead of raised, so the
    report still gets the relay's exit and refusals."""
    try:
        return restore(snapshot).value
    except OSError as exc:
        return f'not restored: {snapshot.path}: {exc.strerror}'


def screen_line(result: Mapping[str, object]) -> str:
    idle = result.get('idle')
    idle_text = json.dumps(idle) if isinstance(idle, dict) else str(result.get('error', 'no window'))
    return f'[{result.get("name")}] keys_ok={result.get("keys_ok")} {idle_text}'


def write_report(path: Path, report: Mapping[str, object]) -> None:
    staged = path.with_name(path.name + '.tmp')
    staged.write_text(json.dumps(report, ensure_ascii=False, indent=1), encoding='utf-8')
    os.replace(staged, path)


def stop_on_signal(signum: int, frame: FrameType | None) -> None:
    del frame
    raise SystemExit(128 + signum)


def measure(options: Options, tui: Path, relay: Relay, running: Running, report: dict[str, object],
            screens: list[dict[str, object]]) -> None:
    report_path = options.out / REPORT_NAME
    health = health_status(relay.port)
    if health != http.client.OK:
        report['aborted'] = f'GET {HEALTH_PATH} through the relay answered {health}; no TUI ran'
        print(f'idle: {report["aborted"]}', file=sys.stderr)
        return
    env = tui_environment(os.environ)
    for step in options.steps:
        if relay.process.poll() is not None:
            report['aborted'] = f'the relay exited before {step.name}'
            return
        result = run_screen(step, options, tui, relay.port, env, running)
        screens.append(result)
        write_report(report_path, report)
        print(screen_line(result), flush=True)


def main(argv: Sequence[str] | None = None) -> int:
    options = parse_options(argv)
    if isinstance(options, str):
        print(f'idle: {options}', file=sys.stderr)
        return USAGE_ERROR
    # Each stop signal must reach the finally below, which stops the TUI before
    # the relay and puts the preferences back.
    for signum in STOP_SIGNALS:
        signal.signal(signum, stop_on_signal)
    options.out.mkdir(parents=True)
    report_path = options.out / REPORT_NAME
    preferences = Snapshot(options.base_path / PREFERENCES, read_or_none(options.base_path / PREFERENCES))
    screens: list[dict[str, object]] = []
    report: dict[str, object] = {
        'tui': options.tui.name, 'tui_sha256': sha256_of(options.tui),
        'size': f'{options.geometry.columns}x{options.geometry.rows}', 'idle_s': options.idle_s,
        'probes': options.probes, 'upstream_port': options.upstream_port,
        'recorded': options.record is not None, 'screens': screens,
    }
    running = Running()
    with tempfile.TemporaryDirectory(prefix=COPY_PREFIX) as scratch, \
            (options.out / RELAY_ERR_NAME).open('wb') as relay_err:
        tui = server_free_copy(options.tui, Path(scratch))
        relay = start_relay(options, relay_err)
        if isinstance(relay, str):
            print(f'idle: {relay}; no TUI ran', file=sys.stderr)
            return USAGE_ERROR
        report['relay_port'] = relay.port
        try:
            measure(options, tui, relay, running, report, screens)
        except SystemExit:
            report['aborted'] = 'stopped by a signal; the screen it was on has no result'
            raise
        finally:
            with stop_signals_held():
                running.stop_tui()
                relay_exit = stop_relay(relay.process)
                refused = refused_requests(options.out / RELAY_LOG_NAME)
                restored = restore_or_why(preferences)
                report |= {'relay': {'exit': relay_exit,
                                     'refused': refused if isinstance(refused, list) else {'error': refused}},
                           'preferences': restored}
                write_report(report_path, report)
            refused_text = str(len(refused)) if isinstance(refused, list) else f'? ({refused})'
            print(f'relay refused {refused_text}; {PREFERENCES.name} {restored}; report {report_path}', flush=True)
    if 'aborted' in report:
        return USAGE_ERROR
    if not isinstance(refused, list) or restored.startswith('not restored') or any(map(screen_failed, screens)):
        return INCOMPLETE
    return 0


if __name__ == '__main__':
    sys.exit(main())
