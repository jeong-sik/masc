#!/usr/bin/env python3
"""Measure the `_blob` argument shape Keepers send and the history that shows it to them.

Reads three stores under `<base-path>/.masc`, never writes to them:

- `tool_calls/YYYY-MM/DD[.NNN].jsonl`: the tool-call ledger. `input` is the
  argument object the tool layer received.
- `keepers/<keeper>/provider-inputs/YYYY-MM/DD.jsonl`: one capture per turn of a
  request the turn sent. Each message lists a `content_ref`, the blob that holds
  the provider-bound message JSON. `wire.model` names the model. Other requests of
  the same turn are not captured.
- `tool_blobs/<sha[:2]>/<sha>`: the stored message JSON, and the stored original
  arguments of a demoted call.

Definitions:

- blob call: a ledger row in the window (`--from-date` midnight UTC to `--until`)
  with `record_kind == "tool_call"` whose `input` is an object with a `_blob` key.
  `alone` means `_blob` is its only key, `mixed` means other keys come with it.
- outcome: `refused_before_run` when the row has no `disposition` and
  `wire_outcome` is `error`, `completed` when `disposition` is `completed`,
  `other` for the rest.
- envelope: an object with exactly `bytes` (non-negative int), `mime` (text without
  whitespace), `preview` (text) and `sha256` (64 lowercase hex). The OCaml reader
  `Tool_output.normalized_artifact_ref_of_json` accepts the same shape. A blob
  call is `complete_envelope` when its `_blob` value is an envelope,
  `wrapped_arguments` when it is some other object, `not_an_object` otherwise.
- stored hash: the file `tool_blobs/<sha[:2]>/<sha>` of an envelope's `sha256`
  exists. Blobs `Keeper_model_input_demotion` writes always exist.
- demoted argument: an assistant `tool_use` block of a captured message whose
  `input` is an object with only a `_blob` key that holds an envelope. Saved bytes
  are the envelope's `bytes` minus the size of that object as compact JSON.
- demoted result: a `tool_result` block of a captured message whose `content` starts
  with `[masc:blob`. Saved bytes are the marker's `bytes=` value minus its length.
- stored and same size: a hash whose blob exists with exactly the envelope's `bytes`.
- stored demotion: a demoted argument that is stored and same size. A request shows
  one when at least one of its demoted arguments is. A refused `_blob` call the model
  made up shows up in later requests as a lone envelope too, but its hash has no such
  blob, so it is a demoted argument and not a stored demotion.
- turn: the calls of one Keeper in (previous stored request, this stored request]
  belong to the turn this request closes. The interval covers more than one turn when
  a turn left no stored request.
- model of a call: the model both neighbouring stored requests of the Keeper share.
  A call with a stored request missing on one side, or two different models, is
  reported apart as unattributed.

`--split <time>` adds the same model summary for what came before and what came at or
after that time, for example a deploy.

Usage:
    docs/evidence/blob-input-2026-11/measure_blob_inputs.py --base-path ~/me \
        --from-date 2026-10-19 --to-date 2026-11-04 --until 2026-11-04T19:10:00Z
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import statistics
import sys
from bisect import bisect_left, bisect_right
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "scripts" / "lib"))

import masc_base_path  # noqa: E402
from tool_call_log_paths import tool_call_log_paths  # noqa: E402

BLOB_KEY = "_blob"
BLOB_KEY_BYTES = BLOB_KEY.encode("ascii")
ENVELOPE_KEYS = frozenset({"bytes", "mime", "preview", "sha256"})
SHA256_HEX = re.compile(r"[0-9a-f]{64}")
BLOB_REF_SHA = re.compile(r"sha256=([0-9a-f]{64})")
MARKER_BYTES = re.compile(r"bytes=(\d+)")
MARKER_PREFIX = "[masc:blob"
BLOB_DIR_PREFIX_CHARS = 2
TOOL_CALL_RECORD_KIND = "tool_call"
TOOL_USE = "tool_use"
TOOL_RESULT = "tool_result"
UNKNOWN = "?"
PER_HUNDRED = 100
TOP_KEEPERS = 8
TOP_TOOLS = 8
TOP_HISTORY_ROWS = 10

ALONE = "alone"
MIXED = "mixed"
COMPLETE_ENVELOPE = "complete_envelope"
WRAPPED_ARGUMENTS = "wrapped_arguments"
NOT_AN_OBJECT = "not_an_object"
REFUSED_BEFORE_RUN = "refused_before_run"
COMPLETED = "completed"
OTHER = "other"
STORED_DEMOTION = "stored_demotion"
NO_STORED_DEMOTION = "no_stored_demotion"
NO_NEIGHBOUR = "unattributed: no stored request on one side"
NEIGHBOURS_DIFFER = "unattributed: the stored requests on both sides use different models"


@dataclass(frozen=True, slots=True)
class BlobCall:
    day: str
    keeper: str
    tool: str
    form: str
    shape: str
    outcome: str
    sha256: str | None
    stamp: float = 0.0


@dataclass(frozen=True, slots=True)
class MessageDemotion:
    arguments: tuple[tuple[str, int, int], ...]
    results: int
    result_saved: int


@dataclass(frozen=True, slots=True)
class HistoryRequest:
    keeper: str
    model: str
    body_bytes: int
    arguments: int
    argument_saved: int
    results: int
    result_saved: int
    unreadable: int
    captured_at: float = 0.0
    stored_arguments: int = 0


@dataclass(frozen=True, slots=True)
class AttributedCall:
    keeper: str
    label: str
    stamp: float


def iso_utc(stamp: float) -> str:
    return datetime.fromtimestamp(stamp, timezone.utc).isoformat()


def number_of(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def envelope_of(value: object) -> dict[str, object] | None:
    if not isinstance(value, dict) or value.keys() != ENVELOPE_KEYS:
        return None
    size, mime, preview, sha = value["bytes"], value["mime"], value["preview"], value["sha256"]
    if isinstance(size, bool) or not isinstance(size, int) or size < 0:
        return None
    if not isinstance(mime, str) or not mime or any(char.isspace() for char in mime):
        return None
    if not isinstance(preview, str):
        return None
    if not isinstance(sha, str) or SHA256_HEX.fullmatch(sha) is None:
        return None
    return value


def classify_input(tool_input: object) -> tuple[str, str, str | None] | None:
    """(form, shape, envelope sha256) of an input that has a `_blob` key, else None."""
    if not isinstance(tool_input, dict) or BLOB_KEY not in tool_input:
        return None
    form = ALONE if len(tool_input) == 1 else MIXED
    inner = tool_input[BLOB_KEY]
    envelope = envelope_of(inner)
    if envelope is not None:
        return form, COMPLETE_ENVELOPE, str(envelope["sha256"])
    if isinstance(inner, dict):
        return form, WRAPPED_ARGUMENTS, None
    return form, NOT_AN_OBJECT, None


def lone_envelope(tool_input: object) -> dict[str, object] | None:
    """The envelope of an input that is exactly `{"_blob": <envelope>}`."""
    if isinstance(tool_input, dict) and tool_input.keys() == {BLOB_KEY}:
        return envelope_of(tool_input[BLOB_KEY])
    return None


def outcome_of(row: dict[str, object]) -> str:
    disposition = row.get("disposition")
    if disposition is None and row.get("wire_outcome") == "error":
        return REFUSED_BEFORE_RUN
    if disposition == "completed":
        return COMPLETED
    return OTHER


def read_blob_calls(base: pathlib.Path, first: date, last: date, since: float, until: float) -> list[BlobCall]:
    calls: list[BlobCall] = []
    day = first
    while day <= last:
        live = base / ".masc" / "tool_calls" / f"{day.year:04d}-{day.month:02d}" / f"{day.day:02d}.jsonl"
        day += timedelta(days=1)
        for path in tool_call_log_paths(base, live):
            with path.open("rb") as handle:
                for line in handle:
                    if BLOB_KEY_BYTES not in line:
                        continue
                    try:
                        row = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(row, dict) or row.get("record_kind") != TOOL_CALL_RECORD_KIND:
                        continue
                    stamp = number_of(row.get("ts"))
                    classified = classify_input(row.get("input"))
                    if stamp is None or not since <= stamp <= until or classified is None:
                        continue
                    keeper, tool = row.get("keeper"), row.get("tool")
                    calls.append(
                        BlobCall(
                            datetime.fromtimestamp(stamp, timezone.utc).strftime("%Y-%m-%d"),
                            keeper if isinstance(keeper, str) else UNKNOWN,
                            tool if isinstance(tool, str) else UNKNOWN,
                            *classified[:2],
                            outcome_of(row),
                            classified[2],
                            stamp,
                        )
                    )
    return calls


def blob_path(base: pathlib.Path, sha: str) -> pathlib.Path:
    return base / ".masc" / "tool_blobs" / sha[:BLOB_DIR_PREFIX_CHARS] / sha


def stored_with_size(base: pathlib.Path, sha: str, size: int) -> bool:
    """The blob store holds [sha] with exactly [size] bytes, which is how `Keeper_model_input_demotion` writes it."""
    try:
        return blob_path(base, sha).stat().st_size == size
    except OSError:
        return False


def compact_json_bytes(value: object) -> int:
    return len(json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


def demotion_of_message(message: dict[str, object]) -> MessageDemotion:
    arguments: list[tuple[str, int, int]] = []
    results = result_saved = 0
    blocks = message.get("content_blocks")
    for block in blocks if isinstance(blocks, list) else []:
        if not isinstance(block, dict):
            continue
        if block.get("type") == TOOL_USE:
            value = block.get("input")
            envelope = lone_envelope(value)
            if envelope is not None:
                arguments.append((str(envelope["sha256"]), int(str(envelope["bytes"])), compact_json_bytes(value)))
        elif block.get("type") == TOOL_RESULT:
            content = block.get("content")
            marker = MARKER_BYTES.search(content) if isinstance(content, str) and content.startswith(MARKER_PREFIX) else None
            if marker is not None and isinstance(content, str):
                results += 1
                result_saved += int(marker.group(1)) - len(content)
    return MessageDemotion(tuple(arguments), results, result_saved)


def message_blob(base: pathlib.Path, content_ref: object) -> dict[str, object] | None:
    match = BLOB_REF_SHA.search(content_ref) if isinstance(content_ref, str) else None
    if match is None:
        return None
    try:
        parsed = json.loads(blob_path(base, match.group(1)).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, ValueError):
        return None
    return parsed if isinstance(parsed, dict) else None


def read_history_requests(
    base: pathlib.Path, first: date, last: date, since: float, until: float
) -> tuple[list[HistoryRequest], dict[str, int]]:
    """Captured requests in the window and the distinct demoted-argument hashes with their original bytes."""
    requests: list[HistoryRequest] = []
    envelopes: dict[str, int] = {}
    cache: dict[str, MessageDemotion | None] = {}
    keepers = base / ".masc" / "keepers"
    if not keepers.is_dir():
        return requests, envelopes
    for keeper_dir in sorted(keepers.iterdir()):
        day = first
        while day <= last:
            path = keeper_dir / "provider-inputs" / f"{day.year:04d}-{day.month:02d}" / f"{day.day:02d}.jsonl"
            day += timedelta(days=1)
            if not path.is_file():
                continue
            with path.open("rb") as handle:
                for line in handle:
                    try:
                        row = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(row, dict):
                        continue
                    wire = row.get("wire")
                    captured = number_of(row.get("captured_at"))
                    body = number_of(wire.get("body_bytes")) if isinstance(wire, dict) else None
                    if captured is None or body is None or not since <= captured <= until:
                        continue
                    arguments = argument_saved = stored_arguments = results = result_saved = unreadable = 0
                    messages = row.get("messages")
                    for message in messages if isinstance(messages, list) else []:
                        artifact = message.get("artifact") if isinstance(message, dict) else None
                        content_ref = artifact.get("content_ref") if isinstance(artifact, dict) else None
                        key = content_ref if isinstance(content_ref, str) else ""
                        if key not in cache:
                            parsed = message_blob(base, content_ref)
                            cache[key] = None if parsed is None else demotion_of_message(parsed)
                        demotion = cache[key]
                        if demotion is None:
                            unreadable += 1
                            continue
                        for sha, original, envelope_bytes in demotion.arguments:
                            envelopes[sha] = original
                            arguments += 1
                            argument_saved += original - envelope_bytes
                            stored_arguments += 1 if stored_with_size(base, sha, original) else 0
                        results += demotion.results
                        result_saved += demotion.result_saved
                    model = wire.get("model") if isinstance(wire, dict) else None
                    requests.append(
                        HistoryRequest(
                            keeper_dir.name,
                            model if isinstance(model, str) else UNKNOWN,
                            int(body),
                            arguments,
                            argument_saved,
                            results,
                            result_saved,
                            unreadable,
                            captured,
                            stored_arguments,
                        )
                    )
    return requests, envelopes


def percent(part: int, whole: int) -> float | None:
    return round(PER_HUNDRED * part / whole, 1) if whole else None


def median_int(values: list[int]) -> int:
    return int(statistics.median(values)) if values else 0


def summarize_blob_calls(calls: list[BlobCall], stored: dict[str, bool]) -> dict[str, object]:
    alone = [call for call in calls if call.form == ALONE]
    envelopes = [call for call in alone if call.shape == COMPLETE_ENVELOPE and call.sha256 is not None]
    by_day: dict[str, Counter[str]] = defaultdict(Counter)
    for call in calls:
        by_day[call.day][call.form] += 1
    keepers: dict[str, Counter[str]] = defaultdict(Counter)
    tools: Counter[str] = Counter()
    for call in alone:
        keepers[call.keeper][call.outcome] += 1
        tools[call.tool] += 1
    ranked_keepers = sorted(keepers.items(), key=lambda item: (-sum(item[1].values()), item[0]))[:TOP_KEEPERS]
    in_store = sum(1 for call in envelopes if stored.get(str(call.sha256), False))
    return {
        "calls": len(calls),
        "alone": len(alone),
        "mixed": len(calls) - len(alone),
        "outcome_alone": dict(sorted(Counter(call.outcome for call in alone).items())),
        "outcome_mixed": dict(sorted(Counter(call.outcome for call in calls if call.form == MIXED).items())),
        "shape_alone": dict(sorted(Counter(call.shape for call in alone).items())),
        "complete_envelope_alone": {
            "calls": len(envelopes),
            "hash_in_store": in_store,
            "hash_not_in_store": len(envelopes) - in_store,
        },
        "by_day": {day: dict(sorted(counts.items())) for day, counts in sorted(by_day.items())},
        "top_keepers_alone": [
            {"keeper": keeper, "calls": sum(counts.values()), "outcome": dict(sorted(counts.items()))}
            for keeper, counts in ranked_keepers
        ],
        "alone_by_keeper": {keeper: sum(counts.values()) for keeper, counts in sorted(keepers.items())},
        "top_tools_alone": [{"tool": tool, "calls": count} for tool, count in sorted(tools.items(), key=lambda item: (-item[1], item[0]))[:TOP_TOOLS]],
    }


def summarize_history(
    requests: list[HistoryRequest], envelopes: dict[str, int], base: pathlib.Path
) -> dict[str, object]:
    grouped: dict[tuple[str, str], list[HistoryRequest]] = defaultdict(list)
    for request in requests:
        grouped[request.keeper, request.model].append(request)
    ranked = sorted(
        ((key, items, [item for item in items if item.arguments > 0]) for key, items in grouped.items()),
        key=lambda entry: (-len(entry[2]), entry[0]),
    )
    rows = []
    for (keeper, model), items, carrying in ranked:
        if not carrying:
            continue
        with_results = [item for item in items if item.results > 0]
        shares = [PER_HUNDRED * item.argument_saved / item.body_bytes for item in carrying if item.body_bytes]
        rows.append(
            {
                "keeper": keeper,
                "model": model,
                "requests": len(items),
                "with_demoted_arguments": len(carrying),
                "with_demoted_arguments_percent": percent(len(carrying), len(items)),
                "with_demoted_results_percent": percent(len(with_results), len(items)),
                "body_bytes_median": median_int([item.body_bytes for item in items]),
                "demoted_arguments_median": median_int([item.arguments for item in carrying]),
                "argument_saved_bytes_median": median_int([item.argument_saved for item in carrying]),
                "argument_saved_percent_of_body_median": round(statistics.median(shares), 1) if shares else None,
                "result_saved_bytes_median": median_int([item.result_saved for item in with_results]),
            }
        )
    requests_by_keeper: dict[str, dict[str, dict[str, int]]] = defaultdict(dict)
    for (keeper, model), items in grouped.items():
        requests_by_keeper[keeper][model] = {
            "requests": len(items),
            "with_demoted_arguments": sum(1 for item in items if item.arguments > 0),
        }
    carrying_total = sum(1 for request in requests if request.arguments > 0)
    same_size = sum(1 for sha, original in envelopes.items() if stored_with_size(base, sha, original))
    return {
        "requests": len(requests),
        "with_demoted_arguments": carrying_total,
        "with_demoted_arguments_percent": percent(carrying_total, len(requests)),
        "unreadable_messages": sum(request.unreadable for request in requests),
        "distinct_demoted_arguments": len(envelopes),
        "stored_and_same_size": same_size,
        "by_keeper_and_model": rows[:TOP_HISTORY_ROWS],
        "requests_by_keeper_and_model": dict(sorted(requests_by_keeper.items())),
    }


def attribute_calls(calls: list[BlobCall], requests: list[HistoryRequest]) -> list[AttributedCall]:
    """Each `alone` call with its Keeper, its time and the model the Keeper's stored requests on both sides of it share.

    A stored request is written when a turn ends, so the first one at or after a call closes the turn that made it
    and the one before it closes the turn before. When the two differ or one is missing, the call stays unattributed.
    """
    by_keeper: dict[str, list[HistoryRequest]] = defaultdict(list)
    for request in sorted(requests, key=lambda item: item.captured_at):
        by_keeper[request.keeper].append(request)
    stamps = {keeper: [item.captured_at for item in items] for keeper, items in by_keeper.items()}
    attributed: list[AttributedCall] = []
    for call in calls:
        if call.form != ALONE:
            continue
        items = by_keeper.get(call.keeper, [])
        index = bisect_left(stamps.get(call.keeper, []), call.stamp)
        if index == 0 or index == len(items):
            label = NO_NEIGHBOUR
        elif items[index - 1].model == items[index].model:
            label = items[index].model
        else:
            label = NEIGHBOURS_DIFFER
        attributed.append(AttributedCall(call.keeper, label, call.stamp))
    return attributed


def summarize_models(
    calls: list[BlobCall], requests: list[HistoryRequest], neighbours: list[HistoryRequest]
) -> dict[str, object]:
    """Stored requests and `alone` calls per model.

    [neighbours] is every stored request, so a call near the edge of [calls] still finds the requests on both sides.
    """
    per_model: dict[str, Counter[str]] = defaultdict(Counter)
    last_stored: dict[str, float] = {}
    for request in requests:
        per_model[request.model]["requests"] += 1
        if request.arguments > 0:
            per_model[request.model]["with_demoted_arguments"] += 1
        if request.stored_arguments > 0:
            per_model[request.model]["with_stored_demotion"] += 1
            last_stored[request.model] = max(request.captured_at, last_stored.get(request.model, request.captured_at))
    carrying = sum(counts["with_demoted_arguments"] for counts in per_model.values())
    with_stored = sum(counts["with_stored_demotion"] for counts in per_model.values())
    attributed = attribute_calls(calls, neighbours)
    calls_by_keeper: dict[str, Counter[str]] = defaultdict(Counter)
    last_call: dict[str, float] = {}
    for item in attributed:
        calls_by_keeper[item.keeper][item.label] += 1
        last_call[item.label] = max(item.stamp, last_call.get(item.label, item.stamp))
    return {
        "stored_requests": len(requests),
        "with_demoted_arguments": carrying,
        "with_demoted_arguments_percent": percent(carrying, len(requests)),
        "with_stored_demotion": with_stored,
        "with_stored_demotion_percent": percent(with_stored, len(requests)),
        "alone_calls": len(attributed),
        "alone_calls_by_model": dict(sorted(Counter(item.label for item in attributed).items())),
        "last_alone_call_by_model": {label: iso_utc(stamp) for label, stamp in sorted(last_call.items())},
        "alone_calls_by_keeper_and_model": {
            keeper: dict(sorted(counts.items())) for keeper, counts in sorted(calls_by_keeper.items())
        },
        "requests_by_model": {
            model: {
                "requests": counts["requests"],
                "with_demoted_arguments": counts["with_demoted_arguments"],
                "with_stored_demotion": counts["with_stored_demotion"],
            }
            for model, counts in sorted(per_model.items())
        },
        "last_stored_demotion_by_model": {model: iso_utc(stamp) for model, stamp in sorted(last_stored.items())},
    }


def summarize_turns(calls: list[BlobCall], requests: list[HistoryRequest]) -> dict[str, dict[str, dict[str, int]]]:
    """`alone` calls per turn, by the model of the request that closes the turn and whether that request shows a stored demotion.

    The calls of one Keeper in (previous stored request, this stored request] belong to the turn this request closes.
    The interval covers more than one turn when a turn left no stored request. A Keeper's first stored request closes
    no turn here, and calls before it or after its last stored request are not counted.
    """
    call_times: dict[str, list[float]] = defaultdict(list)
    for call in calls:
        if call.form == ALONE:
            call_times[call.keeper].append(call.stamp)
    for times in call_times.values():
        times.sort()
    by_keeper: dict[str, list[HistoryRequest]] = defaultdict(list)
    for request in sorted(requests, key=lambda item: item.captured_at):
        by_keeper[request.keeper].append(request)
    totals: dict[str, dict[str, Counter[str]]] = defaultdict(lambda: defaultdict(Counter))
    for keeper, items in by_keeper.items():
        times = call_times.get(keeper, [])
        for previous, closing in zip(items, items[1:]):
            made = bisect_right(times, closing.captured_at) - bisect_right(times, previous.captured_at)
            row = totals[closing.model][STORED_DEMOTION if closing.stored_arguments > 0 else NO_STORED_DEMOTION]
            row["turns"] += 1
            row["calls"] += made
            row["turns_with_call"] += 1 if made else 0
    return {
        model: {exposure: dict(sorted(row.items())) for exposure, row in sorted(by_exposure.items())}
        for model, by_exposure in sorted(totals.items())
    }


def summarize_split(calls: list[BlobCall], requests: list[HistoryRequest], split_at: float) -> dict[str, object]:
    """The same summary before and after one instant. A call or request exactly at [split_at] counts as after."""
    return {
        "at": iso_utc(split_at),
        "before": summarize_models(
            [call for call in calls if call.stamp < split_at],
            [request for request in requests if request.captured_at < split_at],
            requests,
        ),
        "after": summarize_models(
            [call for call in calls if call.stamp >= split_at],
            [request for request in requests if request.captured_at >= split_at],
            requests,
        ),
    }


def parse_day(text: str) -> date:
    return date.fromisoformat(text)


def parse_until(text: str) -> float:
    return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", default=None, help="directory that contains .masc; MASC_BASE_PATH when omitted")
    parser.add_argument("--from-date", type=parse_day, required=True, help="first UTC day, YYYY-MM-DD")
    parser.add_argument("--to-date", type=parse_day, required=True, help="last UTC day, YYYY-MM-DD")
    parser.add_argument("--until", type=parse_until, required=True, help="ignore anything after this ISO-8601 time")
    parser.add_argument(
        "--split",
        type=parse_until,
        default=None,
        help="also summarize before and after this ISO-8601 time, e.g. a deploy; a request or call at it counts as after",
    )
    parser.add_argument("--json-out", default=None, help="write the summary to this file")
    args = parser.parse_args()
    base = masc_base_path.require(parser, args.base_path, "--base-path")

    since = datetime(args.from_date.year, args.from_date.month, args.from_date.day, tzinfo=timezone.utc).timestamp()
    calls = read_blob_calls(base, args.from_date, args.to_date, since, args.until)
    stored = {
        str(call.sha256): blob_path(base, str(call.sha256)).is_file()
        for call in calls
        if call.form == ALONE and call.sha256 is not None
    }
    requests, envelopes = read_history_requests(base, args.from_date, args.to_date, since, args.until)
    summary: dict[str, object] = {
        "window": {
            "from": args.from_date.isoformat(),
            "to": args.to_date.isoformat(),
            "until": iso_utc(args.until),
        },
        "blob_calls": summarize_blob_calls(calls, stored),
        "history_arguments": summarize_history(requests, envelopes, base),
        "by_model": summarize_models(calls, requests, requests),
        "turns_by_model": summarize_turns(calls, requests),
    }
    if args.split is not None:
        summary["split"] = summarize_split(calls, requests, args.split)
    text = json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True)
    print(text)
    if args.json_out:
        pathlib.Path(args.json_out).write_text(text + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
