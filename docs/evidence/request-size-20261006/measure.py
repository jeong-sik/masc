"""Request-size measurements for the RFC "a Keeper request carries the whole
history". Reads a live masc base path read-only and prints numbers only (no
message content).

usage:
  python3 -I measure.py turns     <masc-dir> <YYYY-MM-DD>
  python3 -I measure.py restarts  <masc-dir> <YYYY-MM-DD>
  python3 -I measure.py unfinished <masc-dir> <YYYY-MM-DD> [<HH:MM>]
  python3 -I measure.py span      <masc-dir> <keeper> <YYYY-MM-DDTHH:MM> <YYYY-MM-DDTHH:MM>
  python3 -I measure.py writes    <trace.json> <start-atom> <end-atom>
  python3 -I measure.py carried   <masc-dir> <YYYY-MM-DD> <keeper> <HH:MM> <HH:MM>
  python3 -I measure.py session   <muse-session.jsonl>
  python3 -I measure.py fresh     <muse-session.jsonl> <seed-tokens>[,<seed-tokens>...]

<masc-dir> is the runtime directory (e.g. ~/me/.masc).
"""
import collections
import datetime
import json
import pathlib
import re
import sys

TURN_LINE = re.compile(r"turn=(\d+) total_turns=(\d+) runtime_lane=\S+ tokens=(\d+)")
CARRIED_LINE = re.compile(
    r"model input carried range runtime=(\S+) origin=\S+ first_atom=(\d+) atoms=(\d+)/(\d+) transmitted_bytes=(\d+)"
)
POLICY_LINE = re.compile(r"input policy runtime=\S+ selected=\S+ context_owner=agent_core turn_boundary=boundary:(\d+)")
KEEPER_BOOT = re.compile(r"autoboot: calling start_keepalive for (\S+)")


def log_rows(masc_dir, day):
    path = pathlib.Path(masc_dir) / "logs" / f"system_log_{day}.jsonl"
    with open(path, errors="replace") as handle:
        for line in handle:
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def when(stamp):
    return datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))


def percentile(sorted_values, fraction):
    return sorted_values[min(len(sorted_values) - 1, int(len(sorted_values) * fraction))]


def turns(masc_dir, day):
    """Model calls per Keeper turn, from the per-call `turn=N total_turns=M`
    lines. An official-client turn logs one line with its turn total.

    A turn cut off by a server restart never advances `total_turns`, so the
    turns after it log the same number. A keeper's boot line splits them:
    calls before and after a boot are different turns."""
    table = collections.OrderedDict()
    boots = collections.Counter()
    for row in log_rows(masc_dir, day):
        message = row.get("message", "")
        boot = KEEPER_BOOT.search(message)
        if boot:
            boots[boot.group(1)] += 1
            continue
        match = TURN_LINE.search(message)
        if not match:
            continue
        keeper = row.get("keeper_name") or "?"
        key = (keeper, f"{match.group(2)}#{boots[keeper]}")
        entry = table.setdefault(key, {"first": row["ts"], "last": row["ts"], "calls": 0, "last_tokens": 0})
        entry["last"] = row["ts"]
        entry["calls"] += 1
        entry["last_tokens"] = int(match.group(3))
    calls = sorted(entry["calls"] for entry in table.values())
    longest = sorted(table.items(), key=lambda item: -item[1]["calls"])[:12]
    print(json.dumps({
        "turns": len(calls),
        "calls_per_turn": {
            "p50": percentile(calls, 0.5), "p90": percentile(calls, 0.9),
            "p99": percentile(calls, 0.99), "max": calls[-1],
        },
        "turns_with_at_least_50_calls": sum(1 for value in calls if value >= 50),
        "turns_with_at_least_100_calls": sum(1 for value in calls if value >= 100),
        "longest": [
            {"keeper": keeper, "turn": turn, "calls": entry["calls"],
             "minutes": round((when(entry["last"]) - when(entry["first"])).total_seconds() / 60),
             "last_call_tokens": entry["last_tokens"]}
            for (keeper, turn), entry in longest
        ],
    }, indent=1))


