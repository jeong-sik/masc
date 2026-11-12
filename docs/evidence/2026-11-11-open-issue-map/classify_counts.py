#!/usr/bin/env python3
"""본문 분류 결과 파일에서 보고서의 수를 다시 센다.

usage: classify_counts.py BODY_CLASSIFICATION.json
"""
import collections
import json
import sys
from typing import TypedDict

TOP_TWO = frozenset({"breaks-continuity", "breaks-collab"})
ASKS = ("fix", "decide", "measure", "build", "cleanup", "track")


class Recheck(TypedDict):
    set: str
    observed: bool
    impact: str
    ask: str
    group: str


class Row(TypedDict):
    number: int
    label: str | None
    observed: bool
    impact: str
    ask: str
    group: str
    unsure: bool
    closed_after: bool
    recheck: Recheck | None


def happened_and_promise(observed: bool, impact: str) -> bool:
    return observed and impact in TOP_TWO


def print_totals(rows: list[Row]) -> None:
    print("== body classification: issues", len(rows), "==")
    print("observed true:", sum(row["observed"] for row in rows), "false:", sum(not row["observed"] for row in rows))
    print("impact:", dict(collections.Counter(row["impact"] for row in rows).most_common()))
    print("ask:", dict(collections.Counter(row["ask"] for row in rows).most_common()))
    print("unsure:", sum(row["unsure"] for row in rows))
    cells = collections.Counter((row["observed"], row["impact"] in TOP_TWO) for row in rows)
    print("happened / touches promise:", cells[(True, True)])
    print("happened / lighter:", cells[(True, False)])
    print("no record / touches promise:", cells[(False, True)])
    print("no record / lighter:", cells[(False, False)])


def print_groups(rows: list[Row]) -> None:
    print("== group: issues | happened | touches promise | both |", " ".join(ASKS), "==")
    by_group: dict[str, list[Row]] = collections.defaultdict(list)
    for row in rows:
        by_group[row["group"]].append(row)
    for group, members in sorted(by_group.items(), key=lambda item: -len(item[1])):
        asks = collections.Counter(row["ask"] for row in members)
        print(
            group,
            len(members),
            sum(row["observed"] for row in members),
            sum(row["impact"] in TOP_TWO for row in members),
            sum(happened_and_promise(row["observed"], row["impact"]) for row in members),
            "|",
            " ".join(str(asks[ask]) for ask in ASKS),
        )


def print_lists(rows: list[Row]) -> None:
    print("== happened and touches promise, by group ==")
    by_group: dict[str, list[int]] = collections.defaultdict(list)
    for row in rows:
        if happened_and_promise(row["observed"], row["impact"]):
            by_group[row["group"]].append(row["number"])
    for group, numbers in sorted(by_group.items(), key=lambda item: -len(item[1])):
        print(group, len(numbers), sorted(numbers))
    light = [row for row in rows if not row["observed"] and row["impact"] not in TOP_TWO]
    print("== no record and lighter:", len(light), "==")
    print("ask:", dict(collections.Counter(row["ask"] for row in light).most_common()))
    print("impact:", dict(collections.Counter(row["impact"] for row in light).most_common()))


def cell_name(observed: bool, impact: str) -> str:
    return ("happened" if observed else "no record") + " / " + ("touches promise" if impact in TOP_TWO else "lighter")


def print_recheck(rows: list[Row]) -> None:
    pairs = [(row, row["recheck"]) for row in rows if row["recheck"] is not None]
    random_pairs = [(row, again) for row, again in pairs if again["set"] == "random"]
    print("== recheck of two whole batches in a new order: issues", len(random_pairs), "==")
    print("same observed:", sum(row["observed"] == again["observed"] for row, again in random_pairs))
    print("same impact grade:", sum(row["impact"] == again["impact"] for row, again in random_pairs))
    print(
        "same side of the promise line:",
        sum((row["impact"] in TOP_TWO) == (again["impact"] in TOP_TWO) for row, again in random_pairs),
    )
    print("same ask:", sum(row["ask"] == again["ask"] for row, again in random_pairs))
    print("same group:", sum(row["group"] == again["group"] for row, again in random_pairs))
    print("== every recheck, by first-pass cell: issues | second pass says happened and touches promise ==")
    by_cell: dict[str, list[bool]] = collections.defaultdict(list)
    for row, again in pairs:
        by_cell[cell_name(row["observed"], row["impact"])].append(
            happened_and_promise(again["observed"], again["impact"])
        )
    for name, votes in sorted(by_cell.items()):
        print(name, len(votes), sum(votes))
    both = sorted(
        row["number"]
        for row, again in pairs
        if happened_and_promise(row["observed"], row["impact"])
        and happened_and_promise(again["observed"], again["impact"])
    )
    first_only = sorted(
        row["number"]
        for row, again in pairs
        if happened_and_promise(row["observed"], row["impact"])
        and not happened_and_promise(again["observed"], again["impact"])
    )
    second_only = sorted(
        row["number"]
        for row, again in pairs
        if not happened_and_promise(row["observed"], row["impact"])
        and happened_and_promise(again["observed"], again["impact"])
    )
    print("happened and touches promise in both passes:", len(both), both)
    print("first pass only:", len(first_only), first_only)
    print("second pass only:", len(second_only), second_only)
    by_group: dict[str, list[int]] = collections.defaultdict(list)
    closed_after = {row["number"] for row in rows if row["closed_after"]}
    for row in rows:
        if row["number"] in both:
            by_group[row["group"]].append(row["number"])
    print("== in both passes, by group ==")
    for group, numbers in sorted(by_group.items(), key=lambda item: -len(item[1])):
        print(group, len(numbers), sorted(numbers))
    print("of those, closed after classification:", sorted(set(both) & closed_after))
    labels = collections.Counter(row["label"] or "none" for row in rows if row["number"] in both)
    print("impact label they carried:", dict(labels.most_common()))


def print_labels(rows: list[Row]) -> None:
    print("== impact label the issue carried: issues | happened | touches promise | both | same grade as the label ==")
    by_label: dict[str, list[Row]] = collections.defaultdict(list)
    for row in rows:
        by_label[row["label"] or "none"].append(row)
    for label, members in sorted(by_label.items(), key=lambda item: -len(item[1])):
        print(
            label,
            len(members),
            sum(row["observed"] for row in members),
            sum(row["impact"] in TOP_TWO for row in members),
            sum(happened_and_promise(row["observed"], row["impact"]) for row in members),
            sum(row["impact"] == row["label"] for row in members),
        )


def main(argv: list[str]) -> None:
    with open(argv[1], encoding="utf-8") as handle:
        rows: list[Row] = json.load(handle)
    print_totals(rows)
    print_groups(rows)
    print_lists(rows)
    print_labels(rows)
    print_recheck(rows)


if __name__ == "__main__":
    main(sys.argv)
