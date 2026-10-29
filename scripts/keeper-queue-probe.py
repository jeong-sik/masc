#!/usr/bin/env python3
"""Measure how a Keeper's event queue relates to how its turns end.

Reads, in a keepers runtime directory (``<base-path>/.masc/keepers``):

* ``<keeper>/event-queue-v<N>.json``, the durable queue snapshot. The highest
  version found is read.
* ``<keeper>.decisions.jsonl`` and its ``.1`` rotation, one ``turn`` row per
  turn.

With ``--logs-dir`` (``<base-path>/.masc/logs``) it also reads
``system_log_<date>.jsonl``.

Tables:

1. Queue now: pending rows per Keeper by payload kind, the age and kind of the
   oldest row, and the largest ``checkpoint_retentions`` (how many checkpoint
   turns kept a row instead of consuming it). A snapshot, so it is skipped
   with ``--until``.
2. Turn endings per Keeper and UTC day: turns, checkpoints, the stop reason of
   each checkpoint, completed turns, and completed turns that used a tool.
3. Checkpoint turns by the number of tool calls they made.
4. Turn endings by execution path (direct chat turn or autonomous cycle) and
   runtime family. An official client reports a yield to a queued chat
   operation and a yield to a durable stimulus with the same stop reason, so
   ``op_q`` and ``durable`` are not a split of the cause for those families.
5. Length of completed turns by execution path.
6. The longest run of consecutive turns that ended on a durable stimulus.
7. With ``--logs-dir``: which pending kind headed each logged yield, how often
   a heartbeat found the owner busy before intake, and how many stimuli
   intake consumed again after an earlier turn had already consumed them. The
   chat-operation, scheduled-handoff and Gate-replay yield branches write no
   head line, so table 7 counts fewer yields than table 2. With ``--keeper``,
   table 7b lists that Keeper's consumed stimuli per class: how many were
   consumed, how many were distinct, and the most times one stimulus was
   consumed.

``--timeline`` prints one line per turn of one Keeper in the window instead of
the tables. ``--fleet-by day`` or ``--fleet-by hour`` prints one line per UTC
day or hour for all Keepers together instead of the tables: turns, durable and
operation-queued checkpoints, the share of turns that ended on either, and for
direct and autonomous turns separately how many ended and how many completed.

``--schedule-latency day`` or ``--schedule-latency hour`` (needs ``--logs-dir``)
prints one line per UTC day or hour of the due time instead of the tables:
the seconds from ``due_at`` to the first ``scheduled wake delivered`` log line
of the same schedule occurrence (percentiles and the longest), and how many
occurrences were delivered more than once. ``--since`` and ``--until`` bound
the due time here, not the log time. A schedule occurrence that no turn has
delivered yet writes no line and is not counted.

A line that is not a JSON object is skipped and counted. The count is printed
on stderr when it is not zero.

Both logs rotate, so each Keeper's window differs. ``--since`` and ``--until``
(a UTC day or a UTC time, ``2026-10-29`` or ``2026-10-29T02:54:34Z``) bound
what is read, and every table header repeats the bounds.

Read-only. The keepers directory is an argument; nothing is assumed about
where ``<base-path>/.masc`` lives.

Usage:
    python3 scripts/keeper-queue-probe.py <keepers-dir>
    python3 scripts/keeper-queue-probe.py <keepers-dir> --logs-dir <logs-dir> --since 2026-10-26 --until 2026-10-29T02:54:34Z
    python3 scripts/keeper-queue-probe.py <keepers-dir> --keeper code-reviewer --timeline --since 2026-10-29T02:08:00Z --until 2026-10-29T02:47:00Z
    python3 scripts/keeper-queue-probe.py <keepers-dir> --fleet-by day --since 2026-09-01 --until 2026-10-29T02:54:34Z
    python3 scripts/keeper-queue-probe.py <keepers-dir> --logs-dir <logs-dir> --schedule-latency day --since 2026-10-24 --until 2026-10-29T02:54:34Z
"""

