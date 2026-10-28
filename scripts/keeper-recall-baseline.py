#!/usr/bin/env python3
"""Measure how much Keeper memory recall is used, per runtime.

Reads the Keeper decision logs (``<keeper>.decisions.jsonl`` and rotations) and
the raw run traces (``<keeper>/raw-traces/*.jsonl``) in a keepers runtime
directory and prints three tables:

1. Per runtime provider: turns that used a tool, and how many of those turns
   called ``keeper_memory_search``.
2. Per model: runs whose prompt text carried the Memory OS Recall notice
   against runs whose prompt text did not, and how many of each called
   ``keeper_memory_search``. An official-client session is not sent a block it
   already holds, so the two groups differ for those clients. API lanes carry
   the notice outside ``run_started.prompt``; their rows are not comparable.
3. How many ``keeper_memory_search`` events found nothing.
4. The share of all tool calls that were memory, Skill, wiki or artifact reads.
5. With ``--memory-dir``: how many Retrieved events point at a memory id that
   is no longer a current fact (a memory id is the hash of its claim, so a
   rewritten claim gets a new id).
6. With ``--memory-dir``: memory commits per UTC day against
   ``keeper_memory_search`` calls per UTC day.

Both logs rotate, so each Keeper's window differs; ``--since`` bounds the
earliest record read. A search that returns nothing may be a correct answer
(nothing stored), so the third table bounds recall quality and does not
measure it.

Read-only. The keepers directory is an argument; nothing is assumed about
where ``<base-path>/.masc`` lives.

Usage:
    python3 scripts/keeper-recall-baseline.py <keepers-dir>
    python3 scripts/keeper-recall-baseline.py <keepers-dir> --since 2026-10-02 --exclude lab-sangsu
"""

from __future__ import annotations

import argparse
import collections
import datetime
import glob
import hashlib
import json
import os
import sys
from collections.abc import Iterator

SEARCH_TOOL = "keeper_memory_search"
NOTICE_MARKER = "Memory OS Recall"
# The values of Keeper_semantic_execution.official_client_kind, as they prefix
# a runtime id such as "claude_code_ac22c1f2.claude-sonnet-5-5_...".
OFFICIAL_CLIENT_FAMILIES = ("claude_code", "muse", "codex", "antigravity")
MIN_RUNS_PER_MODEL = 30


def read_jsonl(path: str) -> Iterator[dict[str, object]]:
    try:
        handle = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return
    with handle:
        for line in handle:
            try:
                value = json.loads(line)
            except ValueError:
                continue
            if isinstance(value, dict):
                yield value


def as_int(value: object) -> int:
    return value if isinstance(value, int) and not isinstance(value, bool) else 0


def as_float(value: object) -> float:
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else 0.0


def as_str(value: object) -> str:
    return value if isinstance(value, str) else ""


def provider_of(runtime_id: str) -> str:
    head = runtime_id.split(".")[0]
    for family in OFFICIAL_CLIENT_FAMILIES:
        if head.startswith(family):
            return family
    return head or "none"


def keeper_of(path: str) -> str:
    return os.path.basename(path).split(".decisions")[0]


def decision_logs(keepers_dir: str, excluded: set[str]) -> list[str]:
    paths = glob.glob(os.path.join(keepers_dir, "*.decisions.jsonl*"))
    return sorted(path for path in paths if keeper_of(path) not in excluded)


def trace_files(keepers_dir: str, excluded: set[str]) -> list[str]:
    paths = glob.glob(os.path.join(keepers_dir, "*", "raw-traces", "*.jsonl"))
    return sorted(path for path in paths if path.split(os.sep)[-3] not in excluded)


