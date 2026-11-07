#!/usr/bin/env python3
"""Measure what Keeper `keeper_tools_list` returned and what the inventory that replaces it returns for the same surfaces.

Reads, and never writes, `<base-path>/.masc/tool_calls/<YYYY-MM>/<DD>.jsonl` and `<DD>.<NNN>.jsonl`
(one JSON object per line) and the blobs under `<base-path>/.masc/tool_blobs/<sha[0:2]>/<sha>`.
A line counts when `record_kind` is `tool_call`, `tool` is `keeper_tools_list` and `ts` (UTC seconds) lies in
[--since, --until).

Definitions:

- result_bytes: the `result_bytes` field, the size of the result before it was shown to the model.
- surface: the JSON object a stored result stands for, `{schema, skill_snapshot_revision, surface_digest,
  descriptor_surface, skills}`. `output` is `{"_blob": {"sha256": ...}}` when the text handed to the lane was a
  blob marker (lib/keeper_tool_call_log.ml `blob_aware_output_json`), so the surface is read from the blob;
  text after the JSON object (a failure note) is ignored. Otherwise `output` is a string the ledger keeps cut
  to a few KB, which counts only when it parses as a whole surface.
- inventory: the result `Keeper_capability_surface.inventory_to_yojson` (lib/keeper/keeper_capability_surface.ml)
  gives for the same frozen surface. `inventory_of` ports it onto the stored rows: a Tool row keeps the name the
  Keeper calls it by as `name` (`internal_name` when `keeper_model_projection` is `internal_name`, `public_name`
  otherwise), `transport_alias_of` and the availability's detail field, a Skill row keeps its name, `kind`,
  `tool_name` and the detail field, and both are filed under their `availability` in first-seen order. The
  size is the compact UTF-8 JSON `Yojson.Safe.to_string` writes.
- window bytes: the sum of `result_bytes` over every `tool_call` line of the window, any tool.

Usage:
    python3 docs/evidence/tools-list-inventory-2026-11/measure_tools_list_inventory.py \
        --base-path ~/me --since 2026-11-06T09:52:00 --until 2026-11-07T09:52:00 \
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
TOOL = "keeper_tools_list"
LEDGER_FILE = re.compile(r"^(?P<day>[0-9]{2})(?:\.[0-9]{3})?\.jsonl$")
# The ledger keeps a long inline `output` as a JSON object cut to a few KB that carries this key.
TRUNCATED_KEY = "_truncated"
INVENTORY_SCHEMA = "masc.keeper.capability_inventory.v1"
# Inline ceiling of a tool result per lane, lib/runtime/runtime_execution.ml:85-91 and lib/core/common.ml:217,235.
CEILINGS = (("16384", 16_384), ("32768", 32_768), ("65536", 65_536))
UTC = datetime.timezone.utc
DECODER = json.JSONDecoder()

Json = dict[str, object]


@dataclasses.dataclass(frozen=True, slots=True)
class Call:
    keeper: str
    result_bytes: int
    surface: Json | None
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


def surface_of(output: object, blob_root: pathlib.Path) -> tuple[Json | None, str]:
    """The whole surface a ledger `output` stands for, or None with the reason it cannot be read."""
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


def rows_of(surface: Json, key: str) -> list[Json]:
    rows = surface.get(key)
    return [cast("Json", row) for row in cast("list[object]", rows) if isinstance(row, dict)] if isinstance(rows, list) else []


def string_of(row: Json, key: str) -> str | None:
    value = row.get(key)
    return value if isinstance(value, str) else None


def detail_fields(row: Json) -> list[tuple[str, object]]:
    """Port of `availability_detail_fields`: the field a refusal or a withheld composition carries."""
    return [(key, row[key]) for key in ("sandbox_refusal", "outside_node_tools") if key in row]


def tool_name(row: Json) -> object:
    """Port of `tool_inventory_name`: `internal_name` for a Tool projected by it, `public_name` for every other projection."""
    return row.get("internal_name") if row.get("keeper_model_projection") == "internal_name" else row.get("public_name")


def tool_row(row: Json) -> Json:
    """Port of `tool_inventory_row`. `transport_alias_of` exists in a stored row only for a transport alias."""
    fields: list[tuple[str, object]] = [("name", tool_name(row))]
    if "transport_alias_of" in row:
        fields.append(("transport_alias_of", row["transport_alias_of"]))
    return dict(fields + detail_fields(row))


def skill_name(row: Json) -> object:
    """Port of `skill_name`: the reference's name, else the directory of an invalid Skill, else the configured name."""
    reference = row.get("reference")
    if isinstance(reference, dict):
        identity = cast("Json", reference).get("identity")
        if isinstance(identity, dict):
            return cast("Json", identity).get("name")
    return row["directory"] if "directory" in row else row.get("name")


def skill_row(row: Json) -> Json:
    """Port of `skill_inventory_row`: name, kind (and the composition's tool name), then the detail field."""
    fields: list[tuple[str, object]] = [("name", skill_name(row)), ("kind", row.get("kind"))]
    if "tool_name" in row:
        fields.append(("tool_name", row["tool_name"]))
    return dict(fields + detail_fields(row))


def group_by_availability(rows: Sequence[Json], source: Sequence[Json]) -> Json:
    """Port of `group_by_availability`: rows filed under their availability, groups and rows in first-seen order."""
    groups: dict[str, list[object]] = {}
    for row, stored in zip(rows, source, strict=True):
        groups.setdefault(str(stored.get("availability")), []).append(row)
    return cast("Json", groups)


