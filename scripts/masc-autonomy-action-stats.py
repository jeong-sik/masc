#!/usr/bin/env python3
"""Summarize Autonomy decision/action stats from trace JSONL files."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from typing import Dict, Iterable, List, Tuple


def parse_date(s: str) -> dt.datetime:
    return dt.datetime.strptime(s, "%Y-%m-%d")


def ts_range_from_args(days: int | None, since: str | None, until: str | None) -> Tuple[float, float]:
    now = dt.datetime.now()
    if since:
        start = parse_date(since)
    elif days is not None:
        start = now - dt.timedelta(days=days)
    else:
        start = now - dt.timedelta(days=1)

    if until:
        end = parse_date(until) + dt.timedelta(days=1)
    else:
        end = now

    return start.timestamp(), end.timestamp()


def iter_trace_files(traces_dir: str) -> Iterable[str]:
    if not os.path.isdir(traces_dir):
        return []
    files: List[str] = []
    for agent in os.listdir(traces_dir):
        agent_dir = os.path.join(traces_dir, agent)
        if not os.path.isdir(agent_dir):
            continue
        for name in os.listdir(agent_dir):
            if name.endswith(".jsonl"):
                files.append(os.path.join(agent_dir, name))
    return files


def normalize_action(action: str) -> str:
    if not action:
        return "UNKNOWN"
    base = action.split(":", 1)[0].strip().upper()
    return base or "UNKNOWN"


def system_reason(action: str) -> str:
    if not action:
        return "unknown"
    parts = action.split(":", 1)
    if len(parts) == 2:
        return parts[1].strip().lower() or "unknown"
    return "unknown"


def load_entries(
    traces_dir: str,
    start_ts: float,
    end_ts: float,
    phase: str | None,
    agent_filter: str | None,
) -> List[dict]:
    entries: List[dict] = []
    for path in iter_trace_files(traces_dir):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        entry = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    ts = float(entry.get("timestamp", 0))
                    if ts < start_ts or ts > end_ts:
                        continue
                    if phase and entry.get("phase") != phase:
                        continue
                    if agent_filter and entry.get("agent_name") != agent_filter:
                        continue
                    entries.append(entry)
        except OSError:
            continue
    return entries


def pct(n: int, d: int) -> str:
    if d == 0:
        return "0.0%"
    return f"{(n / d) * 100:.1f}%"


def main() -> int:
    parser = argparse.ArgumentParser(description="Autonomy action/decision stats from traces")
    parser.add_argument("--days", type=int, default=1, help="Look back N days (default: 1)")
    parser.add_argument("--since", type=str, default=None, help="Start date (YYYY-MM-DD)")
    parser.add_argument("--until", type=str, default=None, help="End date (YYYY-MM-DD, inclusive)")
    parser.add_argument("--agent", type=str, default=None, help="Filter by agent name")
    parser.add_argument(
        "--phase",
        type=str,
        default="all",
        choices=["all", "decide_action", "system_skip"],
        help="Trace phase to include (default: all)",
    )
    parser.add_argument("--format", type=str, default="text", choices=["text", "json"], help="Output format")
    args = parser.parse_args()

    base_path = (os.environ.get("MASC_BASE_PATH") or os.path.expanduser("~")).strip()
    traces_dir = os.path.join(base_path, ".masc", "traces")

    start_ts, end_ts = ts_range_from_args(args.days, args.since, args.until)

    if args.phase == "decide_action":
        decide_entries = load_entries(traces_dir, start_ts, end_ts, "decide_action", args.agent)
        system_entries: List[dict] = []
    elif args.phase == "system_skip":
        decide_entries = []
        system_entries = load_entries(traces_dir, start_ts, end_ts, "system_skip", args.agent)
    else:
        decide_entries = load_entries(traces_dir, start_ts, end_ts, "decide_action", args.agent)
        system_entries = load_entries(traces_dir, start_ts, end_ts, "system_skip", args.agent)

    decisions_total = len(decide_entries)
    action_counts: Dict[str, int] = {}
    by_agent: Dict[str, Dict[str, int]] = {}
    self_heartbeat = 0
    model_counts: Dict[str, int] = {}

    for e in decide_entries:
        action = normalize_action(str(e.get("action", "")))
        action_counts[action] = action_counts.get(action, 0) + 1

        agent = str(e.get("agent_name", "unknown"))
        by_agent.setdefault(agent, {})
        by_agent[agent][action] = by_agent[agent].get(action, 0) + 1

        prompt = str(e.get("prompt", ""))
        if "self-heartbeat continuation" in prompt:
            self_heartbeat += 1

        model_name = str(e.get("model_used", ""))
        if model_name:
            model_counts[model_name] = model_counts.get(model_name, 0) + 1

    model_skips = action_counts.get("SKIP", 0)
    acted = decisions_total - model_skips

    system_skip_total = len(system_entries)
    system_skip_reasons: Dict[str, int] = {}
    for e in system_entries:
        reason = system_reason(str(e.get("action", "")))
        system_skip_reasons[reason] = system_skip_reasons.get(reason, 0) + 1

    events_total = decisions_total + system_skip_total

    if args.format == "json":
        out = {
            "events_total": events_total,
            "decisions_total": decisions_total,
            "acted": acted,
            "acted_rate": (acted / decisions_total) if decisions_total else 0.0,
            "model_skips": model_skips,
            "system_skips": system_skip_total,
            "system_skip_reasons": system_skip_reasons,
            "action_counts": action_counts,
            "self_heartbeat_decisions": self_heartbeat,
            "model_counts": model_counts,
            "by_agent": by_agent,
        }
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return 0

    start_s = dt.datetime.fromtimestamp(start_ts).strftime("%Y-%m-%d %H:%M")
    end_s = dt.datetime.fromtimestamp(end_ts).strftime("%Y-%m-%d %H:%M")

    print("Autonomy Decision Stats")
    print(f"Period: {start_s} ~ {end_s}")
    if args.agent:
        print(f"Agent: {args.agent}")
    print(f"Decisions (MODEL): {decisions_total}")
    print(f"Acted: {acted} ({pct(acted, decisions_total)})")
    print(f"MODEL skip: {model_skips} ({pct(model_skips, decisions_total)})")
    print(f"System skip: {system_skip_total} ({pct(system_skip_total, max(events_total, 1))})")
    if system_skip_reasons:
        print("System skip breakdown:")
        for k in sorted(system_skip_reasons.keys()):
            print(f"- {k}: {system_skip_reasons[k]}")

    if decisions_total > 0:
        print("Action breakdown:")
        for k in sorted(action_counts.keys()):
            print(f"- {k}: {action_counts[k]} ({pct(action_counts[k], decisions_total)})")
    print(f"Self-heartbeat decisions: {self_heartbeat} ({pct(self_heartbeat, decisions_total)})")

    if model_counts:
        print("MODEL usage:")
        for k in sorted(model_counts.keys()):
            print(f"- {k}: {model_counts[k]} ({pct(model_counts[k], decisions_total)})")

    if len(by_agent) > 0 and not args.agent and decisions_total > 0:
        print("Per-agent acted rate:")
        for agent in sorted(by_agent.keys()):
            a_total = sum(by_agent[agent].values())
            a_acted = a_total - by_agent[agent].get("SKIP", 0)
            print(f"- {agent}: {a_acted}/{a_total} ({pct(a_acted, a_total)})")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