def table_by_provider(paths: list[str], since: float) -> None:
    turns: collections.Counter[str] = collections.Counter()
    tool_turns: collections.Counter[str] = collections.Counter()
    search_turns: collections.Counter[str] = collections.Counter()
    for path in paths:
        for record in read_jsonl(path):
            if record.get("event") != "turn" or as_float(record.get("ts_unix")) < since:
                continue
            context = record.get("provider_context")
            runtime = ""
            if isinstance(context, dict):
                runtime = as_str(context.get("executed_runtime_id")) or as_str(context.get("runtime_id"))
            provider = provider_of(runtime)
            turns[provider] += 1
            if as_int(record.get("tool_call_count")) > 0:
                tool_turns[provider] += 1
                used = record.get("tools_used")
                if isinstance(used, list) and any(SEARCH_TOOL in str(tool) for tool in used):
                    search_turns[provider] += 1
    print("provider | turns | tool_turns | search_turns | search turns per 100 tool_turns")
    for provider, count in turns.most_common():
        rate = 100 * search_turns[provider] / tool_turns[provider] if tool_turns[provider] else 0.0
        print(f"{provider} | {count} | {tool_turns[provider]} | {search_turns[provider]} | {rate:.2f}")


def table_notice_freshness(paths: list[str], since: float) -> None:
    # model -> [fresh runs, fresh runs that searched, other runs, other runs that searched]
    cells: dict[str, list[int]] = collections.defaultdict(lambda: [0, 0, 0, 0])
    for path in paths:
        model = ""
        fresh = False
        searched = False
        used_tool = False
        in_window = False
        for record in read_jsonl(path):
            kind = record.get("record_type")
            if kind == "run_started":
                model = as_str(record.get("model"))
                fresh = NOTICE_MARKER in as_str(record.get("prompt"))
                in_window = as_float(record.get("ts")) >= since
            elif kind in ("tool_execution_started", "native_tool_started"):
                used_tool = True
                if as_str(record.get("tool_name")).endswith(SEARCH_TOOL):
                    searched = True
        if not model or not used_tool or not in_window:
            continue
        cell = cells[model]
        offset = 0 if fresh else 2
        cell[offset] += 1
        cell[offset + 1] += int(searched)
    print(f"\nmodel | notice in prompt text -> searched | not in prompt text -> searched (runs with tools, n >= {MIN_RUNS_PER_MODEL})")
    for model, cell in sorted(cells.items(), key=lambda item: -(item[1][0] + item[1][2])):
        if cell[0] + cell[2] < MIN_RUNS_PER_MODEL:
            continue
        show = lambda runs, hits: f"{hits}/{runs} ({100 * hits / runs:.1f}%)" if runs else "-"
        print(f"{model} | {show(cell[0], cell[1])} | {show(cell[2], cell[3])}")


def zero_hit_share(paths: list[str], since: float) -> None:
    total = 0
    empty = 0
    for path in paths:
        for record in read_jsonl(path):
            if record.get("event") != "memory_search" or as_float(record.get("ts_unix")) < since:
                continue
            total += 1
            empty += int(as_int(record.get("match_count")) == 0)
    share = 100 * empty / total if total else 0.0
    print(f"\nkeeper_memory_search events: {total}, with no match: {empty} ({share:.1f}%)")


def tool_group(tool: str) -> str:
    if tool.endswith(SEARCH_TOOL):
        return "keeper_memory_search"
    if tool.endswith("keeper_workspace_memory_read"):
        return "keeper_workspace_memory_read"
    if tool.endswith("keeper_memory_write"):
        return "keeper_memory_write"
    if tool.endswith("keeper_artifact_read"):
        return "keeper_artifact_read"
    lowered = tool.lower()
    if "wiki" in lowered:
        return "wiki tools"
    if "skill" in lowered or lowered.startswith("keeper_compose"):
        return "skill tools"
    return ""


def table_tool_share(paths: list[str], since: float) -> None:
    total = 0
    groups: collections.Counter[str] = collections.Counter()
    for path in paths:
        for record in read_jsonl(path):
            if record.get("event") != "tool_exec" or as_float(record.get("ts_unix")) < since:
                continue
            total += 1
            group = tool_group(as_str(record.get("tool")))
            if group:
                groups[group] += 1
    print(f"\ntool_exec events: {total}")
    for group, count in groups.most_common():
        print(f"{group}: {count} ({100 * count / total:.2f}%)")


def memory_id_of(claim: str) -> str:
    # Keeper_memory_os_types.memory_id: the SHA-256 of the claim bytes.
    return "sha256:" + hashlib.sha256(claim.encode("utf-8")).hexdigest()


