#!/usr/bin/env python3
"""Describe the Keeper memory store that a recall layer would read from.

Reads ``<memory-dir>/<keeper>.memory-current.json``, ``.memory-events.jsonl``
and ``.memory-journal.jsonl`` (the ``<base-path>/.masc/config/keepers``
directory) and prints these tables:

1. The current facts: how many, their origin, category, source coordinate
   (``basis``), age since ``last_seen``, and the per-Keeper size a judge would
   have to read.
2. What happened to the facts that Keepers wrote themselves (journal rows whose
   source is ``explicit_write``): still current as written, rewritten, retracted
   or gone from the current set without a recorded event.
   The source-bound claim store and the admission queues are counted next to
   them.
3. Librarian commits against failures per UTC day.
4. How facts left the current set: revised and retracted events, absorptions
   (``.memory-absorbed.jsonl``) and the facts that committed journal rows
   removed or dropped.
5. With ``--keepers-dir``: the memory judgment requests already sent to Jev
   (``<keeper>/memory-selection-evaluations.jsonl``): how many, from which
   Keeper, to which host, how large and how fast.
6. With ``--lane-runs``: how long the exact-output lanes took and how large
   their input was (``<base-path>/.masc/exact-lane-runs-v7.jsonl``).

Read-only. A fact's memory id is the SHA-256 of its claim, so the second table
matches by claim and cannot see a fact that was reworded.

Usage:
    python3 scripts/keeper-recall-store.py <memory-dir> --since 2026-10-02 \\
        --lane-runs <base-path>/.masc/exact-lane-runs-v7.jsonl --exclude lab-sangsu
"""

from __future__ import annotations

import argparse
import collections
import datetime
import glob
import hashlib
import json
import os
import statistics
import sys
import time
from collections.abc import Iterator

LANE_FAILURE_KINDS = frozenset(
    {
        "exact_execution_failure",
        "lane_cancelled",
        "absorb_judgment_failure",
        "exact_setup_failure",
        "domain_output_invalid",
        "unhandled_exception",
    }
)
SECONDS_PER_DAY = 86400


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
                continue
            if isinstance(row, dict):
                yield row


def as_float(value: object) -> float:
    try:
        return float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return 0.0


def as_str(value: object) -> str:
    return value if isinstance(value, str) else ""


def as_dict(value: object) -> dict[str, object]:
    return value if isinstance(value, dict) else {}


def as_list(value: object) -> list[object]:
    return value if isinstance(value, list) else []


def memory_id_of(claim: str) -> str:
    # Keeper_memory_os_types.memory_id: the SHA-256 of the claim bytes.
    return "sha256:" + hashlib.sha256(claim.encode("utf-8")).hexdigest()


def quantile(sorted_values: list[float], fraction: float) -> float:
    return sorted_values[int(fraction * (len(sorted_values) - 1))] if sorted_values else 0.0


def utc_day(epoch: float) -> str:
    return datetime.datetime.fromtimestamp(epoch, tz=datetime.timezone.utc).strftime("%m-%d")


def keeper_of(path: str, marker: str) -> str:
    return os.path.basename(path).split(marker)[0]


def load_current(memory_dir: str, excluded: set[str]) -> dict[str, list[dict[str, object]]]:
    current: dict[str, list[dict[str, object]]] = {}
    for path in sorted(glob.glob(os.path.join(memory_dir, "*.memory-current.json"))):
        keeper = keeper_of(path, ".memory-current")
        if keeper in excluded:
            continue
        try:
            with open(path, encoding="utf-8") as handle:
                snapshot = json.load(handle)
        except (OSError, ValueError):
            continue
        facts = as_list(as_dict(snapshot).get("facts"))
        current[keeper] = [as_dict(fact) for fact in facts if isinstance(fact, dict)]
    return current


