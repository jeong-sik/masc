#!/usr/bin/env python3
"""Run GOAL LOOP phases on deterministic cadences.

The phase tools stay independent. This scheduler owns the runtime loop contract:
which phase is due, what command ran, whether it failed, and whether a failed
Verify result forces an immediate Observe re-entry.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


PHASE_ORDER = ("observe", "orient", "decide", "act", "verify")
DEFAULT_CADENCES = {
    "observe": 5,
    "orient": 60,
    "decide": 60 * 60,
    "act": 24 * 60 * 60,
    "verify": 5 * 60,
}
FAIL_STATUSES = {"FAIL", "ERROR"}


@dataclass(frozen=True)
class PhaseConfig:
    name: str
    cadence_seconds: int
    command: list[str]
    output_path: str | None = None
    timeout_seconds: int | None = None


@dataclass(frozen=True)
class DuePhase:
    name: str
    reason: str
    cadence_seconds: int
    next_due_at: str
    lateness_seconds: int


@dataclass
class PhaseExecution:
    phase: str
    status: str
    started_at: str
    completed_at: str
    duration_seconds: float
    exit_code: int | None
    reason: str
    output_path: str | None = None
    error: str | None = None


def utc_now() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


def iso_utc(value: datetime) -> str:
    return value.astimezone(timezone.utc).replace(microsecond=0).isoformat()


def parse_time(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def load_json_file(path: str | None) -> dict[str, Any]:
    if not path:
        return {}
    file_path = Path(path)
    if not file_path.exists():
        return {}
    with file_path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"expected JSON object: {path}")
    return data


def load_required_json_file(path: str) -> dict[str, Any]:
    file_path = Path(path)
    if not file_path.exists():
        raise FileNotFoundError(f"required JSON file not found: {path}")
    return load_json_file(path)


def write_json_file(path: str, data: dict[str, Any]) -> None:
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(
        json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def as_int(value: Any, default: int = 0) -> int:
    return value if isinstance(value, int) else default


def phase_configs(config: dict[str, Any]) -> dict[str, PhaseConfig]:
    raw_phases = config.get("phases", {})
    phases = raw_phases if isinstance(raw_phases, dict) else {}
    result: dict[str, PhaseConfig] = {}
    for name in PHASE_ORDER:
        raw = phases.get(name, {})
        phase = raw if isinstance(raw, dict) else {}
        command_raw = phase.get("command", [])
        command = (
            [str(item) for item in command_raw] if isinstance(command_raw, list) else []
        )
        cadence = as_int(phase.get("cadence_seconds"), DEFAULT_CADENCES[name])
        if cadence <= 0:
            raise ValueError(f"{name}.cadence_seconds must be positive")
        output_path = phase.get("output_path")
        timeout = phase.get("timeout_seconds")
        result[name] = PhaseConfig(
            name=name,
            cadence_seconds=cadence,
            command=command,
            output_path=output_path if isinstance(output_path, str) else None,
            timeout_seconds=timeout
            if isinstance(timeout, int) and timeout > 0
            else None,
        )
    return result


def empty_phase_state(config: PhaseConfig, now: datetime) -> dict[str, Any]:
    return {
        "cadence_seconds": config.cadence_seconds,
        "last_started_at": None,
        "last_completed_at": None,
        "last_status": "NEVER_RUN",
        "last_exit_code": None,
        "last_error": None,
        "last_duration_seconds": None,
        "next_due_at": iso_utc(now),
        "lateness_seconds": 0,
        "missed_deadline": False,
        "runs_total": 0,
        "consecutive_failures": 0,
    }


def normalize_state(
    state: dict[str, Any],
    configs: dict[str, PhaseConfig],
    now: datetime,
) -> dict[str, Any]:
    raw_phases = state.get("phases", {})
    phases = raw_phases if isinstance(raw_phases, dict) else {}
    normalized = {
        "schema_version": 1,
        "generated_at": iso_utc(now),
        "loop_iteration": str(state.get("loop_iteration", "unknown")),
        "overall_status": str(state.get("overall_status", "unknown")),
        "phases": {},
        "due_phases": [],
        "events": state.get("events", [])
        if isinstance(state.get("events"), list)
        else [],
    }
    for name, config in configs.items():
        existing = phases.get(name, {})
        phase = existing if isinstance(existing, dict) else {}
        merged = empty_phase_state(config, now)
        merged.update({key: value for key, value in phase.items() if key in merged})
        merged["cadence_seconds"] = config.cadence_seconds
        normalized["phases"][name] = merged
    return normalized


def increment_loop_iteration(value: Any) -> str:
    if isinstance(value, int) and value >= 0:
        return str(value + 1)
    if isinstance(value, str) and value.isdigit():
        return str(int(value) + 1)
    return "1"


def next_due_at(
    phase_state: dict[str, Any], cadence_seconds: int, now: datetime
) -> datetime:
    last_completed = parse_time(phase_state.get("last_completed_at"))
    if last_completed is None:
        return now
    return last_completed + timedelta(seconds=cadence_seconds)


def verify_failure_requires_observe(state: dict[str, Any]) -> bool:
    phases = state.get("phases", {})
    if not isinstance(phases, dict):
        return False
    verify = phases.get("verify", {})
    observe = phases.get("observe", {})
    if not isinstance(verify, dict) or not isinstance(observe, dict):
        return False
    if verify.get("last_status") not in FAIL_STATUSES:
        return False
    verify_completed = parse_time(verify.get("last_completed_at"))
    if verify_completed is None:
        return False
    observe_started = parse_time(observe.get("last_started_at"))
    return observe_started is None or observe_started <= verify_completed


def select_due_phases(
    state: dict[str, Any],
    configs: dict[str, PhaseConfig],
    now: datetime,
) -> list[DuePhase]:
    phases = state.get("phases", {})
    phase_states = phases if isinstance(phases, dict) else {}
    reenter_observe = verify_failure_requires_observe(state)
    due: list[DuePhase] = []
    for name in PHASE_ORDER:
        phase_state_raw = phase_states.get(name, {})
        phase_state = phase_state_raw if isinstance(phase_state_raw, dict) else {}
        config = configs[name]
        due_at = next_due_at(phase_state, config.cadence_seconds, now)
        lateness = max(int((now - due_at).total_seconds()), 0)
        last_completed = parse_time(phase_state.get("last_completed_at"))
        reason: str | None = None
        if name == "observe" and reenter_observe:
            reason = "verify_failed_reenter_observe"
        elif last_completed is None:
            reason = "never_run"
        elif now >= due_at:
            reason = "missed_deadline" if lateness > 0 else "cadence_due"
        if reason is not None:
            due.append(
                DuePhase(
                    name=name,
                    reason=reason,
                    cadence_seconds=config.cadence_seconds,
                    next_due_at=iso_utc(due_at),
                    lateness_seconds=lateness,
                )
            )
    return due


def infer_output_status(stdout: str, phase: str, exit_code: int) -> str:
    if exit_code != 0:
        return "ERROR"
    try:
        parsed = json.loads(stdout)
    except json.JSONDecodeError:
        return "ERROR"
    if not isinstance(parsed, dict):
        return "ERROR"
    status = parsed.get("status")
    if isinstance(status, str) and status.strip():
        return status.strip().upper()
    if phase == "verify":
        failing = parsed.get("failing_findings")
        if isinstance(failing, list) and failing:
            return "FAIL"
    return "PASS"


def run_phase(config: PhaseConfig, due: DuePhase, now: datetime) -> PhaseExecution:
    if not config.command:
        return PhaseExecution(
            phase=config.name,
            status="ERROR",
            started_at=iso_utc(now),
            completed_at=iso_utc(now),
            duration_seconds=0.0,
            exit_code=None,
            reason=due.reason,
            output_path=config.output_path,
            error="phase command is not configured",
        )
    started = now
    started_monotonic = time.monotonic()
    try:
        completed = subprocess.run(
            config.command,
            check=False,
            capture_output=True,
            text=True,
            timeout=config.timeout_seconds,
        )
        duration = round(time.monotonic() - started_monotonic, 3)
        ended = started + timedelta(seconds=duration)
        stdout = completed.stdout
        if config.output_path is not None:
            Path(config.output_path).parent.mkdir(parents=True, exist_ok=True)
            Path(config.output_path).write_text(stdout, encoding="utf-8")
        status = infer_output_status(stdout, config.name, completed.returncode)
        error = completed.stderr.strip() or None
        return PhaseExecution(
            phase=config.name,
            status=status,
            started_at=iso_utc(started),
            completed_at=iso_utc(ended),
            duration_seconds=duration,
            exit_code=completed.returncode,
            reason=due.reason,
            output_path=config.output_path,
            error=error,
        )
    except subprocess.TimeoutExpired as error:
        duration = round(time.monotonic() - started_monotonic, 3)
        ended = started + timedelta(seconds=duration)
        return PhaseExecution(
            phase=config.name,
            status="ERROR",
            started_at=iso_utc(started),
            completed_at=iso_utc(ended),
            duration_seconds=duration,
            exit_code=None,
            reason=due.reason,
            output_path=config.output_path,
            error=f"timeout after {error.timeout}s",
        )


def update_phase_state(
    state: dict[str, Any],
    config: PhaseConfig,
    due: DuePhase,
    execution: PhaseExecution | None,
    now: datetime,
) -> None:
    phase_state = state["phases"][config.name]
    phase_state["next_due_at"] = due.next_due_at
    phase_state["lateness_seconds"] = due.lateness_seconds
    phase_state["missed_deadline"] = due.reason == "missed_deadline"
    if execution is None:
        return
    phase_state["last_started_at"] = execution.started_at
    phase_state["last_completed_at"] = execution.completed_at
    phase_state["last_status"] = execution.status
    phase_state["last_exit_code"] = execution.exit_code
    phase_state["last_error"] = execution.error
    phase_state["last_duration_seconds"] = execution.duration_seconds
    phase_state["runs_total"] = as_int(phase_state.get("runs_total")) + 1
    if execution.status in FAIL_STATUSES:
        phase_state["consecutive_failures"] = (
            as_int(phase_state.get("consecutive_failures")) + 1
        )
    else:
        phase_state["consecutive_failures"] = 0
    phase_state["next_due_at"] = iso_utc(
        parse_time(execution.completed_at) + timedelta(seconds=config.cadence_seconds)
        if parse_time(execution.completed_at) is not None
        else now
    )


def overall_status(state: dict[str, Any]) -> str:
    phases = state.get("phases", {})
    if not isinstance(phases, dict):
        return "unknown"
    statuses = [
        phase.get("last_status")
        for phase in phases.values()
        if isinstance(phase, dict) and isinstance(phase.get("last_status"), str)
    ]
    if any(status == "ERROR" for status in statuses):
        return "critical"
    if any(status == "FAIL" for status in statuses):
        return "critical"
    if any(
        isinstance(phase, dict) and phase.get("missed_deadline") is True
        for phase in phases.values()
    ):
        return "warning"
    if any(status == "NEVER_RUN" for status in statuses):
        return "unknown"
    return "ok"


def scheduler_tick(
    *,
    config: dict[str, Any],
    state: dict[str, Any],
    now: datetime,
    dry_run: bool = False,
) -> dict[str, Any]:
    configs = phase_configs(config)
    next_state = normalize_state(state, configs, now)
    next_state["loop_iteration"] = increment_loop_iteration(state.get("loop_iteration"))
    due = select_due_phases(next_state, configs, now)
    next_state["due_phases"] = [asdict(item) for item in due]
    events = next_state["events"]
    for item in due:
        phase_config = configs[item.name]
        execution = None if dry_run else run_phase(phase_config, item, now)
        update_phase_state(next_state, phase_config, item, execution, now)
        event = {
            "phase": item.name,
            "reason": item.reason,
            "dry_run": dry_run,
            "scheduled_at": iso_utc(now),
            "lateness_seconds": item.lateness_seconds,
        }
        if execution is not None:
            event.update(asdict(execution))
        events.append(event)
    next_state["events"] = events[-200:]
    next_state["generated_at"] = iso_utc(now)
    next_state["overall_status"] = overall_status(next_state)
    return next_state


def seconds_until_next_due(state: dict[str, Any], now: datetime) -> int:
    if verify_failure_requires_observe(state):
        return 1
    phases = state.get("phases", {})
    if not isinstance(phases, dict):
        return DEFAULT_CADENCES["observe"]
    due_times = [
        parse_time(phase.get("next_due_at"))
        for phase in phases.values()
        if isinstance(phase, dict)
    ]
    valid = [item for item in due_times if item is not None]
    if not valid:
        return DEFAULT_CADENCES["observe"]
    return max(1, min(max(int((item - now).total_seconds()), 0) for item in valid))


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config", required=True, help="GOAL LOOP scheduler config JSON."
    )
    parser.add_argument("--state", required=True, help="Scheduler state JSON path.")
    parser.add_argument(
        "--status-out", help="Optional path for the emitted status JSON."
    )
    parser.add_argument(
        "--now", help="Override current UTC time for deterministic runs."
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Plan due phases without running commands.",
    )
    parser.add_argument(
        "--loop", action="store_true", help="Run continuously until interrupted."
    )
    parser.add_argument(
        "--sleep-seconds", type=int, default=0, help="Override loop sleep seconds."
    )
    parser.add_argument(
        "--format",
        choices=("json", "text"),
        default="json",
        help="Output format for each tick.",
    )
    return parser.parse_args(argv)


def state_to_text(state: dict[str, Any]) -> str:
    lines = [
        f"GOAL LOOP Scheduler: {state.get('overall_status', 'unknown')}",
        f"generated_at: {state.get('generated_at', 'unknown')}",
    ]
    for due in state.get("due_phases", []):
        if isinstance(due, dict):
            lines.append(
                "due: "
                f"{due.get('name', 'unknown')} "
                f"reason={due.get('reason', 'unknown')} "
                f"late={due.get('lateness_seconds', 0)}s"
            )
    return "\n".join(lines)


def emit_state(
    state: dict[str, Any], *, status_out: str | None, output_format: str
) -> None:
    if status_out:
        write_json_file(status_out, state)
    if output_format == "json":
        print(json.dumps(state, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print(state_to_text(state))


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    config = load_required_json_file(args.config)
    while True:
        now = parse_time(args.now) if args.now else utc_now()
        if now is None:
            raise ValueError(f"invalid --now: {args.now}")
        state = load_json_file(args.state)
        next_state = scheduler_tick(
            config=config,
            state=state,
            now=now,
            dry_run=args.dry_run,
        )
        write_json_file(args.state, next_state)
        emit_state(next_state, status_out=args.status_out, output_format=args.format)
        if not args.loop:
            return 1 if next_state.get("overall_status") == "critical" else 0
        sleep_seconds = args.sleep_seconds or seconds_until_next_due(
            next_state, utc_now()
        )
        time.sleep(max(sleep_seconds, 1))


if __name__ == "__main__":
    raise SystemExit(main())