def restarts(masc_dir, day):
    """The first Agent-Core request each keeper composed after a boot: the
    turn boundary it used, against the newest atom of the history it loaded.
    The newest atom is the new turn's own start prompt, so every atom from
    the boundary up to it was saved by turns that did not finish."""
    booted = set()
    pending = {}
    rows = []
    for row in log_rows(masc_dir, day):
        message = row.get("message", "")
        keeper = row.get("keeper_name")
        boot = KEEPER_BOOT.search(message)
        if boot:
            booted.add(boot.group(1))
            continue
        if keeper not in booted:
            continue
        policy = POLICY_LINE.search(message)
        if policy:
            pending[keeper] = int(policy.group(1))
            continue
        match = CARRIED_LINE.search(message)
        if match and keeper in pending:
            boundary = pending.pop(keeper)
            booted.discard(keeper)
            _, first, atoms, total, sent = match.groups()
            newest = int(total) - 1
            rows.append({"ts": row["ts"][11:19], "keeper": keeper, "boundary": boundary,
                         "newest_atom": newest, "unfinished_atoms": max(0, newest - boundary),
                         "first_atom": int(first), "transmitted_bytes": int(sent)})
    inherited = [entry for entry in rows if entry["unfinished_atoms"] > 0]
    print(json.dumps({
        "first_requests_after_boot": len(rows),
        "with_unfinished_atoms": len(inherited),
        "rows": sorted(inherited, key=lambda entry: -entry["unfinished_atoms"]),
    }, indent=1))


def unfinished(masc_dir, day, until=None):
    """Atoms saved by turns that did not finish, from each keeper's
    turn-boundaries.jsonl. A finished turn's line states where it started;
    when that start is past the end the previous line stated, the atoms
    between were saved by turns that failed or were cancelled and picked up
    by the turns after them. `from` and `until` are the two lines' times: the
    span lay past the last completed boundary between them.

    A previous line with no atom position (an official-client turn) states no
    end. The atoms past its start may belong to that completed turn's own
    Agent-Core candidate, whose end only a later line reveals, so such gaps are
    counted apart as `after_official_client_line` and left out of `spans` and
    `atoms`. Counts the lines recorded on <day> (UTC), up to <until> (HH:MM,
    UTC) when given."""
    spans = []
    after_official_client = []
    for path in sorted((pathlib.Path(masc_dir) / "keepers").glob("*/turn-boundaries.jsonl")):
        previous = None
        with open(path, errors="replace") as handle:
            for line in handle:
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    previous = None
                    continue
                if record.get("kind") != "turn_ended":
                    previous = None
                    continue
                start = record.get("history_at_start")
                position = record.get("position")
                turn = int(record["turn_ref"].rsplit("#", 1)[1])
                stamp = datetime.datetime.fromtimestamp(record["recorded_at"], datetime.timezone.utc)
                start_atom = start.get("start_atom") if isinstance(start, dict) else None
                in_window = stamp.date().isoformat() == day and (until is None or stamp.strftime("%H:%M") <= until)
                if previous and start_atom is not None and in_window:
                    gap_atoms = start_atom - previous["end_atom"]
                    if gap_atoms > 0:
                        entry = {"keeper": path.parent.name, "atoms": gap_atoms,
                                 "turns_without_line": turn - previous["turn"] - 1,
                                 "from": previous["at"], "until": stamp.strftime("%m-%d %H:%M")}
                        (after_official_client if previous["official_client"] else spans).append(entry)
                # The line's end atom. A line with no atom position (an
                # official client) states none; its start stands in as the
                # lower bound and the next gap is classed apart.
                end_atom = position.get("end_atom") if isinstance(position, dict) else None
                witnessed = end_atom if end_atom is not None else start_atom
                previous = ({"end_atom": witnessed, "turn": turn, "at": stamp.strftime("%m-%d %H:%M"),
                             "official_client": end_atom is None}
                            if witnessed is not None else None)
    spans.sort(key=lambda span: -span["atoms"])
    print(json.dumps({
        "spans": len(spans),
        "keepers": len({span["keeper"] for span in spans}),
        "atoms": sum(span["atoms"] for span in spans),
        "turns_without_line": sum(span["turns_without_line"] for span in spans),
        "after_official_client_line": {"spans": len(after_official_client),
                                       "atoms": sum(span["atoms"] for span in after_official_client)},
        "largest": spans[:10],
    }, indent=1))