from __future__ import annotations

import argparse
import collections
import dataclasses
import datetime
import glob
import json
import math
import os
import re
import sys
import time
from collections.abc import Iterator

DECISIONS_SUFFIX = ".decisions.jsonl"
QUEUE_SNAPSHOT_GLOB = "event-queue-v*.json"
YIELD_DURABLE = "yielded_to_durable_stimulus"
YIELD_OPERATION = "yielded_to_operation_queued"
COMPLETED = "completed"
CHECKPOINT = "checkpoint"
DIRECT_PATH = "direct_turn"
# The values of Keeper_semantic_execution.official_client_kind, as they prefix
# a runtime id such as "claude_code_ac22c1f2.claude-sonnet-5-5_...".
OFFICIAL_CLIENT_FAMILIES = ("claude_code", "muse", "codex", "antigravity")
AGENT_CORE_FAMILY = "agent_core"
TOOL_BUCKETS = ((0, 0, "0"), (1, 1, "1"), (2, 2, "2"), (3, 5, "3-5"), (6, None, "6+"))
# The system log messages the yield probes write. The head kind is the payload
# kind of the first pending row the probe saw. The first two exist at
# 3e41385b549. The last two exist only where the probe logs the chat and Gate
# branches, and carry no head.
HEAD_PATTERNS = (
    ("new durable successor", re.compile(r"source turn yields to a new durable successor: .*?head=(\w+)")),
    ("any pending stimulus", re.compile(r"autonomous turn yields to durable stimulus: .*?head=(\w+)")),
    ("queued chat operation", re.compile(r"source turn yields to a queued chat operation()")),
    ("approved Gate", re.compile(r"source turn yields to an approved Gate resolution()")),
)
OWNER_BUSY = "keeper owner busy before stimulus intake"
# The Keeper is named only at the end of the message; the row's keeper_name
# field holds "system" for these lines.
CONSUMED = re.compile(r"turn entry: consumed stimulus stimulus_id=(\S+) .*? class=(\w+) \(keeper=([^)]+)\)")
SCHEDULED = re.compile(r"turn entry: scheduled wake delivered schedule_id=(\S+) due_at=([0-9.]+) \(keeper=([^)]+)\)")
FLEET_BUCKETS = {"day": "%Y-%m-%d", "hour": "%m-%dT%HZ"}
# Lines that json.loads rejected or that were not objects, per file.
SKIPPED_LINES: collections.Counter[str] = collections.Counter()


@dataclasses.dataclass(frozen=True)
class Turn:
    ts: float
    turn_id: int
    path: str
    family: str
    stop: str
    checkpoint: bool
    tools: int
    latency_s: float | None


@dataclasses.dataclass(frozen=True)
class Window:
    since: float
    until: float

    def holds(self, ts: float) -> bool:
        return self.since <= ts <= self.until

    def label(self) -> str:
        def show(ts: float) -> str:
            if math.isinf(ts):
                return "open"
            return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        return "window %s .. %s" % (show(self.since), show(self.until))


@dataclasses.dataclass(frozen=True)
class LatencyRow:
    bucket: str
    occurrences: int
    p50: float
    p90: float
    p99: float
    longest: float
    delivered_again: int
    deliveries: int


def read_jsonl(path: str) -> Iterator[dict[str, object]]:
    try:
        handle = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return
    with handle:
        for line in handle:
            try:
                row = json.loads(line)
            except ValueError:
                SKIPPED_LINES[os.path.basename(path)] += 1
                continue
            if isinstance(row, dict):
                yield row
            else:
                SKIPPED_LINES[os.path.basename(path)] += 1


def parse_time(text: str) -> float:
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%d"):
        try:
            return datetime.datetime.strptime(text, fmt).replace(tzinfo=datetime.timezone.utc).timestamp()
        except ValueError:
            continue
    raise argparse.ArgumentTypeError("not a UTC day or time: %s" % text)


