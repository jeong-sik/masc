#!/usr/bin/env python3
"""Read-only counts behind RFC
librarian-read-waits-and-shrinks-no-further-than-the-refusal-says.

Every subcommand prints aggregates only: keeper names, counts, byte sizes and
durations. Request bodies and conversation text are parsed to measure them and
are never printed. Nothing is written under the workspace.

  collect.py unread    --base WORKSPACE
  collect.py arrivals  --base WORKSPACE --since ISO --until ISO
  collect.py originals --base WORKSPACE
  collect.py attempts  --log SYSTEM_LOG [--from-ts PREFIX] [--to-ts PREFIX]
  collect.py failures  --log SYSTEM_LOG [--log SYSTEM_LOG ...]

WORKSPACE is the directory that holds `.masc`. SYSTEM_LOG is a
`.masc/logs/system_log_YYYY-MM-DD.jsonl` file; its `ts` values are UTC.
"""
from __future__ import annotations

import argparse
import collections
import datetime
import json
import os
import re
import sys
import time

# Declared by addons/keeper-librarian/lane.toml as max_reply_bytes.
FRAME_BYTES = 4_194_304
HISTORY_TOOL = "derive_memory"


def load_json(path: str) -> object | None:
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def as_dict(value: object) -> dict:
    return value if isinstance(value, dict) else {}


def boundary_lines(path: str) -> list[tuple[int, dict | None]]:
    lines: list[tuple[int, dict | None]] = []
    with open(path, encoding="utf-8", errors="replace") as handle:
        for number, raw in enumerate(handle, start=1):
            try:
                record = json.loads(raw)
            except ValueError:
                record = None
            lines.append((number, record if isinstance(record, dict) else None))
    return lines


def keeper_dirs(base: str) -> list[tuple[str, str]]:
    root = os.path.join(base, ".masc", "keepers")
    found = []
    for name in sorted(os.listdir(root)):
        directory = os.path.join(root, name)
        if os.path.isfile(os.path.join(directory, "turn-boundaries.jsonl")):
            found.append((name, directory))
    return found


def is_atom_turn(record: dict) -> bool:
    position = record.get("position")
    return isinstance(position, dict) and position.get("kind") == "atom_history"


def unread(args: argparse.Namespace) -> None:
    """Finished turns beyond each read position.

    An atom turn is unread when its end_atom lies beyond the atom position in
    the current history generation (after the last history_restarted line). A
    turn with any other position kind is unread when its line lies beyond the
    official position. A keeper without a position file counts as zero on that
    side, so the totals are a lower bound. This is not the server's own count.
    """
    now = time.time()
    rows = []
    for name, directory in keeper_dirs(args.base):
        atom = load_json(os.path.join(directory, "librarian-progress.json"))
        official = load_json(os.path.join(directory, "librarian-official-progress.json"))
        lines = boundary_lines(os.path.join(directory, "turn-boundaries.jsonl"))
        restarts = [n for n, r in lines if r and r.get("kind") == "history_restarted"]
        last_restart = max(restarts) if restarts else 0
        end_atom = atom.get("end_atom") if isinstance(atom, dict) else None
        seen = atom.get("boundary_lines_seen") if isinstance(atom, dict) else None
        official_line = official.get("boundary_line") if isinstance(official, dict) else None
        atom_unread = official_unread = 0
        oldest: float | None = None
        for number, record in lines:
            if not record or record.get("kind") != "turn_ended":
                continue
            recorded_at = record.get("recorded_at")
            stamp = float(recorded_at) if isinstance(recorded_at, (int, float)) else now
            if is_atom_turn(record):
                if number <= last_restart or end_atom is None:
                    continue
                # A position written before the last restart names atoms of an
                # older history, so every atom turn after the restart is unread.
                floor = end_atom if (seen is not None and seen >= last_restart) else 0
                if record["position"].get("end_atom", 0) > floor:
                    atom_unread += 1
                    oldest = stamp if oldest is None else min(oldest, stamp)
            elif official_line is not None and number > official_line:
                official_unread += 1
                oldest = stamp if oldest is None else min(oldest, stamp)
        rows.append((name, atom_unread, official_unread, oldest))
    rows.sort(key=lambda row: -(row[1] + row[2]))
    print("%-30s %6s %8s %9s" % ("keeper", "atom", "official", "oldest_h"))
    for name, atom_unread, official_unread, oldest in rows:
        age = "-" if oldest is None else "%.1f" % ((now - oldest) / 3600)
        print("%-30s %6d %8d %9s" % (name, atom_unread, official_unread, age))
    atom_total = sum(row[1] for row in rows)
    official_total = sum(row[2] for row in rows)
    print("total atom=%d official=%d sum=%d at %s" % (
        atom_total, official_total, atom_total + official_total,
        time.strftime("%Y-%m-%d %H:%M %Z", time.localtime(now))))


