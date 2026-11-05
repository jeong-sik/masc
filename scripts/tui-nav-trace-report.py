#!/usr/bin/env python3
# pyright: strict
"""Read a MASC_TUI_NAV_TRACE file (RFC-0485) and say what it shows.

The TUI appends one JSON line per screen it opens and per key after which the
frame stayed the same. This script counts them.

usage: python3 scripts/tui-nav-trace-report.py TRACE [--expect SURFACE[,SURFACE...]]

TRACE is a file path, or - for standard input. Sections:

  Screens opened         how many times each surface was the first frame of a
                         visit, most opened first.
  Announced, unchanged   keys the footer announced after which the frame stayed
                         the same. A key whose answer arrives later (a refresh
                         that asks the server) lands here too, so read these as
                         candidates for a footer that promises a key the screen
                         does not act on.
  Not announced          the same, for keys the footer did not announce.
  Not opened             the surfaces --expect names that never opened.

A trace that reached its line cap ends with a `capped` line; the report says
so, because every count after that point is missing. Lines that are not JSON
objects of a known kind are counted and left out.
"""

import argparse
import json
import sys
from collections import Counter
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import assert_never, cast


@dataclass(frozen=True, slots=True)
class Opened:
    origin: str | None
    surface: str


@dataclass(frozen=True, slots=True)
class Unchanged:
    surface: str
    key: str
    advertised: bool


@dataclass(frozen=True, slots=True)
class Capped:
    limit: int


type Event = Opened | Unchanged | Capped


@dataclass(frozen=True, slots=True)
class Report:
    opened: tuple[tuple[str, int], ...]
    announced: tuple[tuple[str, str, int], ...]
    not_announced: tuple[tuple[str, str, int], ...]
    capped: int | None
    unreadable: int


def parse_line(line: str) -> Event | None:
    """The event a trace line holds, or None when it is not one."""
    try:
        raw: object = json.loads(line)
    except json.JSONDecodeError:
        return None
    if not isinstance(raw, dict):
        return None
    fields = cast(dict[str, object], raw)
    kind = fields.get("kind")
    if kind == "surface":
        surface = fields.get("to")
        origin = fields.get("from")
        if isinstance(surface, str) and (origin is None or isinstance(origin, str)):
            return Opened(origin, surface)
        return None
    if kind == "key_unchanged":
        surface = fields.get("surface")
        key = fields.get("key")
        advertised = fields.get("advertised")
        if isinstance(surface, str) and isinstance(key, str) and isinstance(advertised, bool):
            return Unchanged(surface, key, advertised)
        return None
    if kind == "capped":
        limit = fields.get("limit")
        if isinstance(limit, int) and not isinstance(limit, bool):
            return Capped(limit)
        return None
    return None


def _most_first[K](counts: Counter[K]) -> list[tuple[K, int]]:
    # Ties break on the key, so one trace always reports in one order.
    return sorted(counts.items(), key=lambda item: (-item[1], str(item[0])))


def summarize(lines: Iterable[str]) -> Report:
    opened: Counter[str] = Counter()
    announced: Counter[tuple[str, str]] = Counter()
    not_announced: Counter[tuple[str, str]] = Counter()
    capped: int | None = None
    unreadable = 0
    for line in lines:
        if not line.strip():
            continue
        event = parse_line(line)
        if event is None:
            unreadable += 1
            continue
        match event:
            case Opened(surface=surface):
                opened[surface] += 1
            case Unchanged(surface=surface, key=key, advertised=advertised):
                counts = announced if advertised else not_announced
                counts[(surface, key)] += 1
            case Capped(limit=limit):
                capped = limit
            case _ as unreachable:
                assert_never(unreachable)
    return Report(
        opened=tuple(_most_first(opened)),
        announced=tuple((s, k, n) for (s, k), n in _most_first(announced)),
        not_announced=tuple((s, k, n) for (s, k), n in _most_first(not_announced)),
        capped=capped,
        unreadable=unreadable,
    )


def _key_table(rows: tuple[tuple[str, str, int], ...]) -> list[str]:
    if not rows:
        return ["  (none)"]
    surface_width = max(len(surface) for surface, _, _ in rows)
    key_width = max(len(key) for _, key, _ in rows)
    return [f"  {surface:<{surface_width}}  {key:<{key_width}}  {count:>5}" for surface, key, count in rows]


def render(report: Report, expected: tuple[str, ...]) -> str:
    out: list[str] = []
    out.append(f"Screens opened ({sum(count for _, count in report.opened)} visits, {len(report.opened)} screens)")
    if report.opened:
        width = max(len(surface) for surface, _ in report.opened)
        out.extend(f"  {surface:<{width}}  {count:>5}" for surface, count in report.opened)
    else:
        out.append("  (none)")
    out.append("")
    out.append("Announced, unchanged (the footer named the key and the frame stayed)")
    out.extend(_key_table(report.announced))
    out.append("")
    out.append("Not announced, unchanged")
    out.extend(_key_table(report.not_announced))
    if expected:
        seen = {surface for surface, _ in report.opened}
        missing = [surface for surface in expected if surface not in seen]
        out.append("")
        out.append("Not opened (from --expect)")
        if missing:
            out.extend(f"  {surface}" for surface in missing)
        else:
            out.append("  (none)")
    if report.capped is not None:
        out.append("")
        out.append(f"The trace stopped at its cap of {report.capped} lines; later events are missing.")
    if report.unreadable:
        out.append("")
        out.append(f"{report.unreadable} line(s) were not trace events and were left out.")
    return "\n".join(out) + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Report a MASC_TUI_NAV_TRACE file.")
    parser.add_argument("trace", help="trace file, or - for standard input")
    parser.add_argument("--expect", default="", help="comma-separated surfaces that should have opened")
    arguments = parser.parse_args(argv)
    trace = cast(str, arguments.trace)
    expect = cast(str, arguments.expect)
    try:
        text = sys.stdin.read() if trace == "-" else Path(trace).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        print(f"cannot read {trace}: {error}", file=sys.stderr)
        return 2
    expected = tuple(name for name in (part.strip() for part in expect.split(",")) if name)
    sys.stdout.write(render(summarize(text.splitlines()), expected))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
