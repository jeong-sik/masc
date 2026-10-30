#!/usr/bin/env python3
"""Task 를 Goal 에 연결하는 일이 얼마나, 언제 일어나는지.

Task 와 Goal 의 연결에는 시각이 없다. 그래서 두 가지를 따로 잰다.

1. 연결된 Task 가 Goal 보다 먼저 만들어졌는지. 먼저 만들어진 Task 의 연결은
   Task 를 만든 뒤에 한 일이다(`masc_task_set_goal` 이나 대시보드).
2. keeper 가 `masc_task_set_goal` 을 부른 횟수. keeper 마다 도구별 누적 횟수가
   `<base>/.masc/keepers/tool_usage/<이름>.json` 에 있다. 대시보드로 운영자가
   연결한 횟수는 여기에 없다.

    python3 collect_link_timing.py --base <MASC_BASE_PATH>

`<base>/.masc` 아래를 읽기만 한다. 제목, 설명, 본문은 내지 않는다.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SET_GOAL_TOOL = "masc_task_set_goal"


def read_json(path: Path) -> Any:
    if not path.is_file():
        sys.exit(f"missing input: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


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


def link_timing(
    goals: list[dict[str, Any]],
    tasks: list[dict[str, Any]],
    links: list[dict[str, Any]],
) -> dict[str, Any]:
    goal_created = {g["id"]: parse_time(g["created_at"]) for g in goals}
    task_by_id = {t["id"]: t for t in tasks}
    linked = [(link["goal_id"], task_id) for link in links for task_id in link["task_ids"]]
    before_goal: list[str] = []
    at_or_after_goal = 0
    missing = 0
    for goal_id, task_id in linked:
        task = task_by_id.get(task_id)
        if task is None or goal_id not in goal_created:
            missing += 1
        elif parse_time(task["created_at"]) < goal_created[goal_id]:
            before_goal.append(task["status"])
        else:
            at_or_after_goal += 1
    return {
        "linked_tasks": len(linked),
        "status_of_linked_tasks": dict(Counter(task_by_id[t]["status"] for _, t in linked if t in task_by_id)),
        "task_created_before_its_goal": {
            "n": len(before_goal),
            "status": dict(Counter(before_goal)),
        },
        "task_created_at_or_after_its_goal": at_or_after_goal,
        "unresolved_link": missing,
    }


def set_goal_calls(usage_dir: Path) -> dict[str, Any]:
    if not usage_dir.is_dir():
        sys.exit(f"missing input: {usage_dir}")
    per_keeper: dict[str, dict[str, Any]] = {}
    files = 0
    for path in sorted(usage_dir.glob("*.json")):
        files += 1
        doc = json.loads(path.read_text(encoding="utf-8"))
        for row in doc.get("tools", []):
            if row.get("tool") == SET_GOAL_TOOL:
                per_keeper[doc.get("keeper", path.stem)] = {
                    "count": row["count"],
                    "successes": row["successes"],
                    "failures": row["failures"],
                    "last_used_at": datetime.fromtimestamp(row["last_used_at"], timezone.utc).isoformat(),
                }
    return {
        "keeper_files_read": files,
        "total": sum(v["count"] for v in per_keeper.values()),
        "successes": sum(v["successes"] for v in per_keeper.values()),
        "failures": sum(v["failures"] for v in per_keeper.values()),
        "by_keeper": per_keeper,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", required=True, help="MASC_BASE_PATH (the directory that holds .masc)")
    args = parser.parse_args()
    root = Path(args.base) / ".masc"

    goals_doc = read_json(root / "goals.json")
    goals = goals_doc["goals"] if isinstance(goals_doc, dict) else goals_doc
    live = read_json(root / "tasks" / "backlog.json")["tasks"]
    archived = read_archived_tasks(root / "tasks-archive.json")
    links = read_json(root / "tasks" / "goal_task_links.json")["links"]

    result = {
        "collected_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "link_timing": link_timing(goals, live + archived, links),
        "set_task_goal_calls_by_keepers": set_goal_calls(root / "keepers" / "tool_usage"),
    }
    json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
