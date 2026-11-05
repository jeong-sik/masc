#!/usr/bin/env python3
"""Split the tool-call ledger's waste measures by runtime profile.

`scripts/measure-tool-efficiency.py` reports one number for the whole ledger. A
Keeper changes its runtime profile (model and account) from time to time, and
one profile can repeat a call far more often than another. A whole-ledger number
before and after a tool change then also moves when the profile mix moves. This
script reads the same ledger with the same row rules and reports each profile
on its own, so a before/after comparison can hold the profile fixed.

It loads `scripts/measure-tool-efficiency.py` and calls its `observe_row` for
every row, so a tool call, an identical re-read and a spilled result mean what
they mean there. One totals object per profile takes the row. One `last_seen`
per UTC day is shared by all profiles, so a repeat is found whichever profile
made the earlier call, and it counts under the profile of the later call. The
sum over profiles of every count equals the whole-ledger count.

- profile: the `runtime_profile` of the row, `unrecorded` when it has none.
- keeper counts: tool calls per Keeper under that profile, rows with the
  `tool_call` record kind only.
- `tools` keeps the `--top` tools with the most calls of the profile; `daily`
  keeps the UTC days of the window; the hourly series, the bursts and the
  empty-input table of the official summary are left out.

Reads `<base-path>/.masc/tool_calls/YYYY-MM/DD[.NNN].jsonl` and never writes to
it. A day that is still being written changes under the script, so measure a
window whose last UTC day is over to get a repeatable result. A line that is
not a JSON object, holds NaN or Infinity, or is not valid UTF-8 is counted under
`unreadable_lines` and belongs to no profile.

Usage:
    docs/evidence/tool-efficiency-by-profile-2026-11/measure_by_profile.py \
        --base-path ~/me --from-date 2026-11-01 --to-date 2026-11-04 --json-out result.json
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import pathlib
import sys
from collections import Counter
from collections.abc import Callable
from dataclasses import dataclass
from datetime import date, timedelta
from typing import Protocol, cast

JsonObject = dict[str, object]
LastSeen = dict[tuple[str, str, str], tuple[float, str, str]]

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
OFFICIAL_SCRIPT = REPO_ROOT / "scripts" / "measure-tool-efficiency.py"
OFFICIAL_MODULE = "measure_tool_efficiency"
UNRECORDED_PROFILE = "unrecorded"  # the label observe_row gives a row without runtime_profile
DEFAULT_TOP = 8
SUMMARY_KEEP = ("tool_time_s", "result_bytes", "identical_rereads", "spilled_results", "daily")


class Totals(Protocol):
    """The part of the official DayTotals this script writes."""

    unreadable_lines: int


@dataclass(frozen=True, slots=True)
class Official:
    """The functions of measure-tool-efficiency.py this script calls."""

    ledger_files: Callable[[pathlib.Path, date], list[pathlib.Path]]
    reject_constant: Callable[[str], object]
    as_object: Callable[[object], JsonObject | None]
    as_text: Callable[[object], str | None]
    new_totals: Callable[[], Totals]
    observe_row: Callable[[Totals, JsonObject, LastSeen, float], None]
    merge: Callable[[list[Totals]], Totals]
    summarize: Callable[[Totals, int], JsonObject]
    require_base_path: Callable[[argparse.ArgumentParser, str | None, str], pathlib.Path]
    parse_day: Callable[[str], date]
    record_kind: str
    default_window_sec: float


def load_official() -> Official:
    """measure-tool-efficiency.py: the one place that says what a re-read and a spilled result are."""
    spec = importlib.util.spec_from_file_location(OFFICIAL_MODULE, OFFICIAL_SCRIPT)
    if spec is None or spec.loader is None:
        raise ImportError(f"{OFFICIAL_SCRIPT} is not a Python file")
    module = importlib.util.module_from_spec(spec)
    # The dataclasses of that script resolve their annotations through sys.modules.
    sys.modules[OFFICIAL_MODULE] = module
    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True  # the import leaves no __pycache__ next to the other scripts
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[OFFICIAL_MODULE]
        raise
    finally:
        sys.dont_write_bytecode = previous
    return Official(
        ledger_files=cast(Callable[[pathlib.Path, date], list[pathlib.Path]], module.ledger_files),
        reject_constant=cast(Callable[[str], object], module.reject_constant),
        as_object=cast(Callable[[object], JsonObject | None], module.as_object),
        as_text=cast(Callable[[object], str | None], module.as_text),
        new_totals=cast(Callable[[], Totals], module.DayTotals),
        observe_row=cast(Callable[[Totals, JsonObject, LastSeen, float], None], module.observe_row),
        merge=cast(Callable[[list[Totals]], Totals], module.merge),
        summarize=cast(Callable[[Totals, int], JsonObject], module.summarize),
        require_base_path=cast(
            Callable[[argparse.ArgumentParser, str | None, str], pathlib.Path], module.masc_base_path.require
        ),
        parse_day=cast(Callable[[str], date], module.parse_day),
        record_kind=cast(str, module.TOOL_CALL_RECORD_KIND),
        default_window_sec=cast(float, module.DEFAULT_REREAD_WINDOW_SEC),
    )


@dataclass(slots=True)
class DayProfiles:
    totals: dict[str, Totals]
    keepers: Counter[tuple[str, str]]  # (profile, keeper) -> tool calls
    unreadable_lines: int


def measure_day(official: Official, base: pathlib.Path, day: date, window_sec: float) -> DayProfiles:
    result = DayProfiles({}, Counter(), 0)
    last_seen: LastSeen = {}
    for path in official.ledger_files(base, day):
        with path.open("rb") as handle:
            for line in handle:
                if not line.strip():
                    continue
                try:
                    parsed: object = json.loads(line, parse_constant=official.reject_constant)
                except ValueError:  # JSONDecodeError, UnicodeDecodeError and reject_constant
                    result.unreadable_lines += 1
                    continue
                row = official.as_object(parsed)
                if row is None:
                    result.unreadable_lines += 1
                    continue
                if row.get("record_kind") != official.record_kind:
                    continue
                profile = official.as_text(row.get("runtime_profile")) or UNRECORDED_PROFILE
                keeper = official.as_text(row.get("keeper")) or "?"
                result.keepers[(profile, keeper)] += 1
                totals = result.totals.setdefault(profile, official.new_totals())
                official.observe_row(totals, row, last_seen, window_sec)
    return result


def days_between(first: date, last: date) -> list[date]:
    return [first + timedelta(days=offset) for offset in range((last - first).days + 1)]


def calls_of(summary: JsonObject) -> int:
    return cast(int, summary["rows"])


def profile_report(profile: str, summary: JsonObject, keepers: Counter[str], whole_calls: int, top: int) -> JsonObject:
    tools = sorted(cast(list[JsonObject], summary["tools"]), key=lambda row: -cast(int, row["calls"]))
    calls = calls_of(summary)
    report: JsonObject = {
        "profile": profile,
        "calls": calls,
        "calls_pct_of_ledger": round(100.0 * calls / whole_calls, 2) if whole_calls else 0.0,
    }
    report.update({key: summary[key] for key in SUMMARY_KEEP})
    report["keepers"] = dict(keepers.most_common(top))
    report["tools"] = tools[:top]
    return report


def measure(official: Official, base: pathlib.Path, first: date, last: date, window_sec: float, top: int) -> JsonObject:
    days = [measure_day(official, base, day, window_sec) for day in days_between(first, last)]
    by_profile: dict[str, list[Totals]] = {}
    keepers: dict[str, Counter[str]] = {}
    for day in days:
        for profile, totals in day.totals.items():
            by_profile.setdefault(profile, []).append(totals)
        for (profile, keeper), calls in day.keepers.items():
            keepers.setdefault(profile, Counter())[keeper] += calls
    summaries = {profile: official.summarize(official.merge(parts), top) for profile, parts in by_profile.items()}
    whole_calls = sum(calls_of(summary) for summary in summaries.values())
    ordered = sorted(summaries.items(), key=lambda item: -calls_of(item[1]))
    return {
        "from_date": first.isoformat(),
        "to_date": last.isoformat(),
        "reread_window_sec": window_sec,
        "rows": whole_calls,
        "unreadable_lines": sum(day.unreadable_lines for day in days),
        "profiles": [profile_report(name, summary, keepers[name], whole_calls, top) for name, summary in ordered],
    }


def render(result: JsonObject) -> str:
    lines = [
        f"tool calls {result['from_date']} .. {result['to_date']}: {result['rows']:,} rows, "
        f"{result['unreadable_lines']} unreadable lines",
        f"{'profile':<34}{'calls':>9}{'share':>8}{'re-read':>9}{'bytes MB':>10}{'spilled':>9}{'bytes MB':>10}  top keeper",
    ]
    for report in cast(list[JsonObject], result["profiles"]):
        reread = cast(JsonObject, report["identical_rereads"])
        spilled = cast(JsonObject, report["spilled_results"])
        keepers = cast(dict[str, int], report["keepers"])
        top_keeper = next(iter(keepers), "-")
        lines.append(
            f"{str(report['profile']):<34}{cast(int, report['calls']):>9,}{cast(float, report['calls_pct_of_ledger']):>7.1f}%"
            f"{cast(int, reread['calls']):>9,}{cast(int, reread['bytes']) / 1e6:>10.1f}"
            f"{cast(int, spilled['calls']):>9,}{cast(int, spilled['bytes']) / 1e6:>10.1f}  {top_keeper}"
        )
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    official = load_official()
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", default=None, help="directory that contains .masc; MASC_BASE_PATH when omitted")
    parser.add_argument("--from-date", type=official.parse_day, required=True, help="first UTC day, YYYY-MM-DD")
    parser.add_argument("--to-date", type=official.parse_day, required=True, help="last UTC day, YYYY-MM-DD")
    parser.add_argument("--reread-window-sec", type=float, default=official.default_window_sec)
    parser.add_argument("--top", type=int, default=DEFAULT_TOP, help="keepers and tools kept per profile")
    parser.add_argument("--json-out", default=None, help="write the full result to this file")
    args = parser.parse_args(argv)
    first, last = cast(date, args.from_date), cast(date, args.to_date)
    if last < first:
        parser.error("--to-date is before --from-date")
    base = official.require_base_path(parser, cast(str | None, args.base_path), "--base-path")
    result = measure(official, base, first, last, cast(float, args.reread_window_sec), cast(int, args.top))
    if args.json_out is not None:
        destination = pathlib.Path(cast(str, args.json_out))
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(json.dumps(result, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    sys.stdout.write(render(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
