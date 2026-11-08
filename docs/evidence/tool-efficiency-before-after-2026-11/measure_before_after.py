#!/usr/bin/env python3
"""Compare the tool-call ledger before and after one server boot.

Reads, and never writes, `<base-path>/.masc/tool_calls/<YYYY-MM>/<DD>.jsonl` and
`<DD>.<NNN>.jsonl`: one JSON object per line. A line counts when `record_kind` is `tool_call`
and `ts` (UTC seconds) lies in a window. Fields used: `tool`, `keeper`, `duration_ms`,
`result_bytes`, `disposition`, `input`, `output` and `runtime_contract.sandbox_profile`.

Windows (all UTC):

- after: [boot + settle, end). The settle gap keeps the first minutes of a fresh server, when
  Keepers are still waking, out of both windows.
- before: [boot - hours_before, boot). `hours_before` defaults to the length of the after window.

Numbers of one window:

- failed: `disposition` is `failed`.
- sized: for Grep, keeper_tools_list, BrowserTabs and masc_dashboard, the calls, the median
  (the element at index n // 2 of the sorted `result_bytes`), the maximum, and how many calls are
  at or over the lane cap named in `cap`. `result_bytes` is what the tool produced, not the cut
  `output` that the ledger keeps and not what the model saw.
- execute: calls, the hours they held a turn (`duration_ms` summed), calls that passed
  `run_in_background`, and calls held 60 s or longer.
- sleep_polls: Execute calls by the named Keepers that were held 60 s or longer and whose input
  holds `sleep` and a number (the definition of the Execute RFC); the argument is not read.
  `keeper_execute_calls` is every Execute call by those Keepers, so a poll count can be read
  against how much they ran.
- execute_overhead: for Execute calls that did not fail and whose output carries
  `execution_time_ms`, `duration_ms` minus that value, which is the time outside the command.
- execute_overhead_by_sandbox: the same overhead per `runtime_contract.sandbox_profile` (`unknown`
  when the line has none): calls, overhead hours, the median overhead in seconds, and the calls
  whose overhead is 0.5 s or more with their hours and mean. On a `remote_ssh` Execute that is
  almost always a call that ran an SSH preflight pass: calls that found the cache full have a
  median overhead of 0.02 s.
- disk_low: failed calls whose output holds `remote_ssh_disk_low`, by tool, and for Execute by
  intent: `request_effect` when the input says so, `auto` when it names no intent, `unknown` when
  the input is not JSON. A call that only quotes the code in a successful result does not count.
- background_starts: Execute calls that passed `run_in_background` and did not fail, and how many
  of their outputs name both `keeper_composition_status` and `keeper_composition_cancel`.

A line that is not JSON, or has no numeric `ts` or no text `tool`, is counted in `skipped` and
left out of every number.

Usage:
    python3 docs/evidence/tool-efficiency-before-after-2026-11/measure_before_after.py \
        --base-path ~/me --boot 2026-11-07T18:24:19 --end 2026-11-08T14:08:00 \
        --json-out docs/evidence/tool-efficiency-before-after-2026-11/result-boot-2026-11-07T18-24-19Z.json
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime
import json
import pathlib
import re
import sys
from collections import Counter
from collections.abc import Iterator, Sequence
from typing import cast

RECORD_KIND = "tool_call"
FAILED = "failed"
EXECUTE = "Execute"
LEDGER_FILE = re.compile(r"^(?P<day>[0-9]{2})(?:\.[0-9]{3})?\.jsonl$")
SLEEP_COMMAND = re.compile(r"\bsleep\s+[0-9]")
BACKGROUND_FLAG = re.compile(r'"run_in_background"\s*:\s*true')
DISK_LOW = "remote_ssh_disk_low"
HANDLE_TOOLS = ("keeper_composition_status", "keeper_composition_cancel")
SIZE_CAPS = {"Grep": 102_400, "keeper_tools_list": 102_400, "BrowserTabs": 16_384, "masc_dashboard": 16_384}
DEFAULT_SLEEP_KEEPERS = ("github-pr-checker", "pr-updater")
SLEEP_POLL_MS = 60_000
OVERHEAD_TAIL_MS = 5_000
OVERHEAD_SLOW_MS = 500
UNKNOWN_SANDBOX = "unknown"
MS_PER_HOUR = 3_600_000
DEFAULT_SETTLE_S = 300.0
TOP_FAILED_TOOLS = 4
MAX_DAYS = 366

UTC = datetime.timezone.utc


@dataclasses.dataclass(frozen=True, slots=True)
class Call:
    """One ledger line. `input_text` and `output_text` are kept only for Execute and failed calls."""

    ts: float
    tool: str
    keeper: str
    duration_ms: float
    result_bytes: int
    failed: bool
    input_text: str
    output_text: str
    sandbox: str


@dataclasses.dataclass(slots=True)
class Skipped:
    bad_lines: int = 0


@dataclasses.dataclass(frozen=True, slots=True)
class Windows:
    before_since: float
    before_until: float
    after_since: float
    after_until: float


def text_of(value: object) -> str:
    return value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)


def number_of(value: object) -> float | None:
    """A JSON number or a numeric text as a float; a boolean is not a number."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return None
    return None


