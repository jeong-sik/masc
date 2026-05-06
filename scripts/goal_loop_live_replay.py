#!/usr/bin/env python3
"""Capture a bounded GOAL LOOP post-ACT log replay artifact.

This runner is intentionally a thin orchestrator over the existing phase tools:
Observe scans captured logs, Orient classifies findings, Decide maps ACT
coverage, Verify judges the post-ACT evidence, and Status writes the aggregate
snapshot. It does not claim a permanent fix; it only stores the replay evidence
needed to keep the loop moving.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import tempfile
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import decide_goal_loop_findings  # noqa: E402
import goal_loop_status  # noqa: E402
import observe_goal_loop_logs  # noqa: E402
import orient_goal_loop_logs  # noqa: E402
import verify_goal_loop_logs  # noqa: E402


VERIFY_EVIDENCE_KEYS = (
    "evidence_kind",
    "evidence_source",
    "evidence_window_start",
    "evidence_window_end",
    "checked_at",
)


@dataclass(frozen=True)
class ReplaySummary:
    artifact_dir: str
    overall_status: str
    verify_status: str
    captured_logs: list[str]
    observe_json: str
    orient_json: str
    decide_json: str
    verify_json: str
    status_json: str
    metadata_json: str
    dashboard_status_json: str | None


@dataclass(frozen=True)
class SourceSnapshot:
    inode: int
    size: int
    mtime_ns: int
    offset: int


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def write_json_atomic(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=path.parent,
        text=True,
    )
    temp_path = Path(temp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        temp_path.replace(path)
    finally:
        if temp_path.exists():
            temp_path.unlink()


def normalize_base_path(base_path: str | None) -> str | None:
    """Expand ``~`` so every downstream consumer (artifact metadata,
    evidence_source, dashboard status path) sees the same canonical form.

    Without this, ``--base-path ~/foo`` produced inconsistent artifacts:
    metadata.base_path / evidence_source kept the unexpanded ``~``, but
    dashboard_status_path_for_base_path expanded it for filesystem writes.
    """
    if base_path is None:
        return None
    stripped = base_path.strip()
    if not stripped:
        # Whitespace-only is treated the same as missing so the publish-mode
        # guard does not silently fall through and write
        # ./.masc/goal-loop/status.json relative to CWD.
        return None
    return str(Path(stripped).expanduser())


def dashboard_status_path_for_base_path(base_path: str) -> Path:
    return Path(base_path).expanduser() / ".masc" / "goal-loop" / "status.json"


def artifact_log_name(index: int, source: Path) -> str:
    name = source.name or f"log-{index}"
    return f"{index:02d}-{name}"


def source_snapshots(
    paths: list[Path], *, tail_only: bool
) -> dict[Path, SourceSnapshot]:
    snapshots: dict[Path, SourceSnapshot] = {}
    for path in paths:
        stat = path.stat()
        snapshots[path] = SourceSnapshot(
            inode=stat.st_ino,
            size=stat.st_size,
            mtime_ns=stat.st_mtime_ns,
            offset=stat.st_size if tail_only else 0,
        )
    return snapshots


def capture_offset_after_window(source: Path, snapshot: SourceSnapshot) -> int:
    current = source.stat()
    if current.st_ino != snapshot.inode:
        return 0
    if current.st_size < snapshot.size:
        return 0
    if current.st_size == snapshot.size and current.st_mtime_ns != snapshot.mtime_ns:
        return 0
    return snapshot.offset


def capture_log_window(
    log_paths: list[str],
    *,
    artifact_dir: Path,
    duration_seconds: float,
) -> list[str]:
    if not log_paths:
        raise ValueError("at least one --log path is required")
    sources = [Path(raw_path) for raw_path in log_paths]
    for source in sources:
        if not source.is_file():
            raise FileNotFoundError(f"log path is not a file: {source}")

    log_dir = artifact_dir / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    snapshots = source_snapshots(sources, tail_only=duration_seconds > 0)
    if duration_seconds > 0:
        time.sleep(duration_seconds)

    captured: list[str] = []
    for index, source in enumerate(sources, start=1):
        target = log_dir / artifact_log_name(index, source)
        if duration_seconds <= 0:
            shutil.copyfile(source, target)
        else:
            offset = capture_offset_after_window(source, snapshots[source])
            with source.open("rb") as input_handle:
                input_handle.seek(offset)
                target.write_bytes(input_handle.read())
        captured.append(str(target))
    return captured


def format_evidence_source(
    *,
    runtime_source: str,
    captured_logs: list[str],
    base_path: str | None,
) -> str:
    parts = [f"runtime_source={runtime_source}"]
    if base_path:
        parts.append(f"base_path={base_path}")
    parts.append("logs=" + ",".join(captured_logs))
    return ";".join(parts)


def status_summary_with_verify_metadata(
    status_json: dict[str, Any],
    verify_json: dict[str, Any],
) -> dict[str, Any]:
    phases = status_json.get("phases")
    if not isinstance(phases, dict):
        return status_json
    verify_phase = phases.get("verify")
    if not isinstance(verify_phase, dict):
        return status_json
    summary = verify_phase.get("summary")
    if not isinstance(summary, dict):
        summary = {}

    post_act_verify = verify_json.get("post_act_verify")
    if isinstance(post_act_verify, bool):
        summary["post_act_verify"] = post_act_verify

    violations = verify_json.get("violations")
    summary["violation_kinds"] = []
    if isinstance(violations, list):
        summary["violation_kinds"] = sorted(
            {
                str(kind)
                for violation in violations
                if isinstance(violation, dict)
                for kind in [violation.get("kind")]
                if isinstance(kind, str)
            }
        )

    for key in VERIFY_EVIDENCE_KEYS:
        value = verify_json.get(key)
        if isinstance(value, str) and value.strip():
            summary[key] = value.strip()

    verify_phase["summary"] = summary
    return status_json


def replay_logs(
    *,
    log_paths: list[str],
    artifact_dir: Path,
    duration_seconds: float,
    act_map_path: str | None,
    loop_iteration: str,
    verify_policy: str,
    max_samples: int,
    runtime_source: str,
    base_path: str | None,
    publish_dashboard_status: bool = False,
) -> ReplaySummary:
    # Normalize at the API boundary (not just in main()) so callers that go
    # through replay_logs directly — unit tests, downstream Python harnesses —
    # also see consistent base_path semantics. Strip whitespace before any
    # check so a base_path of "  " is treated as missing instead of writing
    # ./.masc/goal-loop/status.json relative to CWD.
    base_path = normalize_base_path(base_path)
    if publish_dashboard_status and not base_path:
        raise ValueError("--publish-dashboard-status requires --base-path")

    artifact_dir.mkdir(parents=True, exist_ok=True)
    max_samples_effective = max(max_samples, 0)
    window_start = utc_now_iso()
    captured_logs = capture_log_window(
        log_paths,
        artifact_dir=artifact_dir,
        duration_seconds=duration_seconds,
    )
    window_end = utc_now_iso()

    observe_report = observe_goal_loop_logs.scan_logs(
        captured_logs,
        max_samples=max_samples_effective,
    )
    observe_json = asdict(observe_report)

    orient_report = orient_goal_loop_logs.orient_scan(observe_json)
    orient_json = asdict(orient_report)

    act_map = (
        decide_goal_loop_findings.load_act_map_input(act_map_path)
        if act_map_path
        else None
    )
    decide_report = decide_goal_loop_findings.decide_orient(
        orient_json,
        act_map=act_map,
    )
    decide_json = asdict(decide_report)

    verify_report = verify_goal_loop_logs.verify_orient(
        orient_json,
        policy=verify_policy,
    )
    verify_json = asdict(verify_report)
    verify_json.update(
        {
            "post_act_verify": True,
            "evidence_kind": "live_runtime_logs",
            "evidence_source": format_evidence_source(
                runtime_source=runtime_source,
                captured_logs=captured_logs,
                base_path=base_path,
            ),
            "evidence_window_start": window_start,
            "evidence_window_end": window_end,
            "checked_at": utc_now_iso(),
        }
    )

    status_report = goal_loop_status.build_status_report(
        observe=observe_json,
        orient=orient_json,
        decide=decide_json,
        verify=verify_json,
        generated_at=verify_json["checked_at"],
        loop_iteration=loop_iteration,
    )
    status_json = asdict(status_report)
    status_json = status_summary_with_verify_metadata(status_json, verify_json)
    dashboard_status_json = (
        dashboard_status_path_for_base_path(base_path)
        if publish_dashboard_status and base_path
        else None
    )

    metadata = {
        "schema_version": 1,
        "generated_at": verify_json["checked_at"],
        "loop_iteration": loop_iteration,
        "source_logs": log_paths,
        "captured_logs": captured_logs,
        "runtime_source": runtime_source,
        "base_path": base_path,
        "duration_seconds": duration_seconds,
        "evidence_window_start": window_start,
        "evidence_window_end": window_end,
        "act_map_path": act_map_path,
        "verify_policy": verify_policy,
        "max_samples": max_samples_effective,
        "max_samples_requested": max_samples,
        "max_samples_effective": max_samples_effective,
        "dashboard_status_json": str(dashboard_status_json)
        if dashboard_status_json is not None
        else None,
    }

    paths = {
        "metadata_json": artifact_dir / "metadata.json",
        "observe_json": artifact_dir / "observe.json",
        "orient_json": artifact_dir / "orient.json",
        "decide_json": artifact_dir / "decide.json",
        "verify_json": artifact_dir / "verify.json",
        "status_json": artifact_dir / "status.json",
    }
    write_json(paths["metadata_json"], metadata)
    write_json(paths["observe_json"], observe_json)
    write_json(paths["orient_json"], orient_json)
    write_json(paths["decide_json"], decide_json)
    write_json(paths["verify_json"], verify_json)
    write_json(paths["status_json"], status_json)
    if dashboard_status_json is not None:
        write_json_atomic(dashboard_status_json, status_json)

    return ReplaySummary(
        artifact_dir=str(artifact_dir),
        overall_status=status_report.overall_status,
        verify_status=verify_report.status,
        captured_logs=captured_logs,
        observe_json=str(paths["observe_json"]),
        orient_json=str(paths["orient_json"]),
        decide_json=str(paths["decide_json"]),
        verify_json=str(paths["verify_json"]),
        status_json=str(paths["status_json"]),
        metadata_json=str(paths["metadata_json"]),
        dashboard_status_json=str(dashboard_status_json)
        if dashboard_status_json is not None
        else None,
    )


def summary_to_text(summary: ReplaySummary) -> str:
    lines = [
        f"GOAL LOOP Live Replay: {summary.overall_status}",
        f"verify_status: {summary.verify_status}",
        f"artifact_dir: {summary.artifact_dir}",
        f"captured_logs: {', '.join(summary.captured_logs)}",
        f"observe_json: {summary.observe_json}",
        f"orient_json: {summary.orient_json}",
        f"decide_json: {summary.decide_json}",
        f"verify_json: {summary.verify_json}",
        f"status_json: {summary.status_json}",
        f"metadata_json: {summary.metadata_json}",
    ]
    if summary.dashboard_status_json:
        lines.append(f"dashboard_status_json: {summary.dashboard_status_json}")
    return "\n".join(lines)


def should_fail(summary: ReplaySummary, mode: str) -> bool:
    if mode == "none":
        return False
    if mode == "verify":
        return summary.verify_status != "PASS"
    if mode == "critical":
        return summary.overall_status == "critical"
    raise ValueError(f"unknown fail mode: {mode}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--log",
        action="append",
        required=True,
        help="Runtime log file to replay. Repeat for multiple files.",
    )
    parser.add_argument(
        "--artifact-dir",
        required=True,
        help="Directory where replay JSON artifacts will be written.",
    )
    parser.add_argument(
        "--duration-seconds",
        type=float,
        default=0.0,
        help=(
            "Capture only bytes appended during this window. "
            "Use 0 to replay the current file contents."
        ),
    )
    parser.add_argument(
        "--act-map",
        help="Optional decision-to-PR artifact map JSON.",
    )
    parser.add_argument(
        "--runtime-source",
        default="local_runtime",
        help="Human-readable runtime source label stored in evidence metadata.",
    )
    parser.add_argument(
        "--base-path",
        help="Runtime base path associated with the captured logs.",
    )
    parser.add_argument(
        "--publish-dashboard-status",
        action="store_true",
        help=(
            "Also write status.json to <base-path>/.masc/goal-loop/status.json, "
            "which is the dashboard runtime status path."
        ),
    )
    parser.add_argument(
        "--loop-iteration",
        default="post-act-live",
        help="Loop iteration label stored in status.json.",
    )
    parser.add_argument(
        "--verify-policy",
        choices=("critical", "present"),
        default="critical",
        help="Post-ACT Orient verification policy.",
    )
    parser.add_argument(
        "--max-samples",
        type=int,
        default=3,
        help="Maximum sample lines retained per Observe pattern.",
    )
    parser.add_argument(
        "--format",
        choices=("json", "text"),
        default="json",
        help="Output format (default: json).",
    )
    parser.add_argument(
        "--fail-on",
        choices=("none", "verify", "critical"),
        default="verify",
        help="Exit non-zero when replay reaches this condition.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    summary = replay_logs(
        log_paths=list(args.log),
        artifact_dir=Path(args.artifact_dir),
        duration_seconds=max(args.duration_seconds, 0.0),
        act_map_path=args.act_map,
        loop_iteration=args.loop_iteration,
        verify_policy=args.verify_policy,
        max_samples=args.max_samples,
        runtime_source=args.runtime_source,
        # replay_logs normalizes base_path internally, so unit tests and
        # other Python callers get the same expansion + whitespace handling.
        base_path=args.base_path,
        publish_dashboard_status=args.publish_dashboard_status,
    )
    if args.format == "json":
        print(json.dumps(asdict(summary), ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print(summary_to_text(summary))
    return 1 if should_fail(summary, args.fail_on) else 0


if __name__ == "__main__":
    raise SystemExit(main())
