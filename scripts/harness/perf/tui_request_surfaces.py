# pyright: strict
"""Which TUI surface was on screen in each window.

With MASC_TUI_FRAME_TIMING set, the TUI's frame-timing report names each run
of frames that showed one surface by the ordinal of the run's first frame
(`masc.tui.surface_run.v1`), and then the number of frames it wrote
(`masc.tui.surface_runs.v1`). A frame is a write that opens with FRAME_START:
a frame of the TUI's presenter, a batch of its machine screen (`machine`), or
the FRAME_START that draws nothing which the TUI writes when a picture drawn
outside the presenter takes the terminal (`image`). The TUI writes it nowhere
else, so the n-th FRAME_START in the terminal stream opens the n-th frame. A
surface is on screen from the arrival of a frame that shows it until the next
frame arrives. Anything that adds a FRAME_START, such as server text that
reaches the terminal unescaped (#48578), makes the two counts differ, and the
runs are then not read.
"""
from bisect import bisect_right
from collections.abc import Sequence
from dataclasses import dataclass
import json

from tui_request_events import json_fields

FRAME_START = b'\x1b[?7l'
RUN_SCHEMA = 'masc.tui.surface_run.v1'
COUNT_SCHEMA = 'masc.tui.surface_runs.v1'
FIRST_WRITTEN_FRAME = 1


class FrameClock:
    """When each FRAME_START arrived, also one split across two reads."""

    __slots__ = ('_tail', 'starts')

    def __init__(self) -> None:
        self._tail = b''
        self.starts: list[float] = []

    def feed(self, data: bytes, now: float) -> None:
        joined = self._tail + data
        start = 0
        while (found := joined.find(FRAME_START, start)) >= 0:
            self.starts.append(now)
            start = found + len(FRAME_START)
        self._tail = joined[max(start, len(joined) - len(FRAME_START) + 1):]


@dataclass(frozen=True, slots=True)
class Runs:
    """The first written frame of each kept run with its surface, in order,
    the written frame from which the TUI recorded no surface, and the number
    of frames it wrote."""
    starts: tuple[int, ...]
    surfaces: tuple[str, ...]
    unknown_from: int | None
    written: int

    def surface(self, frame: int) -> str | None:
        if self.unknown_from is not None and frame >= self.unknown_from:
            return None
        index = bisect_right(self.starts, frame) - 1
        return self.surfaces[index] if index >= 0 else None


@dataclass(frozen=True, slots=True)
class FrameSpan:
    """The frames that arrived in a window, by their place in arrival order:
    the first `first` arrived before it opened, and it holds those up to
    `end`. A frame read together with a step's keys arrived before them, so
    counting rather than timing keeps it in the window before the step."""
    first: int
    end: int


@dataclass(frozen=True, slots=True)
class Shown:
    """A surface on screen in a window, `None` where the TUI recorded none,
    with its seconds on screen and the number of its frames that arrived."""
    surface: str | None
    seconds: float
    frames: int


def count(value: object, least: int) -> int | None:
    """`value` when it is a JSON integer of at least `least`."""
    if isinstance(value, int) and not isinstance(value, bool) and value >= least:
        return value
    return None


def parse_runs(text: str) -> Runs | str:
    """The surface runs in a frame-timing report, or why they cannot be read."""
    starts: list[int] = []
    surfaces: list[str] = []
    counted: Runs | None = None
    # Only LF ends a report line. splitlines() also breaks at U+0085, U+2028
    # and U+2029, which JSON strings in the report may hold unescaped.
    for number, line in enumerate(text.split('\n'), 1):
        if not line.startswith('{'):
            continue
        try:
            fields = json_fields(json.loads(line))
        except (ValueError, RecursionError):
            return f'report line {number} is not JSON'
        schema = fields.get('schema')
        if schema == RUN_SCHEMA:
            surface = fields.get('surface')
            first = count(fields.get('first_written_frame'), FIRST_WRITTEN_FRAME)
            if counted is not None:
                return f'report line {number}: a surface run after the count'
            if not isinstance(surface, str) or not surface or first is None:
                return f'report line {number}: a surface run needs a surface and a written frame'
            if (first <= starts[-1]) if starts else (first != FIRST_WRITTEN_FRAME):
                return f'report line {number}: surface runs are out of order'
            if surfaces and surface == surfaces[-1]:
                return f'report line {number}: a surface run repeats the surface before it'
            starts.append(first)
            surfaces.append(surface)
        elif schema == COUNT_SCHEMA:
            written = count(fields.get('written_frames'), 0)
            kept = count(fields.get('runs'), 0)
            omitted = count(fields.get('omitted'), 0)
            unknown_field = fields.get('unknown_from_written_frame')
            unknown = None if unknown_field is None else count(unknown_field, FIRST_WRITTEN_FRAME)
            if counted is not None:
                return f'report line {number}: a second surface run count'
            if (written is None or kept != len(starts) or omitted is None
                    or (unknown_field is not None and unknown is None)
                    or (omitted == 0) != (unknown is None)
                    or bool(starts) != (written > 0)
                    or (bool(starts) and starts[-1] > written)
                    or (unknown is not None
                        and not (bool(starts) and starts[-1] < unknown <= written))):
                return f'report line {number}: the surface run count does not fit the runs'
            counted = Runs(tuple(starts), tuple(surfaces), unknown, written)
    if counted is None:
        return 'the report has no surface run count'
    return counted


def read_runs(text: str, frames_seen: int) -> Runs | str:
    """The report's runs, when the terminal received every frame they count."""
    runs = parse_runs(text)
    if isinstance(runs, str):
        return runs
    if frames_seen != runs.written:
        return (f'the TUI wrote {runs.written} frames, but the terminal received '
                f'{frames_seen} frame starts')
    return runs


def shown(arrivals: Sequence[float], runs: Runs, frames: FrameSpan, start: float,
          end: float) -> tuple[Shown, ...]:
    """The surfaces on screen from `start` to `end`, in the order they first
    appeared. `arrivals` are when the frames arrived and `frames` are the ones
    that arrived in the window. The frame before them is on screen when the
    window opens; before the first frame arrives nothing is."""
    seconds: dict[str | None, float] = {}
    counts: dict[str | None, int] = {}

    def until(index: int) -> float:
        return arrivals[index + 1] if index + 1 < frames.end else end

    def add(surface: str | None, since: float, to: float, arrived: int) -> None:
        seconds[surface] = seconds.get(surface, 0.0) + max(0.0, min(to, end) - max(since, start))
        counts[surface] = counts.get(surface, 0) + arrived

    if frames.first > 0:
        add(runs.surface(frames.first), start, until(frames.first - 1), 0)
    for index in range(frames.first, frames.end):
        add(runs.surface(index + 1), arrivals[index], until(index), 1)
    return tuple(Shown(surface, seconds[surface], counts[surface]) for surface in seconds)


def record(runs: Runs | str, frames_received: int) -> dict[str, object]:
    """The result's account of the frames and runs the windows' surfaces come from."""
    if isinstance(runs, str):
        return {'frames_received': frames_received, 'frames_written': None, 'runs': None,
                'unknown_from_written_frame': None, 'error': runs}
    return {'frames_received': frames_received, 'frames_written': runs.written,
            'runs': len(runs.starts), 'unknown_from_written_frame': runs.unknown_from,
            'error': None}


def describe(rows: tuple[Shown, ...] | None) -> str:
    if rows is None:
        return 'unknown'
    return ', '.join(f"{'unrecorded' if row.surface is None else row.surface} {row.seconds:.2f}s"
                     for row in rows) or 'nothing drawn'
