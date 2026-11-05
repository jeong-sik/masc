#!/usr/bin/env python3
"""Draw the waste series of scripts/measure-tool-efficiency.py as one SVG.

Input is the file `measure-tool-efficiency.py --json-out` writes. The picture
has four panels on the UTC clock:

- three small multiples over the days: identical re-reads as a share of the
  day's result bytes, results spilled to a blob as a share of the day's result
  bytes, and the hours the day's Execute calls spent blocked on a sleep or poll;
- the last `--hours` hours of result bytes, split into the part spilled to a
  blob and the part kept inline.

`--mark 2026-11-05T02:19:09Z=label` draws a labelled line on the hourly panel at
that instant, for example the instant a tool change reached the server. A mark
outside the plotted hours is an error.

An hour with no row in the input is drawn as an hour with no calls. The last
day is marked with `*` when the last hour in the input is not hour 23, because
that day is still being written. The colors, the 4 px rounded data ends, the
2 px gap between stacked parts and the dark-mode and forced-colors rules follow
the dataviz skill. Each bar carries a `<title>` with its numbers, and the same
numbers are in the JSON the picture is drawn from.

Usage:
    scripts/measure-tool-efficiency.py --base-path ~/me --from-date 2026-11-01 \\
        --to-date 2026-11-05 --json-out result.json
    python3 scripts/tool-efficiency-chart.py --json result.json --out chart.svg \\
        --mark '2026-11-05T02:19:09Z=keeper_artifact_read contains'
"""

from __future__ import annotations

import argparse
import json
import math
import pathlib
import sys
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import cast
from xml.sax.saxutils import escape

JsonObject = dict[str, object]

BYTES_PER_MB = 1_000_000
SECONDS_PER_HOUR = 3600
PERCENT = 100
DAY_FORMAT = "%Y-%m-%d"
HOUR_FORMAT = "%Y-%m-%dT%H"
INSTANT_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
LAST_HOUR_OF_DAY = 23
DEFAULT_HOURS = 48
HOURS_BETWEEN_LABELS = 6
MAX_INTERVALS = 4
STEP_MANTISSAS = (1, 2, 5)
SMALLEST_EXPONENT = -3
LARGEST_EXPONENT = 12

WIDTH = 760
HEIGHT = 552
LEFT = 56
RIGHT = 24
TICK_COLUMN = 34
TICK_GAP = 6
PANEL_COUNT = 3
PANEL_GAP = 34
TITLE_Y = 22
SUBTITLE_Y = 38
DAILY_TITLE_Y = 70
DAILY_TOP = 84
DAILY_BOTTOM = 184
DAILY_LABEL_Y = 200
HOURLY_TITLE_Y = 256
HOURLY_TOP = 312
HOURLY_BOTTOM = 452
HOURLY_LABEL_Y = 468
HOURLY_DATE_Y = 481
NOTE_Y = 516
NOTE_LINE = 14
MAX_BAR = 24.0
MIN_BAR = 1.0
SURFACE_GAP = 2.0
CORNER = 4.0
SWATCH = 8
MARK_LABEL_STEP = 11
MAX_MARKS = 3
MARK_LEAD = 4
CHARACTER_WIDTH = 5.6
SHORT_BAR = 1.0
DAY_LABEL = slice(5, None)

LIGHT = {
    "surface": "#fcfcfb",
    "ink": "#0b0b0b",
    "ink2": "#52514e",
    "muted": "#898781",
    "grid": "#e1e0d9",
    "axis": "#c3c2b7",
    "accent": "#2a78d6",
    "context": "#898781",
}
DARK = {
    "surface": "#1a1a19",
    "ink": "#f0efec",
    "ink2": "#c3c2b7",
    "muted": "#898781",
    "grid": "#2c2c2a",
    "axis": "#383835",
    "accent": "#3987e5",
    "context": "#898781",
}
FORCED = {
    "surface": "Canvas",
    "ink": "CanvasText",
    "ink2": "CanvasText",
    "muted": "CanvasText",
    "grid": "GrayText",
    "axis": "GrayText",
    "accent": "Highlight",
    "context": "GrayText",
}


def color_rules(colors: dict[str, str]) -> str:
    """Class rules with literal colors: an SVG viewer that does not resolve var() still draws them."""
    fills = "".join(f".{name}{{fill:{colors[name]}}}" for name in ("surface", "ink", "ink2", "muted", "accent", "context"))
    strokes = "".join(f".{name}{{stroke:{colors[name]};stroke-width:1;fill:none}}" for name in ("grid", "axis"))
    return f"{fills}{strokes}.mark{{stroke:{colors['muted']};stroke-width:1;fill:none}}"


