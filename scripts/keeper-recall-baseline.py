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
4. The share of all tool calls by group: memory search, memory select, memory write, shared
   memory read, artifact read, wiki read, wiki maintenance, Skill use and Skill
   authoring. A group with no call is printed with 0.
5. With ``--memory-dir``: for every Retrieved event, whether its memory id is
   still a current fact. If not, where the revised and absorbed records lead:
   to a current fact, to an id that is gone, or nowhere; or whether it was
   retracted. An id with no record at all is split by whether a committed
   journal row removed that fact.
6. With ``--memory-dir``: memory commits per UTC day against
   ``keeper_memory_search`` calls per UTC day.
7. With ``--memory-dir``: turns per UTC day, the Keepers that took them, and
   the claim bytes a judgment of every current fact would read per turn.

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
TOOL_GROUPS = (
    "keeper_memory_search",
    "keeper_memory_select",
    "keeper_memory_write",
    "keeper_workspace_memory_read",
    "keeper_artifact_read",
    "wiki read tools",
    "wiki maintenance tools",
    "skill use tools",
    "skill authoring tools",
)
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
    if tool.endswith("keeper_memory_select"):
        return "keeper_memory_select"
    if tool.endswith("keeper_memory_write"):
        return "keeper_memory_write"
    if tool.endswith("keeper_artifact_read"):
        return "keeper_artifact_read"
    lowered = tool.lower()
    if "wiki" in lowered:
        if lowered.endswith(("_read", "_search", "_list")):
            return "wiki read tools"
        return "wiki maintenance tools"
    if lowered.endswith(("keeper_skill_validate", "keeper_skill_publish")):
        return "skill authoring tools"
    if lowered.endswith("keeper_skill") or lowered.startswith("keeper_compose"):
        return "skill use tools"
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
    for group in TOOL_GROUPS:
        count = groups[group]
        share = 100 * count / total if total else 0.0
        print(f"{group}: {count} ({share:.2f}%)")


def memory_id_of(claim: str) -> str:
    # Keeper_memory_os_types.memory_id: the SHA-256 of the claim bytes.
    return "sha256:" + hashlib.sha256(claim.encode("utf-8")).hexdigest()


def lineage_outcome(
    memory_id: str,
    current: set[str],
    revised: dict[str, str],
    absorbed: dict[str, str],
    retracted: set[str],
) -> str:
    """Follow one memory id through its revised and absorbed records.

    Returns ``current`` when the id is a current fact, ``no_record`` when it is
    not and has no record at all, ``retracted``, ``to_current_by_rewrite`` when
    revised records alone lead to a current fact, ``to_current_by_absorption``
    when the path crosses at least one absorbed record, and ``dead_end`` when
    the records lead to an id that is neither current nor recorded.
    """
    seen: set[str] = set()
    followed = False
    absorbed_hop = False
    node = memory_id
    while True:
        if node in current:
            if not followed:
                return "current"
            return "to_current_by_absorption" if absorbed_hop else "to_current_by_rewrite"
        if node in seen:
            return "dead_end"
        seen.add(node)
        if node in revised:
            node = revised[node]
        elif node in absorbed:
            node = absorbed[node]
            absorbed_hop = True
        elif node in retracted:
            return "retracted"
        else:
            return "dead_end" if followed else "no_record"
        followed = True


def journal_removed_ids(path: str) -> set[str]:
    """Memory ids of the facts that committed journal rows took out of the current set."""
    removed: set[str] = set()
    for row in read_jsonl(path):
        change = row.get("change")
        if row.get("outcome") != "committed" or not isinstance(change, dict):
            continue
        facts = change.get("removed")
        for fact in facts if isinstance(facts, list) else []:
            if isinstance(fact, dict):
                removed.add(memory_id_of(as_str(fact.get("claim"))))
    return removed