def span(masc_dir, keeper, start, end):
    """One keeper's model calls between two UTC instants, grouped by the
    `total_turns` value each call logged and the keeper's boot count since
    the window opened (`<total_turns>#<boots>`), with the tools it called.
    A boot that cuts a turn leaves `total_turns` unchanged, so the turns on
    either side of it log the same number and only the boot line splits them."""
    turns_seen = collections.OrderedDict()
    boots = 0
    tools = collections.Counter()
    day = datetime.date.fromisoformat(start[:10])
    while day.isoformat() <= end[:10]:
        for row in log_rows(masc_dir, day.isoformat()):
            stamp = row["ts"][:16]
            if not (start <= stamp <= end):
                continue
            message = row.get("message", "")
            boot = KEEPER_BOOT.search(message)
            if boot:
                if boot.group(1) == keeper:
                    boots += 1
                continue
            if message.startswith(f"keeper:{keeper} tool_call tool="):
                tools[message.split("tool=", 1)[1].split()[0]] += 1
                continue
            if row.get("keeper_name") != keeper:
                continue
            match = TURN_LINE.search(message)
            if match:
                entry = turns_seen.setdefault(f"{match.group(2)}#{boots}", {"first": row["ts"][:19], "first_call_tokens": int(match.group(3)),
                                                               "calls": 0, "tokens": 0, "max_tokens": 0})
                entry["last"] = row["ts"][:19]
                entry["calls"] += 1
                entry["tokens"] += int(match.group(3))
                entry["max_tokens"] = max(entry["max_tokens"], int(match.group(3)))
        day += datetime.timedelta(days=1)
    print(json.dumps({"keeper": keeper, "from": start, "until": end,
                      "calls": sum(entry["calls"] for entry in turns_seen.values()),
                      "tokens": sum(entry["tokens"] for entry in turns_seen.values()),
                      "by_total_turns_and_boot": turns_seen, "tools": tools.most_common(8)}, indent=1))


def writes(trace_path, start, end):
    """Tool calls in atoms [start, end) of a checkpoint trace: how many of each
    tool, how many distinct keeper_memory_write titles, and what the writes
    answered (identity_disposition). Counts only."""
    with open(trace_path) as handle:
        messages = json.load(handle)["messages"]
    atom = -1
    calls = collections.Counter()
    titles = set()
    dispositions = collections.Counter()
    for message in messages:
        if message.get("role") in ("user", "assistant"):
            atom += 1
        if not (start <= atom < end) or not isinstance(message.get("content"), list):
            continue
        for block in message["content"]:
            if block.get("type") == "tool_use":
                calls[block.get("name")] += 1
                if block.get("name") == "keeper_memory_write":
                    titles.add((block.get("input") or {}).get("title", ""))
            elif block.get("type") == "tool_result" and isinstance(block.get("content"), str):
                try:
                    answer = json.loads(block["content"])
                except json.JSONDecodeError:
                    continue
                if isinstance(answer, dict) and "identity_disposition" in answer:
                    dispositions[answer["identity_disposition"]] += 1
    print(json.dumps({"atoms": [start, end], "tool_calls": calls.most_common(6),
                      "memory_write_distinct_titles": len(titles),
                      "memory_write_dispositions": dispositions.most_common()}, indent=1))


def carried(masc_dir, day, keeper, start, end):
    """Where each request's carried range opened, against the turn it ran in."""
    for row in log_rows(masc_dir, day):
        if row.get("keeper_name") != keeper or not (start <= row["ts"][11:16] <= end):
            continue
        message = row.get("message", "")
        match = CARRIED_LINE.search(message)
        if match:
            runtime, first, atoms, total, sent = match.groups()
            print(row["ts"][11:19], "carried", runtime.split(".")[0], "first_atom", first,
                  "atoms", f"{atoms}/{total}", "bytes", sent)
        elif "memory os librarian committed" in message or "memory os librarian kept" in message:
            print(row["ts"][11:19], "librarian", message.split(":")[0][:60])
        else:
            turn = TURN_LINE.search(message)
            if turn:
                print(row["ts"][11:19], "turn", turn.group(2))


