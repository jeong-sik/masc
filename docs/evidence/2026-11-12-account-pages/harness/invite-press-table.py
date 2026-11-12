"""Prints the table of the invitation presses from the JSON of invite-press.mjs.

usage: python3 invite-press-table.py NAME=FILE [NAME=FILE ...]
Each NAME heads one column, in the order given, and each case is one row.
"""
import json
import sys
from typing import TypedDict, cast


class Then(TypedDict):
    page: str
    fragmentLength: int
    buttonShown: bool
    invite: str


class Row(TypedDict):
    label: str
    holdMs: int
    atMs: int
    pressed: bool
    firstLoad: str
    openReturnedAfterMs: int
    actedAfterMs: int
    actedInTime: bool
    firstPressSent: list[str] | None
    invitationPagesAsked: int
    load: str
    then: Then
    pressThenSent: list[str] | str


WORDS = {
    "the first link": "첫 링크",
    "the second link": "둘째 링크",
    "an empty value": "빈 값",
    "another value": "다른 값",
    "no field": "칸 없음",
    "/accounts/invite": "초대 화면",
    "the page of the stand-in after a start": "로그인 시작",
}


def word(value: str) -> str:
    return WORDS.get(value, value)


def sent(value: list[str] | str | None) -> str:
    if value is None:
        return "-"
    if isinstance(value, str):
        return "단추 없음" if value == "no button" else value
    return " · ".join(word(one) for one in value) if value else "보낸 것 없음"


def case(row: Row) -> str:
    acted = "누름" if row["pressed"] else "화면만 찍음"
    return f"{row['holdMs']}ms 붙잡음, {row['atMs']}ms 에 {acted}"


def cell(row: Row) -> str:
    then = row["then"]
    after = word(then["page"])
    if then["page"] == "/accounts/invite":
        after += f" · 양식 {word(then['invite'])}"
    late = "" if row["actedInTime"] else ", 붙잡은 시간이 지난 뒤"
    if row["pressed"]:
        pressed = f"누름({row['actedAfterMs']}ms{late}): {sent(row['firstPressSent'])}"
        return f"{pressed} → {after} → 다시 누름: {sent(row['pressThenSent'])}"
    return f"찍음({row['actedAfterMs']}ms{late}) → {after}"


columns: list[tuple[str, list[Row]]] = []
for argument in sys.argv[1:]:
    name, path = argument.split("=", 1)
    with open(path, encoding="utf-8") as handle:
        columns.append((name, cast(list[Row], json.load(handle))))
count = len(columns[0][1])
assert all(len(rows) == count for _, rows in columns), "every file must hold the same cases"
print("| 경우 | " + " | ".join(name for name, _ in columns) + " |")
print("| --- | " + " | ".join("---" for _ in columns) + " |")
for index in range(count):
    first = columns[0][1][index]
    assert all(
        (rows[index]["holdMs"], rows[index]["atMs"], rows[index]["pressed"]) == (first["holdMs"], first["atMs"], first["pressed"])
        for _, rows in columns
    ), "the cases must be in the same order"
    print(f"| {case(first)} | " + " | ".join(cell(rows[index]) for _, rows in columns) + " |")
