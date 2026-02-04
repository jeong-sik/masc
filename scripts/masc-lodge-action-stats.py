#!/usr/bin/env python3
"""Summarize Lodge decision/action stats from trace JSONL files."""

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


def load_entries(
    traces_dir: str,
    start_ts: float,
    end_ts: float,
    phase: str,
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
    parser = argparse.ArgumentParser(description="Lodge action/decision stats from traces")
    parser.add_argument("--days", type=int, default=1, help="Look back N days (default: 1)")
    parser.add_argument("--since", type=str, default=None, help="Start date (YYYY-MM-DD)")
    parser.add_argument("--until", type=str, default=None, help="End date (YYYY-MM-DD, inclusive)")
    parser.add_argument("--agent", type=str, default=None, help="Filter by agent name")
    parser.add_argument("--phase", type=str, default="decide_action", help="Trace phase to include")
    parser.add_argument("--format", type=str, default="text", choices=["text", "json"], help="Output format")
    args = parser.parse_args()

    me_root = os.environ.get("ME_ROOT", os.path.expanduser("~/me"))
    traces_dir = os.path.join(me_root, ".masc", "traces")

    start_ts, end_ts = ts_range_from_args(args.days, args.since, args.until)
    entries = load_entries(traces_dir, start_ts, end_ts, args.phase, args.agent)

    total = len(entries)
    action_counts: Dict[str, int] = {}
    by_agent: Dict[str, Dict[str, int]] = {}
    self_heartbeat = 0
    llm_counts: Dict[str, int] = {}

    for e in entries:
        action = normalize_action(str(e.get("action", "")))
        action_counts[action] = action_counts.get(action, 0) + 1

        agent = str(e.get("agent_name", "unknown"))
        by_agent.setdefault(agent, {})
        by_agent[agent][action] = by_agent[agent].get(action, 0) + 1

        prompt = str(e.get("prompt", ""))
        if "self-heartbeat continuation" in prompt:
            self_heartbeat += 1

        llm = str(e.get("llm_used", ""))
        if llm:
            llm_counts[llm] = llm_counts.get(llm, 0) + 1

    acted = total - action_counts.get("SKIP", 0)

    if args.format == "json":
        out = {
            "total": total,
            "acted": acted,
            "acted_rate": (acted / total) if total else 0.0,
            "action_counts": action_counts,
            "self_heartbeat_decisions": self_heartbeat,
            "llm_counts": llm_counts,
            "by_agent": by_agent,
        }
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return 0

    start_s = dt.datetime.fromtimestamp(start_ts).strftime("%Y-%m-%d %H:%M")
    end_s = dt.datetime.fromtimestamp(end_ts).strftime("%Y-%m-%d %H:%M")

    print("Lodge Decision Stats")
    print(f"Period: {start_s} ~ {end_s}")
    if args.agent:
        print(f"Agent: {args.agent}")
    print(f"Total decisions: {total}")
    print(f"Acted: {acted} ({pct(acted, total)})")
    print("Action breakdown:")
    for k in sorted(action_counts.keys()):
        print(f"- {k}: {action_counts[k]} ({pct(action_counts[k], total)})")
    print(f"Self-heartbeat decisions: {self_heartbeat} ({pct(self_heartbeat, total)})")

    if llm_counts:
        print("LLM usage:")
        for k in sorted(llm_counts.keys()):
            print(f"- {k}: {llm_counts[k]} ({pct(llm_counts[k], total)})")

    if len(by_agent) > 0 and not args.agent:
        print("Per-agent acted rate:")
        for agent in sorted(by_agent.keys()):
            a_total = sum(by_agent[agent].values())
            a_acted = a_total - by_agent[agent].get("SKIP", 0)
            print(f"- {agent}: {a_acted}/{a_total} ({pct(a_acted, a_total)})")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
