#!/usr/bin/env python3
# pyright: strict
"""One line per screen from idle.py's results, and with --reads what the TUI
read in each idle window.

usage: summary.py OUT [OUT ...] [--reads]

Screen line: frames per second the TUI recorded in the window ('?' when the
window reached past the frames it keeps, '-' without a frame report), PTY bytes
per second, CPU percent, RSS, build p50/p95 in ms, and the rows that changed
most with the cells that moved. A screen with an error shows the error instead,
and one that did not land on the surface its step names shows the surface that
was on screen.

--reads adds, per window, from the relay's log in the same directory:
  reads    requests that arrived in the window and are not event streams,
           by path without the query: count, kilobytes, statuses
  refused  requests the relay refused in the window
  streams  per event name, the events and bytes between the last progress
           line of each stream at or before the window start and the last one
           at or before its end; rates divide by the time between those two
           lines, not by the window
"""
import argparse
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
import json
from pathlib import Path
import sys
from typing import cast

from relay_files import json_object, path_of, read_log

REPORT_NAME = 'idle.json'
RELAY_LOG_NAME = 'relay.jsonl'
SHOWN_ROWS = 3
SHOWN_PATHS = 10
MOVING_CHARS = 38
KB = 1000


def number(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, int | float):
        return None
    return float(value)


def objects(value: object) -> list[dict[str, object]]:
    if not isinstance(value, list):
        return []
    found: list[dict[str, object]] = []
    for item in cast(list[object], value):
        fields = json_object(item)
        if fields is not None:
            found.append(fields)
    return found


def field(fields: object, *path: str) -> object:
    value = fields
    for name in path:
        current = json_object(value)
        if current is None:
            return None
        value = current.get(name)
    return value


def text(value: object, missing: str = '-') -> str:
    return missing if value is None else str(value)


def frames_per_second(screen: Mapping[str, object]) -> str:
    frames = json_object(screen.get('frames'))
    seconds = number(field(screen, 'window', 'seconds'))
    count = number(field(frames, 'build_ms', 'n'))
    if frames is None or seconds is None or count is None or not seconds:
        return '-'
    if frames.get('covered') is not True:
        return '?'
    return f'{count / seconds:.2f}'


def screen_line(screen: Mapping[str, object]) -> str:
    changes = sorted(objects(screen.get('row_changes')), key=lambda change: -(number(change.get('changes')) or 0))
    rows = ' | '.join(f'{text(change.get("row"))}x{text(change.get("changes"))} '
                      f'{text(change.get("moving"))[:MOVING_CHARS]}' for change in changes[:SHOWN_ROWS])
    bytes_per_s = number(field(screen, 'idle', 'bytes_per_s'))
    cpu = number(field(screen, 'idle', 'cpu_pct'))
    rss = number(screen.get('rss_mb'))
    build = f'{text(field(screen, "frames", "build_ms", "p50"))}/{text(field(screen, "frames", "build_ms", "p95"))}'
    error = screen.get('error')
    landed = json_object(screen.get('landed'))
    if isinstance(error, str):
        tail = f'error: {error}'
    elif landed is not None and landed.get('ok') is not True:
        tail = f'not landed: {text(landed.get("shown"))} on screen, {text(landed.get("expected"))} named'
    else:
        tail = rows
    return (f'{text(screen.get("name"), "?"):16s} {frames_per_second(screen):>8s} '
            f'{text(None if bytes_per_s is None else f"{bytes_per_s:.1f}"):>9s} '
            f'{text(None if cpu is None else f"{cpu:.2f}"):>6s} {text(None if rss is None else f"{rss:.0f}"):>7s} '
            f'{build:>17s}  {tail}')


@dataclass(frozen=True, slots=True)
class Point:
    t: float
    events: Mapping[str, tuple[int, int]]


def stream_points(log: Sequence[Mapping[str, object]]) -> dict[tuple[str, float], list[Point]]:
    """Per stream (target, arrival time), its cumulative per-event counts over time."""
    streams: dict[tuple[str, float], list[Point]] = {}
    for entry in log:
        decision = entry.get('decision')
        if decision != 'progress' and not (decision == 'done' and entry.get('stream') is True):
            continue
        target, started, t = entry.get('path'), number(entry.get('started')), number(entry.get('t'))
        events = json_object(entry.get('events'))
        if not isinstance(target, str) or started is None or t is None or events is None:
            continue
        counts = {name: (int(number(field(value, 'events')) or 0), int(number(field(value, 'bytes')) or 0))
                  for name, value in events.items()}
        streams.setdefault((target, started), []).append(Point(t, counts))
    for points in streams.values():
        points.sort(key=lambda point: point.t)
    return streams