def utc_day(ts: float) -> str:
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%d")


def utc_clock(ts: float) -> str:
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%H:%M:%S")


def log_ts(row: dict[str, object]) -> float:
    ts = row.get("ts")
    if not isinstance(ts, str):
        return 0.0
    try:
        return datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc).timestamp()
    except ValueError:
        return 0.0


def percentile(sorted_values: list[float], fraction: float) -> float:
    """Nearest rank over an ascending list."""
    return sorted_values[min(len(sorted_values) - 1, int(fraction * len(sorted_values)))]


def keeper_names(keepers_dir: str, only: str | None) -> list[str]:
    names = set()
    for path in glob.glob(os.path.join(keepers_dir, "*" + DECISIONS_SUFFIX + "*")):
        names.add(os.path.basename(path).split(DECISIONS_SUFFIX)[0])
    if only is not None:
        return [only] if only in names else []
    return sorted(names)


def runtime_family(row: dict[str, object]) -> str:
    context = row.get("provider_context")
    runtime_id = context.get("runtime_id") if isinstance(context, dict) else None
    if isinstance(runtime_id, str):
        for family in OFFICIAL_CLIENT_FAMILIES:
            if runtime_id.startswith(family + "_"):
                return family
    return AGENT_CORE_FAMILY


def parse_turn(row: dict[str, object]) -> Turn | None:
    ts = row.get("ts_unix")
    turn_id = row.get("turn_id")
    if row.get("event") != "turn" or not isinstance(ts, (int, float)) or not isinstance(turn_id, int):
        return None
    telemetry = row.get("telemetry")
    reason = telemetry.get("stop_reason") if isinstance(telemetry, dict) else None
    tools = row.get("tool_call_count")
    latency = row.get("latency_ms")
    path = row.get("execution_path")
    return Turn(
        ts=float(ts),
        turn_id=turn_id,
        path=path if isinstance(path, str) else "unknown",
        family=runtime_family(row),
        stop=reason.split(":")[0] if isinstance(reason, str) else "none",
        checkpoint=row.get("terminal_reason_code") == CHECKPOINT,
        tools=tools if isinstance(tools, int) else 0,
        latency_s=latency / 1000.0 if isinstance(latency, (int, float)) else None,
    )


def read_turns(keepers_dir: str, keeper: str, window: Window) -> list[Turn]:
    turns = []
    for path in glob.glob(os.path.join(keepers_dir, keeper + DECISIONS_SUFFIX + "*")):
        for row in read_jsonl(path):
            turn = parse_turn(row)
            if turn is not None and window.holds(turn.ts):
                turns.append(turn)
    turns.sort(key=lambda turn: turn.ts)
    return turns