def inventory_of(surface: Json) -> Json:
    """Port of `inventory_to_yojson` onto the rows of a stored surface."""
    tools = rows_of(surface, "descriptor_surface")
    skills = rows_of(surface, "skills")
    return {
        "schema": INVENTORY_SCHEMA,
        "skill_snapshot_revision": surface.get("skill_snapshot_revision"),
        "surface_digest": surface.get("surface_digest"),
        "tools": group_by_availability([tool_row(row) for row in tools], tools),
        "skills": group_by_availability([skill_row(row) for row in skills], skills),
    }


def json_bytes(value: object) -> int:
    """The size `Yojson.Safe.to_string` gives a value: compact, non-ASCII kept as UTF-8."""
    return len(json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


def row_names(groups: object) -> list[object]:
    """The `name` of every row of an inventory's grouped rows, group by group."""
    if not isinstance(groups, dict):
        return []
    return [cast("Json", row).get("name") for rows in cast("Json", groups).values() if isinstance(rows, list) for row in cast("list[object]", rows) if isinstance(row, dict)]


def group_sizes(groups: object) -> dict[str, int]:
    if not isinstance(groups, dict):
        return {}
    return {name: len(cast("list[object]", rows)) for name, rows in cast("Json", groups).items() if isinstance(rows, list)}


def row_keys(groups: object) -> list[str]:
    """The keys any row of an inventory's grouped rows carries."""
    if not isinstance(groups, dict):
        return []
    keys = {key for rows in cast("Json", groups).values() if isinstance(rows, list) for row in cast("list[object]", rows) if isinstance(row, dict) for key in cast("Json", row)}
    return sorted(keys)


def read_calls(paths: Sequence[pathlib.Path], since: float, until: float, blob_root: pathlib.Path) -> Iterator[Call]:
    for path in paths:
        with path.open("rb") as handle:
            for raw in handle:
                if b'"keeper_tools_list"' not in raw:
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
                surface, reason = surface_of(fields.get("output"), blob_root)
                yield Call(
                    keeper=keeper if isinstance(keeper, str) else "",
                    result_bytes=size if isinstance(size, int) and not isinstance(size, bool) else 0,
                    surface=surface,
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


def summarize(calls: Iterator[Call]) -> Json:
    total = 0
    before_total = 0
    unreadable: Counter[str] = Counter()
    keepers: Counter[str] = Counter()
    digests: set[str] = set()
    after_sizes: list[int] = []
    tool_rows_kept = True
    skill_rows_kept = True
    tool_rows = 0
    skill_rows = 0
    before_calls = {name: 0 for name, _ in CEILINGS}
    after_calls = {name: 0 for name, _ in CEILINGS}
    old_tool_keys: set[str] = set()
    largest: Json | None = None
    largest_size = 0
    for call in calls:
        total += 1
        before_total += call.result_bytes
        keepers[call.keeper] += 1
        for name, ceiling in CEILINGS:
            if call.result_bytes > ceiling:
                before_calls[name] += 1
        if call.surface is None:
            unreadable[call.unreadable] += 1
            continue
        inventory = inventory_of(call.surface)
        size = json_bytes(inventory)
        after_sizes.append(size)
        digest = call.surface.get("surface_digest")
        if isinstance(digest, str):
            digests.add(digest)
        tools = rows_of(call.surface, "descriptor_surface")
        skills = rows_of(call.surface, "skills")
        tool_rows += len(tools)
        skill_rows += len(skills)
        tool_rows_kept = tool_rows_kept and Counter(map(str, row_names(inventory["tools"]))) == Counter(str(tool_name(row)) for row in tools)
        skill_rows_kept = skill_rows_kept and Counter(map(str, row_names(inventory["skills"]))) == Counter(str(skill_name(row)) for row in skills)
        for row in tools:
            old_tool_keys.update(row)
        for name, ceiling in CEILINGS:
            if size > ceiling:
                after_calls[name] += 1
        if size > largest_size:
            largest, largest_size = inventory, size
    after_sizes.sort()
    return {
        "calls": total,
        "keepers": dict(keepers.most_common()),
        "unreadable": dict(sorted(unreadable.items())),
        "readable_calls": len(after_sizes),
        "distinct_surfaces": len(digests),
        "result_bytes_before": before_total,
        "inventory_bytes_after": sum(after_sizes),
        "inventory_bytes": {"min": after_sizes[0] if after_sizes else 0, "p50": percentile(after_sizes, 0.5), "max": after_sizes[-1] if after_sizes else 0},
        "tool_rows_in_surfaces": tool_rows,
        "skill_rows_in_surfaces": skill_rows,
        "every_tool_name_kept_once_per_surface": tool_rows_kept,
        "every_skill_name_kept_once_per_surface": skill_rows_kept,
        "tool_row_keys_before": sorted(old_tool_keys),
        "tool_row_keys_after": row_keys(largest["tools"]) if largest is not None else [],
        "skill_row_keys_after": row_keys(largest["skills"]) if largest is not None else [],
        "groups_of_the_largest_inventory": (
            {"tools": group_sizes(largest["tools"]), "skills": group_sizes(largest["skills"])} if largest is not None else {}
        ),
        "above_ceiling_before": before_calls,
        "above_ceiling_after": after_calls,
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