STYLE = (
    'text{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;font-size:10px}'
    ".title{font-size:13px;font-weight:600}.panel{font-size:11px;font-weight:600}"
    f"{color_rules(LIGHT)}"
    f"@media (prefers-color-scheme:dark){{{color_rules(DARK)}}}"
    f"@media (forced-colors:active){{{color_rules(FORCED)}}}"
)


@dataclass(frozen=True, slots=True)
class Bucket:
    start: datetime
    calls: int
    result_bytes: int
    spilled_bytes: int
    reread_bytes: int
    wait_s: float


@dataclass(frozen=True, slots=True)
class Mark:
    at: datetime
    label: str


@dataclass(frozen=True, slots=True)
class DailyPanel:
    title: str
    suffix: str
    value_of: Callable[[Bucket], float]
    tip_of: Callable[[Bucket, float], str]


def as_object(value: object, where: str) -> JsonObject:
    if not isinstance(value, dict):
        raise ValueError(f"{where} is not an object")
    return cast("JsonObject", value)


def count_of(fields: JsonObject, key: str, where: str) -> float:
    value = fields.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        raise ValueError(f"{where}.{key} is not a non-negative number")
    return float(value)


def parse_bucket(key: str, raw: object, key_format: str, where: str) -> Bucket:
    try:
        start = datetime.strptime(key, key_format).replace(tzinfo=UTC)
    except ValueError as error:
        raise ValueError(f"{where} has the key {key!r}, which is not {key_format}") from error
    fields = as_object(raw, f"{where}.{key}")
    return Bucket(
        start=start,
        calls=int(count_of(fields, "calls", f"{where}.{key}")),
        result_bytes=int(count_of(fields, "result_bytes", f"{where}.{key}")),
        spilled_bytes=int(count_of(fields, "spilled_bytes", f"{where}.{key}")),
        reread_bytes=int(count_of(fields, "reread_bytes", f"{where}.{key}")),
        wait_s=count_of(fields, "wait_s", f"{where}.{key}"),
    )


def parse_series(result: JsonObject, name: str, key_format: str) -> list[Bucket]:
    raw = as_object(result.get(name), name)
    series = sorted((parse_bucket(key, value, key_format, name) for key, value in raw.items()), key=lambda b: b.start)
    if not series:
        raise ValueError(f"{name} has no buckets")
    return series


def reject_constant(token: str) -> object:
    raise ValueError(f"the input holds {token}, which is not JSON")


def read_result(path: pathlib.Path) -> JsonObject:
    try:
        return as_object(json.loads(path.read_text(encoding="utf-8"), parse_constant=reject_constant), "the input")
    except json.JSONDecodeError as error:
        raise ValueError(f"{path} is not JSON: {error}") from error


def hour_window(hourly: list[Bucket], hours: int) -> list[Bucket]:
    """The `hours` hours that end with the last hour of the input; an hour without a row has no calls."""
    by_start = {bucket.start: bucket for bucket in hourly}
    last = hourly[-1].start
    starts = [last - timedelta(hours=offset) for offset in range(hours - 1, -1, -1)]
    return [by_start.get(start, Bucket(start, 0, 0, 0, 0, 0.0)) for start in starts]


def bar_width_of(slot: float, count: int, gap: float, what: str) -> float:
    """The bar width in a slot after the surface gap; a panel whose bars would vanish is an error, not a blank."""
    width = min(MAX_BAR, slot - gap)
    if width < MIN_BAR:
        raise ValueError(f"{count} {what} do not fit in the panel: each bar would be narrower than {MIN_BAR:g} px")
    return width


def label_step(labels: list[str], slot: float) -> int:
    """How many slots the widest label spans; CHARACTER_WIDTH estimates a 10 px label."""
    return max(1, math.ceil(max(len(label) for label in labels) * CHARACTER_WIDTH / slot))


def every_nth_from_last(labels: list[str], slot: float) -> set[int]:
    """The last label and every `step`th one before it, so the newest day is always named."""
    step = label_step(labels, slot)
    return {index for index in range(len(labels)) if (len(labels) - 1 - index) % step == 0}


def peak_and_last(labels: list[str], values: list[float], slot: float) -> set[int]:
    """Every value label when they fit side by side; otherwise the peak, and the last bar when it is clear of the peak."""
    step = label_step(labels, slot)
    if step == 1:
        return set(range(len(labels)))
    peak = values.index(max(values))
    last = len(values) - 1
    return {peak} if last - peak < step else {peak, last}


def share(part: int, whole: int) -> float:
    return PERCENT * part / whole if whole else 0.0


