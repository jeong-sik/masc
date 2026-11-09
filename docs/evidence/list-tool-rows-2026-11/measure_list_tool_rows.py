#!/usr/bin/env python3
"""Size the rows of the list tools in the tool-call ledger, and what cutting a field saves.

Reads, and never writes:

- `<base-path>/.masc/tool_calls/<YYYY-MM>/*.jsonl`: one JSON object per line. A line counts when
  `record_kind` is `tool_call`. Fields used: `ts` (UTC seconds), `tool`, `keeper`, `input`,
  `output` and `result_bytes`. `result_bytes` is what the tool produced. When it is over the lane
  ceiling the ledger keeps `output` as `{"_blob": {"sha256", "bytes", "mime", "preview"}}`, and the
  model got that marker with its 200 character preview.
- `<base-path>/.masc/tool_blobs/<sha256[:2]>/<sha256>`: the full text behind a marker.
- `<base-path>/.masc/runs/<task_id>/run.json`: one record per run.

Subcommands:

- `calls TOOL`: a line per call of TOOL in the month: UTC time, keeper, `result_bytes`, input, and
  `blob` or `inline`.
- `goal-list`: opens the blob of the newest unfiltered `masc_goal_list` call that kept one. Prints
  the bytes of each goal field (the JSON of its value), the rows per phase, and the size of the
  unfiltered list and of each phase list as it is and with `criterion_review` cut to the keys the
  list keeps. Sizes are re-serialised compact JSON, a few bytes off the ledger's `result_bytes`.
  The `rollup` stays whole in every phase list.
- `run-list`: sizes the rows of `masc_run_list` from the run records: the row bytes, the listing of
  the newest 50, 100 and all runs, and the listing that carries every plan text (the old shape).

Lines that are not JSON are counted and reported, never dropped silently.
"""

import argparse
import datetime
import json
import pathlib
import sys
from typing import Final

type Json = None | bool | int | float | str | list[Json] | dict[str, Json]

# The keys of `criterion_review` that a masc_goal_list row keeps.
SUMMARY_KEYS: Final = ("state", "request_id", "criterion_revision", "reason", "detail", "authority")
PHASES: Final = ("executing", "verifying")


