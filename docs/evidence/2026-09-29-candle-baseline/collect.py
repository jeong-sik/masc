#!/usr/bin/env python3
"""Candle 을 켜기 전 keeper 행동의 기준선.

`<base>/.masc` 의 Goal, Goal 이벤트, Task(backlog 와 GC 가 옮긴 `tasks-archive.json`),
Task 와 Goal 의 연결을 읽어 집계만 JSON 으로 낸다. 담당자가 keeper 인지는 keeper 설정 폴더에
`<이름>.toml` 이 있는지로 본다. 제목, 설명, 본문은 내지 않는다. 아무것도 쓰지 않는다.

    python3 collect.py --base <MASC_BASE_PATH> [--keepers-dir <DIR>]

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


def read_archived_tasks(path: Path) -> list[dict[str, Any]]:
    """GC 가 옮긴 끝난 Task. 파일이 없으면 옮긴 적이 없는 것이라 빈 목록이다."""
    if not path.is_file():
        return []
    doc = json.loads(path.read_text(encoding="utf-8"))
    tasks = doc.get("tasks") if isinstance(doc, dict) else None
    if not isinstance(tasks, list):
        sys.exit(f'unexpected shape (want {{"tasks": [...]}}): {path}')
    return tasks


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def is_date_only(value: str) -> bool:
    return len(value) == 10 and value[4] == "-" and value[7] == "-"


def goal_summary(goals: list[dict[str, Any]]) -> dict[str, Any]:
    created = sorted(parse_time(g["created_at"]) for g in goals)
    due = [g["due_date"] for g in goals if g.get("due_date")]
    # 날짜만 있는 기한은 그날 UTC 23:59:59 로 읽는다(RFC 3.3).
    windows = [
        (parse_time(g["due_date"] + "T23:59:59Z") - parse_time(g["created_at"])).total_seconds() / 3600
        for g in goals
        if g.get("due_date") and is_date_only(g["due_date"])
    ]
    return {
        "total": len(goals),
        "by_phase": dict(Counter(g["phase"] for g in goals)),
        "with_due_date": len(due),
        "due_date_is_date_only": sum(1 for d in due if is_date_only(d)),
        "hours_from_created_to_due": {
            "n": len(windows),
            "min": round(min(windows), 2) if windows else None,
            "median": round(statistics.median(windows), 2) if windows else None,
            "max": round(max(windows), 2) if windows else None,
        },
        "first_created": created[0].isoformat() if created else None,
    }


def goal_edit_summary(events: list[dict[str, Any]]) -> dict[str, Any]:
    """Count recorded field changes, which carry their own before/after values.

    goal_updated contains an after-snapshot. Its append can follow a later
    edit's append, so adjacent snapshots cannot establish a change or actor.
    """
    changes: dict[str, Counter[str]] = {"due_date": Counter(), "priority": Counter()}
    recorded_events = 0
    for event in events:
        if event["event_type"] != "goal_edited":
            continue
        payload = event["payload"]
        if not isinstance(payload, dict):
            raise ValueError("goal_edited payload must be an object")
        actor = payload.get("actor")
        if not isinstance(actor, str) or not actor.strip():
            raise ValueError("goal_edited requires a nonempty actor")
        fields = set(payload) - {"actor"}
        if not fields or fields - changes.keys():
            raise ValueError("goal_edited requires due_date or priority changes only")
        for field in fields:
            change = payload[field]
            if not isinstance(change, dict) or set(change) != {"from", "to"}:
                raise ValueError(f"goal_edited {field} requires from and to")
            before, after = change["from"], change["to"]
            values = (before, after)
            if field == "due_date":
                valid = all(value is None or isinstance(value, str) for value in values)
            else:
                valid = all(type(value) is int for value in values)
            if not valid or before == after:
                raise ValueError(f"goal_edited {field} must contain distinct typed values")
            changes[field][actor] += 1
        recorded_events += 1
    return {
        "source_event_type": "goal_edited",
        "coverage": "recorded_changes_only" if recorded_events else "not_observed",
        "recorded_events": recorded_events,
        **{
            field: {"changes": sum(by_actor.values()), "by_actor": dict(by_actor)}
            for field, by_actor in changes.items()
        },
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
        "metadata_edits": goal_edit_summary(events),
        "verify_to_confirm_hours": {
            "n": len(waits),
            "min": round(min(waits), 2) if waits else None,
            "median": round(statistics.median(waits), 2) if waits else None,
            "max": round(max(waits), 2) if waits else None,
        },
    }


def task_summary(
    live: list[dict[str, Any]], archived: list[dict[str, Any]], links: list[dict[str, Any]]
) -> dict[str, Any]:
    tasks = live + archived
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
    archived_ids = {t["id"] for t in archived}
    return {
        "total": len(tasks),
        "live": len(live),
        "archived": len(archived),
        "by_status": dict(Counter(t["status"] for t in tasks)),
        "linked_to_a_goal": len(linked_ids),
        "linked_in_archive": len(linked_ids & archived_ids),
        "goals_with_a_link": len(links),
        "done_total": len(done),
        "done_created_by_the_assignee": self_done,
        "done_created_by_the_assignee_share": round(self_done / len(done), 3) if done else None,
        "delegation": delegation,
    }


def payout_basis(
    goals: list[dict[str, Any]],
    tasks: list[dict[str, Any]],
    links: list[dict[str, Any]],
    keepers: set[str],
) -> dict[str, Any]:
    """RFC 3.4 의 후보 규칙을 Goal 마다 적용한 개수.

    후보는 Goal 에 연결된 done Task 중 끝난 시각이 Goal 생성 시각보다 늦고,
    담당자에게 keeper 설정 파일이 있는 것의 담당자다.
    """
    by_id = {t["id"]: t for t in tasks}
    task_ids_of = {link["goal_id"]: link["task_ids"] for link in links}
    per_phase: dict[str, Counter[str]] = {}
    missing = 0
    linked_done = 0
    after_creation = 0
    without_config: set[str] = set()
    for goal in goals:
        created = parse_time(goal["created_at"])
        candidates: set[str] = set()
        for task_id in task_ids_of.get(goal["id"], []):
            task = by_id.get(task_id)
            if task is None:
                missing += 1
                continue
            if task["status"] != "done":
                continue
            completed = task.get("completed_at")
            if not completed:
                sys.exit(f"done task without completed_at: {task_id}")
            linked_done += 1
            if parse_time(completed) <= created:
                continue
            after_creation += 1
            assignee = task.get("assignee")
            if assignee in keepers:
                candidates.add(assignee)
            else:
                without_config.add(str(assignee))
        counter = per_phase.setdefault(goal["phase"], Counter())
        counter["total"] += 1
        counter["with_candidate" if candidates else "without_candidate"] += 1
    return {
        "goals_by_phase": {phase: dict(c) for phase, c in sorted(per_phase.items())},
        "linked_tasks_not_found": missing,
        "linked_done_tasks": linked_done,
        "linked_done_after_goal_created": after_creation,
        "linked_done_assignees_without_keeper_config": len(without_config),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Candle 을 켜기 전 keeper 행동의 기준선을 집계한다.")
    parser.add_argument("--base", required=True, help="MASC base path (the directory that holds .masc)")
    parser.add_argument("--keepers-dir", help="keeper 설정 폴더. 기본값은 <base>/.masc/config/keepers")
    args = parser.parse_args()
    masc = Path(args.base).expanduser() / ".masc"
    keepers_dir = Path(args.keepers_dir).expanduser() if args.keepers_dir else masc / "config" / "keepers"
    if not keepers_dir.is_dir():
        sys.exit(f"missing keepers dir: {keepers_dir}")
    keepers = {p.stem for p in keepers_dir.glob("*.toml")}
    goals: list[dict[str, Any]] = read_json(masc / "goals.json")["goals"]
    events = read_jsonl(masc / "goal_events.jsonl")
    live: list[dict[str, Any]] = read_json(masc / "tasks" / "backlog.json")["tasks"]
    archived = read_archived_tasks(masc / "tasks-archive.json")
    links: list[dict[str, Any]] = read_json(masc / "tasks" / "goal_task_links.json")["links"]
    out = {
        "as_of": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "goals": goal_summary(goals),
        "goal_events": goal_event_summary(events),
        "tasks": task_summary(live, archived, links),
        "payout_basis": payout_basis(goals, live + archived, links, keepers),
    }
    json.dump(out, sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
