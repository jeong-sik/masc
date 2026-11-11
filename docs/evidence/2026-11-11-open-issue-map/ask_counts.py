#!/usr/bin/env python3
"""Keeper 가 운영자에게 물은 Ask 의 건수와 답까지 걸린 시간을 센다.

usage: ask_counts.py <base-path>/.masc/keeper_ask

질문과 답의 내용은 읽지 않고 사건 종류와 시각만 쓴다.
"""
import collections
import datetime as dt
import glob
import json
import os
import statistics
import sys
from typing import cast

SECONDS_PER_HOUR = 3600


def week_of(epoch: float) -> str:
    day = dt.datetime.fromtimestamp(epoch, dt.timezone.utc).date()
    return (day - dt.timedelta(days=day.weekday())).isoformat()


def main(store_dir: str) -> None:
    asked_at: dict[str, float] = {}
    answered_at: dict[str, float] = {}
    withdrawn: set[str] = set()
    for path in sorted(glob.glob(os.path.join(store_dir, "*.jsonl"))):
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                if not line.strip():
                    continue
                row = cast(dict[str, object], json.loads(line))
                event = row["event"]
                if event == "asked":
                    ask = cast(dict[str, object], row["ask"])
                    asked_at[cast(str, ask["ask_id"])] = cast(float, ask["asked_at"])
                elif event == "answered":
                    answered_at[cast(str, row["ask_id"])] = cast(float, row["answered_at"])
                elif event == "withdrawn":
                    withdrawn.add(cast(str, row["ask_id"]))
                else:
                    raise ValueError(f"unknown event {event!r} in {path}")
    pending = [ask_id for ask_id in asked_at if ask_id not in answered_at and ask_id not in withdrawn]
    first = dt.datetime.fromtimestamp(min(asked_at.values()), dt.timezone.utc)
    last = dt.datetime.fromtimestamp(max(asked_at.values()), dt.timezone.utc)
    print("asked", len(asked_at), "answered", len(answered_at), "withdrawn", len(withdrawn), "pending", len(pending))
    print("first asked", first.isoformat()[:16], "last asked", last.isoformat()[:16])
    hours = sorted(
        (answered_at[ask_id] - asked_at[ask_id]) / SECONDS_PER_HOUR for ask_id in answered_at if ask_id in asked_at
    )
    print(
        "hours from asked to answered: median %.2f p75 %.2f p90 %.2f max %.1f"
        % (statistics.median(hours), hours[len(hours) * 3 // 4], hours[len(hours) * 9 // 10], hours[-1])
    )
    print("asked per week (Monday):", dict(sorted(collections.Counter(week_of(t) for t in asked_at.values()).items())))


if __name__ == "__main__":
    main(sys.argv[1])
