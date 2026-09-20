#!/usr/bin/env python3
"""Mine adjacent tool-call pairs and triplets from retained MASC logs.

The report is evidence only.  It does not select composition candidates,
invent frequency thresholds, or write Skill packages.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Sequence


SCHEMA_VERSION = "masc.tool-call-sequence-miner/v1"
VALID_RECORD_KINDS = {"tool_call", "composition_run"}


class RowError(ValueError):
    """One JSONL row cannot be interpreted without guessing."""


@dataclass(frozen=True)
class Source:
    file: str
    line: int

    def json(self) -> dict[str, Any]:
        return {"file": self.file, "line": self.line}


@dataclass(frozen=True)
class Call:
    source: Source
    ts: int | float
    keeper: str
    tool: str
    success: bool
    trace_id: str | None
    keeper_turn_id: int | None
    execution_id: str | None
    tool_use_id: str | None
    planned_index: int | None
    batch_index: int | None
    batch_size: int | None
    execution_mode: str | None
    descriptor_id: str | None
    runtime_profile: str | None
    result_bytes: int | None
    gaps: tuple[str, ...]

    @property
    def turn_key(self) -> tuple[str, str, int] | None:
        if self.trace_id is None or self.keeper_turn_id is None:
            return None
        return self.keeper, self.trace_id, self.keeper_turn_id

    def identity_json(self) -> dict[str, Any]:
        return {
            "source": self.source.json(),
            "ts": self.ts,
            "tool": self.tool,
            "execution_id": self.execution_id,
            "tool_use_id": self.tool_use_id,
            "planned_index": self.planned_index,
            "batch_index": self.batch_index,
            "batch_size": self.batch_size,
            "execution_mode": self.execution_mode,
            "descriptor_id": self.descriptor_id,
            "runtime_profile": self.runtime_profile,
            "success": self.success,
            "result_bytes": self.result_bytes,
            "coverage_gaps": list(self.gaps),
        }


@dataclass
class NgramAggregate:
    occurrence_count: int = 0
    failure_count: int = 0
    keepers: set[str] = field(default_factory=set)
    occurrences: list[tuple[tuple[str, str, int], tuple[Call, ...]]] | None = None


def _required_string(row: dict[str, Any], name: str) -> str:
    value = row.get(name)
    if not isinstance(value, str) or not value:
        raise RowError(f"{name} must be a non-empty string")
    return value


def _optional_string(row: dict[str, Any], name: str) -> str | None:
    if name not in row or row[name] is None:
        return None
    value = row[name]
    if not isinstance(value, str):
        raise RowError(f"{name} must be a string when present")
    return value


def _optional_nonnegative_int(row: dict[str, Any], name: str) -> int | None:
    if name not in row or row[name] is None:
        return None
    value = row[name]
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise RowError(f"{name} must be a non-negative integer when present")
    return value


def _runtime_identity(
    row: dict[str, Any], keeper: str
) -> tuple[str | None, int | None]:
    contract = row.get("runtime_contract")
    if contract is None:
        return None, None
    if not isinstance(contract, dict):
        raise RowError("runtime_contract must be an object when present")

    contract_keeper = contract.get("keeper_name")
    if contract_keeper is not None:
        if not isinstance(contract_keeper, str) or not contract_keeper:
            raise RowError("runtime_contract.keeper_name must be a non-empty string")
        if contract_keeper != keeper:
            raise RowError("keeper conflicts with runtime_contract.keeper_name")

    trace_id = contract.get("trace_id")
    if trace_id is not None and (not isinstance(trace_id, str) or not trace_id):
        raise RowError("runtime_contract.trace_id must be a non-empty string")

    keeper_turn_id = contract.get("keeper_turn_id")
    if keeper_turn_id is not None and (
        isinstance(keeper_turn_id, bool)
        or not isinstance(keeper_turn_id, int)
        or keeper_turn_id < 0
    ):
        raise RowError("runtime_contract.keeper_turn_id must be a non-negative integer")
    return trace_id, keeper_turn_id


def _descriptor(row: dict[str, Any], gaps: set[str]) -> str | None:
    evidence = row.get("route_evidence")
    if evidence is None:
        gaps.add("missing_descriptor")
        return None
    if not isinstance(evidence, dict):
        raise RowError("route_evidence must be an object when present")

    descriptor_id = evidence.get("descriptor_id")
    if descriptor_id is None:
        gaps.add("missing_descriptor")
    elif not isinstance(descriptor_id, str) or not descriptor_id:
        raise RowError("route_evidence.descriptor_id must be a non-empty string")

    composable = evidence.get("composable_output")
    if composable is None:
        gaps.add("missing_composable_output_contract")
    elif not isinstance(composable, dict):
        raise RowError("route_evidence.composable_output must be an object")
    else:
        kind = composable.get("kind")
        if kind == "opaque":
            gaps.add("opaque_output")
        elif kind == "json":
            if "schema" not in composable:
                gaps.add("missing_output_schema")
        elif kind is None:
            gaps.add("missing_composable_output_contract")
        else:
            raise RowError(
                "route_evidence.composable_output.kind must be opaque or json"
            )
    return descriptor_id


def _contains_truncation_marker(value: Any) -> bool:
    if isinstance(value, str):
        return value.endswith("...(truncated)")
    if isinstance(value, list):
        return any(_contains_truncation_marker(item) for item in value)
    if isinstance(value, dict):
        return any(_contains_truncation_marker(item) for item in value.values())
    return False


def _call_from_row(row: dict[str, Any], source: Source) -> Call | None:
    record_kind = row.get("record_kind")
    if not isinstance(record_kind, str):
        raise RowError("record_kind must be a string")
    if record_kind not in VALID_RECORD_KINDS:
        raise RowError(f"unknown record_kind {record_kind!r}")
    if record_kind != "tool_call":
        return None

    if "composition_run_id" in row:
        run_id = row["composition_run_id"]
        if not isinstance(run_id, str) or not run_id:
            raise RowError("composition_run_id must be a non-empty string when present")
        return None

    keeper = _required_string(row, "keeper")
    tool = _required_string(row, "tool")
    ts = row.get("ts")
    if isinstance(ts, bool) or not isinstance(ts, (int, float)):
        raise RowError("ts must be a number")
    if not math.isfinite(ts):
        raise RowError("ts must be finite")
    success = row.get("success")
    if not isinstance(success, bool):
        raise RowError("success must be a boolean")
    if "input" not in row:
        raise RowError("input is required")
    if "output" not in row:
        raise RowError("output is required")

    gaps: set[str] = set()
    input_value = row["input"]
    if _contains_truncation_marker(input_value):
        gaps.add("truncated_input")
    if isinstance(input_value, str):
        if "truncated_input" not in gaps:
            gaps.add("non_structured_input")

    output_value = row["output"]
    if isinstance(output_value, str):
        if output_value.endswith("...(truncated)"):
            gaps.add("truncated_output")
    elif isinstance(output_value, dict):
        if set(output_value) != {"_blob"} or not isinstance(
            output_value["_blob"], dict
        ):
            raise RowError("output object must be a normalized _blob reference")
        gaps.add("blob_only_output")
    else:
        raise RowError("output must be a string or normalized _blob object")

    result_bytes = _optional_nonnegative_int(row, "result_bytes")
    truncated_to = _optional_nonnegative_int(row, "truncated_to")
    if result_bytes is None:
        gaps.add("missing_result_bytes")
    if truncated_to is not None:
        gaps.add("truncated_output")
        if result_bytes is not None and truncated_to > result_bytes:
            raise RowError("truncated_to cannot exceed result_bytes")

    trace_id, keeper_turn_id = _runtime_identity(row, keeper)
    if trace_id is None or keeper_turn_id is None:
        gaps.add("missing_runtime_identity")

    execution_id = _optional_string(row, "execution_id")
    tool_use_id = _optional_string(row, "tool_use_id")
    if execution_id is None:
        gaps.add("missing_execution_id")
    if tool_use_id is None:
        gaps.add("missing_tool_use_id")

    descriptor_id = _descriptor(row, gaps)
    return Call(
        source=source,
        ts=ts,
        keeper=keeper,
        tool=tool,
        success=success,
        trace_id=trace_id,
        keeper_turn_id=keeper_turn_id,
        execution_id=execution_id,
        tool_use_id=tool_use_id,
        planned_index=_optional_nonnegative_int(row, "planned_index"),
        batch_index=_optional_nonnegative_int(row, "batch_index"),
        batch_size=_optional_nonnegative_int(row, "batch_size"),
        execution_mode=_optional_string(row, "execution_mode"),
        descriptor_id=descriptor_id,
        runtime_profile=_optional_string(row, "runtime_profile"),
        result_bytes=result_bytes,
        gaps=tuple(sorted(gaps)),
    )


def _load_json(line: str) -> dict[str, Any]:
    try:
        value = json.loads(
            line,
            parse_constant=lambda value: (_ for _ in ()).throw(
                ValueError(f"non-finite number {value}")
            ),
        )
    except (json.JSONDecodeError, ValueError) as exc:
        raise RowError(f"invalid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise RowError("row must be a JSON object")
    return value


def _ngram_report(
    turns: dict[tuple[str, str, int], list[Call]],
    size: int,
    *,
    include_evidence: bool,
) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, ...], NgramAggregate] = {}
    for turn_key in sorted(turns):
        calls = turns[turn_key]
        for start in range(0, len(calls) - size + 1):
            occurrence = tuple(calls[start : start + size])
            tools = tuple(call.tool for call in occurrence)
            aggregate = grouped.get(tools)
            if aggregate is None:
                aggregate = NgramAggregate(occurrences=[] if include_evidence else None)
                grouped[tools] = aggregate
            aggregate.occurrence_count += 1
            aggregate.keepers.add(turn_key[0])
            if any(not call.success for call in occurrence):
                aggregate.failure_count += 1
            if aggregate.occurrences is not None:
                aggregate.occurrences.append((turn_key, occurrence))

    report = []
    for tools in sorted(grouped):
        aggregate = grouped[tools]
        item: dict[str, Any] = {
            "tools": list(tools),
            "occurrence_count": aggregate.occurrence_count,
            "keeper_count": len(aggregate.keepers),
            "keepers": sorted(aggregate.keepers),
            "successful_occurrence_count": (
                aggregate.occurrence_count - aggregate.failure_count
            ),
            "failed_occurrence_count": aggregate.failure_count,
        }
        if aggregate.occurrences is not None:
            item["occurrences"] = [
                {
                    "turn": {
                        "keeper": turn_key[0],
                        "trace_id": turn_key[1],
                        "keeper_turn_id": turn_key[2],
                    },
                    "calls": [call.identity_json() for call in calls],
                }
                for turn_key, calls in aggregate.occurrences
            ]
        report.append(item)
    return report


def analyze(tool_calls_dir: Path, *, include_evidence: bool = False) -> dict[str, Any]:
    root = tool_calls_dir.resolve()
    if not root.is_dir():
        raise RowError(f"tool calls directory does not exist: {root}")
    files = sorted(path for path in root.rglob("*.jsonl") if path.is_file())

    calls: list[Call] = []
    rows_read = 0
    ignored_non_tool_records = 0
    excluded_composition_nodes = 0
    excluded_pre_schema_rows = 0
    pre_schema_rows: list[dict[str, Any]] | None = [] if include_evidence else None
    diagnostics: list[str] = []
    for path in files:
        relative = path.relative_to(root).as_posix()
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeError) as exc:
            diagnostics.append(f"{relative}: cannot read UTF-8 JSONL: {exc}")
            continue
        for line_number, line in enumerate(lines, start=1):
            rows_read += 1
            source = Source(relative, line_number)
            try:
                row = _load_json(line)
                kind = row.get("record_kind")
                if kind is None:
                    excluded_pre_schema_rows += 1
                    if pre_schema_rows is not None:
                        pre_schema_rows.append({"source": source.json()})
                    continue
                has_composition_run_id = "composition_run_id" in row
                call = _call_from_row(row, source)
                if call is None:
                    if kind == "tool_call" and has_composition_run_id:
                        excluded_composition_nodes += 1
                    else:
                        ignored_non_tool_records += 1
                else:
                    calls.append(call)
            except RowError as exc:
                diagnostics.append(f"{relative}:{line_number}: {exc}")
    if diagnostics:
        raise RowError("\n".join(diagnostics))

    turns: dict[tuple[str, str, int], list[Call]] = defaultdict(list)
    ungrouped_count = 0
    ungrouped: list[dict[str, Any]] | None = [] if include_evidence else None
    for call in calls:
        turn_key = call.turn_key
        if turn_key is None:
            ungrouped_count += 1
            if ungrouped is not None:
                ungrouped.append(
                    {
                        "source": call.source.json(),
                        "keeper": call.keeper,
                        "tool": call.tool,
                        "execution_id": call.execution_id,
                        "tool_use_id": call.tool_use_id,
                        "coverage_gaps": list(call.gaps),
                    }
                )
        else:
            turns[turn_key].append(call)

    for turn_calls in turns.values():
        turn_calls.sort(key=lambda call: (call.ts, call.source.file, call.source.line))

    gap_counts = Counter(gap for call in calls for gap in call.gaps)
    gap_counts["pre_schema_missing_record_kind"] += excluded_pre_schema_rows
    coverage_rows = None
    if include_evidence:
        coverage_rows = [
            {
                "source": call.source.json(),
                "keeper": call.keeper,
                "tool": call.tool,
                "execution_id": call.execution_id,
                "tool_use_id": call.tool_use_id,
                "gaps": list(call.gaps),
            }
            for call in calls
            if call.gaps
        ]
    pairs = _ngram_report(turns, 2, include_evidence=include_evidence)
    triplets = _ngram_report(turns, 3, include_evidence=include_evidence)
    report = {
        "schema": SCHEMA_VERSION,
        "source": {
            "tool_calls_dir": str(root),
            "files": [path.relative_to(root).as_posix() for path in files],
            "first_file": files[0].relative_to(root).as_posix() if files else None,
            "last_file": files[-1].relative_to(root).as_posix() if files else None,
        },
        "summary": {
            "files_read": len(files),
            "rows_read": rows_read,
            "selected_tool_calls": len(calls),
            "excluded_composition_nodes": excluded_composition_nodes,
            "excluded_pre_schema_rows": excluded_pre_schema_rows,
            "ignored_non_tool_records": ignored_non_tool_records,
            "grouped_tool_calls": sum(len(value) for value in turns.values()),
            "ungrouped_tool_calls": ungrouped_count,
            "turns": len(turns),
            "pair_occurrences": sum(item["occurrence_count"] for item in pairs),
            "triplet_occurrences": sum(item["occurrence_count"] for item in triplets),
            "coverage_gap_counts": dict(sorted(gap_counts.items())),
        },
        "evidence": {
            "included": include_evidence,
            "request_flag": "--include-evidence",
            "omitted": (
                []
                if include_evidence
                else [
                    "coverage_gaps",
                    "ungrouped_calls",
                    "pre_schema_rows",
                    "pairs[].occurrences",
                    "triplets[].occurrences",
                ]
            ),
        },
        "pairs": pairs,
        "triplets": triplets,
        "limits": [
            "No frequency threshold or candidate verdict is inferred.",
            "No JSON Pointer data-flow mapping is inferred from truncated, blob-only, opaque, or descriptor-less evidence.",
            "Lane-specific inline size eligibility is not inferred because tool-call rows do not carry the typed runtime execution owner.",
            "Skill visibility, N_u adoption, dry-run safety, and Skill publication are outside this read-only report.",
        ],
    }
    if include_evidence:
        report["coverage_gaps"] = coverage_rows
        report["ungrouped_calls"] = ungrouped
        report["pre_schema_rows"] = pre_schema_rows
    return report


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Mine adjacent pairs and triplets from MASC tool-call JSONL."
    )
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument(
        "--base-path",
        type=Path,
        help="workspace root whose logs are under <base-path>/.masc/tool_calls",
    )
    source.add_argument(
        "--tool-calls-dir", type=Path, help="explicit tool_calls directory"
    )
    parser.add_argument(
        "--include-evidence",
        action="store_true",
        help="include every occurrence and row identity; omitted by default",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    tool_calls_dir = (
        args.tool_calls_dir
        if args.tool_calls_dir is not None
        else args.base_path / ".masc" / "tool_calls"
    )
    try:
        report = analyze(tool_calls_dir, include_evidence=args.include_evidence)
    except RowError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    json.dump(report, sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