def table_current_facts(current: dict[str, list[dict[str, object]]], now: float) -> None:
    facts = [fact for rows in current.values() for fact in rows]
    ages = sorted((now - as_float(fact.get("last_seen"))) / SECONDS_PER_DAY for fact in facts)
    origin = collections.Counter(as_str(as_dict(fact.get("origin")).get("kind")) for fact in facts)
    category = collections.Counter(as_str(fact.get("category")) for fact in facts)
    with_board = sum(1 for fact in facts if "board" in as_dict(fact.get("basis")))
    derived = sum(1 for fact in facts if as_str(as_dict(fact.get("basis")).get("kind")) == "derived")
    per_keeper = sorted(float(len(rows)) for rows in current.values())
    claim_bytes = sorted(
        float(sum(len(as_str(fact.get("claim")).encode("utf-8")) for fact in rows)) for rows in current.values()
    )
    total = len(facts)
    print(f"as of {datetime.datetime.fromtimestamp(now, tz=datetime.timezone.utc).isoformat()}")
    print(f"\ncurrent facts: {total} in {len(current)} Keepers")
    if not total:
        return
    print(f"origin: {dict(origin)}")
    print(f"category: {category.most_common(8)}")
    print(f"source coordinate: board {with_board} ({100 * with_board / total:.1f}%), derived {derived}, other {total - with_board - derived}")
    print(
        "age since last_seen, days: "
        f"p10 {quantile(ages, 0.1):.1f}, p50 {quantile(ages, 0.5):.1f}, p90 {quantile(ages, 0.9):.1f}, max {ages[-1]:.1f}; "
        f"older than 7 days {100 * sum(a > 7 for a in ages) / total:.1f}%, "
        f"older than 14 days {100 * sum(a > 14 for a in ages) / total:.1f}%"
    )
    print(f"facts per Keeper: median {statistics.median(per_keeper):.1f}, max {per_keeper[-1]:.0f}")
    print(
        "claim bytes per Keeper, KB: "
        f"median {statistics.median(claim_bytes) / 1000:.0f}, p90 {quantile(claim_bytes, 0.9) / 1000:.0f}, max {claim_bytes[-1] / 1000:.0f}"
    )


def table_write_fate(memory_dir: str, current: dict[str, list[dict[str, object]]], since: float) -> None:
    written: list[tuple[str, str, str]] = []  # (keeper, trace id, fate) per fact
    per_day: collections.Counter[str] = collections.Counter()
    categories: collections.Counter[str] = collections.Counter()
    replaced = 0
    for keeper, facts in current.items():
        by_id = {memory_id_of(as_str(fact.get("claim"))): fact for fact in facts}
        revised: set[str] = set()
        retracted: set[str] = set()
        absorbed = {
            as_str(row.get("memory_id"))
            for row in read_jsonl(os.path.join(memory_dir, f"{keeper}.memory-absorbed.jsonl"))
        }
        for event in read_jsonl(os.path.join(memory_dir, f"{keeper}.memory-events.jsonl")):
            kind = event.get("kind")
            if kind == "revised":
                revised.add(as_str(event.get("memory_id")))
            elif kind == "retracted":
                retracted.add(as_str(event.get("memory_id")))
        for row in read_jsonl(os.path.join(memory_dir, f"{keeper}.memory-journal.jsonl")):
            recorded = as_float(row.get("recorded_at"))
            source = as_dict(row.get("source"))
            if as_str(source.get("kind")) != "explicit_write":
                continue
            if row.get("outcome") != "committed" or recorded < since:
                continue
            per_day[utc_day(recorded)] += 1
            replaced += int(bool(as_list(row.get("dropped"))))
            for added in as_list(as_dict(row.get("change")).get("added")):
                claim = as_str(as_dict(added).get("claim"))
                categories[as_str(as_dict(added).get("category"))] += 1
                memory_id = memory_id_of(claim)
                if memory_id in by_id:
                    mine = as_str(as_dict(by_id[memory_id].get("origin")).get("kind")) == "authored"
                    fate = "still current, origin authored" if mine else "still current, origin other"
                elif memory_id in revised:
                    fate = "rewritten (a revised event)"
                elif memory_id in retracted:
                    fate = "retracted"
                elif memory_id in absorbed:
                    fate = "absorbed into another fact"
                else:
                    fate = "gone from the current set, no revised, retracted or absorbed record"
                written.append((keeper, as_str(source.get("trace_id")), fate))
    print(f"\nfacts that Keepers wrote and the journal committed (explicit_write): {len(written)}")
    print(f"category: {dict(categories)}; commits that also dropped an older fact: {replaced}")
    print("commits per UTC day: " + ", ".join(f"{day} {count}" for day, count in sorted(per_day.items())))
    if not written:
        return
    traces = collections.Counter(trace for _, trace, _ in written)
    largest, largest_count = traces.most_common(1)[0]
    owners = collections.Counter(keeper for keeper, trace, _ in written if trace == largest)
    print(f"largest single run (trace {largest}): {largest_count} facts, written by {dict(owners)}")
    for title, rows in (
        ("all", written),
        ("without the largest run", [row for row in written if row[1] != largest]),
    ):
        fates = collections.Counter(fate for _, _, fate in rows)
        print(f"  {title}: {len(rows)} facts in {len({keeper for keeper, _, _ in rows})} Keepers")
        for label, count in fates.most_common():
            print(f"    {label}: {count} ({100 * count / len(rows):.1f}%)")