def queue_snapshot(keepers_dir: str, keeper: str) -> dict[str, object] | None:
    found = sorted(glob.glob(os.path.join(keepers_dir, keeper, QUEUE_SNAPSHOT_GLOB)),
                   key=lambda path: int(re.findall(r"v(\d+)", os.path.basename(path))[0]))
    if not found:
        return None
    try:
        with open(found[-1], encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def print_queue_now(keepers_dir: str, names: list[str]) -> None:
    now = time.time()
    print("1. Queue now (snapshot read at %s UTC)" % datetime.datetime.fromtimestamp(
        now, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
    print("%-30s %6s %-44s %9s %-26s %7s" % ("keeper", "rows", "by kind", "oldest_h", "oldest_kind", "max_ret"))
    total = 0
    for keeper in names:
        snapshot = queue_snapshot(keepers_dir, keeper)
        pending = snapshot.get("pending") if snapshot else None
        if not isinstance(pending, list) or not pending:
            continue
        kinds: collections.Counter[str] = collections.Counter()
        oldest = now
        oldest_kind = "-"
        retention = 0
        for entry in pending:
            source = entry.get("source", {})
            kind = str(source.get("payload", {}).get("kind"))
            kinds[kind] += 1
            arrived = float(source.get("arrived_at_unix", now))
            if arrived < oldest:
                oldest, oldest_kind = arrived, kind
            retention = max(retention, int(entry.get("checkpoint_retentions", 0)))
        total += len(pending)
        by_kind = ",".join("%s=%d" % kv for kv in kinds.most_common())
        print("%-30s %6d %-44s %9.2f %-26s %7d" % (
            keeper, len(pending), by_kind, (now - oldest) / 3600, oldest_kind, retention))
    print("%-30s %6d" % ("fleet", total))
    print()


def count_endings(turns: list[Turn], into: collections.Counter[str]) -> None:
    for turn in turns:
        into["turns"] += 1
        if turn.checkpoint:
            into["ckpt"] += 1
            if turn.tools <= 1:
                into["ckpt_t01"] += 1
        if turn.stop == YIELD_DURABLE:
            into["durable"] += 1
        elif turn.stop == YIELD_OPERATION:
            into["op_q"] += 1
        elif turn.stop == COMPLETED:
            into["done"] += 1
            if turn.tools >= 1:
                into["done_tool"] += 1


def ending_row(label: str, day: str, counts: collections.Counter[str]) -> str:
    share = 100.0 * counts["ckpt"] / counts["turns"] if counts["turns"] else 0.0
    return "%-26s %-10s %6d %6d %7d %7d %6d %9d %8d %9.1f%%" % (
        label, day, counts["turns"], counts["ckpt"], counts["durable"], counts["op_q"],
        counts["done"], counts["done_tool"], counts["ckpt_t01"], share)


ENDING_HEADER = "%-26s %-10s %6s %6s %7s %7s %6s %9s %8s %10s" % (
    "keeper", "day", "turns", "ckpt", "durable", "op_q", "done", "done+tool", "ckpt_t01", "ckpt_share")


def print_turn_endings(per_keeper: dict[str, list[Turn]], window: Window) -> None:
    print("2. Turn endings per Keeper and UTC day (%s; ckpt_t01 = checkpoint turns with 0 or 1 tool calls)"
          % window.label())
    print(ENDING_HEADER)
    fleet: collections.Counter[str] = collections.Counter()
    for keeper, turns in per_keeper.items():
        days: dict[str, list[Turn]] = collections.defaultdict(list)
        for turn in turns:
            days[utc_day(turn.ts)].append(turn)
        for day in sorted(days):
            counts: collections.Counter[str] = collections.Counter()
            count_endings(days[day], counts)
            fleet.update(counts)
            print(ending_row(keeper, day, counts))
    print(ending_row("fleet", "all", fleet))
    print()


def print_tool_histogram(per_keeper: dict[str, list[Turn]], window: Window) -> None:
    print("3. Checkpoint turns by tool calls made (%s)" % window.label())
    buckets: collections.Counter[str] = collections.Counter()
    for turns in per_keeper.values():
        for turn in turns:
            if not turn.checkpoint:
                continue
            for low, high, label in TOOL_BUCKETS:
                if turn.tools >= low and (high is None or turn.tools <= high):
                    buckets[label] += 1
                    break
    total = sum(buckets.values())
    print("%-8s %7s %8s" % ("tools", "turns", "share"))
    for _, _, label in TOOL_BUCKETS:
        share = 100.0 * buckets[label] / total if total else 0.0
        print("%-8s %7d %7.1f%%" % (label, buckets[label], share))
    print("%-8s %7d" % ("all", total))
    print()


def print_path_and_family(per_keeper: dict[str, list[Turn]], window: Window) -> None:
    print("4. Turn endings by execution path and runtime family (%s)" % window.label())
    print("%-18s %-12s %6s %6s %7s %7s %6s" % ("path", "family", "turns", "ckpt", "durable", "op_q", "done"))
    cells: dict[tuple[str, str], collections.Counter[str]] = collections.defaultdict(collections.Counter)
    for turns in per_keeper.values():
        for turn in turns:
            counts = cells[(turn.path, turn.family)]
            counts["turns"] += 1
            counts["ckpt"] += 1 if turn.checkpoint else 0
            counts["durable"] += 1 if turn.stop == YIELD_DURABLE else 0
            counts["op_q"] += 1 if turn.stop == YIELD_OPERATION else 0
            counts["done"] += 1 if turn.stop == COMPLETED else 0
    for (path, family), counts in sorted(cells.items()):
        print("%-18s %-12s %6d %6d %7d %7d %6d" % (
            path, family, counts["turns"], counts["ckpt"], counts["durable"], counts["op_q"], counts["done"]))
    print()


def print_completed_lengths(per_keeper: dict[str, list[Turn]], window: Window) -> None:
    print("5. Length of completed turns in seconds, nearest rank (%s)" % window.label())
    print("%-18s %7s %8s %8s %8s %9s" % ("path", "turns", "p50", "p90", "p99", "max"))
    lengths: dict[str, list[float]] = collections.defaultdict(list)
    for turns in per_keeper.values():
        for turn in turns:
            if turn.stop == COMPLETED and turn.latency_s is not None:
                lengths[turn.path].append(turn.latency_s)
                lengths["(all paths)"].append(turn.latency_s)
    for path in sorted(lengths):
        values = sorted(lengths[path])
        print("%-18s %7d %8.0f %8.0f %8.0f %9.0f" % (
            path, len(values), percentile(values, 0.5), percentile(values, 0.9),
            percentile(values, 0.99), values[-1]))
    print()


def print_longest_streaks(per_keeper: dict[str, list[Turn]], window: Window) -> None:
    print("6. Longest run of consecutive turns ended on a durable stimulus (%s)" % window.label())
    print("%-30s %6s %-20s %-20s" % ("keeper", "turns", "from_utc", "to_utc"))
    fmt = "%Y-%m-%dT%H:%M:%SZ"
    results = []
    for keeper, turns in per_keeper.items():
        best = (0, 0.0, 0.0)
        run, start = 0, 0.0
        for turn in turns:
            if turn.stop == YIELD_DURABLE:
                if run == 0:
                    start = turn.ts
                run += 1
                if run > best[0]:
                    best = (run, start, turn.ts)
            else:
                run = 0
        if best[0] > 0:
            results.append((best[0], keeper, best[1], best[2]))
    for count, keeper, start, end in sorted(results, reverse=True)[:10]:
        print("%-30s %6d %-20s %-20s" % (
            keeper, count,
            datetime.datetime.fromtimestamp(start, datetime.timezone.utc).strftime(fmt),
            datetime.datetime.fromtimestamp(end, datetime.timezone.utc).strftime(fmt)))
    print()


def print_consumed_by_class(keeper: str, times: dict[str, dict[str, list[float]]], window: Window) -> None:
    print("7b. Stimuli consumed by %s, per class (%s)" % (keeper, window.label()))
    print("%-32s %9s %9s %11s %10s" % ("class", "consumed", "distinct", "max_repeat", "gap_p50_s"))
    for kind, ids in sorted(times.items(), key=lambda item: -sum(len(stamps) for stamps in item[1].values())):
        firsts = sorted(min(stamps) for stamps in ids.values())
        gaps = sorted(later - earlier for earlier, later in zip(firsts, firsts[1:], strict=False))
        print("%-32s %9d %9d %11d %10s" % (
            kind, sum(len(stamps) for stamps in ids.values()), len(ids),
            max(len(stamps) for stamps in ids.values()),
            "%.0f" % percentile(gaps, 0.5) if gaps else "-"))
    print("gap_p50_s = median seconds between the first consumptions of two distinct stimuli of the class")
    print()


def print_log_counts(logs_dir: str, names: list[str], window: Window, detail_keeper: str | None) -> None:
    print("7. System log lines per Keeper (%s)" % window.label())
    wanted = set(names)
    heads: dict[str, collections.Counter[str]] = collections.defaultdict(collections.Counter)
    busy: collections.Counter[str] = collections.Counter()
    seen: dict[str, set[str]] = collections.defaultdict(set)
    consumed: collections.Counter[str] = collections.Counter()
    again: collections.Counter[str] = collections.Counter()
    again_by_class: collections.Counter[str] = collections.Counter()
    times: dict[str, dict[str, list[float]]] = collections.defaultdict(lambda: collections.defaultdict(list))
    for path in sorted(glob.glob(os.path.join(logs_dir, "system_log_*.jsonl"))):
        for row in read_jsonl(path):
            message = row.get("message")
            if not isinstance(message, str) or not window.holds(log_ts(row)):
                continue
            found = CONSUMED.search(message)
            if found:
                stimulus, kind, keeper = found.groups()
                if keeper in wanted:
                    consumed[keeper] += 1
                    if stimulus in seen[keeper]:
                        again[keeper] += 1
                        again_by_class[kind] += 1
                    seen[keeper].add(stimulus)
                    if keeper == detail_keeper:
                        times[kind][stimulus].append(log_ts(row))
                continue
            keeper_name = row.get("keeper_name")
            if keeper_name not in wanted:
                continue
            keeper = str(keeper_name)
            if OWNER_BUSY in message:
                busy[keeper] += 1
            elif "yield" in message:
                for label, pattern in HEAD_PATTERNS:
                    head = pattern.search(message)
                    if head:
                        kind = head.group(1)
                        heads[keeper]["%s head=%s" % (label, kind) if kind else label] += 1
                        break
    print("%-26s %6s %9s %8s  %s" % ("keeper", "busy", "consumed", "again", "yield probe and head kind"))
    for keeper in names:
        if not (heads[keeper] or busy[keeper] or consumed[keeper]):
            continue
        detail = "; ".join("%s=%d" % kv for kv in heads[keeper].most_common())
        print("%-26s %6d %9d %8d  %s" % (keeper, busy[keeper], consumed[keeper], again[keeper], detail))
    by_head: collections.Counter[str] = collections.Counter()
    for counts in heads.values():
        by_head.update(counts)
    print("%-26s %6d %9d %8d  %s" % ("fleet", sum(busy.values()), sum(consumed.values()), sum(again.values()),
                                     "; ".join("%s=%d" % kv for kv in by_head.most_common())))
    print("again = consumed a stimulus that an earlier turn of the same Keeper had consumed in the window; by class: "
          + ", ".join("%s=%d" % kv for kv in again_by_class.most_common()))
    print()
    if detail_keeper is not None and times:
        print_consumed_by_class(detail_keeper, times, window)


def read_scheduled_deliveries(logs_dir: str, wanted: set[str]) -> dict[tuple[str, str, float], list[float]]:
    """Log times of every delivery per (keeper, schedule id, due time)."""
    deliveries: dict[tuple[str, str, float], list[float]] = collections.defaultdict(list)
    for path in sorted(glob.glob(os.path.join(logs_dir, "system_log_*.jsonl"))):
        for row in read_jsonl(path):
            message = row.get("message")
            if not isinstance(message, str):
                continue
            found = SCHEDULED.search(message)
            if found is None:
                continue
            schedule_id, due_at, keeper = found.groups()
            if keeper in wanted:
                deliveries[(keeper, schedule_id, round(float(due_at), 3))].append(log_ts(row))
    return deliveries


def schedule_latency_rows(deliveries: dict[tuple[str, str, float], list[float]], window: Window,
                          unit: str) -> list[LatencyRow]:
    """One row per bucket of the due time, then ``all``. The delay is first delivery minus due time."""
    delays: dict[str, list[float]] = collections.defaultdict(list)
    counts: dict[str, list[int]] = collections.defaultdict(list)
    for (_keeper, _schedule, due_at), times in deliveries.items():
        if not window.holds(due_at):
            continue
        bucket = datetime.datetime.fromtimestamp(due_at, datetime.timezone.utc).strftime(FLEET_BUCKETS[unit])
        for key in (bucket, "all"):
            delays[key].append(min(times) - due_at)
            counts[key].append(len(times))
    rows: list[LatencyRow] = []
    for bucket in sorted(delays, key=lambda key: (key == "all", key)):
        ordered = sorted(delays[bucket])
        rows.append(LatencyRow(
            bucket=bucket, occurrences=len(ordered),
            p50=percentile(ordered, 0.5), p90=percentile(ordered, 0.9), p99=percentile(ordered, 0.99),
            longest=ordered[-1],
            delivered_again=sum(1 for count in counts[bucket] if count > 1),
            deliveries=sum(counts[bucket])))
    return rows


def print_schedule_latency(logs_dir: str, names: list[str], window: Window, unit: str) -> None:
    print("8. Due schedule latency per UTC %s of due_at (%s)" % (unit, window.label().replace("window", "due window")))
    print("seconds from due_at to the first 'scheduled wake delivered' line of the same occurrence")
    print("%-12s %6s %8s %8s %8s %8s %11s %7s" % ("bucket", "n", "p50_s", "p90_s", "p99_s", "max_s", "deliv/occ", "again%"))
    rows = schedule_latency_rows(read_scheduled_deliveries(logs_dir, set(names)), window, unit)
    for row in rows:
        print("%-12s %6d %8.0f %8.0f %8.0f %8.0f %11.2f %6.1f%%" % (
            row.bucket, row.occurrences, row.p50, row.p90, row.p99, row.longest,
            row.deliveries / row.occurrences, 100.0 * row.delivered_again / row.occurrences))
    print()


def print_timeline(keeper: str, turns: list[Turn], window: Window) -> None:
    print("Timeline of %s (%s)" % (keeper, window.label()))
    print("%-9s %7s %-17s %-11s %-30s %5s %9s" % ("utc", "turn", "path", "family", "stop", "tools", "seconds"))
    for turn in turns:
        print("%-9s %7d %-17s %-11s %-30s %5d %9s" % (
            utc_clock(turn.ts), turn.turn_id, turn.path, turn.family, turn.stop, turn.tools,
            "-" if turn.latency_s is None else "%.1f" % turn.latency_s))
    changes = sum(1 for before, after in zip(turns, turns[1:], strict=False) if before.path != after.path)
    print("turns %d, execution path changed between %d of %d consecutive pairs" % (
        len(turns), changes, max(len(turns) - 1, 0)))


def print_fleet_buckets(per_keeper: dict[str, list[Turn]], window: Window, unit: str) -> None:
    print("Fleet per UTC %s (%s; yield%% = durable + op_q turns over all turns)" % (unit, window.label()))
    print("%-10s %7s %8s %6s %7s | %7s %8s %9s | %7s %8s" % (
        "bucket", "turns", "durable", "op_q", "yield%", "direct", "dir_yld%", "dir_done%", "auto", "auto_yld%"))
    buckets: dict[str, collections.Counter[str]] = collections.defaultdict(collections.Counter)
    for turns in per_keeper.values():
        for turn in turns:
            when = datetime.datetime.fromtimestamp(turn.ts, datetime.timezone.utc)
            counts = buckets[when.strftime(FLEET_BUCKETS[unit])]
            lane = "dir" if turn.path == DIRECT_PATH else "auto"
            yielded = turn.stop in (YIELD_DURABLE, YIELD_OPERATION)
            counts["turns"] += 1
            counts["durable"] += turn.stop == YIELD_DURABLE
            counts["op_q"] += turn.stop == YIELD_OPERATION
            counts[lane] += 1
            counts[lane + "_yield"] += yielded
            counts[lane + "_done"] += turn.stop == COMPLETED

    def share(part: int, whole: int) -> str:
        return "%.1f%%" % (100.0 * part / whole) if whole else "-"

    total: collections.Counter[str] = collections.Counter()
    for bucket in sorted(buckets):
        counts = buckets[bucket]
        total.update(counts)
        print("%-10s %7d %8d %6d %7s | %7d %8s %9s | %7d %8s" % (
            bucket, counts["turns"], counts["durable"], counts["op_q"],
            share(counts["durable"] + counts["op_q"], counts["turns"]),
            counts["dir"], share(counts["dir_yield"], counts["dir"]), share(counts["dir_done"], counts["dir"]),
            counts["auto"], share(counts["auto_yield"], counts["auto"])))
    print("%-10s %7d %8d %6d %7s | %7d %8s %9s | %7d %8s" % (
        "all", total["turns"], total["durable"], total["op_q"],
        share(total["durable"] + total["op_q"], total["turns"]),
        total["dir"], share(total["dir_yield"], total["dir"]), share(total["dir_done"], total["dir"]),
        total["auto"], share(total["auto_yield"], total["auto"])))


def report_skipped() -> None:
    if SKIPPED_LINES:
        print("skipped %d line(s) that were not JSON objects: %s" % (
            sum(SKIPPED_LINES.values()),
            ", ".join("%s=%d" % kv for kv in SKIPPED_LINES.most_common(5))), file=sys.stderr)


def run(args: argparse.Namespace) -> int:
    window = Window(args.since if args.since is not None else 0.0,
                    args.until if args.until is not None else math.inf)
    names = keeper_names(args.keepers_dir, args.keeper)
    if not names:
        print("no decision logs found in %s" % args.keepers_dir, file=sys.stderr)
        return 1
    if args.schedule_latency:
        if not args.logs_dir:
            print("--schedule-latency needs --logs-dir", file=sys.stderr)
            return 2
        print_schedule_latency(args.logs_dir, names, window, args.schedule_latency)
        return 0
    per_keeper = {keeper: read_turns(args.keepers_dir, keeper, window) for keeper in names}
    if args.timeline:
        if args.keeper is None:
            print("--timeline needs --keeper", file=sys.stderr)
            return 2
        print_timeline(args.keeper, per_keeper[args.keeper], window)
        return 0
    if args.fleet_by:
        print_fleet_buckets(per_keeper, window, args.fleet_by)
        return 0
    if args.until is None:
        print_queue_now(args.keepers_dir, names)
    print_turn_endings(per_keeper, window)
    print_tool_histogram(per_keeper, window)
    print_path_and_family(per_keeper, window)
    print_completed_lengths(per_keeper, window)
    print_longest_streaks(per_keeper, window)
    if args.logs_dir:
        print_log_counts(args.logs_dir, names, window, args.keeper)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("keepers_dir")
    parser.add_argument("--logs-dir")
    parser.add_argument("--since", type=parse_time, help="earliest UTC day or time to read")
    parser.add_argument("--until", type=parse_time, help="latest UTC day or time to read")
    parser.add_argument("--keeper", help="only this Keeper")
    parser.add_argument("--timeline", action="store_true", help="one line per turn of --keeper")
    parser.add_argument("--fleet-by", choices=sorted(FLEET_BUCKETS), help="one line per UTC day or hour for all Keepers")
    parser.add_argument("--schedule-latency", choices=sorted(FLEET_BUCKETS),
                        help="one line per UTC day or hour of due_at: seconds until the first delivery (needs --logs-dir)")
    code = run(parser.parse_args())
    report_skipped()
    return code


if __name__ == "__main__":
    sys.exit(main())