def megabytes(size: int) -> str:
    return f"{size / BYTES_PER_MB:,.2f} MB"


def nice_scale(peak: float) -> tuple[float, list[float]]:
    """A top and ticks on 1, 2 or 5 steps with at most MAX_INTERVALS intervals."""
    if peak <= 0:
        return 1.0, [0.0, 1.0]
    for exponent in range(SMALLEST_EXPONENT, LARGEST_EXPONENT):
        for mantissa in STEP_MANTISSAS:
            step = mantissa * 10.0**exponent
            intervals = math.ceil(peak / step)
            if intervals <= MAX_INTERVALS:
                return step * intervals, [step * index for index in range(intervals + 1)]
    raise ValueError(f"{peak} is too large to scale")


def format_tick(value: float, suffix: str) -> str:
    return f"{value:g}{suffix}"


def text(x: float, y: float, content: str, classes: str, anchor: str = "start") -> str:
    return f'<text x="{x:.1f}" y="{y:.1f}" class="{classes}" text-anchor="{anchor}">{escape(content)}</text>'


def line(x1: float, y1: float, x2: float, y2: float, classes: str) -> str:
    return f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" class="{classes}"/>'


def column_path(x: float, bottom: float, width: float, height: float, round_top: bool) -> str:
    """A column with a square foot; the top has a 4 px rounded end when it is the data end."""
    top = bottom - height
    radius = min(CORNER, width / 2, height) if round_top else 0.0
    if radius <= 0:
        return f"M{x:.2f},{bottom:.2f}V{top:.2f}H{x + width:.2f}V{bottom:.2f}Z"
    return (
        f"M{x:.2f},{bottom:.2f}V{top + radius:.2f}A{radius:.2f},{radius:.2f} 0 0 1 {x + radius:.2f},{top:.2f}"
        f"H{x + width - radius:.2f}A{radius:.2f},{radius:.2f} 0 0 1 {x + width:.2f},{top + radius:.2f}"
        f"V{bottom:.2f}Z"
    )


def path(d: str, classes: str) -> str:
    return f'<path d="{d}" class="{classes}"/>'


def hit_area(x: float, top: float, width: float, height: float) -> str:
    return f'<rect x="{x:.2f}" y="{top:.2f}" width="{width:.2f}" height="{height:.2f}" fill="none" pointer-events="all"/>'


def grid(left: float, right: float, top: float, bottom: float, ticks: list[float], scale_top: float, suffix: str) -> list[str]:
    parts: list[str] = []
    for tick in ticks:
        y = bottom - (bottom - top) * tick / scale_top
        parts.append(line(left, y, right, y, "axis" if tick == 0 else "grid"))
        parts.append(text(left - TICK_GAP, y + 3.5, format_tick(tick, suffix), "muted", "end"))
    return parts


def daily_panel(panel: DailyPanel, days: list[Bucket], left: float, width: float, partial: bool) -> list[str]:
    values = [panel.value_of(day) for day in days]
    scale_top, ticks = nice_scale(max(values))
    plot_left = left + TICK_COLUMN
    plot_right = left + width
    slot = (plot_right - plot_left) / len(days)
    bar_width = bar_width_of(slot, len(days), 2 * SURFACE_GAP, "days")
    value_labels = [f"{value:.1f}{panel.suffix}" for value in values]
    names = [day.start.strftime(DAY_FORMAT)[DAY_LABEL] + ("*" if partial and index == len(days) - 1 else "") for index, day in enumerate(days)]
    shown_values = peak_and_last(value_labels, values, slot)
    shown_names = every_nth_from_last(names, slot)
    parts = [text(left, DAILY_TITLE_Y, panel.title, "panel ink")]
    parts += grid(plot_left, plot_right, DAILY_TOP, DAILY_BOTTOM, ticks, scale_top, panel.suffix)
    for index, (day, value) in enumerate(zip(days, values, strict=True)):
        x = plot_left + slot * index + (slot - bar_width) / 2
        height = (DAILY_BOTTOM - DAILY_TOP) * value / scale_top
        parts.append(f"<g><title>{panel.tip_of(day, value)}</title>")
        parts.append(hit_area(plot_left + slot * index, DAILY_TOP, slot, DAILY_BOTTOM - DAILY_TOP))
        if height >= SHORT_BAR:
            parts.append(path(column_path(x, DAILY_BOTTOM, bar_width, height, True), "accent"))
        parts.append("</g>")
        if index in shown_values:
            parts.append(text(x + bar_width / 2, DAILY_BOTTOM - height - 5, value_labels[index], "ink2", "middle"))
        if index in shown_names:
            parts.append(text(x + bar_width / 2, DAILY_LABEL_Y, names[index], "muted", "middle"))
    return parts