def parse_call(raw: bytes, since: float, until: float, skipped: Skipped) -> Call | None:
    """The call a ledger line records, or None when the line is outside the span or not a call."""
    try:
        row = cast("object", json.loads(raw))
    except ValueError:
        skipped.bad_lines += 1
        return None
    if not isinstance(row, dict):
        skipped.bad_lines += 1
        return None
    fields = cast("dict[str, object]", row)
    if fields.get("record_kind") != RECORD_KIND:
        return None
    stamp = number_of(fields.get("ts"))
    tool = fields.get("tool")
    if isinstance(fields.get("ts"), str) or stamp is None or not isinstance(tool, str):
        skipped.bad_lines += 1
        return None
    if not since <= stamp < until:
        return None
    keeper = fields.get("keeper")
    duration = number_of(fields.get("duration_ms"))
    size = number_of(fields.get("result_bytes"))
    failed = fields.get("disposition") == FAILED
    keep_text = tool == EXECUTE or failed
    contract = fields.get("runtime_contract")
    profile = cast("dict[str, object]", contract).get("sandbox_profile") if isinstance(contract, dict) else None
    return Call(
        ts=stamp,
        tool=tool,
        keeper=keeper if isinstance(keeper, str) else "",
        duration_ms=duration if duration is not None else 0.0,
        result_bytes=int(size) if size is not None else 0,
        failed=failed,
        input_text=text_of(fields.get("input")) if keep_text else "",
        output_text=text_of(fields.get("output")) if keep_text else "",
        sandbox=profile if isinstance(profile, str) and profile else UNKNOWN_SANDBOX,
    )


def ledger_files(base: pathlib.Path, since: datetime.datetime, until: datetime.datetime) -> list[pathlib.Path]:
    """The ledger files of each UTC day the span touches, in name order."""
    paths: list[pathlib.Path] = []
    day = since.date()
    last = until.date()
    while day <= last:
        folder = base / ".masc" / "tool_calls" / f"{day.year:04d}-{day.month:02d}"
        if folder.is_dir():
            paths.extend(sorted(p for p in folder.iterdir() if (m := LEDGER_FILE.match(p.name)) and int(m["day"]) == day.day))
        day += datetime.timedelta(days=1)
    return paths


def read_calls(paths: Sequence[pathlib.Path], since: float, until: float, skipped: Skipped) -> Iterator[Call]:
    for path in paths:
        with path.open("rb") as handle:
            for raw in handle:
                call = parse_call(raw, since, until, skipped)
                if call is not None:
                    yield call


def windows_of(boot: float, end: float, settle_s: float, hours_before: float | None) -> Windows:
    after_since = boot + settle_s
    if end <= after_since:
        raise ValueError("--end must come after --boot plus the settle gap")
    span = hours_before * 3600 if hours_before is not None else end - after_since
    if span <= 0:
        raise ValueError("--hours-before must be positive")
    return Windows(before_since=boot - span, before_until=boot, after_since=after_since, after_until=end)