def table_source_bound(memory_dir: str, excluded: set[str]) -> None:
    """Claims bound to a source file live in their own store, apart from the facts above."""
    claims = 0
    claim_bytes = 0
    keepers = 0
    for path in sorted(glob.glob(os.path.join(memory_dir, "*.memory-source-current.json"))):
        if keeper_of(path, ".memory-source-current") in excluded:
            continue
        try:
            with open(path, encoding="utf-8") as handle:
                facts = as_list(as_dict(json.load(handle)).get("facts"))
        except (OSError, ValueError):
            continue
        rows = [as_dict(fact) for fact in facts]
        claims += len(rows)
        claim_bytes += sum(len(as_str(row.get("claim")).encode("utf-8")) for row in rows)
        keepers += int(bool(rows))
    print(f"\nsource-bound claims (separate store, not in the facts above): {claims} claims, {claim_bytes / 1000:.0f} KB, in {keepers} Keepers")


def table_admission_queues(memory_dir: str, excluded: set[str]) -> None:
    """Explicit writes wait in a per-Keeper admission queue until the worker admits them."""
    files = 0
    waiting = 0
    for path in sorted(glob.glob(os.path.join(memory_dir, "*.memory-admission.json"))):
        if keeper_of(path, ".memory-admission") in excluded:
            continue
        try:
            with open(path, encoding="utf-8") as handle:
                pending = as_list(as_dict(json.load(handle)).get("pending"))
        except (OSError, ValueError):
            continue
        files += 1
        waiting += int(bool(pending))
    print(f"\nadmission queues: {files} Keepers, {waiting} with a pending write")


def table_librarian_outcomes(memory_dir: str, excluded: set[str], since: float) -> None:
    committed: collections.Counter[str] = collections.Counter()
    failed: collections.Counter[str] = collections.Counter()
    kinds: collections.Counter[str] = collections.Counter()
    for path in sorted(glob.glob(os.path.join(memory_dir, "*.memory-journal.jsonl"))):
        if keeper_of(path, ".memory-journal") in excluded:
            continue
        for row in read_jsonl(path):
            recorded = as_float(row.get("recorded_at"))
            if recorded < since:
                continue
            source = row.get("source")
            if isinstance(source, dict):
                if as_str(source.get("kind")) == "librarian" and row.get("outcome") == "committed":
                    committed[utc_day(recorded)] += 1
            elif as_str(row.get("kind")) in LANE_FAILURE_KINDS:
                failed[utc_day(recorded)] += 1
                kinds[as_str(row.get("kind"))] += 1
    ok, bad = sum(committed.values()), sum(failed.values())
    share = 100 * bad / (ok + bad) if ok + bad else 0.0
    print(f"\nLibrarian commits {ok}, lane failures {bad} ({share:.1f}% of attempts): {dict(kinds)}")
    print("UTC day | commits | failures | failure share")
    for day in sorted(set(committed) | set(failed)):
        attempts = committed[day] + failed[day]
        print(f"{day} | {committed[day]} | {failed[day]} | {100 * failed[day] / attempts:.0f}%")


