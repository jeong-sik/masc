#!/usr/bin/env python3
"""'지금 안 함' 닫기의 결과와 댓글 재독 결과에서 보고서의 수를 다시 센다.

usage: closure_counts.py NOT_PLANNED_CLOSURE.json COMMENT_RECHECK.json
"""
import collections
import json
import sys
from typing import TypedDict

CLOSED_OUTCOMES = frozenset({"closed_not_planned", "closed_completed"})
DETAILED_OUTCOMES = ("left_out", "reopened", "closed_completed")


class Closure(TypedDict):
    number: int
    outcome: str
    why: str


class Recheck(TypedDict):
    number: int
    reader: str
    evidence: str
    decision: str
    merged_in: list[int]
    outcome: str


def counted(values: list[str]) -> dict[str, int]:
    return dict(sorted(collections.Counter(values).items()))


def print_closure(rows: list[Closure]) -> None:
    print("== not-planned closure: candidates", len(rows), "==")
    print("outcome:", counted([row["outcome"] for row in rows]))
    print("closed in the batch:", sum(row["outcome"] != "left_out" for row in rows))
    print("closed now:", sum(row["outcome"] in CLOSED_OUTCOMES for row in rows))
    for outcome in DETAILED_OUTCOMES:
        subset = [row for row in rows if row["outcome"] == outcome]
        print(outcome, "why:", counted([row["why"] for row in subset]))
        print(outcome, "numbers:", [row["number"] for row in subset])


def print_recheck(rows: list[Recheck]) -> None:
    print("== comment recheck: issues", len(rows), "==")
    print("reader:", counted([row["reader"] for row in rows]))
    print("evidence:", counted([row["evidence"] for row in rows]))
    for evidence in sorted({row["evidence"] for row in rows}):
        subset = [row for row in rows if row["evidence"] == evidence]
        print(evidence, "outcome:", counted([row["outcome"] for row in subset]))
    occurred_closed = [row["number"] for row in rows if row["evidence"] == "occurred" and row["outcome"] in CLOSED_OUTCOMES]
    print("occurred and closed now:", occurred_closed)
    print("a comment records a decision:", sum(bool(row["decision"]) for row in rows))
    print("umbrella issues:", [(row["number"], len(row["merged_in"])) for row in rows if row["merged_in"]])


def main(argv: list[str]) -> None:
    with open(argv[1], encoding="utf-8") as handle:
        closure: list[Closure] = json.load(handle)
    with open(argv[2], encoding="utf-8") as handle:
        recheck: list[Recheck] = json.load(handle)
    print_closure(closure)
    print_recheck(recheck)


if __name__ == "__main__":
    main(sys.argv)
