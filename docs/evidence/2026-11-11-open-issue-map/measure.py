#!/usr/bin/env python3
"""열린 이슈 지도 보고서의 수치를 한 번에 뽑는다.

usage: measure.py OPEN.jsonl CLOSED.jsonl XREFS.jsonl [CLUSTERS_OUT.json]

입력은 fetch_issues.py 와 fetch_xrefs.py 가 만든 파일이다.
결과는 표준 출력에 쓴다. 넷째 인자를 주면 묶음별 이슈 번호를 그 경로에 쓴다.
"""
import collections
import datetime as dt
import json
import re
import sys
from typing import TypedDict, cast


class OpenIssue(TypedDict):
    number: int
    title: str
    createdAt: str
    updatedAt: str
    author: str | None
    labels: list[str]
    comments: int
    body: str | None


class ClosedIssue(TypedDict):
    number: int
    title: str
    createdAt: str
    closedAt: str
    stateReason: str | None
    labels: list[str]


class PullRef(TypedDict):
    number: int
    state: str
    draft: bool
    mergedAt: str | None
    title: str
    closes: bool
    connected: bool


class XrefRow(TypedDict):
    number: int
    prs: list[PullRef]


# 제품이 약속한 것(턴이 돈다, 이어진다, Keeper 끼리 닿는다)을 깨는 이슈의 라벨.
PROMISE_IMPACTS = frozenset({"breaks-continuity", "breaks-collab"})
LABEL_FAMILIES = ("kind", "impact", "area", "root")
ISSUE_REF = re.compile(r"#(\d{4,6})\b")
BACKLOG_FROM_WEEK = "2026-07-27"
AGE_CUTS_DAYS = (7, 14, 30, 60, 90)

# 제목에서 묶음을 잡는 정규식. 본문은 보지 않는다(본문은 인용이 많아 넓게 걸린다).
TITLE_CLUSTERS: dict[str, re.Pattern[str]] = {
    "tui": re.compile(r"\bTUI\b|tui[\(:]|푸터|footer|칸에서|터미널", re.I),
    "follow_up": re.compile(r"후속|follow-?up|남은 것|남은 지적|잔여|잔손질|리뷰에서|P3 묶음|remaining", re.I),
    "failing_test": re.compile(
        r"(^test[\(:_])|시험.*실패|실패.*시험|fails? on main|main 에서.*실패|main 에서 실패|빨갛|flaky|간헐", re.I
    ),
    "unbounded_growth": re.compile(
        r"\d+(\.\d+)?\s*(GB|GiB|MB|MiB|TB)|쌓여|쌓인다|쌓이|무한|unbounded|accumulat|상한 없이|상한이 없|grow", re.I
    ),
    "side_feature": re.compile(
        r"music|midi|alphatex|fluidsynth|msx|\bdos\b|figma|1password|voice|음성|초상화|portrait", re.I
    ),
    "old_data": re.compile(
        r"(^|\s)구 |옛 |이전 빌드|v1 |version 1|하드컷|hard.?cut|업그레이드 전|historical|legacy|레거시", re.I
    ),
    "n_of_m": re.compile(
        r"(\d+\s*(곳|개|자리|벌|건|줄|화면|종)\s*(중|가운데)\s*\d+)|(\d+\s*of\s*\d+)|(\d+/\d+\s*(곳|개|건))"
        r"|두 벌|세 벌|일곱 벌|두 곳|세 곳|네 곳|따로|마다 다르|마다 손으로|제각각|서로 다르게"
        r"|two (places|copies)|three (places|copies)|each .* differently|이중 정의|두 번 정의|중복 정의",
        re.I,
    ),
}


def load_jsonl(path: str) -> list[dict[str, object]]:
    with open(path, encoding="utf-8") as handle:
        return [cast(dict[str, object], json.loads(line)) for line in handle if line.strip()]


def parse_time(text: str) -> dt.datetime:
    return dt.datetime.fromisoformat(text.replace("Z", "+00:00"))


def week_of(text: str) -> str:
    day = parse_time(text).date()
    return (day - dt.timedelta(days=day.weekday())).isoformat()


def family(labels: list[str], name: str) -> list[str]:
    prefix = name + "/"
    return [label[len(prefix):] for label in labels if label.startswith(prefix)]


def touches_promise(issue: OpenIssue) -> bool:
    return bool(PROMISE_IMPACTS & set(family(issue["labels"], "impact")))


def print_totals(opened: list[OpenIssue], closed: list[ClosedIssue], snapshot: dt.datetime) -> None:
    total = len(opened)
    print("== totals ==")
    print("open", total, "closed", len(closed))
    print("open by created month", dict(sorted(collections.Counter(i["createdAt"][:7] for i in opened).items())))
    print("authors", dict(collections.Counter(i["author"] for i in opened).most_common()))
    print("comments == 0:", sum(1 for i in opened if i["comments"] == 0))
    ages = [(snapshot - parse_time(i["createdAt"])).days for i in opened]
    print("older than N days:", {cut: sum(1 for age in ages if age > cut) for cut in AGE_CUTS_DAYS})

    print("\n== labels ==")
    for name in LABEL_FAMILIES:
        counts = collections.Counter(value for i in opened for value in family(i["labels"], name))
        missing = sum(1 for i in opened if not family(i["labels"], name))
        print(name, dict(counts.most_common()), "none", missing)
    print("no label at all:", sum(1 for i in opened if not i["labels"]))
    promise = [i for i in opened if touches_promise(i)]
    with_impact = sum(1 for i in opened if family(i["labels"], "impact"))
    print(
        "touches promise (impact/breaks-continuity or breaks-collab):",
        len(promise),
        f"= {100 * len(promise) / total:.1f}% of open, {100 * len(promise) / with_impact:.1f}% of impact-labelled",
    )
    must_do = [i for i in opened if "must-do" in i["labels"]]
    print("must-do:", len(must_do), "of which touch promise:", sum(1 for i in must_do if touches_promise(i)))


