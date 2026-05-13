#!/usr/bin/env python3
"""Quantitative production-readiness gate for keeper turn evidence.

This script is read-only.  It aggregates persisted keeper runtime manifests and
checks the concrete evidence chain that a production promotion needs:
terminal turn, receipt, checkpoint, provider closure, event-bus correlation,
memory injection, optional tool-call log, and timestamp ordering.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import tempfile
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ERROR_STATUSES = {"error", "failed", "failure", "timeout", "cancelled", "canceled"}


@dataclass
class Thresholds:
    min_terminal_turns: int = 3
    min_success_turns: int = 3
    min_receipt_coverage_pct: float = 100.0
    min_checkpoint_coverage_pct: float = 100.0
    min_provider_closure_pct: float = 100.0
    min_event_bus_coverage_pct: float = 100.0
    min_memory_coverage_pct: float = 100.0
    min_tool_log_coverage_pct: float = 100.0
    min_timestamp_coverage_pct: float = 100.0
    max_missing_artifacts: int = 0
    max_order_violations: int = 0
    max_dangling_provider_attempts: int = 0
    max_evidence_span_sec: float = 600.0


@dataclass
class ReadinessMetrics:
    manifest_files: int = 0
    manifest_rows: int = 0
    terminal_turns: int = 0
    success_turns: int = 0
    provider_turns: int = 0
    success_provider_turns: int = 0
    receipt_ok_turns: int = 0
    checkpoint_ok_turns: int = 0
    provider_closed_turns: int = 0
    event_bus_ok_turns: int = 0
    memory_ok_turns: int = 0
    tool_used_turns: int = 0
    tool_log_ok_turns: int = 0
    timestamp_rows: int = 0
    parseable_timestamp_rows: int = 0
    missing_artifacts: int = 0
    order_violations: int = 0
    dangling_provider_attempts: int = 0
    max_evidence_span_sec: float = 0.0


@dataclass
class ReadinessSummary:
    status: str
    base_path: str
    keepers: list[str]
    thresholds: dict[str, Any]
    metrics: dict[str, Any]
    derived: dict[str, float]
    failures: list[str]


def iter_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line_no, line in enumerate(handle, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"{path}:{line_no}: {exc}") from exc
            if isinstance(row, dict):
                row["_source_path"] = str(path)
                rows.append(row)
    return rows


def parse_ts(value: Any) -> float | None:
    if not isinstance(value, str) or not value:
        return None
    text = value
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.timestamp()


def pct(num: int, den: int) -> float:
    if den <= 0:
        return 100.0
    return round((num / den) * 100.0, 4)


def path_from_link(base_path: Path, value: Any) -> Path | None:
    if not isinstance(value, str) or not value:
        return None
    path = Path(value)
    if path.is_absolute():
        return path
    return base_path / value


def event_rows(rows: list[dict[str, Any]], event: str) -> list[dict[str, Any]]:
    return [row for row in rows if row.get("event") == event]


def final_status(rows: list[dict[str, Any]]) -> str:
    finished = event_rows(rows, "turn_finished")
    if not finished:
        return "missing"
    status = finished[-1].get("status")
    return str(status or "unknown").lower()


def linked_artifact_ok(base_path: Path, rows: list[dict[str, Any]], event: str, link_key: str) -> bool:
    for row in reversed(event_rows(rows, event)):
        links = row.get("links")
        if not isinstance(links, dict):
            continue
        path = path_from_link(base_path, links.get(link_key))
        if path is not None and path.is_file():
            return True
    return False


def receipt_tools_used(base_path: Path, rows: list[dict[str, Any]]) -> int:
    for row in reversed(event_rows(rows, "receipt_appended")):
        links = row.get("links")
        if not isinstance(links, dict):
            continue
        path = path_from_link(base_path, links.get("receipt_path"))
        if path is None or not path.is_file():
            continue
        count = 0
        for receipt_row in iter_jsonl(path):
            tools = receipt_row.get("tools_used")
            if isinstance(tools, list):
                count += len(tools)
        return count
    return 0


def timestamps_for_rows(rows: list[dict[str, Any]]) -> list[float | None]:
    return [parse_ts(row.get("ts")) for row in rows if "ts" in row]


def check_timestamp_order(rows: list[dict[str, Any]]) -> tuple[int, float]:
    parsed = timestamps_for_rows(rows)
    ordered = [ts for ts in parsed if ts is not None]
    violations = 0
    for prev, current in zip(ordered, ordered[1:]):
        if current < prev:
            violations += 1

    if ordered:
        terminal = event_rows(rows, "turn_finished")
        terminal_ts = parse_ts(terminal[-1].get("ts")) if terminal else None
        if terminal_ts is not None:
            for event in ("checkpoint_saved", "receipt_appended", "event_bus_correlated", "memory_injected"):
                for row in event_rows(rows, event):
                    ts = parse_ts(row.get("ts"))
                    if ts is not None and ts > terminal_ts:
                        violations += 1
            started = [parse_ts(row.get("ts")) for row in event_rows(rows, "provider_attempt_started")]
            finished = [parse_ts(row.get("ts")) for row in event_rows(rows, "provider_attempt_finished")]
            if started and finished:
                max_started = max(ts for ts in started if ts is not None) if any(ts is not None for ts in started) else None
                max_finished = max(ts for ts in finished if ts is not None) if any(ts is not None for ts in finished) else None
                if max_started is not None and max_finished is not None and max_started > max_finished:
                    violations += 1
        return violations, max(ordered) - min(ordered)
    return violations, 0.0


def discover_manifest_files(base_path: Path, keepers: list[str], trace_ids: list[str], max_traces_per_keeper: int) -> list[Path]:
    root = base_path / ".masc" / "keepers"
    if keepers:
        keeper_dirs = [root / keeper for keeper in keepers]
    else:
        keeper_dirs = [path for path in root.iterdir() if path.is_dir()] if root.is_dir() else []

    manifests: list[Path] = []
    wanted_traces = set(trace_ids)
    for keeper_dir in keeper_dirs:
        manifest_dir = keeper_dir / "runtime-manifests"
        if not manifest_dir.is_dir():
            continue
        candidates = sorted(
            manifest_dir.glob("*.jsonl"),
            key=lambda path: path.stat().st_mtime,
            reverse=True,
        )
        if wanted_traces:
            candidates = [path for path in candidates if path.stem in wanted_traces]
        manifests.extend(candidates[:max_traces_per_keeper])
    return manifests


def evaluate(
    *,
    base_path: Path,
    keepers: list[str],
    trace_ids: list[str],
    max_traces_per_keeper: int,
    thresholds: Thresholds,
) -> ReadinessSummary:
    metrics = ReadinessMetrics()
    rows_by_turn: dict[tuple[str, str, int], list[dict[str, Any]]] = {}
    manifest_files = discover_manifest_files(base_path, keepers, trace_ids, max_traces_per_keeper)
    metrics.manifest_files = len(manifest_files)

    discovered_keepers: set[str] = set()
    for manifest in manifest_files:
        for row in iter_jsonl(manifest):
            metrics.manifest_rows += 1
            if "ts" in row:
                metrics.timestamp_rows += 1
                if parse_ts(row.get("ts")) is not None:
                    metrics.parseable_timestamp_rows += 1
            keeper = str(row.get("keeper_name") or manifest.parent.parent.name)
            trace = str(row.get("trace_id") or manifest.stem)
            turn = row.get("keeper_turn_id")
            if not isinstance(turn, int):
                continue
            discovered_keepers.add(keeper)
            rows_by_turn.setdefault((keeper, trace, turn), []).append(row)

    for (_keeper, _trace, _turn), rows in rows_by_turn.items():
        if not event_rows(rows, "turn_finished"):
            continue
        metrics.terminal_turns += 1
        status = final_status(rows)
        success = status not in ERROR_STATUSES
        if success:
            metrics.success_turns += 1

        provider = bool(
            event_rows(rows, "provider_lane_resolved")
            or event_rows(rows, "provider_attempt_started")
            or event_rows(rows, "provider_attempt_finished")
        )
        if provider:
            metrics.provider_turns += 1
            if success:
                metrics.success_provider_turns += 1

        started_count = len(event_rows(rows, "provider_attempt_started"))
        finished_count = len(event_rows(rows, "provider_attempt_finished"))
        if provider and finished_count >= started_count:
            metrics.provider_closed_turns += 1
        if provider and finished_count < started_count:
            metrics.dangling_provider_attempts += started_count - finished_count

        if linked_artifact_ok(base_path, rows, "receipt_appended", "receipt_path"):
            metrics.receipt_ok_turns += 1
        else:
            metrics.missing_artifacts += 1

        checkpoint_required = provider and success
        if checkpoint_required:
            if linked_artifact_ok(base_path, rows, "checkpoint_saved", "checkpoint_path"):
                metrics.checkpoint_ok_turns += 1
            else:
                metrics.missing_artifacts += 1

        if provider and success and event_rows(rows, "event_bus_correlated"):
            metrics.event_bus_ok_turns += 1
        if provider and success and event_rows(rows, "memory_injected"):
            metrics.memory_ok_turns += 1

        tools_used = receipt_tools_used(base_path, rows)
        if tools_used > 0:
            metrics.tool_used_turns += 1
            if linked_artifact_ok(base_path, rows, "turn_finished", "tool_call_log_path"):
                metrics.tool_log_ok_turns += 1
            else:
                metrics.missing_artifacts += 1

        order_violations, evidence_span = check_timestamp_order(rows)
        metrics.order_violations += order_violations
        metrics.max_evidence_span_sec = max(metrics.max_evidence_span_sec, evidence_span)

    derived = {
        "receipt_coverage_pct": pct(metrics.receipt_ok_turns, metrics.terminal_turns),
        "checkpoint_coverage_pct": pct(metrics.checkpoint_ok_turns, metrics.success_provider_turns),
        "provider_closure_pct": pct(metrics.provider_closed_turns, metrics.provider_turns),
        "event_bus_coverage_pct": pct(metrics.event_bus_ok_turns, metrics.success_provider_turns),
        "memory_coverage_pct": pct(metrics.memory_ok_turns, metrics.success_provider_turns),
        "tool_log_coverage_pct": pct(metrics.tool_log_ok_turns, metrics.tool_used_turns),
        "timestamp_coverage_pct": pct(metrics.parseable_timestamp_rows, metrics.timestamp_rows),
    }

    failures: list[str] = []
    if metrics.terminal_turns < thresholds.min_terminal_turns:
        failures.append(f"terminal_turns {metrics.terminal_turns} < {thresholds.min_terminal_turns}")
    if metrics.success_turns < thresholds.min_success_turns:
        failures.append(f"success_turns {metrics.success_turns} < {thresholds.min_success_turns}")
    if derived["receipt_coverage_pct"] < thresholds.min_receipt_coverage_pct:
        failures.append(
            f"receipt_coverage_pct {derived['receipt_coverage_pct']} < {thresholds.min_receipt_coverage_pct}"
        )
    if derived["checkpoint_coverage_pct"] < thresholds.min_checkpoint_coverage_pct:
        failures.append(
            f"checkpoint_coverage_pct {derived['checkpoint_coverage_pct']} < {thresholds.min_checkpoint_coverage_pct}"
        )
    if derived["provider_closure_pct"] < thresholds.min_provider_closure_pct:
        failures.append(
            f"provider_closure_pct {derived['provider_closure_pct']} < {thresholds.min_provider_closure_pct}"
        )
    if derived["event_bus_coverage_pct"] < thresholds.min_event_bus_coverage_pct:
        failures.append(
            f"event_bus_coverage_pct {derived['event_bus_coverage_pct']} < {thresholds.min_event_bus_coverage_pct}"
        )
    if derived["memory_coverage_pct"] < thresholds.min_memory_coverage_pct:
        failures.append(f"memory_coverage_pct {derived['memory_coverage_pct']} < {thresholds.min_memory_coverage_pct}")
    if derived["tool_log_coverage_pct"] < thresholds.min_tool_log_coverage_pct:
        failures.append(
            f"tool_log_coverage_pct {derived['tool_log_coverage_pct']} < {thresholds.min_tool_log_coverage_pct}"
        )
    if derived["timestamp_coverage_pct"] < thresholds.min_timestamp_coverage_pct:
        failures.append(
            f"timestamp_coverage_pct {derived['timestamp_coverage_pct']} < {thresholds.min_timestamp_coverage_pct}"
        )
    if metrics.missing_artifacts > thresholds.max_missing_artifacts:
        failures.append(f"missing_artifacts {metrics.missing_artifacts} > {thresholds.max_missing_artifacts}")
    if metrics.order_violations > thresholds.max_order_violations:
        failures.append(f"order_violations {metrics.order_violations} > {thresholds.max_order_violations}")
    if metrics.dangling_provider_attempts > thresholds.max_dangling_provider_attempts:
        failures.append(
            f"dangling_provider_attempts {metrics.dangling_provider_attempts} > {thresholds.max_dangling_provider_attempts}"
        )
    if metrics.max_evidence_span_sec > thresholds.max_evidence_span_sec:
        failures.append(
            f"max_evidence_span_sec {metrics.max_evidence_span_sec:.3f} > {thresholds.max_evidence_span_sec}"
        )

    return ReadinessSummary(
        status="PASS" if not failures else "FAIL",
        base_path=str(base_path),
        keepers=sorted(discovered_keepers),
        thresholds=asdict(thresholds),
        metrics=asdict(metrics),
        derived=derived,
        failures=failures,
    )


def write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True) + "\n")


def fixture_ts(turn: int, offset: int) -> str:
    return f"2026-05-13T00:{turn:02d}:{offset:02d}Z"


def write_fixture_turn(base_path: Path, keeper: str, trace: str, turn: int, *, tools: bool = False) -> None:
    keeper_dir = base_path / ".masc" / "keepers" / keeper
    manifest_path = keeper_dir / "runtime-manifests" / f"{trace}.jsonl"
    receipt_path = keeper_dir / "execution-receipts" / "2026-05" / f"{turn:02d}.jsonl"
    checkpoint_path = keeper_dir / "checkpoints" / f"turn-{turn}.json"
    tool_log_path = base_path / ".masc" / "tool_calls" / "2026-05" / f"{turn:02d}.jsonl"
    checkpoint_path.parent.mkdir(parents=True, exist_ok=True)
    checkpoint_path.write_text('{"ok":true}\n', encoding="utf-8")
    tools_used = ["keeper_tool_search"] if tools else []
    write_jsonl(
        receipt_path,
        [
            {
                "schema": "keeper.execution_receipt.v1",
                "keeper_name": keeper,
                "trace_id": trace,
                "turn_count": turn,
                "outcome": "success",
                "tools_used": tools_used,
            }
        ],
    )
    if tools:
        write_jsonl(
            tool_log_path,
            [{"keeper": keeper, "trace_id": trace, "tool": "keeper_tool_search", "success": True}],
        )

    base_row = {
        "schema_version": 1,
        "keeper_name": keeper,
        "trace_id": trace,
        "generation": 1,
        "keeper_turn_id": turn,
        "oas_turn_count": 1,
        "cascade_name": "fixture",
        "status": "ok",
        "decision": {},
        "links": {"receipt_path": None, "checkpoint_path": None, "tool_call_log_path": None},
    }
    rows = []
    for offset, event in enumerate(
        [
            "provider_lane_resolved",
            "provider_attempt_started",
            "provider_attempt_finished",
            "event_bus_correlated",
            "memory_injected",
            "checkpoint_saved",
            "receipt_appended",
            "turn_finished",
        ],
        start=1,
    ):
        row = dict(base_row)
        row["ts"] = fixture_ts(turn, offset)
        row["event"] = event
        if event == "checkpoint_saved":
            row["links"] = {"receipt_path": None, "checkpoint_path": str(checkpoint_path), "tool_call_log_path": None}
        elif event == "receipt_appended":
            row["links"] = {"receipt_path": str(receipt_path), "checkpoint_path": None, "tool_call_log_path": None}
        elif event == "turn_finished":
            row["status"] = "success"
            row["links"] = {
                "receipt_path": None,
                "checkpoint_path": None,
                "tool_call_log_path": str(tool_log_path) if tools else None,
            }
        rows.append(row)
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    with manifest_path.open("a", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True) + "\n")


def run_self_test() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        base_path = Path(tmp)
        keeper = "prod-readiness"
        trace = "trace-prod-readiness"
        for turn in range(1, 4):
            write_fixture_turn(base_path, keeper, trace, turn, tools=(turn == 2))
        summary = evaluate(
            base_path=base_path,
            keepers=[keeper],
            trace_ids=[trace],
            max_traces_per_keeper=5,
            thresholds=Thresholds(),
        )
        assert summary.status == "PASS", summary.failures

        checkpoint = base_path / ".masc" / "keepers" / keeper / "checkpoints" / "turn-1.json"
        checkpoint.unlink()
        broken = evaluate(
            base_path=base_path,
            keepers=[keeper],
            trace_ids=[trace],
            max_traces_per_keeper=5,
            thresholds=Thresholds(),
        )
        assert broken.status == "FAIL"
        assert any("missing_artifacts" in failure for failure in broken.failures)
    print("keeper-production-readiness-gate: self-test PASS")


def thresholds_from_args(args: argparse.Namespace) -> Thresholds:
    return Thresholds(
        min_terminal_turns=args.min_terminal_turns,
        min_success_turns=args.min_success_turns,
        min_receipt_coverage_pct=args.min_receipt_coverage_pct,
        min_checkpoint_coverage_pct=args.min_checkpoint_coverage_pct,
        min_provider_closure_pct=args.min_provider_closure_pct,
        min_event_bus_coverage_pct=args.min_event_bus_coverage_pct,
        min_memory_coverage_pct=args.min_memory_coverage_pct,
        min_tool_log_coverage_pct=args.min_tool_log_coverage_pct,
        min_timestamp_coverage_pct=args.min_timestamp_coverage_pct,
        max_missing_artifacts=args.max_missing_artifacts,
        max_order_violations=args.max_order_violations,
        max_dangling_provider_attempts=args.max_dangling_provider_attempts,
        max_evidence_span_sec=args.max_evidence_span_sec,
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-path", default=os.environ.get("MASC_BASE_PATH") or os.path.expanduser("~/me"))
    parser.add_argument("--keeper", action="append", default=[], help="Keeper name to scan. Repeatable.")
    parser.add_argument("--trace-id", action="append", default=[], help="Trace id to scan. Repeatable.")
    parser.add_argument("--max-traces-per-keeper", type=int, default=20)
    parser.add_argument("--json", action="store_true", help="Print machine-readable summary only.")
    parser.add_argument("--output", help="Optional JSON summary output path.")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--min-terminal-turns", type=int, default=3)
    parser.add_argument("--min-success-turns", type=int, default=3)
    parser.add_argument("--min-receipt-coverage-pct", type=float, default=100.0)
    parser.add_argument("--min-checkpoint-coverage-pct", type=float, default=100.0)
    parser.add_argument("--min-provider-closure-pct", type=float, default=100.0)
    parser.add_argument("--min-event-bus-coverage-pct", type=float, default=100.0)
    parser.add_argument("--min-memory-coverage-pct", type=float, default=100.0)
    parser.add_argument("--min-tool-log-coverage-pct", type=float, default=100.0)
    parser.add_argument("--min-timestamp-coverage-pct", type=float, default=100.0)
    parser.add_argument("--max-missing-artifacts", type=int, default=0)
    parser.add_argument("--max-order-violations", type=int, default=0)
    parser.add_argument("--max-dangling-provider-attempts", type=int, default=0)
    parser.add_argument("--max-evidence-span-sec", type=float, default=600.0)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.self_test:
        run_self_test()
        return 0

    thresholds = thresholds_from_args(args)
    summary = evaluate(
        base_path=Path(args.base_path).expanduser(),
        keepers=args.keeper,
        trace_ids=args.trace_id,
        max_traces_per_keeper=args.max_traces_per_keeper,
        thresholds=thresholds,
    )
    payload = asdict(summary)
    if args.output:
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(f"keeper-production-readiness-gate: {summary.status}")
        print(f"  base_path: {summary.base_path}")
        print(f"  keepers: {', '.join(summary.keepers) if summary.keepers else '<none>'}")
        for key, value in summary.metrics.items():
            if isinstance(value, float) and math.isfinite(value):
                print(f"  {key}: {value:.4f}")
            else:
                print(f"  {key}: {value}")
        for key, value in summary.derived.items():
            print(f"  {key}: {value:.4f}")
        if summary.failures:
            print("  failures:")
            for failure in summary.failures:
                print(f"    - {failure}")
    return 0 if summary.status == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