def table_orphaned_retrievals(memory_dir: str, excluded: set[str]) -> None:
    """Retrieved events whose memory id is no longer a current fact.

    A memory id is the hash of its claim, so rewriting a claim gives the fact a
    new id and leaves its earlier retrieval history pointing at an id that no
    longer exists.
    """
    facts = 0
    retrieved = 0
    orphaned = 0
    revised = 0
    for current_path in sorted(glob.glob(os.path.join(memory_dir, "*.memory-current.json"))):
        keeper = os.path.basename(current_path).split(".memory-current")[0]
        if keeper in excluded:
            continue
        try:
            with open(current_path, encoding="utf-8") as handle:
                snapshot = json.load(handle)
        except (OSError, ValueError):
            continue
        rows = snapshot.get("facts") if isinstance(snapshot, dict) else None
        current = {
            memory_id_of(as_str(row.get("claim")))
            for row in (rows if isinstance(rows, list) else [])
            if isinstance(row, dict)
        }
        facts += len(current)
        events_path = os.path.join(memory_dir, f"{keeper}.memory-events.jsonl")
        for event in read_jsonl(events_path):
            kind = event.get("kind")
            if kind == "retrieved":
                retrieved += 1
                orphaned += int(as_str(event.get("memory_id")) not in current)
            elif kind == "revised":
                revised += 1
    share = 100 * orphaned / retrieved if retrieved else 0.0
    print(f"\ncurrent facts: {facts}, revised events: {revised}")
    print(f"retrieved events: {retrieved}, pointing at an id that is no longer current: {orphaned} ({share:.1f}%)")


def utc_day(epoch: float) -> str:
    return datetime.datetime.fromtimestamp(epoch, tz=datetime.timezone.utc).strftime("%Y-%m-%d")


def table_daily_production(memory_dir: str, logs: list[str], excluded: set[str], since: float) -> None:
    """Memory commits per UTC day against keeper_memory_search calls per UTC day."""
    commits: collections.Counter[str] = collections.Counter()
    searches: collections.Counter[str] = collections.Counter()
    for path in sorted(glob.glob(os.path.join(memory_dir, "*.memory-journal.jsonl"))):
        keeper = os.path.basename(path).split(".memory-journal")[0]
        if keeper in excluded:
            continue
        for row in read_jsonl(path):
            recorded = as_float(row.get("recorded_at"))
            source = row.get("source")
            if row.get("outcome") != "committed" or recorded < since or not isinstance(source, dict):
                continue
            kind = as_str(source.get("kind"))
            if kind in ("librarian", "explicit_write"):
                commits[f"{utc_day(recorded)} {kind}"] += 1
    for path in logs:
        for record in read_jsonl(path):
            stamp = as_float(record.get("ts_unix"))
            if record.get("event") == "tool_exec" and stamp >= since and as_str(record.get("tool")).endswith(SEARCH_TOOL):
                searches[utc_day(stamp)] += 1
    print("\nUTC day | librarian commits | explicit_write commits | keeper_memory_search calls")
    for day in sorted({key.split(" ")[0] for key in commits} | set(searches)):
        print(f"{day} | {commits[day + ' librarian']} | {commits[day + ' explicit_write']} | {searches[day]}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("keepers_dir", help="the <base-path>/.masc/keepers directory")
    parser.add_argument("--memory-dir", help="the <base-path>/.masc/config/keepers directory; adds the orphaned-retrieval table")
    parser.add_argument("--since", help="earliest UTC date to read, YYYY-MM-DD")
    parser.add_argument("--exclude", action="append", default=[], help="Keeper name to skip; repeatable")
    args = parser.parse_args()
    if not os.path.isdir(args.keepers_dir):
        print(f"not a directory: {args.keepers_dir}", file=sys.stderr)
        return 2
    since = 0.0
    if args.since:
        since = datetime.datetime.fromisoformat(args.since).replace(tzinfo=datetime.timezone.utc).timestamp()
    excluded = set(args.exclude)
    logs = decision_logs(args.keepers_dir, excluded)
    table_by_provider(logs, since)
    table_notice_freshness(trace_files(args.keepers_dir, excluded), since)
    zero_hit_share(logs, since)
    table_tool_share(logs, since)
    if args.memory_dir:
        table_orphaned_retrievals(args.memory_dir, excluded)
        table_daily_production(args.memory_dir, logs, excluded, since)
    return 0


if __name__ == "__main__":
    sys.exit(main())