def hour_tip(bucket: Bucket) -> str:
    stamp = bucket.start.strftime("%m-%dT%H")
    inline = bucket.result_bytes - bucket.spilled_bytes
    noun = "call" if bucket.calls == 1 else "calls"
    return (
        f"{stamp}Z · {bucket.calls:,} {noun} · spilled {megabytes(bucket.spilled_bytes)} "
        f"({share(bucket.spilled_bytes, bucket.result_bytes):.1f}% of {megabytes(bucket.result_bytes)}) · inline {megabytes(inline)}"
    )


def hourly_panel(window: list[Bucket], marks: list[Mark]) -> list[str]:
    plot_left = LEFT + TICK_COLUMN
    plot_right = WIDTH - RIGHT
    plot_height = HOURLY_BOTTOM - HOURLY_TOP
    scale_top, ticks = nice_scale(max(bucket.result_bytes for bucket in window) / BYTES_PER_MB)
    slot = (plot_right - plot_left) / len(window)
    bar_width = bar_width_of(slot, len(window), SURFACE_GAP, "hours")
    parts = [text(LEFT, HOURLY_TITLE_Y, "Result bytes per hour (MB)", "panel ink")]
    legend_x = plot_right
    for label, classes in (("kept inline", "context"), ("spilled to a blob", "accent")):
        legend_x -= len(label) * CHARACTER_WIDTH + SWATCH + 16
        parts.append(f'<rect x="{legend_x:.1f}" y="{HOURLY_TITLE_Y - SWATCH}" width="{SWATCH}" height="{SWATCH}" rx="2" class="{classes}"/>')
        parts.append(text(legend_x + SWATCH + 4, HOURLY_TITLE_Y, label, "ink2"))
    parts += grid(plot_left, plot_right, HOURLY_TOP, HOURLY_BOTTOM, ticks, scale_top, "")
    for index, bucket in enumerate(window):
        x = plot_left + slot * index + (slot - bar_width) / 2
        inline_height = plot_height * (bucket.result_bytes - bucket.spilled_bytes) / BYTES_PER_MB / scale_top
        spilled_height = plot_height * bucket.spilled_bytes / BYTES_PER_MB / scale_top
        parts.append(f"<g><title>{hour_tip(bucket)}</title>")
        parts.append(hit_area(plot_left + slot * index, HOURLY_TOP, slot, plot_height))
        if inline_height >= SHORT_BAR:
            parts.append(path(column_path(x, HOURLY_BOTTOM, bar_width, inline_height, spilled_height < SHORT_BAR), "context"))
        drawn = spilled_height - SURFACE_GAP if inline_height >= SHORT_BAR else spilled_height
        if drawn >= SHORT_BAR:
            parts.append(path(column_path(x, HOURLY_BOTTOM - inline_height - (SURFACE_GAP if inline_height >= SHORT_BAR else 0), bar_width, drawn, True), "accent"))
        parts.append("</g>")
        if bucket.start.hour % HOURS_BETWEEN_LABELS == 0:
            parts.append(text(x + bar_width / 2, HOURLY_LABEL_Y, f"{bucket.start.hour:02d}", "muted", "middle"))
            if bucket.start.hour == 0:
                parts.append(text(x + bar_width / 2, HOURLY_DATE_Y, bucket.start.strftime(DAY_FORMAT)[DAY_LABEL], "ink2", "middle"))
    first = window[0].start
    ordered = sorted(marks, key=lambda mark: mark.at)
    for position, mark in enumerate(ordered):
        x = plot_left + slot * (mark.at - first).total_seconds() / SECONDS_PER_HOUR
        label = f"{mark.at.strftime('%H:%M')} {mark.label}"
        y = HOURLY_TOP - 8 - MARK_LABEL_STEP * (len(ordered) - 1 - position)
        flip = x + MARK_LEAD + len(label) * CHARACTER_WIDTH > plot_right
        parts.append(line(x, y - 8, x, HOURLY_BOTTOM, "mark"))
        parts.append(text(x + (-MARK_LEAD if flip else MARK_LEAD), y, label, "ink2", "end" if flip else "start"))
    return parts


