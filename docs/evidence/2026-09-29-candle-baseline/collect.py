#!/usr/bin/env python3
"""Candle 을 켜기 전 keeper 행동의 기준선.

`<base>/.masc` 의 Goal, Goal 이벤트, Task, Task 와 Goal 의 연결을 읽어 집계만 JSON 으로 낸다.
제목, 설명, 본문은 내지 않는다. 아무것도 쓰지 않는다.

    python3 collect.py --base <MASC_BASE_PATH>

같은 명령을 Candle 을 켠 뒤에도 돌려서 두 결과를 비교한다(RFC-goal-candle-ledger 3.11).
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# 이 표본 크기 미만인 만든 사람은 위임 통계에서 뺀다.
MIN_CREATED_DONE_FOR_DELEGATION = 10


def read_json(path: Path) -> Any:
    if not path.is_file():
        sys.exit(f"missing input: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        sys.exit(f"missing input: {path}")
    rows: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            rows.append(json.loads(line))
    return rows


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def is_date_only(value: str) -> bool:
    return len(value) == 10 and value[4] == "-" and value[7] == "-"


def goal_summary(goals: list[dict[str, Any]]) -> dict[str, Any]:
    created = sorted(parse_time(g["created_at"]) for g in goals)
    due = [g["due_date"] for g in goals if g.get("due_date")]
    return {
        "total": len(goals),
        "by_phase": dict(Counter(g["phase"] for g in goals)),
        "with_due_date": len(due),
        "due_date_is_date_only": sum(1 for d in due if is_date_only(d)),
        "owner_known": sum(1 for g in goals if g.get("owner") not in (None, "", "unknown")),
        "first_created": created[0].isoformat() if created else None,
    }


def goal_event_summary(events: list[dict[str, Any]]) -> dict[str, Any]:
    drops = Counter(
        e["payload"].get("actor", "?")
        for e in events
        if e["event_type"] == "goal_phase" and e["payload"].get("phase") == "dropped"
    )
    by_goal: dict[str, dict[str, datetime]] = {}
    for e in events:
        if e["event_type"] != "goal_phase":
            continue
        phase = e["payload"].get("phase")
        if phase in ("awaiting_confirmation", "completed"):
            by_goal.setdefault(e["goal_id"], {})[phase] = parse_time(e["ts"])
    waits = [
        (p["completed"] - p["awaiting_confirmation"]).total_seconds() / 3600
        for p in by_goal.values()
        if "completed" in p and "awaiting_confirmation" in p and p["completed"] >= p["awaiting_confirmation"]
    ]
    return {
        "by_type": dict(Counter(e["event_type"] for e in events)),
        "dropped_by_actor": dict(drops),
        "verify_to_confirm_hours": {
            "n": len(waits),
            "min": round(min(waits), 2) if waits else None,
            "median": round(statistics.median(waits), 2) if waits else None,
            "max": round(max(waits), 2) if waits else None,
        },
    }


def task_summary(tasks: list[dict[str, Any]], links: list[dict[str, Any]]) -> dict[str, Any]:
    done = [t for t in tasks if t["status"] == "done"]
    self_done = sum(1 for t in done if t.get("created_by") == t.get("assignee"))
    created_done = Counter(t.get("created_by") for t in done)
    delegation: dict[str, dict[str, int]] = {}
    for creator, n in created_done.items():
        if creator is None or n < MIN_CREATED_DONE_FOR_DELEGATION:
            continue
        mine = [t for t in done if t.get("created_by") == creator]
        delegation[creator] = {
            "created_and_done": len(mine),
            "done_by_others": sum(1 for t in mine if t.get("assignee") != creator),
        }
    linked_ids = {i for link in links for i in link["task_ids"]}
    return {
        "total": len(tasks),
        "by_status": dict(Counter(t["status"] for t in tasks)),
        "linked_to_a_goal": len(linked_ids),
        "goals_with_a_link": len(links),
        "done_total": len(done),
        "done_created_by_the_assignee": self_done,
        "done_created_by_the_assignee_share": round(self_done / len(done), 3) if done else None,
        "delegation": delegation,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Candle 을 켜기 전 keeper 행동의 기준선을 집계한다.")
    parser.add_argument("--base", required=True, help="MASC base path (the directory that holds .masc)")
    args = parser.parse_args()
    masc = Path(args.base).expanduser() / ".masc"
    goals: list[dict[str, Any]] = read_json(masc / "goals.json")["goals"]
    events = read_jsonl(masc / "goal_events.jsonl")
    tasks: list[dict[str, Any]] = read_json(masc / "tasks" / "backlog.json")["tasks"]
    links: list[dict[str, Any]] = read_json(masc / "tasks" / "goal_task_links.json")["links"]
    out = {
        "as_of": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "goals": goal_summary(goals),
        "goal_events": goal_event_summary(events),
        "tasks": task_summary(tasks, links),
    }
    json.dump(out, sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
