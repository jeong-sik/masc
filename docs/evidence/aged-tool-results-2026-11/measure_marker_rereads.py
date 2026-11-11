#!/usr/bin/env python3
"""How often a Keeper reads back a tool result that its stored request carries as a marker.

Joins three stores and never writes to any of them.

- `<base-path>/.masc/keepers/<keeper>/provider-inputs/YYYY-MM/DD.jsonl`: a row is the last
  request one attempt sent, after the rewrite. `runtime_profile` names the lane. `messages[]`
  holds `role` and `artifact.content_ref`, a blob reference to the message body.
- `<base-path>/.masc/tool_blobs/<first two hex>/<sha256>`: the message bodies.
- `<base-path>/.masc/tool_calls/YYYY-MM/DD.jsonl` and `DD.NNN.jsonl`: the ledger. A read is a
  `tool_call` row with `tool == "keeper_artifact_read"` and a string `input.sha256`.

Definitions:

- marker: the whole body of a `role == "tool"` message, or the whole text of one of its
  blocks, that starts with `[masc:blob sha256=<hex> bytes=<n>`. `bytes` is the size of the
  body the marker stands for. A result that quotes a marker in the middle of its text is not
  one. The match is anchored on the JSON string that opens the body.
- marker key: (Keeper, marker sha256). The same body seen in many requests counts once.
- aged marker: a marker whose `bytes` is at least `--aged-min-bytes` and at most
  `--inline-ceiling-bytes`. A finished turn's result of that size is replaced by a marker at the
  turn boundary. A result above the ceiling was stored when it was made, so it is a creation
  marker. A marker under the minimum is neither.
- read: a ledger row that names the marker key's sha256, by the same Keeper, on one of the
  scanned days.

Only requests whose `runtime_profile` starts with one of `--profile-prefix` are read. The
defaults are the providers that run through Agent Core in `config/runtime.toml`. The two byte
limits are the values in `Keeper_turn_driver_try_provider.aged_result_min_bytes` and
`Common.max_agent_core_inline_result_bytes`, and the test pins them to the OCaml source.

Limits:

- It counts finished-turn markers that a stored request still carried. It says nothing about
  a result that is turned into a marker inside a turn.
- A stored row is the last request of an attempt, so a marker is seen only if the attempt that
  stored it carried it.
- A read that passed another field (`answer_sha256`) is counted in `reads_without_sha256` and
  is not matched to a marker.
- A read is not tied to a time. It counts if it happened on a scanned day, before or after the
  request that carried the marker.

Usage:
    python3 docs/evidence/aged-tool-results-2026-11/measure_marker_rereads.py \
        --base-path ~/me --from-date 2026-11-09 --to-date 2026-11-11 \
        --json-out result.json
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime
import json
import pathlib
import re
import sys
from collections.abc import Iterator, Sequence
from typing import cast

CONTENT_REF = re.compile(r"sha256=([0-9a-f]{64})")
MARKER = re.compile(rb'(?:"content":"|"text":")\[masc:blob sha256=([0-9a-f]{64}) bytes=([0-9]+)')
LEDGER_FILE = re.compile(r"(\d{2})(?:\.\d+)?\.jsonl")
READ_TOOL = "keeper_artifact_read"
AGED_MIN_BYTES = 2_048
AGENT_CORE_INLINE_CEILING_BYTES = 65_536
DEFAULT_PROFILE_PREFIXES = ("ollama_cloud.", "glm-coding.")
DEFAULT_TOP = 8

Key = tuple[str, str]


@dataclasses.dataclass(slots=True)
class Scan:
    requests: int = 0
    tool_messages: int = 0
    missing_blobs: int = 0
    bad_lines: int = 0
    messages_with_marker: int = 0
    keepers: set[str] = dataclasses.field(default_factory=set[str])
    markers: dict[Key, int] = dataclasses.field(default_factory=dict[Key, int])


@dataclasses.dataclass(slots=True)
class Reads:
    rows: int = 0
    without_sha256: int = 0
    bad_lines: int = 0
    rows_by_keeper: dict[str, int] = dataclasses.field(default_factory=dict[str, int])
    result_bytes: dict[Key, list[int]] = dataclasses.field(default_factory=dict[Key, list[int]])


def as_int(value: object) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def as_object(value: object) -> dict[str, object] | None:
    return cast(dict[str, object], value) if isinstance(value, dict) else None


def as_list(value: object) -> list[object]:
    return cast(list[object], value) if isinstance(value, list) else []


def days_between(first: datetime.date, last: datetime.date) -> list[datetime.date]:
    count = (last - first).days + 1
    return [first + datetime.timedelta(days=offset) for offset in range(max(count, 0))]


def json_rows(path: pathlib.Path, bad_lines: list[int]) -> Iterator[dict[str, object]]:
    with path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if not line.strip():
                continue
            try:
                row = as_object(json.loads(line))
            except ValueError:
                row = None
            if row is None:
                bad_lines[0] += 1
                continue
            yield row


def markers_in(blob: bytes) -> tuple[tuple[str, int], ...]:
    return tuple((match.group(1).decode("ascii"), int(match.group(2))) for match in MARKER.finditer(blob))


def scan_requests(
    base: pathlib.Path, days: Sequence[datetime.date], prefixes: Sequence[str]
) -> Scan:
    scan = Scan()
    cache: dict[str, tuple[tuple[str, int], ...]] = {}
    bad = [0]
    blobs = base / ".masc" / "tool_blobs"
    for day in days:
        pattern = f"*/provider-inputs/{day:%Y-%m}/{day:%d}.jsonl"
        for path in sorted((base / ".masc" / "keepers").glob(pattern)):
            keeper = path.parent.parent.parent.name
            for row in json_rows(path, bad):
                profile = row.get("runtime_profile")
                if not isinstance(profile, str) or not profile.startswith(tuple(prefixes)):
                    continue
                scan.requests += 1
                scan.keepers.add(keeper)
                for message in as_list(row.get("messages")):
                    entry = as_object(message)
                    if entry is None or entry.get("role") != "tool":
                        continue
                    scan.tool_messages += 1
                    artifact = as_object(entry.get("artifact")) or {}
                    reference = artifact.get("content_ref")
                    match = CONTENT_REF.search(reference) if isinstance(reference, str) else None
                    if match is None:
                        continue
                    sha = match.group(1)
                    if sha not in cache:
                        try:
                            cache[sha] = markers_in((blobs / sha[:2] / sha).read_bytes())
                        except OSError:
                            scan.missing_blobs += 1
                            cache[sha] = ()
                    found = cache[sha]
                    if found:
                        scan.messages_with_marker += 1
                    for marker_sha, size in found:
                        scan.markers[(keeper, marker_sha)] = size
    scan.bad_lines = bad[0]
    return scan


def scan_reads(base: pathlib.Path, days: Sequence[datetime.date]) -> Reads:
    reads = Reads()
    bad = [0]
    wanted: dict[str, set[str]] = {}
    for day in days:
        wanted.setdefault(f"{day:%Y-%m}", set()).add(f"{day:%d}")
    for month, numbers in sorted(wanted.items()):
        for path in sorted((base / ".masc" / "tool_calls" / month).glob("*.jsonl")):
            name = LEDGER_FILE.fullmatch(path.name)
            if name is None or name.group(1) not in numbers:
                continue
            for row in json_rows(path, bad):
                if row.get("record_kind") != "tool_call" or row.get("tool") != READ_TOOL:
                    continue
                reads.rows += 1
                call_input = as_object(row.get("input")) or {}
                sha = call_input.get("sha256")
                keeper = row.get("keeper")
                if isinstance(keeper, str):
                    reads.rows_by_keeper[keeper] = reads.rows_by_keeper.get(keeper, 0) + 1
                if not isinstance(sha, str) or not isinstance(keeper, str):
                    reads.without_sha256 += 1
                    continue
                returned = as_int(row.get("result_bytes")) or 0
                reads.result_bytes.setdefault((keeper, sha), []).append(returned)
    reads.bad_lines = bad[0]
    return reads


def size_edges(aged_min: int, ceiling: int) -> list[int]:
    edges = [aged_min]
    while edges[-1] * 2 < ceiling:
        edges.append(edges[-1] * 2)
    edges.append(ceiling + 1)
    return edges


def share(part: int, whole: int) -> float:
    return round(part / whole, 6) if whole else 0.0


def summarize(
    scan: Scan, reads: Reads, aged_min: int, ceiling: int, top: int
) -> dict[str, object]:
    aged = {key: size for key, size in scan.markers.items() if aged_min <= size <= ceiling}
    creation = {key: size for key, size in scan.markers.items() if size > ceiling}
    under = len(scan.markers) - len(aged) - len(creation)
    read_aged = [key for key in aged if key in reads.result_bytes]
    aged_bytes = sum(aged.values())
    read_origin = sum(aged[key] for key in read_aged)
    returned = sum(sum(reads.result_bytes[key]) for key in read_aged)
    read_calls = sum(len(reads.result_bytes[key]) for key in read_aged)
    edges = size_edges(aged_min, ceiling)
    bands: list[dict[str, object]] = []
    for low, high in zip(edges, edges[1:]):
        keys = [key for key, size in aged.items() if low <= size < high]
        bands.append(
            {
                "from_bytes": low,
                "to_bytes_exclusive": high,
                "markers": len(keys),
                "read": sum(1 for key in keys if key in reads.result_bytes),
            }
        )
    per_keeper: dict[str, list[int]] = {}
    for key in aged:
        counts = per_keeper.setdefault(key[0], [0, 0])
        counts[0] += 1
        counts[1] += 1 if key in reads.result_bytes else 0
    ranked = sorted(per_keeper.items(), key=lambda item: (-item[1][0], item[0]))[:top]
    on_known = sum(len(values) for key, values in reads.result_bytes.items() if key in scan.markers)
    by_scanned = sum(count for name, count in reads.rows_by_keeper.items() if name in scan.keepers)
    return {
        "requests": scan.requests,
        "tool_messages": scan.tool_messages,
        "tool_messages_with_marker": scan.messages_with_marker,
        "missing_message_blobs": scan.missing_blobs,
        "markers": len(scan.markers),
        "aged_markers": len(aged),
        "creation_markers": len(creation),
        "markers_under_minimum": under,
        "aged_markers_read": len(read_aged),
        "aged_markers_read_share": share(len(read_aged), len(aged)),
        "aged_original_bytes": aged_bytes,
        "read_aged_original_bytes": read_origin,
        "read_aged_original_share": share(read_origin, aged_bytes),
        "read_aged_returned_bytes": returned,
        "read_aged_returned_share_of_aged_original": share(returned, aged_bytes),
        "read_calls_on_aged_markers": read_calls,
        "creation_markers_read": sum(1 for key in creation if key in reads.result_bytes),
        "reads_total": reads.rows,
        "reads_by_keepers_with_scanned_requests": by_scanned,
        "reads_without_sha256": reads.without_sha256,
        "reads_on_known_markers": on_known,
        "bands": bands,
        "keepers_by_aged_markers": [
            {"keeper": name, "aged_markers": counts[0], "read": counts[1]} for name, counts in ranked
        ],
        "bad_request_lines": scan.bad_lines,
        "bad_ledger_lines": reads.bad_lines,
    }


def print_summary(result: dict[str, object]) -> None:
    for name, value in result.items():
        if name in ("bands", "keepers_by_aged_markers"):
            continue
        print(f"{name}: {value}")
    for band in cast(list[dict[str, object]], result["bands"]):
        print(f"band {band['from_bytes']}..{band['to_bytes_exclusive']}: markers {band['markers']} read {band['read']}")
    for entry in cast(list[dict[str, object]], result["keepers_by_aged_markers"]):
        print(f"keeper {entry['keeper']}: aged markers {entry['aged_markers']} read {entry['read']}")


def parse_day(text: str) -> datetime.date:
    return datetime.date.fromisoformat(text)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--from-date", type=parse_day, required=True, help="first UTC day, YYYY-MM-DD")
    parser.add_argument("--to-date", type=parse_day, required=True, help="last UTC day, YYYY-MM-DD")
    parser.add_argument("--profile-prefix", action="append", dest="prefixes")
    parser.add_argument("--aged-min-bytes", type=int, default=AGED_MIN_BYTES)
    parser.add_argument("--inline-ceiling-bytes", type=int, default=AGENT_CORE_INLINE_CEILING_BYTES)
    parser.add_argument("--top", type=int, default=DEFAULT_TOP)
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    days = days_between(args.from_date, args.to_date)
    if not days:
        print("--to-date is before --from-date", file=sys.stderr)
        return 2
    prefixes = tuple(args.prefixes or DEFAULT_PROFILE_PREFIXES)
    base = args.base_path.expanduser()
    scan = scan_requests(base, days, prefixes)
    reads = scan_reads(base, days)
    result = summarize(scan, reads, args.aged_min_bytes, args.inline_ceiling_bytes, args.top)
    result["window"] = {"from": args.from_date.isoformat(), "to": args.to_date.isoformat()}
    result["profile_prefixes"] = list(prefixes)
    print_summary(result)
    if args.json_out is not None:
        args.json_out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