def session_runs(path):
    runs = collections.OrderedDict()
    largest = None
    observers = 0
    with open(path) as handle:
        for line in handle:
            if not line.startswith('{"schema'):
                continue
            record = json.loads(line)
            if record.get("payload_type") != "runtime.session":
                continue
            payload = record["payload"]
            if payload.get("kind") != "run":
                continue
            event = payload.get("event") or {}
            kind = event.get("kind")
            run = runs.setdefault(payload["run_id"], [])
            if kind == "model_completed":
                usage = event["usage"]
                run.append((usage["input_tokens"], usage.get("cached_tokens", 0), usage["output_tokens"]))
            elif kind == "memory_reminder_child_session_linked":
                observers += 1
            elif kind == "model_input_trace_recorded":
                bounded = event.get("bounded", {})
                if largest is None or bounded.get("total_lane_bytes", 0) > largest.get("total_lane_bytes", 0):
                    largest = bounded
    return [calls for calls in runs.values() if calls], largest, observers


def session(path):
    """Calls per run, input per call, and what the largest request held."""
    runs, largest, observers = session_runs(path)
    calls = [call for run in runs for call in run]
    total_input = sum(call[0] for call in calls)
    print(json.dumps({
        "runs": len(runs),
        "model_calls": len(calls),
        "input_tokens": total_input,
        "cached_share": round(sum(call[1] for call in calls) / max(total_input, 1), 3),
        "input_per_call_mean": round(total_input / max(len(calls), 1)),
        "input_per_call_max": max(call[0] for call in calls),
        "observer_child_sessions": observers,
        "largest_request_bytes": largest.get("total_lane_bytes") if largest else None,
        "largest_request_by_lane": [
            {"lane": group["logical_lane"]["value"], "source": group["source"]["value"],
             "role": group["provider_wire_destination"]["value"], "parts": group["lane_count"],
             "bytes": group["byte_count"]}
            for group in (largest or {}).get("aggregates", []) if group["byte_count"]
        ],
    }, indent=1))


def fresh(path, seeds):
    """What the same calls would have carried if each run started a fresh host
    session from a seed of `seed` tokens instead of resuming: call k of a run
    carries seed + (input_k - input_0), the run's own growth. Cache is not
    modelled; the first call of each run is the seed sent anew."""
    runs, _, _ = session_runs(path)
    actual = sum(call[0] for run in runs for call in run)
    actual_uncached = sum(call[0] - call[1] for run in runs for call in run)
    result = {"runs": len(runs), "actual_input_tokens": actual, "actual_uncached_tokens": actual_uncached, "fresh": []}
    for seed in seeds:
        total = 0
        for run in runs:
            base = run[0][0]
            total += sum(seed + max(0, call[0] - base) for call in run)
        result["fresh"].append({"seed_tokens": seed, "input_tokens": total,
                                "ratio_to_actual": round(total / max(actual, 1), 3),
                                "seeds_sent_uncached": seed * len(runs)})
    print(json.dumps(result, indent=1))


def main(argv):
    command = argv[1]
    if command == "turns":
        turns(argv[2], argv[3])
    elif command == "restarts":
        restarts(argv[2], argv[3])
    elif command == "unfinished":
        unfinished(argv[2], argv[3], argv[4] if len(argv) > 4 else None)
    elif command == "span":
        span(argv[2], argv[3], argv[4], argv[5])
    elif command == "writes":
        writes(argv[2], int(argv[3]), int(argv[4]))
    elif command == "carried":
        carried(argv[2], argv[3], argv[4], argv[5], argv[6])
    elif command == "session":
        session(argv[2])
    elif command == "fresh":
        fresh(argv[2], [int(value) for value in argv[3].split(",")])
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