def arrivals(args: argparse.Namespace) -> None:
    """Turns whose turn_ended line was recorded inside [since, until)."""
    since = datetime.datetime.fromisoformat(args.since).timestamp()
    until = datetime.datetime.fromisoformat(args.until).timestamp()
    rows = []
    for name, directory in keeper_dirs(args.base):
        atom = official = 0
        for _, record in boundary_lines(os.path.join(directory, "turn-boundaries.jsonl")):
            if not record or record.get("kind") != "turn_ended":
                continue
            recorded_at = record.get("recorded_at")
            if not isinstance(recorded_at, (int, float)) or not since <= recorded_at < until:
                continue
            if is_atom_turn(record):
                atom += 1
            else:
                official += 1
        if atom or official:
            rows.append((name, atom, official))
    rows.sort(key=lambda row: -(row[1] + row[2]))
    for name, atom, official in rows:
        print("%-30s atom=%5d official=%5d sum=%5d" % (name, atom, official, atom + official))
    atom_total = sum(row[1] for row in rows)
    official_total = sum(row[2] for row in rows)
    hours = (until - since) / 3600
    print("total atom=%d official=%d sum=%d over %.1fh = %.1f/h" % (
        atom_total, official_total, atom_total + official_total, hours,
        (atom_total + official_total) / hours))


def utf8_len(text: str) -> int:
    return len(text.encode("utf-8"))


def rendered_message_bytes(message: dict) -> int:
    """Approximate bytes one message takes in the rendered Librarian prompt.

    Mirrors lib/keeper/keeper_librarian.ml text_of_content: conversation text is
    kept; tool use, tool results, thinking and media become short placeholders.
    The fixed numbers stand for the role label and those placeholders. They are
    this script's approximation, not values the product uses.
    """
    origin = message.get("origin")
    origin_kind = origin.get("kind") if isinstance(origin, dict) else origin
    size = 40
    if origin_kind not in (None, "conversation", "Conversation"):
        return size + 25
    content = message.get("content")
    if isinstance(content, str):
        return size + utf8_len(content)
    for block in content if isinstance(content, list) else []:
        if not isinstance(block, dict):
            continue
        kind = block.get("kind") or block.get("type")
        if kind == "text":
            size += utf8_len(block.get("text") or "")
        elif kind in ("tool_use", "tool_result"):
            size += 70
        elif kind in ("image", "document", "audio"):
            size += 20
    return size


def originals(args: argparse.Namespace) -> None:
    """Open history originals: estimated Exact request size and admission events.

    The estimate is rendered messages plus the other prompt variables, the
    prompt template and the output schema. It is not the canonical byte count
    the worker measures against its frame.
    """
    addons = os.path.join(args.base, ".masc", "lane-addons")
    owners = os.path.join(addons, "tool-request-owners")
    bodies = os.path.join(addons, "tool-request-bodies")
    body_paths = {}
    for scope in os.listdir(bodies):
        scope_dir = os.path.join(bodies, scope)
        if os.path.isdir(scope_dir):
            for name in os.listdir(scope_dir):
                body_paths[name.split(".")[0]] = os.path.join(scope_dir, name)
    rows = []
    for scope in os.listdir(owners):
        scope_dir = os.path.join(owners, scope)
        if not os.path.isdir(scope_dir):
            continue
        for name in os.listdir(scope_dir):
            record = load_json(os.path.join(scope_dir, name))
            if not isinstance(record, dict) or record.get("tool") != HISTORY_TOOL:
                continue
            summary = as_dict(record.get("summary"))
            keeper = as_dict(summary.get("owner")).get("keeper_id")
            body_path = body_paths.get(record.get("request_digest"))
            if not keeper or body_path is None:
                continue
            body = load_json(body_path)
            if not isinstance(body, dict):
                continue
            source = json.loads(body["source_text"])
            prompt_input = json.loads(source["input_text"])
            messages = prompt_input.get("messages") or []
            conversation = sum(rendered_message_bytes(m) for m in messages if isinstance(m, dict))
            conversation += 9 * max(0, len(messages) - 1)
            variables = sum(
                utf8_len(json.dumps(prompt_input[key], ensure_ascii=False))
                for key in ("current", "working_context", "historical_task_contexts",
                            "counterpart_observations", "goal_context", "keeper_instructions")
                if prompt_input.get(key) is not None)
            tools = 60 * len(prompt_input.get("tool_observations") or [])
            preparation = body["preparation"]
            template = utf8_len(preparation["prompt"]["effective"]) + utf8_len(
                json.dumps(preparation["output_schema"]))
            estimate = conversation + variables + tools + template
            events = collections.Counter(
                event.get("event") for event in record.get("progress") or [] if isinstance(event, dict))
            rows.append((keeper, source.get("extent"), bool(summary.get("predecessor")), estimate,
                         events.get("admission_declined", 0), events.get("waiting", 0)))
    rows.sort(key=lambda row: -row[3])
    print("frame %d" % FRAME_BYTES)
    print("%-28s %-10s %-9s %12s %6s %9s %8s" % (
        "keeper", "extent", "successor", "request_est", "%frame", "declined", "admitted"))
    for keeper, extent, successor, estimate, declined, waiting in rows:
        print("%-28s %-10s %-9s %12d %6.0f %9d %8s" % (
            keeper, extent, "yes" if successor else "no", estimate,
            100.0 * estimate / FRAME_BYTES, declined, "yes" if waiting else "no"))
    total = sum(row[3] for row in rows)
    print("records=%d sum=%d B = %.1f frames" % (len(rows), total, total / FRAME_BYTES))


