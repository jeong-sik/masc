#!/usr/bin/env python3
"""Count `keeper_artifact_read` calls that fail with "artifact does not exist" and trace the hashes.

A stored tool result reaches the model as `[masc:blob sha256=<artifact> bytes=... mime=...
answer_sha256=<fingerprint> preview=...]`. Only the `sha256=` value names a stored artifact.
The `answer_sha256=` value is a checksum of the answer inside the stored manifest. This script
counts how often a read misses and how many of the missed hashes are such a checksum.

Reads, and never writes:

- `<base-path>/.masc/tool_calls/<YYYY-MM>/<DD>.jsonl` and `<DD>.<NNN>.jsonl`: one JSON object
  per line. A line counts when `record_kind` is `tool_call` and `tool` is `keeper_artifact_read`.
  Fields used: `ts` (UTC seconds), `keeper`, `input.sha256` and `output`.
- `<base-path>/.masc/keepers/<keeper>/raw-traces/*.jsonl`, scanned as bytes for
  `answer_sha256=<64 hex>`. Raw traces are deleted over time, so a miss without a trace file
  is `not_traced`, which does not mean the hash was something else.

Definitions:

- read: a counted line. Its outcome is `missing` when `output` contains "artifact does not
  exist", `failed` when `output` starts with `{"ok":false` for another reason, else `ok`.
- day: the UTC date of `ts`. The ledger files are cut at UTC midnight.
- after a miss: the next read of the same keeper (by `ts`, ties by file order) decides the class.
  - `read_other_hash`: it comes within `--follow-seconds`, did not fail, and asks for another hash.
  - `read_same_hash`: it comes within `--follow-seconds`, did not fail, and asks for the same hash.
  - `missed_again`: it comes within `--follow-seconds` and also misses.
  - `failed_otherwise`: it comes within `--follow-seconds` and fails for another reason.
  - `no_next_read`: there is none within `--follow-seconds`.
- traced: the missed hash is the value after `answer_sha256=` somewhere in the scanned raw traces.
- median, p90: the value at rank `ceil(q * n)` of the sorted values, never an average of two.

A line that is not JSON, has no numeric `ts`, or whose `output` is not text is counted in
`skipped` and left out of every number.

Usage:
    python3 docs/evidence/artifact-read-misses-2026-11/measure_artifact_read_misses.py \
        --base-path ~/me --from-date 2026-11-01 --to-date 2026-11-06 --json-out result.json
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime
import json
import math
import pathlib
import re
import sys
from collections import defaultdict
from collections.abc import Iterator, Sequence
from typing import cast

TOOL = "keeper_artifact_read"
RECORD_KIND = "tool_call"
MISSING_TEXT = "artifact does not exist"
FAILED_PREFIX = '{"ok":false'
SHA256 = re.compile(r"^[0-9a-f]{64}$")
ANSWER_FINGERPRINT = re.compile(rb"answer_sha256=([0-9a-f]{64})")
ANSWER_MARK = b"answer_sha256="
LEDGER_FILE = re.compile(r"^(?P<day>[0-9]{2})(?:\.[0-9]{3})?\.jsonl$")
DEFAULT_FOLLOW_SECONDS = 600.0
DEFAULT_TOP = 8
MAX_DAYS = 366
SECONDS_PER_DAY = 86400.0

OK = "ok"
MISSING = "missing"
FAILED = "failed"

FOLLOW_CLASSES = ("read_other_hash", "read_same_hash", "missed_again", "failed_otherwise", "no_next_read")


@dataclasses.dataclass(frozen=True, slots=True)
class Read:
    stamp: float
    keeper: str
    sha256: str | None
    outcome: str


@dataclasses.dataclass(slots=True)
class Skipped:
    bad_lines: int = 0
    bad_outputs: int = 0


def outcome_of(output: str) -> str:
    if MISSING_TEXT in output:
        return MISSING
    if output.startswith(FAILED_PREFIX):
        return FAILED
    return OK


def parse_read(raw: bytes, skipped: Skipped) -> Read | None:
    """The read a ledger line records, or None when the line is not a counted read."""
    try:
        row = cast("object", json.loads(raw))
    except ValueError:
        skipped.bad_lines += 1
        return None
    if not isinstance(row, dict):
        skipped.bad_lines += 1
        return None
    fields = cast("dict[str, object]", row)
    if fields.get("record_kind") != RECORD_KIND or fields.get("tool") != TOOL:
        return None
    stamp = fields.get("ts")
    keeper = fields.get("keeper")
    if isinstance(stamp, bool) or not isinstance(stamp, (int, float)) or not isinstance(keeper, str):
        skipped.bad_lines += 1
        return None
    output = fields.get("output")
    if not isinstance(output, str):
        skipped.bad_outputs += 1
        return None
    given = fields.get("input")
    sha256 = cast("dict[str, object]", given).get("sha256") if isinstance(given, dict) else None
    return Read(float(stamp), keeper, sha256 if isinstance(sha256, str) else None, outcome_of(output))


def days_of(first: datetime.date, last: datetime.date) -> list[datetime.date]:
    return [first + datetime.timedelta(days=offset) for offset in range((last - first).days + 1)]


def ledger_files(base: pathlib.Path, first: datetime.date, last: datetime.date) -> tuple[list[pathlib.Path], list[str]]:
    """The ledger files of each day in the range, and the days that have none."""
    paths: list[pathlib.Path] = []
    without: list[str] = []
    for day in days_of(first, last):
        folder = base / ".masc" / "tool_calls" / f"{day.year:04d}-{day.month:02d}"
        found = (
            sorted(p for p in folder.iterdir() if (m := LEDGER_FILE.match(p.name)) and int(m["day"]) == day.day)
            if folder.is_dir()
            else []
        )
        if found:
            paths.extend(found)
        else:
            without.append(day.isoformat())
    return paths, without


def read_ledger(paths: Sequence[pathlib.Path], since: float, until: float, skipped: Skipped) -> list[Read]:
    mark = TOOL.encode()
    reads: list[Read] = []
    for path in paths:
        with path.open("rb") as handle:
            for raw in handle:
                if mark not in raw:
                    continue
                read = parse_read(raw, skipped)
                if read is not None and since <= read.stamp < until:
                    reads.append(read)
    return reads


def raw_trace_paths(base: pathlib.Path) -> Iterator[pathlib.Path]:
    yield from sorted((base / ".masc" / "keepers").glob("*/raw-traces/*.jsonl"))


def answer_fingerprints(base: pathlib.Path) -> tuple[set[str], int]:
    """Every `answer_sha256=` value in the raw traces, and how many trace files were scanned."""
    found: set[str] = set()
    scanned = 0
    for path in raw_trace_paths(base):
        scanned += 1
        data = path.read_bytes()
        if ANSWER_MARK in data:
            found.update(match.decode("ascii") for match in ANSWER_FINGERPRINT.findall(data))
    return found, scanned


def quantile(sorted_values: Sequence[float], q: float) -> float:
    if not sorted_values:
        return 0.0
    return sorted_values[max(0, math.ceil(q * len(sorted_values)) - 1)]


def share(part: float, whole: float) -> float:
    return round(part / whole, 4) if whole > 0 else 0.0


def follow_class(miss: Read, following: Read | None, window: float) -> str:
    if following is None or following.stamp - miss.stamp > window:
        return "no_next_read"
    if following.outcome == MISSING:
        return "missed_again"
    if following.outcome == FAILED:
        return "failed_otherwise"
    return "read_same_hash" if following.sha256 == miss.sha256 else "read_other_hash"


def after_misses(reads: Sequence[Read], window: float) -> dict[str, object]:
    by_keeper: dict[str, list[Read]] = defaultdict(list)
    for read in sorted(reads, key=lambda item: item.stamp):
        by_keeper[read.keeper].append(read)
    classes: dict[str, int] = dict.fromkeys(FOLLOW_CLASSES, 0)
    recovery: list[float] = []
    for rows in by_keeper.values():
        for index, miss in enumerate(rows):
            if miss.outcome != MISSING:
                continue
            following = rows[index + 1] if index + 1 < len(rows) else None
            kind = follow_class(miss, following, window)
            classes[kind] += 1
            if kind == "read_other_hash" and following is not None:
                recovery.append(following.stamp - miss.stamp)
    recovery.sort()
    return {
        **classes,
        "read_other_hash_seconds": {
            "p50": round(quantile(recovery, 0.5), 1),
            "p90": round(quantile(recovery, 0.9), 1),
        },
    }


def report(
    reads: Sequence[Read],
    fingerprints: set[str],
    files: dict[str, object],
    skipped: Skipped,
    params: dict[str, object],
    window: float,
    top: int,
) -> dict[str, object]:
    misses = [read for read in reads if read.outcome == MISSING]
    by_day: dict[str, dict[str, int]] = defaultdict(lambda: {"reads": 0, "missing": 0, "traced": 0})
    by_keeper: dict[str, dict[str, int]] = defaultdict(lambda: {"reads": 0, "missing": 0})
    for read in reads:
        day = datetime.datetime.fromtimestamp(read.stamp, datetime.timezone.utc).date().isoformat()
        by_day[day]["reads"] += 1
        by_keeper[read.keeper]["reads"] += 1
        if read.outcome == MISSING:
            by_day[day]["missing"] += 1
            by_keeper[read.keeper]["missing"] += 1
            if read.sha256 in fingerprints:
                by_day[day]["traced"] += 1
    hashes = {read.sha256 for read in misses if read.sha256 is not None and SHA256.match(read.sha256)}
    traced_calls = sum(1 for read in misses if read.sha256 in fingerprints)
    keepers = sorted(by_keeper.items(), key=lambda item: (-item[1]["missing"], -item[1]["reads"], item[0]))[:top]
    return {
        "params": params,
        "files": files,
        "skipped": dataclasses.asdict(skipped),
        "reads": {
            "total": len(reads),
            "missing": len(misses),
            "missing_share": share(len(misses), len(reads)),
            "by_day": {day: by_day[day] for day in sorted(by_day)},
        },
        "missed_calls": {"traced_to_answer_sha256": traced_calls, "not_traced": len(misses) - traced_calls},
        "missed_hashes": {
            "distinct": len(hashes),
            "traced_to_answer_sha256": len(hashes & fingerprints),
            "not_traced": len(hashes - fingerprints),
        },
        "after_a_miss": after_misses(reads, window),
        "by_keeper": [{"keeper": name, **counts} for name, counts in keepers],
    }


def parse_day(text: str) -> datetime.date:
    return datetime.date.fromisoformat(text)


def parse_instant(text: str) -> float:
    return datetime.datetime.fromisoformat(text).replace(tzinfo=datetime.timezone.utc).timestamp()


def day_start(day: datetime.date) -> float:
    return datetime.datetime.combine(day, datetime.time.min, tzinfo=datetime.timezone.utc).timestamp()


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--from-date", required=True, help="first UTC day to read, YYYY-MM-DD")
    parser.add_argument("--to-date", required=True, help="last UTC day to read, YYYY-MM-DD")
    parser.add_argument("--since", help="count reads at or after this UTC time, YYYY-MM-DDTHH:MM:SS")
    parser.add_argument("--until", help="count reads before this UTC time")
    parser.add_argument("--follow-seconds", type=float, default=DEFAULT_FOLLOW_SECONDS)
    parser.add_argument("--top", type=int, default=DEFAULT_TOP)
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    try:
        first = parse_day(cast("str", args.from_date))
        last = parse_day(cast("str", args.to_date))
    except ValueError:
        parser.error("--from-date and --to-date must be YYYY-MM-DD")
    if last < first:
        parser.error("--to-date is before --from-date")
    if last == datetime.date.max:
        parser.error(f"--to-date must be before {datetime.date.max.isoformat()}")
    if (last - first).days + 1 > MAX_DAYS:
        parser.error(f"the range is longer than {MAX_DAYS} days")
    if cast("float", args.follow_seconds) <= 0:
        parser.error("--follow-seconds must be positive")
    bounds = {"since": day_start(first), "until": day_start(last) + SECONDS_PER_DAY}
    for name in ("since", "until"):
        text = cast("str | None", getattr(args, name))
        if text is not None:
            try:
                bounds[name] = parse_instant(text)
            except ValueError:
                parser.error(f"not a YYYY-MM-DDTHH:MM:SS time: {text}")
    base = cast("pathlib.Path", args.base_path).expanduser()
    skipped = Skipped()
    paths, without = ledger_files(base, first, last)
    reads = read_ledger(paths, bounds["since"], bounds["until"], skipped)
    fingerprints, scanned = answer_fingerprints(base)
    files: dict[str, object] = {"ledger": len(paths), "days_without_file": without, "raw_traces": scanned}
    params: dict[str, object] = {
        "from_date": first.isoformat(),
        "to_date": last.isoformat(),
        "since": bounds["since"],
        "until": bounds["until"],
        "follow_seconds": cast("float", args.follow_seconds),
    }
    result = report(reads, fingerprints, files, skipped, params, cast("float", args.follow_seconds), cast("int", args.top))
    text = json.dumps(result, ensure_ascii=False, indent=2)
    if args.json_out is not None:
        cast("pathlib.Path", args.json_out).write_text(text + "\n", encoding="utf-8")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