def intent_of(input_text: str) -> str:
    try:
        value = cast("object", json.loads(input_text))
    except ValueError:
        return "unknown"
    if not isinstance(value, dict):
        return "unknown"
    intent = cast("dict[str, object]", value).get("intent")
    return "request_effect" if intent == "request_effect" else "auto"


def execution_time_ms_of(output_text: str) -> float | None:
    try:
        value = cast("object", json.loads(output_text))
    except ValueError:
        return None
    if not isinstance(value, dict):
        return None
    return number_of(cast("dict[str, object]", value).get("execution_time_ms"))


def hours(milliseconds: float) -> float:
    return round(milliseconds / MS_PER_HOUR, 3)


def sized_of(calls: Sequence[Call], tool: str, cap: int) -> dict[str, object]:
    sizes = sorted(call.result_bytes for call in calls if call.tool == tool)
    over = [size for size in sizes if size >= cap]
    return {
        "cap": cap,
        "calls": len(sizes),
        "p50": sizes[len(sizes) // 2] if sizes else None,
        "max": sizes[-1] if sizes else None,
        "at_or_over_cap": len(over),
        "bytes_at_or_over_cap": sum(over),
    }


def is_sleep_poll(call: Call, keepers: Sequence[str]) -> bool:
    return (
        call.tool == EXECUTE
        and call.keeper in keepers
        and call.duration_ms >= SLEEP_POLL_MS
        and SLEEP_COMMAND.search(call.input_text) is not None
    )


def execute_overhead(executes: Sequence[Call]) -> dict[str, object]:
    held = 0.0
    inside = 0.0
    tail_calls = 0
    tail_ms = 0.0
    rows = 0
    for call in executes:
        if call.failed:
            continue
        run = execution_time_ms_of(call.output_text)
        if run is None:
            continue
        rows += 1
        held += call.duration_ms
        inside += run
        outside = call.duration_ms - run
        if outside >= OVERHEAD_TAIL_MS:
            tail_calls += 1
            tail_ms += outside
    return {
        "calls": rows,
        "duration_hours": hours(held),
        "execution_hours": hours(inside),
        "overhead_hours": hours(held - inside),
        "overhead_share": round((held - inside) / held, 3) if held > 0 else None,
        "overhead_5s_or_more_calls": tail_calls,
        "overhead_5s_or_more_hours": hours(tail_ms),
    }


def overhead_by_sandbox(executes: Sequence[Call]) -> dict[str, object]:
    outside_by_sandbox: dict[str, list[float]] = {}
    for call in executes:
        if call.failed:
            continue
        run = execution_time_ms_of(call.output_text)
        if run is None:
            continue
        outside_by_sandbox.setdefault(call.sandbox, []).append(call.duration_ms - run)
    split: dict[str, object] = {}
    for sandbox, outside in sorted(outside_by_sandbox.items()):
        ordered = sorted(outside)
        slow = [milliseconds for milliseconds in ordered if milliseconds >= OVERHEAD_SLOW_MS]
        split[sandbox] = {
            "calls": len(ordered),
            "overhead_hours": hours(sum(ordered)),
            "overhead_p50_s": round(ordered[len(ordered) // 2] / 1000, 3),
            "slow_calls": len(slow),
            "slow_hours": hours(sum(slow)),
            "slow_mean_s": round(sum(slow) / len(slow) / 1000, 2) if slow else None,
        }
    return split


def disk_low_of(calls: Sequence[Call]) -> dict[str, object]:
    hit = [call for call in calls if call.failed and DISK_LOW in call.output_text]
    by_tool = Counter(call.tool for call in hit)
    by_intent = Counter(intent_of(call.input_text) for call in hit if call.tool == EXECUTE)
    return {
        "calls": len(hit),
        "by_tool": dict(sorted(by_tool.items(), key=lambda item: (-item[1], item[0]))),
        "execute_by_intent": dict(sorted(by_intent.items())),
    }


def summarize(calls: Sequence[Call], sleep_keepers: Sequence[str]) -> dict[str, object]:
    executes = [call for call in calls if call.tool == EXECUTE]
    background = [call for call in executes if BACKGROUND_FLAG.search(call.input_text)]
    started = [call for call in background if not call.failed]
    polls = [call for call in executes if is_sleep_poll(call, sleep_keepers)]
    long_held = [call for call in executes if call.duration_ms >= SLEEP_POLL_MS]
    failed_by_tool = Counter(call.tool for call in calls if call.failed)
    return {
        "calls": len(calls),
        "failed": sum(failed_by_tool.values()),
        "failed_by_tool": [
            {"tool": tool, "failed": count}
            for tool, count in sorted(failed_by_tool.items(), key=lambda item: (-item[1], item[0]))[:TOP_FAILED_TOOLS]
        ],
        "sized": {tool: sized_of(calls, tool, cap) for tool, cap in SIZE_CAPS.items()},
        "execute": {
            "calls": len(executes),
            "held_hours": hours(sum(call.duration_ms for call in executes)),
            "background_calls": len(background),
            "background_by_keeper": dict(sorted(Counter(call.keeper for call in background).items())),
            "held_60s_or_more_calls": len(long_held),
            "held_60s_or_more_hours": hours(sum(call.duration_ms for call in long_held)),
        },
        "sleep_polls": {
            "keepers": list(sleep_keepers),
            "keeper_execute_calls": sum(1 for call in executes if call.keeper in sleep_keepers),
            "calls": len(polls),
            "hours": hours(sum(call.duration_ms for call in polls)),
        },
        "execute_overhead": execute_overhead(executes),
        "execute_overhead_by_sandbox": overhead_by_sandbox(executes),
        "disk_low": disk_low_of(calls),
        "background_starts": {
            "calls": len(started),
            "naming_both_handle_tools": sum(1 for call in started if all(name in call.output_text for name in HANDLE_TOOLS)),
        },
    }


def compare(calls: Sequence[Call], windows: Windows, sleep_keepers: Sequence[str]) -> dict[str, object]:
    before = [call for call in calls if windows.before_since <= call.ts < windows.before_until]
    after = [call for call in calls if windows.after_since <= call.ts < windows.after_until]
    return {"before": summarize(before, sleep_keepers), "after": summarize(after, sleep_keepers)}


def parse_instant(text: str) -> datetime.datetime:
    return datetime.datetime.fromisoformat(text).replace(tzinfo=UTC)


def stamp(epoch: float) -> str:
    return datetime.datetime.fromtimestamp(epoch, UTC).isoformat()


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--boot", required=True, help="UTC, like 2026-11-07T18:24:19")
    parser.add_argument("--end", required=True, help="UTC, like 2026-11-08T14:08:00")
    parser.add_argument("--settle-s", type=float, default=DEFAULT_SETTLE_S)
    parser.add_argument("--hours-before", type=float)
    parser.add_argument("--sleep-keepers", nargs="*", default=list(DEFAULT_SLEEP_KEEPERS))
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    boot = parse_instant(cast("str", args.boot))
    end = parse_instant(cast("str", args.end))
    try:
        windows = windows_of(boot.timestamp(), end.timestamp(), cast("float", args.settle_s), cast("float | None", args.hours_before))
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2
    first = datetime.datetime.fromtimestamp(windows.before_since, UTC)
    if end - first > datetime.timedelta(days=MAX_DAYS):
        print(f"the span must stay within {MAX_DAYS} days", file=sys.stderr)
        return 2
    base = cast("pathlib.Path", args.base_path).expanduser()
    skipped = Skipped()
    paths = ledger_files(base, first, end)
    calls = list(read_calls(paths, windows.before_since, windows.after_until, skipped))
    result = compare(calls, windows, cast("list[str]", args.sleep_keepers))
    result["skipped"] = dataclasses.asdict(skipped)
    result["window"] = {
        "boot": boot.isoformat(),
        "settle_s": cast("float", args.settle_s),
        "before": [stamp(windows.before_since), stamp(windows.before_until)],
        "after": [stamp(windows.after_since), stamp(windows.after_until)],
        "files": len(paths),
    }
    out = cast("pathlib.Path | None", args.json_out)
    if out is not None:
        out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