ATTEMPT = re.compile(
    r"Lane Add-on exact attempt ended installation=(\S+) output=(\S+) result=(\S+) "
    r"elapsed_ms=(\d+) running_at_start=(\d+)")


def log_records(paths: list[str], needle: str):
    for path in paths:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for raw in handle:
                if needle not in raw:
                    continue
                try:
                    record = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(record, dict):
                    yield record


def attempts(args: argparse.Namespace) -> None:
    """Host cycle Exact attempts by installation, output and result."""
    by_kind: dict[tuple[str, str, str], list[int]] = collections.defaultdict(list)
    running = collections.Counter()
    first = last = None
    for record in log_records([args.log], "exact attempt ended"):
        stamp = str(record.get("ts", ""))
        if (args.from_ts and stamp < args.from_ts) or (args.to_ts and stamp >= args.to_ts):
            continue
        match = ATTEMPT.search(str(record.get("message", "")))
        if not match:
            continue
        installation, output, result = match.group(1), match.group(2), match.group(3)
        by_kind[(installation, output, result)].append(int(match.group(4)))
        running[(installation, int(match.group(5)))] += 1
        first = first or stamp
        last = stamp
    print("window %s .. %s" % (first, last))
    for (installation, output, result), values in sorted(by_kind.items(), key=lambda kv: -len(kv[1])):
        ordered = sorted(values)
        print("%-20s %-10s %-18s n=%5d p50=%7.1fs p90=%7.1fs max=%7.1fs" % (
            installation, output, result, len(ordered), ordered[len(ordered) // 2] / 1000,
            ordered[int(len(ordered) * 0.9)] / 1000, ordered[-1] / 1000))
    print("running_at_start:", sorted(running.items()))


def failures(args: argparse.Namespace) -> None:
    """Durable round failure reports, split by what the log line names.

    The server logs a repeated problem once per change of text, so these are
    counts of reports and a lower bound on occurrences. Splitting log text is
    for this measurement only.
    """
    blocked = collections.Counter()
    refused = collections.Counter()
    for record in log_records(args.log, "durable Librarian"):
        message = str(record.get("message", ""))
        if "durable Librarian range not consumed: " in message:
            detail = message.split("not consumed: ", 1)[1]
            blocked[re.sub(r"\d+", "N", detail)[:80]] += 1
        elif "durable Librarian pass not committed" in message:
            named = re.search(r"provider_input_refusals=\[([a-z_,]*)\]", message)
            refused[named.group(1) if named else "?"] += 1
    print("range not consumed (reports):")
    for detail, count in blocked.most_common():
        print("  %5d %s" % (count, detail))
    print("pass not committed (reports), by provider_input_refusals:")
    for named, count in refused.most_common():
        print("  %5d [%s]" % (count, named))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    for name, handler in (("unread", unread), ("originals", originals)):
        sub = commands.add_parser(name)
        sub.add_argument("--base", required=True)
        sub.set_defaults(handler=handler)
    sub = commands.add_parser("arrivals")
    sub.add_argument("--base", required=True)
    sub.add_argument("--since", required=True, help="ISO 8601 with offset")
    sub.add_argument("--until", required=True, help="ISO 8601 with offset")
    sub.set_defaults(handler=arrivals)
    sub = commands.add_parser("attempts")
    sub.add_argument("--log", required=True)
    sub.add_argument("--from-ts", default=None, help="inclusive UTC ts prefix, e.g. 2026-11-16T00")
    sub.add_argument("--to-ts", default=None, help="exclusive UTC ts prefix")
    sub.set_defaults(handler=attempts)
    sub = commands.add_parser("failures")
    sub.add_argument("--log", required=True, action="append")
    sub.set_defaults(handler=failures)
    args = parser.parse_args()
    args.handler(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
