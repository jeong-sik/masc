#!/usr/bin/env python3
"""라벨 재판정과 닫기 검증 결과 파일에서 보고서의 수를 다시 센다.

usage: audit_counts.py LABEL_AUDIT_2.json CLOSE_VERIFICATION.json
"""
import collections
import json
import sys
from typing import TypedDict

TOP_TWO = frozenset({"breaks-continuity", "breaks-collab"})
JUDGES = 2


class Relabel(TypedDict):
    number: int
    observed: list[bool]
    impact: list[str]
    closed_2026_11_11: bool


class Verified(TypedDict):
    number: int
    set: str
    verdict: str
    action: str


def print_label_audit(rows: list[Relabel]) -> None:
    print("== label audit: issues", len(rows), "==")
    cells = collections.Counter(
        (sum(row["observed"]), sum(impact in TOP_TWO for impact in row["impact"])) for row in rows
    )
    for observed_votes in range(JUDGES, -1, -1):
        print(
            "judges saying it happened:",
            observed_votes,
            "| top-two votes 2/1/0:",
            [cells[(observed_votes, top_votes)] for top_votes in range(JUDGES, -1, -1)],
        )
    print("same answer on observed:", sum(row["observed"][0] == row["observed"][1] for row in rows))
    print("same impact grade:", sum(row["impact"][0] == row["impact"][1] for row in rows))
    sure = [row for row in rows if all(row["observed"]) and all(impact in TOP_TWO for impact in row["impact"])]
    closed = [row["number"] for row in sure if row["closed_2026_11_11"]]
    print("happened and top-two by both judges:", len(sure), "closed on 2026-11-11:", closed)
    print("still open:", sorted(row["number"] for row in sure if not row["closed_2026_11_11"]))


def print_close_verification(rows: list[Verified]) -> None:
    for name in sorted({row["set"] for row in rows}):
        subset = [row for row in rows if row["set"] == name]
        print("== close verification:", name, len(subset), "==")
        print("verifier verdict:", dict(sorted(collections.Counter(row["verdict"] for row in subset).items())))
        print("action:", dict(sorted(collections.Counter(row["action"] for row in subset).items())))


def main(argv: list[str]) -> None:
    with open(argv[1], encoding="utf-8") as handle:
        relabels: list[Relabel] = json.load(handle)
    with open(argv[2], encoding="utf-8") as handle:
        verified: list[Verified] = json.load(handle)
    print_label_audit(relabels)
    print_close_verification(verified)


if __name__ == "__main__":
    main(sys.argv)
