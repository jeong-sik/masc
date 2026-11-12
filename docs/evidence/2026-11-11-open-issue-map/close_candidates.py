#!/usr/bin/env python3
"""본문 분류에서 "지금 안 함"으로 닫을 후보(보고서 10절 3번)와 직접 읽을 표본을 다시 만든다.

usage: close_candidates.py BODY_CLASSIFICATION.json OPEN.jsonl XREFS.jsonl
"""
import collections
import json
import random
import sys
from typing import TypedDict

TOP_TWO = frozenset({"breaks-continuity", "breaks-collab"})
CLOSE_ASKS = frozenset({"fix", "cleanup"})
MUST_DO = "must-do"
OPEN_STATE = "OPEN"
SAMPLE_SEED = 7777
SAMPLE_SIZE = 20


class Row(TypedDict):
    number: int
    observed: bool
    impact: str
    ask: str
    group: str
    closed_after: bool


class Issue(TypedDict):
    number: int
    labels: list[str]


class PullRef(TypedDict):
    number: int
    state: str


class Xref(TypedDict):
    number: int
    prs: list[PullRef]


def read_issues(path: str) -> list[Issue]:
    with open(path, encoding="utf-8") as handle:
        issues: list[Issue] = [json.loads(line) for line in handle]
    return issues


def read_xrefs(path: str) -> list[Xref]:
    with open(path, encoding="utf-8") as handle:
        xrefs: list[Xref] = [json.loads(line) for line in handle]
    return xrefs


def no_record_and_lighter(row: Row) -> bool:
    return not row["observed"] and row["impact"] not in TOP_TWO


def main(argv: list[str], rng: random.Random) -> None:
    with open(argv[1], encoding="utf-8") as handle:
        rows: list[Row] = json.load(handle)
    must_do = {issue["number"] for issue in read_issues(argv[2]) if MUST_DO in issue["labels"]}
    open_pr = {xref["number"] for xref in read_xrefs(argv[3]) if any(pr["state"] == OPEN_STATE for pr in xref["prs"])}
    base = sorted(row["number"] for row in rows if no_record_and_lighter(row) and row["ask"] in CLOSE_ASKS)
    left_must_do = [number for number in base if number in must_do]
    left_open_pr = [number for number in base if number in open_pr and number not in must_do]
    candidates = [number for number in base if number not in must_do and number not in open_pr]
    groups = {row["number"]: row["group"] for row in rows}
    print("== no record and lighter, ask fix or cleanup:", len(base), "==")
    print("left out, must-do label:", len(left_must_do), left_must_do)
    print("left out, mentioned by an open PR:", len(left_open_pr), left_open_pr)
    print("candidates:", len(candidates))
    print("group:", dict(collections.Counter(groups[number] for number in candidates).most_common()))
    print("sample of", SAMPLE_SIZE, "with seed", str(SAMPLE_SEED) + ":", sorted(rng.sample(candidates, SAMPLE_SIZE)))
    closed = {row["number"] for row in rows if row["closed_after"]}
    closed_candidates = [number for number in candidates if number in closed]
    still_open = [number for number in candidates if number not in closed]
    print("closed after classification:", len(closed_candidates), closed_candidates)
    print("candidates still open:", len(still_open))
    print("candidate numbers still open:", still_open)


if __name__ == "__main__":
    main(sys.argv, random.Random(SAMPLE_SEED))