def table_orphaned_retrievals(memory_dir: str, excluded: set[str]) -> None:
    """Retrieved events whose memory id is no longer a current fact, and why.

    A memory id is the hash of its claim. A fact leaves the current set when
    its claim is rewritten (a ``revised`` event), merged into another fact (an
    entry in ``memory-absorbed.jsonl``) or retracted. The table follows those
    records from each retrieved id. A fact can also leave in a committed
    journal row (``change.removed``) with none of those records; such ids are
    counted apart from ids that no file mentions.
    """
    facts = 0
    revised_events = 0
    outcomes: collections.Counter[str] = collections.Counter()
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
        revised: dict[str, str] = {}
        retracted: set[str] = set()
        retrieved: list[str] = []
        for event in read_jsonl(os.path.join(memory_dir, f"{keeper}.memory-events.jsonl")):
            kind = event.get("kind")
            if kind == "retrieved":
                retrieved.append(as_str(event.get("memory_id")))
            elif kind == "revised":
                revised_events += 1
                revised[as_str(event.get("memory_id"))] = as_str(event.get("superseded_by"))
            elif kind == "retracted":
                retracted.add(as_str(event.get("memory_id")))
        absorbed = {
            as_str(row.get("memory_id")): as_str(row.get("into"))
            for row in read_jsonl(os.path.join(memory_dir, f"{keeper}.memory-absorbed.jsonl"))
        }
        removed = journal_removed_ids(os.path.join(memory_dir, f"{keeper}.memory-journal.jsonl"))
        for memory_id in retrieved:
            outcome = lineage_outcome(memory_id, current, revised, absorbed, retracted)
            if outcome == "no_record" and memory_id in removed:
                outcome = "removed_by_commit"
            outcomes[outcome] += 1
    total = sum(outcomes.values())
    print(f"\ncurrent facts: {facts}, revised events: {revised_events}")
    print(f"retrieved events: {total}")
    labels = (
        ("current", "the id is a current fact"),
        ("to_current_by_rewrite", "not current; revised records alone lead to a current fact"),
        ("to_current_by_absorption", "not current; the records cross an absorption and lead to a current fact"),
        ("dead_end", "not current; the records lead to an id that is gone"),
        ("retracted", "retracted"),
        ("removed_by_commit", "not current, no revised/absorbed/retracted record; a committed journal row removed it"),
        ("no_record", "not current and no file mentions it"),
    )
    for key, label in labels:
        share = 100 * outcomes[key] / total if total else 0.0
        print(f"  {label}: {outcomes[key]} ({share:.1f}%)")


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


def table_daily_turns(memory_dir: str, logs: list[str], excluded: set[str], since: float) -> None:
    """Turns per UTC day and the claim bytes a per-turn judgment of all current facts would read.

    The bytes use each Keeper's current facts for every day, so a past day is
    only as accurate as the Keeper's fact count was stable.
    """
    claim_bytes: dict[str, int] = {}
    for path in sorted(glob.glob(os.path.join(memory_dir, "*.memory-current.json"))):
        keeper = os.path.basename(path).split(".memory-current")[0]
        if keeper in excluded:
            continue
        try:
            with open(path, encoding="utf-8") as handle:
                snapshot = json.load(handle)
        except (OSError, ValueError):
            continue
        rows = snapshot.get("facts") if isinstance(snapshot, dict) else None
        claim_bytes[keeper] = sum(
            len(as_str(row.get("claim")).encode("utf-8"))
            for row in (rows if isinstance(rows, list) else [])
            if isinstance(row, dict)
        )
    turns: collections.Counter[str] = collections.Counter()
    keepers: dict[str, set[str]] = collections.defaultdict(set)
    read_bytes: collections.Counter[str] = collections.Counter()
    for path in logs:
        keeper = keeper_of(path)
        for record in read_jsonl(path):
            stamp = as_float(record.get("ts_unix"))
            if record.get("event") != "turn" or stamp < since:
                continue
            day = utc_day(stamp)
            turns[day] += 1
            keepers[day].add(keeper)
            read_bytes[day] += claim_bytes.get(keeper, 0)
    print("\nUTC day | turns | Keepers with a turn | claim MB over all turns | KB per turn")
    for day in sorted(turns):
        per_turn = read_bytes[day] / turns[day] / 1e3
        print(f"{day} | {turns[day]} | {len(keepers[day])} | {read_bytes[day] / 1e6:.0f} | {per_turn:.0f}")


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
        table_daily_turns(args.memory_dir, logs, excluded, since)
    return 0


if __name__ == "__main__":
    sys.exit(main())