def table_removals(memory_dir: str, excluded: set[str], since: float) -> None:
    """How facts leave the current set: events, absorptions and journal rows."""
    counts: collections.Counter[str] = collections.Counter()
    for path in sorted(glob.glob(os.path.join(memory_dir, "*.memory-events.jsonl"))):
        if keeper_of(path, ".memory-events") in excluded:
            continue
        for row in read_jsonl(path):
            if as_float(row.get("recorded_at")) >= since and as_str(row.get("kind")) in ("revised", "retracted"):
                counts[f"event {as_str(row.get('kind'))}"] += 1
    for path in sorted(glob.glob(os.path.join(memory_dir, "*.memory-absorbed.jsonl"))):
        if keeper_of(path, ".memory-absorbed") in excluded:
            continue
        counts["absorbed into another fact"] += sum(1 for row in read_jsonl(path) if as_float(row.get("recorded_at")) >= since)
    for path in sorted(glob.glob(os.path.join(memory_dir, "*.memory-journal.jsonl"))):
        if keeper_of(path, ".memory-journal") in excluded:
            continue
        for row in read_jsonl(path):
            if row.get("outcome") != "committed" or as_float(row.get("recorded_at")) < since:
                continue
            change = as_dict(row.get("change"))
            counts["journal change.removed facts"] += len(as_list(change.get("removed")))
            for dropped in as_list(row.get("dropped")):
                reason = as_str(as_dict(dropped).get("reason"))
                counts["journal dropped, superseded_by" if reason.startswith("superseded_by") else "journal dropped, other reason"] += 1
    print("\nhow facts left the current set since the start date (committed journal rows only)")
    for label, count in sorted(counts.items()):
        print(f"  {label}: {count}")


def table_jev_requests(keepers_dir: str, excluded: set[str]) -> None:
    """Memory judgment requests already sent to Jev: size, latency, destination."""
    latency: list[float] = []
    state_kb: list[float] = []
    question_kb: list[float] = []
    bytes_per_token: list[float] = []
    tokens: list[float] = []
    per_keeper: collections.Counter[str] = collections.Counter()
    purposes: collections.Counter[str] = collections.Counter()
    hosts: collections.Counter[str] = collections.Counter()
    failed = 0
    for path in sorted(glob.glob(os.path.join(keepers_dir, "*", "memory-selection-evaluations.jsonl"))):
        keeper = path.split(os.sep)[-2]
        if keeper in excluded:
            continue
        pending: dict[str, tuple[float, int, int]] = {}
        for row in read_jsonl(path):
            request = as_str(row.get("request_id"))
            status = as_str(row.get("status"))
            if status == "started":
                state, questions = as_dict(row.get("state")), row.get("questions")
                size = len(json.dumps(state, ensure_ascii=False).encode("utf-8"))
                asked = len(json.dumps(questions, ensure_ascii=False).encode("utf-8"))
                pending[request] = (as_float(row.get("recorded_at")), size, asked)
                per_keeper[keeper] += 1
                purposes["successor_memory_recall" if state.get("purpose") == "successor_memory_recall" else "other"] += 1
                for destination in as_list(row.get("destinations")):
                    uri = as_str(as_dict(destination).get("destination_uri"))
                    hosts[uri.split("/")[2] if uri.count("/") >= 2 else uri] += 1
            elif status == "provider_failed":
                failed += 1
            elif status == "response_received" and request in pending:
                begun, size, asked = pending.pop(request)
                latency.append(as_float(row.get("recorded_at")) - begun)
                state_kb.append(size / 1000)
                question_kb.append(asked / 1000)
                used = as_dict(as_dict(row.get("response")).get("usage")).get("input_tokens")
                if isinstance(used, int) and used > 0:
                    tokens.append(float(used))
                    bytes_per_token.append((size + asked) / used)
    latency.sort()
    state_kb.sort()
    question_kb.sort()
    tokens.sort()
    bytes_per_token.sort()
    total = sum(per_keeper.values())
    print(f"\nJev memory judgment requests: {total} sent, {len(latency)} answered, {failed} provider_failed")
    print(f"  Keepers with requests: {len(per_keeper)}; destinations {dict(hosts)}; purposes {dict(purposes)}")
    print(f"  requests per Keeper: {dict(per_keeper.most_common())}")
    if latency:
        print(f"  latency s: p50 {quantile(latency, 0.5):.2f}, p90 {quantile(latency, 0.9):.2f}, max {latency[-1]:.2f}")
        print(f"  state KB: p50 {quantile(state_kb, 0.5):.1f}, max {state_kb[-1]:.1f}; question KB: p50 {quantile(question_kb, 0.5):.1f}")
    if tokens:
        print(f"  input tokens: p50 {quantile(tokens, 0.5):.0f}, max {tokens[-1]:.0f}; bytes per input token: p50 {quantile(bytes_per_token, 0.5):.2f}, min {bytes_per_token[0]:.2f}")