def title_clusters(opened: list[OpenIssue]) -> dict[str, list[int]]:
    return {
        name: [i["number"] for i in opened if pattern.search(i["title"] or "")]
        for name, pattern in TITLE_CLUSTERS.items()
    }


def print_clusters(opened: list[OpenIssue], clusters: dict[str, list[int]]) -> None:
    promise_numbers = {i["number"] for i in opened if touches_promise(i)}
    november = {i["number"] for i in opened if i["createdAt"].startswith("2026-11")}
    print("\n== title clusters: count / touch promise / created in November ==")
    for name, numbers in clusters.items():
        members = set(numbers)
        print(name, len(members), len(members & promise_numbers), len(members & november))
    in_any = set().union(*(set(numbers) for numbers in clusters.values()))
    print("in any title cluster:", len(in_any))
    body_n_of_m = sum(
        1 for i in opened if TITLE_CLUSTERS["n_of_m"].search((i["title"] or "") + "\n" + (i["body"] or ""))
    )
    print("n_of_m in title or body:", body_n_of_m)


def print_reference_graph(opened: list[OpenIssue], closed: list[ClosedIssue]) -> list[tuple[int, int]]:
    open_numbers = {i["number"] for i in opened}
    closed_numbers = {i["number"] for i in closed}
    to_open: dict[int, set[int]] = {}
    to_closed = 0
    to_other = 0
    no_reference = 0
    in_degree: collections.Counter[int] = collections.Counter()
    for issue in opened:
        text = (issue["title"] or "") + "\n" + (issue["body"] or "")
        refs = {int(match) for match in ISSUE_REF.findall(text)} - {issue["number"]}
        to_open[issue["number"]] = refs & open_numbers
        in_degree.update(refs & open_numbers)
        to_closed += 1 if refs & closed_numbers else 0
        to_other += 1 if refs - open_numbers - closed_numbers else 0
        no_reference += 0 if refs else 1
    linked: set[int] = set()
    for source, targets in to_open.items():
        if targets:
            linked.add(source)
            linked.update(targets)
    print("\n== #number references in title and body ==")
    print("cites another open issue:", sum(1 for targets in to_open.values() if targets))
    print("cites a closed issue:", to_closed)
    print("cites a number that is not an issue (a pull request):", to_other)
    print("cites nothing:", no_reference)
    print("not linked to any other open issue:", len(opened) - len(linked))
    hubs = in_degree.most_common(15)
    print("most cited open issues:", hubs)
    return hubs


def print_pull_request_mentions(opened: list[OpenIssue], xrefs: list[XrefRow]) -> None:
    by_number = {row["number"]: row for row in xrefs}
    later = earlier_only = none = closing = 0
    for issue in opened:
        row = by_number.get(issue["number"])
        merged = [pr for pr in (row["prs"] if row else []) if pr["state"] == "MERGED"]
        merged_later = [pr for pr in merged if pr["number"] > issue["number"]]
        if merged_later:
            later += 1
            closing += 1 if any(pr["closes"] or pr["connected"] for pr in merged_later) else 0
        elif merged:
            earlier_only += 1
        else:
            none += 1
    print("\n== merged pull requests that mention the issue ==")
    print("a later-numbered merged PR mentions it:", later, "(with a closing keyword:", closing, ")")
    print("only earlier-numbered merged PRs mention it (the issue came out of a PR):", earlier_only)
    print("no merged PR mentions it:", none)


def print_flow(opened: list[OpenIssue], closed: list[ClosedIssue]) -> None:
    created = collections.Counter(week_of(i["createdAt"]) for i in opened)
    created.update(week_of(i["createdAt"]) for i in closed)
    closed_in = collections.Counter(week_of(i["closedAt"]) for i in closed)
    print("\n== week (Monday): created closed backlog ==")
    backlog = 0
    for week in sorted(set(created) | set(closed_in)):
        backlog += created[week] - closed_in[week]
        if week >= BACKLOG_FROM_WEEK:
            print(week, created[week], closed_in[week], backlog)
    print("closed stateReason:", collections.Counter(i["stateReason"] for i in closed).most_common())


def main(argv: list[str]) -> None:
    opened = cast(list[OpenIssue], load_jsonl(argv[1]))
    closed = cast(list[ClosedIssue], load_jsonl(argv[2]))
    xrefs = cast(list[XrefRow], load_jsonl(argv[3]))
    snapshot = max(parse_time(i["updatedAt"]) for i in opened)
    print("snapshot (latest updatedAt among open issues):", snapshot.isoformat())
    print_totals(opened, closed, snapshot)
    clusters = title_clusters(opened)
    print_clusters(opened, clusters)
    hubs = print_reference_graph(opened, closed)
    print_pull_request_mentions(opened, xrefs)
    print_flow(opened, closed)
    if len(argv) > 4:
        promise = sorted(i["number"] for i in opened if touches_promise(i))
        with open(argv[4], "w", encoding="utf-8") as handle:
            json.dump(
                {"title_clusters": clusters, "touches_promise": promise, "most_cited": hubs},
                handle,
                ensure_ascii=False,
                indent=1,
            )
            handle.write("\n")


if __name__ == "__main__":
    main(sys.argv)
