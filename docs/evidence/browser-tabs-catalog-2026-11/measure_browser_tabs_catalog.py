#!/usr/bin/env python3
"""Measure what Keeper `BrowserTabs` calls returned and what the result becomes when only the operations named in
`requiredActions` carry their constraints.

Reads, and never writes, `<base-path>/.masc/tool_calls/<YYYY-MM>/<DD>.jsonl` and `<DD>.<NNN>.jsonl`
(one JSON object per line) and the blobs under `<base-path>/.masc/tool_blobs/<sha[0:2]>/<sha>`.
A line counts when `record_kind` is `tool_call`, `tool` is `BrowserTabs` and `ts` (UTC seconds) lies in
[--since, --until).

Definitions:

- result_bytes: the `result_bytes` field, the size of the result before it was shown to the model.
- result: the JSON object a stored call stands for. `output` is `{"_blob": {"sha256": ...}}` when the text handed
  to the lane was a blob marker (lib/keeper_tool_call_log.ml `blob_aware_output_json`), so the result is read from
  the blob. Otherwise `output` is a string the ledger keeps cut to a few KB, which counts only when it parses as a
  whole object.
- catalog call: a readable result with a `browserCapabilities` object that has an `operations` list. A result
  of `mode=connections` or a failure has none.
- reprojected: the result `Browser_addon_tools.project` gives for the same call after the change
  (lib/browser_addon_tools.ml, lib/browser_capabilities.ml `to_json ~constraints_for`). `reproject` ports it onto
  the stored result: every field but `browserCapabilities` and `requiredActions` keeps its place, then comes
  `browserCapabilities` with a `scope` that says where the constraints are, and `requiredActions`. A conditional row
  keeps `constraints` only when its operation is in `requiredActions`. The size is the compact UTF-8 JSON
  `Yojson.Safe.to_string` writes.
- cut call: a call whose `output` the ledger kept cut (the lane received the whole text, so it was under the lane's
  ceiling). Its result cannot be reprojected. Its size after the change is bounded from above by `result_bytes` minus
  the smallest reduction of a readable catalog call, which assumes the catalog of a cut call is no smaller than the
  smallest catalog among the readable ones.
- window bytes: the sum of `result_bytes` over every `tool_call` line of the window, any tool.

Usage:
    python3 docs/evidence/browser-tabs-catalog-2026-11/measure_browser_tabs_catalog.py \
        --base-path ~/me --since 2026-11-03T00:00:00 --until 2026-11-07T14:00:00 \
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
from collections import Counter
from collections.abc import Iterator, Sequence
from typing import cast

RECORD_KIND = "tool_call"
TOOL = "BrowserTabs"
LEDGER_FILE = re.compile(r"^(?P<day>[0-9]{2})(?:\.[0-9]{3})?\.jsonl$")
# The ledger keeps a long inline `output` as a JSON object cut to a few KB that carries this key.
TRUNCATED_KEY = "_truncated"
CAPABILITIES = "browserCapabilities"
REQUIRED = "requiredActions"
SCOPE_BEFORE = "implemented public tools for this browser; not readiness, effect success or dispatch authority"
SCOPE_AFTER = SCOPE_BEFORE + "; a conditional row lists its constraints only when its operation is in requiredActions"
# Inline ceiling of a tool result per lane, lib/runtime/runtime_execution.ml:85-91 and lib/core/common.ml:217,235.
CEILINGS = (("16384", 16_384), ("32768", 32_768), ("65536", 65_536))
UTC = datetime.timezone.utc
DECODER = json.JSONDecoder()

Json = dict[str, object]


@dataclasses.dataclass(frozen=True, slots=True)
class Call:
    keeper: str
    result_bytes: int
    result: Json | None
    unreadable: str


def ledger_files(base: pathlib.Path, since: datetime.datetime, until: datetime.datetime) -> list[pathlib.Path]:
    """The ledger files of each UTC day the window touches, in name order."""
    paths: list[pathlib.Path] = []
    day = since.date()
    last = until.date()
    while day <= last:
        folder = base / ".masc" / "tool_calls" / f"{day.year:04d}-{day.month:02d}"
        if folder.is_dir():
            paths.extend(sorted(p for p in folder.iterdir() if (m := LEDGER_FILE.match(p.name)) and int(m["day"]) == day.day))
        day += datetime.timedelta(days=1)
    return paths


def first_object(text: str) -> Json | None:
    """The JSON object a text starts with; text after it (a failure note) is ignored."""
    try:
        value = cast("object", DECODER.raw_decode(text.lstrip())[0])
    except ValueError:
        return None
    return cast("Json", value) if isinstance(value, dict) else None


def result_of(output: object, blob_root: pathlib.Path) -> tuple[Json | None, str]:
    """The whole result a ledger `output` stands for, or None with the reason it cannot be read."""
    if isinstance(output, dict):
        blob = cast("Json", output).get("_blob")
        sha = cast("Json", blob).get("sha256") if isinstance(blob, dict) else None
        if not isinstance(sha, str) or len(sha) < 2:
            return None, "no_blob_sha"
        path = blob_root / sha[:2] / sha
        if not path.is_file():
            return None, "blob_missing"
        parsed = first_object(path.read_text(encoding="utf-8", errors="replace"))
        return (parsed, "") if parsed is not None else (None, "blob_not_json")
    if isinstance(output, str):
        parsed = first_object(output)
        if parsed is None or TRUNCATED_KEY in parsed:
            return None, "cut_excerpt"
        return parsed, ""
    return None, "no_output"


def operations_of(result: Json) -> list[Json] | None:
    """The catalog rows of a result, or None when it has no catalog."""
    caps = result.get(CAPABILITIES)
    rows = cast("Json", caps).get("operations") if isinstance(caps, dict) else None
    if not isinstance(rows, list):
        return None
    return [cast("Json", row) for row in cast("list[object]", rows) if isinstance(row, dict)]


def required_of(result: Json) -> list[str]:
    """The operation names a result echoes as `requiredActions`."""
    names = result.get(REQUIRED)
    return [name for name in cast("list[object]", names) if isinstance(name, str)] if isinstance(names, list) else []


def reproject_row(row: Json, named: bool) -> Json:
    """Port of `entry_json ~with_constraints`: a conditional row keeps `constraints` only when its operation is named."""
    if named or row.get("status") != "conditional":
        return dict(row)
    return {key: value for key, value in row.items() if key != "constraints"}


def reproject(result: Json) -> Json:
    """Port of the Inventory projection onto a stored result that has a catalog."""
    rows = operations_of(result)
    if rows is None:
        raise ValueError("a result without a catalog has nothing to reproject")
    required = required_of(result)
    rest = {key: value for key, value in result.items() if key not in (CAPABILITIES, REQUIRED)}
    return {
        **rest,
        CAPABILITIES: {"scope": SCOPE_AFTER, "operations": [reproject_row(row, row.get("operation") in required) for row in rows]},
        REQUIRED: required,
    }


def json_bytes(value: object) -> int:
    """The size `Yojson.Safe.to_string` gives a value: compact, non-ASCII kept as UTF-8."""
    return len(json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


def constraints_bytes(row: Json) -> int:
    constraints = row.get("constraints")
    return json_bytes(constraints) if constraints is not None else 0


def without_constraints(row: Json) -> Json:
    return {key: value for key, value in row.items() if key != "constraints"}


def checks_hold(before: Json, after: Json) -> dict[str, bool]:
    """What must stay true of one reprojected result."""
    rows_before = operations_of(before) or []
    rows_after = operations_of(after) or []
    required = required_of(before)
    named_conditional = [str(row.get("operation")) for row in rows_before if row.get("status") == "conditional" and row.get("operation") in required]
    listed = [str(row.get("operation")) for row in rows_after if "constraints" in row]
    keys_before = [key for key in before if key not in (CAPABILITIES, REQUIRED)]
    keys_after = list(after)
    same_rows = len(rows_before) == len(rows_after)
    return {
        "catalog_had_only_scope_and_operations": list(cast("Json", before[CAPABILITIES])) == ["scope", "operations"],
        "scope_was_the_old_text": cast("Json", before[CAPABILITIES]).get("scope") == SCOPE_BEFORE,
        "every_row_kept_in_order": same_rows and [without_constraints(row) for row in rows_before] == [without_constraints(row) for row in rows_after],
        "constraints_exactly_for_named_conditional_rows": listed == named_conditional,
        "named_rows_keep_their_text": same_rows and all(a == b for a, b in zip(rows_before, rows_after, strict=True) if a.get("operation") in required),
        "other_fields_unchanged": all(after.get(key) == before.get(key) for key in keys_before) and keys_after[: len(keys_before)] == keys_before,
        "catalog_and_echo_last": keys_after[-2:] == [CAPABILITIES, REQUIRED],
    }


def read_calls(paths: Sequence[pathlib.Path], since: float, until: float, blob_root: pathlib.Path) -> Iterator[Call]:
    for path in paths:
        with path.open("rb") as handle:
            for raw in handle:
                if b'"BrowserTabs"' not in raw:
                    continue
                try:
                    row = cast("object", json.loads(raw))
                except ValueError:
                    continue
                if not isinstance(row, dict):
                    continue
                fields = cast("Json", row)
                if fields.get("record_kind") != RECORD_KIND or fields.get("tool") != TOOL:
                    continue
                stamp = fields.get("ts")
                if isinstance(stamp, bool) or not isinstance(stamp, (int, float)) or not since <= float(stamp) < until:
                    continue
                size = fields.get("result_bytes")
                keeper = fields.get("keeper")
                result, reason = result_of(fields.get("output"), blob_root)
                yield Call(
                    keeper=keeper if isinstance(keeper, str) else "",
                    result_bytes=size if isinstance(size, int) and not isinstance(size, bool) else 0,
                    result=result,
                    unreadable=reason,
                )


def window_bytes(paths: Sequence[pathlib.Path], since: float, until: float) -> int:
    """The sum of `result_bytes` over every `tool_call` line of the window, any tool."""
    total = 0
    for path in paths:
        with path.open("rb") as handle:
            for raw in handle:
                if b'"result_bytes"' not in raw:
                    continue
                try:
                    row = cast("object", json.loads(raw))
                except ValueError:
                    continue
                if not isinstance(row, dict):
                    continue
                fields = cast("Json", row)
                stamp = fields.get("ts")
                size = fields.get("result_bytes")
                if fields.get("record_kind") != RECORD_KIND or isinstance(stamp, bool) or not isinstance(stamp, (int, float)):
                    continue
                if since <= float(stamp) < until and isinstance(size, int) and not isinstance(size, bool):
                    total += size
    return total


def percentile(sorted_values: Sequence[int], fraction: float) -> int:
    return sorted_values[min(len(sorted_values) - 1, int(fraction * (len(sorted_values) - 1)))] if sorted_values else 0


def spread(values: Sequence[int]) -> dict[str, int]:
    ordered = sorted(values)
    return {"min": ordered[0] if ordered else 0, "p50": percentile(ordered, 0.5), "max": ordered[-1] if ordered else 0}


def summarize(calls: Iterator[Call]) -> Json:
    total = 0
    unreadable: Counter[str] = Counter()
    keepers: Counter[str] = Counter()
    no_catalog = 0
    sizes_before: list[int] = []
    sizes_after: list[int] = []
    catalog_bytes_before: list[int] = []
    catalog_bytes_after: list[int] = []
    operation_counts: list[int] = []
    tabs_sizes: list[int] = []
    named: Counter[int] = Counter()
    matches_ledger = 0
    failed_checks: Counter[str] = Counter()
    above_before = {name: 0 for name, _ in CEILINGS}
    above_after = {name: 0 for name, _ in CEILINGS}
    above_ledger = {name: 0 for name, _ in CEILINGS}
    cut_sizes: list[int] = []
    all_bytes = 0
    largest: Json | None = None
    largest_size = 0
    for call in calls:
        total += 1
        all_bytes += call.result_bytes
        keepers[call.keeper] += 1
        for name, ceiling in CEILINGS:
            if call.result_bytes > ceiling:
                above_ledger[name] += 1
        if call.result is None:
            unreadable[call.unreadable] += 1
            if call.unreadable == "cut_excerpt" and call.result_bytes > CEILINGS[0][1]:
                cut_sizes.append(call.result_bytes)
            continue
        if operations_of(call.result) is None:
            no_catalog += 1
            continue
        after = reproject(call.result)
        before_size = json_bytes(call.result)
        after_size = json_bytes(after)
        sizes_before.append(before_size)
        sizes_after.append(after_size)
        catalog_bytes_before.append(json_bytes(call.result[CAPABILITIES]))
        catalog_bytes_after.append(json_bytes(after[CAPABILITIES]))
        operation_counts.append(len(operations_of(call.result) or []))
        tabs_sizes.append(json_bytes(call.result["tabs"]) if "tabs" in call.result else 0)
        named[len(required_of(call.result))] += 1
        matches_ledger += before_size == call.result_bytes
        for name, held in checks_hold(call.result, after).items():
            if not held:
                failed_checks[name] += 1
        for name, ceiling in CEILINGS:
            above_before[name] += before_size > ceiling
            above_after[name] += after_size > ceiling
        if before_size > largest_size:
            largest, largest_size = call.result, before_size
    per_operation = [constraints_bytes(row) for row in (operations_of(largest) if largest is not None else None) or [] if row.get("status") == "conditional"]
    catalog_calls = len(sizes_before)
    smallest_reduction = min((b - a for b, a in zip(sizes_before, sizes_after, strict=True)), default=0)
    cut_after_bound = [size - smallest_reduction for size in cut_sizes]
    return {
        "calls": total,
        "result_bytes_of_all_calls": all_bytes,
        "keepers": dict(keepers.most_common()),
        "unreadable": dict(sorted(unreadable.items())),
        "readable_without_catalog": no_catalog,
        "catalog_calls": catalog_calls,
        "calls_naming_required_actions": {str(count): n for count, n in sorted(named.items())},
        "result_bytes_equal_to_reserialized_before": matches_ledger,
        "bytes_before": {"sum": sum(sizes_before), **spread(sizes_before)},
        "bytes_after": {"sum": sum(sizes_after), **spread(sizes_after)},
        "operations_per_catalog": spread(operation_counts),
        "tabs_bytes": spread(tabs_sizes),
        "catalog_bytes_before": spread(catalog_bytes_before),
        "catalog_bytes_after": spread(catalog_bytes_after),
        "above_ceiling_before": above_before,
        "above_ceiling_after": above_after,
        "above_ceiling_by_ledger_result_bytes_any_catalog_or_not": above_ledger,
        "cut_calls_over_16384": {
            "calls": len(cut_sizes),
            "result_bytes": spread(cut_sizes),
            "smallest_reduction_of_a_readable_call": smallest_reduction,
            "bytes_after_at_most": spread(cut_after_bound),
            "above_ceiling_before": {name: sum(size > ceiling for size in cut_sizes) for name, ceiling in CEILINGS},
            "above_ceiling_after_at_most": {name: sum(size > ceiling for size in cut_after_bound) for name, ceiling in CEILINGS},
        },
        "bytes_of_the_calls_over_16384": {
            "calls": catalog_calls + len(cut_sizes),
            "before": sum(sizes_before) + sum(cut_sizes),
            "after_at_most": sum(sizes_after) + sum(cut_after_bound),
        },
        "checks_failed": dict(sorted(failed_checks.items())),
        "constraints_bytes_per_conditional_operation_of_the_largest_result": spread(per_operation),
        "conditional_operations_of_the_largest_result": len(per_operation),
    }


def parse_instant(text: str) -> datetime.datetime:
    parsed = datetime.datetime.fromisoformat(text)
    return parsed.replace(tzinfo=UTC) if parsed.tzinfo is None else parsed.astimezone(UTC)


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--since", type=parse_instant, required=True)
    parser.add_argument("--until", type=parse_instant, required=True)
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    base = cast("pathlib.Path", args.base_path).expanduser()
    since = cast("datetime.datetime", args.since)
    until = cast("datetime.datetime", args.until)
    paths = ledger_files(base, since, until)
    calls = read_calls(paths, since.timestamp(), until.timestamp(), base / ".masc" / "tool_blobs")
    summary = summarize(calls)
    summary["window_result_bytes_any_tool"] = window_bytes(paths, since.timestamp(), until.timestamp())
    summary["window"] = {"since": since.isoformat(), "until": until.isoformat(), "ledger_files": len(paths)}
    text = json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True)
    out = cast("pathlib.Path | None", args.json_out)
    if out is not None:
        out.write_text(text + "\n", encoding="utf-8")
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