def table_lane_latency(path: str, since: float) -> None:
    registered: dict[str, tuple[str, float, float]] = {}
    completed: dict[str, dict[str, object]] = {}
    for row in read_jsonl(path):
        identity = as_str(row.get("id"))
        if row.get("event") == "register":
            registration = as_dict(row.get("registration"))
            size = as_float(as_dict(registration.get("input")).get("bytes"))
            registered[identity] = (as_str(registration.get("lane")), as_float(row.get("started_at")), size)
        elif row.get("event") == "complete":
            completed[identity] = as_dict(row.get("completion"))
    elapsed: dict[str, list[float]] = collections.defaultdict(list)
    sizes: dict[str, list[float]] = collections.defaultdict(list)
    outcomes: dict[str, collections.Counter[str]] = collections.defaultdict(collections.Counter)
    for identity, (lane, started, size) in registered.items():
        if started < since:
            continue
        completion = completed.get(identity)
        outcome = as_str(completion.get("outcome")) if completion else "no_completion"
        outcomes[lane][outcome] += 1
        seconds = completion.get("elapsed_s") if completion else None
        if outcome == "succeeded" and isinstance(seconds, (int, float)):
            elapsed[lane].append(float(seconds))
            sizes[lane].append(size)
    print("\nexact-output lane runs (elapsed time includes any wait for a permit)")
    for lane in sorted(outcomes):
        times, bytes_in = sorted(elapsed[lane]), sorted(sizes[lane])
        spread = (
            f"elapsed s p50 {quantile(times, 0.5):.1f}, p90 {quantile(times, 0.9):.1f}, p99 {quantile(times, 0.99):.1f}; "
            f"input KB p50 {quantile(bytes_in, 0.5) / 1000:.0f}, p90 {quantile(bytes_in, 0.9) / 1000:.0f}; "
            if times
            else "no successful run; "
        )
        print(f"{lane}: {spread}outcomes {dict(outcomes[lane])}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("memory_dir", help="the <base-path>/.masc/config/keepers directory")
    parser.add_argument("--since", help="earliest UTC date to read, YYYY-MM-DD")
    parser.add_argument("--now", help="UTC time the ages are measured at, ISO 8601; default is the current time")
    parser.add_argument("--lane-runs", help="the <base-path>/.masc/exact-lane-runs-v7.jsonl file; adds the lane latency table")
    parser.add_argument("--keepers-dir", help="the <base-path>/.masc/keepers directory; adds the Jev memory request table")
    parser.add_argument("--exclude", action="append", default=[], help="Keeper name to skip; repeatable")
    args = parser.parse_args()
    if not os.path.isdir(args.memory_dir):
        print(f"not a directory: {args.memory_dir}", file=sys.stderr)
        return 2
    since = 0.0
    if args.since:
        since = datetime.datetime.fromisoformat(args.since).replace(tzinfo=datetime.timezone.utc).timestamp()
    now = time.time()
    if args.now:
        now = datetime.datetime.fromisoformat(args.now.replace("Z", "+00:00")).timestamp()
    excluded = set(args.exclude)
    current = load_current(args.memory_dir, excluded)
    table_current_facts(current, now)
    table_source_bound(args.memory_dir, excluded)
    table_admission_queues(args.memory_dir, excluded)
    table_write_fate(args.memory_dir, current, since)
    table_librarian_outcomes(args.memory_dir, excluded, since)
    table_removals(args.memory_dir, excluded, since)
    if args.keepers_dir:
        table_jev_requests(args.keepers_dir, excluded)
    if args.lane_runs:
        table_lane_latency(args.lane_runs, since)
    return 0


if __name__ == "__main__":
    sys.exit(main())