def window_streams(streams: Mapping[tuple[str, float], list[Point]], low: float, high: float) -> list[str]:
    lines: list[str] = []
    for (target, _), points in sorted(streams.items()):
        before = [point for point in points if point.t <= low]
        upto = [point for point in points if point.t <= high]
        if not before or not upto or upto[-1] is before[-1]:
            continue
        first, last = before[-1], upto[-1]
        span = last.t - first.t
        lines.append(f'   stream {path_of(target)} over {span:.1f}s')
        deltas = {name: (events - first.events.get(name, (0, 0))[0], size - first.events.get(name, (0, 0))[1])
                  for name, (events, size) in last.events.items()}
        for name, (events, size) in sorted(deltas.items(), key=lambda item: -item[1][1]):
            if events or size:
                lines.append(f'     {name:40s} events={events:6d} bytes={size:10d} '
                             f'{size / span / KB:8.1f} KB/s {events / span:7.1f} ev/s')
    return lines


def window_reads(log: Sequence[Mapping[str, object]], low: float, high: float) -> list[str]:
    reads: dict[str, tuple[int, int, dict[str, int]]] = {}
    refused: dict[str, int] = {}
    for entry in log:
        decision = entry.get('decision')
        target = entry.get('path')
        if not isinstance(target, str):
            continue
        if decision == 'refused':
            t = number(entry.get('t'))
            if t is not None and low <= t <= high:
                key = f'{text(entry.get("verb"))} {path_of(target)} ({text(entry.get("why"))})'
                refused[key] = refused.get(key, 0) + 1
            continue
        started = number(entry.get('started'))
        if decision != 'done' or entry.get('stream') is True or started is None or not low <= started <= high:
            continue
        count, size, statuses = reads.get(path_of(target), (0, 0, {}))
        status = text(entry.get('status'))
        reads[path_of(target)] = (count + 1, size + int(number(entry.get('bytes')) or 0),
                                  {**statuses, status: statuses.get(status, 0) + 1})
    lines = [f'   {count:4d} reads {size / KB:9.1f} KB {statuses} {target}'
             for target, (count, size, statuses) in sorted(reads.items(), key=lambda item: -item[1][1])[:SHOWN_PATHS]]
    lines += [f'   refused {count}x {key}' for key, count in sorted(refused.items())]
    return lines


def relay_exit(report: Mapping[str, object]) -> int | None:
    """The relay's exit as idle.py wrote it; None when the run ended before it was written."""
    code = field(report, 'relay', 'exit')
    return code if isinstance(code, int) and not isinstance(code, bool) else None


def summarize(out: Path, reads: bool) -> list[str]:
    try:
        report = json_object(json.loads((out / REPORT_NAME).read_text(encoding='utf-8')))
    except (OSError, ValueError, RecursionError) as exc:
        return [f'######## {out}: cannot read {REPORT_NAME}: {exc}']
    if report is None:
        return [f'######## {out}: {REPORT_NAME} is not an object']
    lines = [f'######## {out}  tui={text(report.get("tui"))} sha256={text(report.get("tui_sha256"))[:12]} '
             f'size={text(report.get("size"))} idle_s={text(report.get("idle_s"))} '
             f'preferences={text(report.get("preferences"))}',
             f'{"screen":16s} {"frames/s":>8s} {"bytes/s":>9s} {"cpu%":>6s} {"rss MB":>7s} '
             f'{"build p50/p95 ms":>17s}  rows changed (row x count, cells that moved)']
    log = read_log(out / RELAY_LOG_NAME, relay_exit(report)) if reads else []
    if isinstance(log, str):
        lines.append(f'   no relay log: {log}')
        log = []
    streams = stream_points(log)
    for screen in objects(report.get('screens')):
        lines.append(screen_line(screen))
        wall = field(screen, 'window', 'wall')
        bounds = [number(value) for value in cast(list[object], wall)] if isinstance(wall, list) else []
        if not reads or len(bounds) != 2 or bounds[0] is None or bounds[1] is None:
            continue
        low, high = bounds[0], bounds[1]
        lines += window_reads(log, low, high) + window_streams(streams, low, high)
    aborted = report.get('aborted')
    if isinstance(aborted, str):
        lines.append(f'   aborted: {aborted}')
    return lines


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description='Summarize idle.py results.')
    parser.add_argument('out', type=Path, nargs='+', help='directories idle.py --out wrote')
    parser.add_argument('--reads', action='store_true', help='add reads and stream events per idle window')
    args = parser.parse_args(argv)
    outs: list[Path] = args.out
    reads: bool = args.reads
    for out in outs:
        print('\n'.join(summarize(out, reads)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