def render(result: JsonObject, hours: int, marks: list[Mark]) -> str:
    if hours < 1:
        raise ValueError("--hours must be at least 1")
    if len(marks) > MAX_MARKS:
        raise ValueError(f"at most {MAX_MARKS} --mark lines fit above the hourly panel")
    days = parse_series(result, "daily", DAY_FORMAT)
    hourly = parse_series(result, "hourly", HOUR_FORMAT)
    window = hour_window(hourly, hours)
    outside = [mark for mark in marks if not window[0].start <= mark.at < window[-1].start + timedelta(hours=1)]
    if outside:
        raise ValueError(f"the mark {outside[0].label!r} is outside the plotted hours {window[0].start:%Y-%m-%dT%H}Z..{window[-1].start:%Y-%m-%dT%H}Z")
    partial = hourly[-1].start.hour != LAST_HOUR_OF_DAY
    panels = (
        DailyPanel(
            "Identical re-reads, % of result bytes",
            "%",
            lambda day: share(day.reread_bytes, day.result_bytes),
            lambda day, value: f"{day.start:%m-%d} · identical re-reads {value:.1f}% of {megabytes(day.result_bytes)} ({megabytes(day.reread_bytes)})",
        ),
        DailyPanel(
            "Spilled to a blob, % of result bytes",
            "%",
            lambda day: share(day.spilled_bytes, day.result_bytes),
            lambda day, value: f"{day.start:%m-%d} · spilled {value:.1f}% of {megabytes(day.result_bytes)} ({megabytes(day.spilled_bytes)})",
        ),
        DailyPanel(
            "Execute blocked on sleep or poll, hours",
            "",
            lambda day: day.wait_s / SECONDS_PER_HOUR,
            lambda day, value: f"{day.start:%m-%d} · Execute blocked {value:.1f} h ({day.wait_s:,.0f} s)",
        ),
    )
    panel_width = (WIDTH - LEFT - RIGHT - PANEL_GAP * (PANEL_COUNT - 1)) / PANEL_COUNT
    first_day, last_day = days[0].start, days[-1].start
    last_hour = hourly[-1].start
    body: list[str] = [
        text(LEFT, TITLE_Y, "Tool call waste by day and by hour", "title ink"),
        text(LEFT, SUBTITLE_Y, f"UTC, {first_day:%Y-%m-%d} to {last_day:%Y-%m-%d}; each day is measured on its own", "ink2"),
    ]
    for index, panel in enumerate(panels):
        body += daily_panel(panel, days, LEFT + index * (panel_width + PANEL_GAP), panel_width, partial)
    body += hourly_panel(window, marks)
    notes = [
        "Source: scripts/measure-tool-efficiency.py. Identical re-read: same Keeper, tool, input and result bytes within one hour.",
        "Blocked: Execute calls whose command sleeps, polls or watches (a reporting heuristic).",
    ]
    if partial:
        notes.append(f"* {last_day:%m-%d} is still being written: the last hour read starts at {last_hour:%H}:00Z.")
    body += [text(LEFT, NOTE_Y + NOTE_LINE * index, note, "muted") for index, note in enumerate(notes)]
    heading = "Tool call waste by day and by hour"
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {WIDTH} {HEIGHT}" role="img" aria-labelledby="t d">\n'
        f"<title id=\"t\">{heading}</title>\n"
        f'<desc id="d">Three daily panels and one hourly panel drawn from the tool-efficiency JSON. Each bar has a title with its numbers.</desc>\n'
        f"<style>{STYLE}</style>\n"
        f'<rect width="{WIDTH}" height="{HEIGHT}" class="surface"/>\n' + "\n".join(body) + "\n</svg>"
    )


def parse_instant(text_value: str) -> datetime:
    try:
        return datetime.strptime(text_value, INSTANT_FORMAT).replace(tzinfo=UTC)
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"{text_value!r} is not a UTC instant like 2026-11-05T02:19:09Z") from error


def parse_mark(text_value: str) -> Mark:
    instant, separator, label = text_value.partition("=")
    if not separator or not label:
        raise argparse.ArgumentTypeError(f"{text_value!r} is not INSTANT=LABEL")
    return Mark(parse_instant(instant), label)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--json", type=pathlib.Path, required=True, help="the file measure-tool-efficiency.py --json-out wrote")
    parser.add_argument("--out", type=pathlib.Path, help="write the SVG here; standard output when omitted")
    parser.add_argument("--hours", type=int, default=DEFAULT_HOURS, help="hours in the hourly panel")
    parser.add_argument("--mark", action="append", default=[], type=parse_mark, metavar="INSTANT=LABEL")
    args = parser.parse_args(argv)
    try:
        svg = render(read_result(args.json), args.hours, args.mark)
    except ValueError as error:
        parser.error(str(error))
    if args.out:
        args.out.write_text(svg + "\n", encoding="utf-8")
    else:
        sys.stdout.write(svg + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