def compact_bytes(value: Json) -> int:
    return len(json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


def as_dict(value: Json, what: str) -> dict[str, Json]:
    if not isinstance(value, dict):
        raise ValueError(f"{what}: expected an object")
    return value


def as_list(value: Json, what: str) -> list[Json]:
    if not isinstance(value, list):
        raise ValueError(f"{what}: expected an array")
    return value


def as_number(value: Json, what: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{what}: expected a number")
    return float(value)


def tool_calls(base: pathlib.Path, month: str, tool: str) -> list[dict[str, Json]]:
    calls: list[dict[str, Json]] = []
    unreadable = 0
    for path in sorted((base / ".masc" / "tool_calls" / month).glob("*.jsonl")):
        with path.open(encoding="utf-8", errors="replace") as lines:
            for line in lines:
                if tool not in line:
                    continue
                try:
                    record: Json = json.loads(line)
                except json.JSONDecodeError:
                    unreadable += 1
                    continue
                if (
                    isinstance(record, dict)
                    and record.get("record_kind") == "tool_call"
                    and record.get("tool") == tool
                ):
                    calls.append(record)
    if unreadable:
        print(f"skipped {unreadable} lines that are not JSON", file=sys.stderr)
    calls.sort(key=lambda call: as_number(call.get("ts"), "ts"))
    return calls


def blob_marker(call: dict[str, Json]) -> dict[str, Json] | None:
    output = call.get("output")
    if isinstance(output, dict) and "_blob" in output:
        return as_dict(output["_blob"], "_blob")
    return None


def blob_path(base: pathlib.Path, marker: dict[str, Json]) -> pathlib.Path:
    sha = marker.get("sha256")
    if not isinstance(sha, str) or len(sha) < 3:
        raise ValueError("_blob.sha256: expected a hex string")
    return base / ".masc" / "tool_blobs" / sha[:2] / sha


def show_calls(base: pathlib.Path, month: str, tool: str) -> None:
    calls = tool_calls(base, month, tool)
    total = 0
    by_input: dict[str, tuple[int, int]] = {}
    for call in calls:
        stamp = datetime.datetime.fromtimestamp(as_number(call.get("ts"), "ts"), datetime.UTC)
        size = call.get("result_bytes")
        bytes_out = int(size) if isinstance(size, int) else 0
        total += bytes_out
        kind = "blob" if blob_marker(call) is not None else "inline"
        arguments = json.dumps(call.get("input"), ensure_ascii=False, sort_keys=True)
        count, summed = by_input.get(arguments, (0, 0))
        by_input[arguments] = (count + 1, summed + bytes_out)
        print(f"{stamp:%m-%d %H:%MZ} {call.get('keeper')} {bytes_out} {kind} {arguments}")
    print("by input: calls, bytes")
    for arguments, (count, summed) in sorted(by_input.items(), key=lambda item: -item[1][1]):
        print(f"  {count:4} {summed:10} {arguments}")
    print(f"{tool}: {len(calls)} calls, {total} bytes in {month}")


def cut_review(goal: dict[str, Json]) -> dict[str, Json]:
    review = goal.get("criterion_review")
    if not isinstance(review, dict):
        return goal
    return {**goal, "criterion_review": {key: review[key] for key in SUMMARY_KEYS if key in review}}


def list_size(listing: dict[str, Json], goals: list[dict[str, Json]]) -> int:
    return compact_bytes({**listing, "count": len(goals), "goals": list(goals)})


def goal_list(base: pathlib.Path, month: str) -> None:
    candidates = [
        call
        for call in tool_calls(base, month, "masc_goal_list")
        if call.get("input") == {} and blob_marker(call) is not None
    ]
    if not candidates:
        raise SystemExit(f"no unfiltered masc_goal_list call with a blob in {month}")
    newest = candidates[-1]
    marker = blob_marker(newest)
    if marker is None:
        raise SystemExit("unreachable: the filter above kept only calls with a blob")
    listing = as_dict(json.loads(blob_path(base, marker).read_text(encoding="utf-8")), "goal list")
    goals = [as_dict(goal, "goal") for goal in as_list(listing["goals"], "goals")]
    stamp = datetime.datetime.fromtimestamp(as_number(newest.get("ts"), "ts"), datetime.UTC)
    print(f"call {stamp:%m-%d %H:%MZ} {newest.get('keeper')} result_bytes={newest.get('result_bytes')} goals={len(goals)}")

    fields: dict[str, int] = {}
    for goal in goals:
        for key, value in goal.items():
            fields[key] = fields.get(key, 0) + compact_bytes(value)
    total = sum(fields.values())
    print("bytes of each goal field (value only):")
    for key, size in sorted(fields.items(), key=lambda item: -item[1])[:6]:
        print(f"  {key:20} {size:9} {100.0 * size / total:5.1f}%")

    inner: dict[str, int] = {}
    for goal in goals:
        review = goal.get("criterion_review")
        if isinstance(review, dict):
            for key, value in review.items():
                inner[key] = inner.get(key, 0) + compact_bytes(value)
    print("bytes of each criterion_review key (value only):")
    for key, size in sorted(inner.items(), key=lambda item: -item[1])[:5]:
        print(f"  {key:20} {size:9}")

    print("rows per phase: goals, row bytes, criterion_review bytes")
    for phase in sorted({str(goal.get("phase")) for goal in goals}):
        rows = [goal for goal in goals if str(goal.get("phase")) == phase]
        review = sum(compact_bytes(goal.get("criterion_review")) for goal in rows)
        print(f"  {phase:12} {len(rows):3} {sum(compact_bytes(goal) for goal in rows):9} {review:9}")

    print("list bytes as it is -> with criterion_review cut to its summary keys:")
    for label, phase in (("unfiltered", None), *((phase, phase) for phase in PHASES)):
        rows = [goal for goal in goals if phase is None or goal.get("phase") == phase]
        before = list_size(listing, rows)
        after = list_size(listing, [cut_review(goal) for goal in rows])
        print(f"  {label:12} {before:9} -> {after:9}  (the cut removes {before - after} bytes, {100.0 * (before - after) / before:.1f}%)")


def run_list(base: pathlib.Path) -> None:
    records: list[dict[str, Json]] = []
    for path in sorted((base / ".masc" / "runs").glob("*/run.json")):
        records.append(as_dict(json.loads(path.read_text(encoding="utf-8")), str(path)))
    records.sort(key=lambda run: str(run.get("task_id")))
    records.sort(key=lambda run: str(run.get("updated_at")), reverse=True)

    def row(run: dict[str, Json]) -> dict[str, Json]:
        plan = run.get("plan")
        return {
            "task_id": run.get("task_id"),
            "agent_name": run.get("agent_name"),
            "plan_bytes": len(plan.encode("utf-8")) if isinstance(plan, str) else 0,
            "created_at": run.get("created_at"),
            "updated_at": run.get("updated_at"),
        }

    rows = [row(run) for run in records]
    sizes = [compact_bytes(r) for r in rows]
    plans = sorted(len(str(run.get("plan", "")).encode("utf-8")) for run in records)
    print(f"runs {len(records)}")
    print(f"row bytes: mean {sum(sizes) / len(sizes):.1f}, max {max(sizes)}")
    print(f"plan bytes: median {plans[len(plans) // 2]}, max {plans[-1]}, not empty {sum(1 for p in plans if p)}")
    for shown in (50, 100, len(rows)):
        listing: dict[str, Json] = {"count": len(rows), "shown": min(shown, len(rows)), "runs": list(rows[:shown])}
        print(f"listing of the newest {shown}: {compact_bytes(listing)} bytes")
    old: dict[str, Json] = {"count": len(records), "runs": list(records)}
    print(f"old shape, every run with its plan text: {compact_bytes(old)} bytes")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, default=pathlib.Path("~/me").expanduser())
    parser.add_argument("--month", default="2026-11")
    sub = parser.add_subparsers(dest="command", required=True)
    calls = sub.add_parser("calls")
    calls.add_argument("tool")
    sub.add_parser("goal-list")
    sub.add_parser("run-list")
    args = parser.parse_args()
    base: pathlib.Path = args.base_path
    month: str = args.month
    match args.command:
        case "calls":
            show_calls(base, month, str(args.tool))
        case "goal-list":
            goal_list(base, month)
        case "run-list":
            run_list(base)
        case other:
            raise SystemExit(f"unknown subcommand {other}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
