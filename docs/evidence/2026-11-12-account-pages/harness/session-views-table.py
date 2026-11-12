"""Prints the rows of two runs of session-views.mjs, one above the other for
each case, as a Markdown table.
usage: session-views-table.py BEFORE_JSON AFTER_JSON"""
import json
import pathlib
import sys

before, after = (json.loads(pathlib.Path(p).read_text(encoding="utf-8")) for p in sys.argv[1:3])
assert [r["case"] for r in before] == [r["case"] for r in after]

CASE = {
    "session_unread": "세션 경로가 503 인 서버에서 화면을 연다",
    "signout_ended": "로그아웃한다, 서버가 세션을 끝낸다(204)",
    "signout_refused": "로그아웃한다, 서버가 거절하고(503) 세션은 그대로다",
    "signout_refused_then_unread": "로그아웃한다, 서버가 거절하고(503) 세션 경로도 503 이 된다",
}
VIEW = {
    "the sign-in": "로그인 카드",
    "the tools of a signed-in person": "로그인한 사람의 도구",
    "that the session was not read": "확인하지 못했다는 안내",
}
LOAD = {"a document was loaded": "다시 읽음", "no document was loaded": "그대로", None: "-"}
LIMIT = 44


def line(text):
    if text is None:
        return "보이지 않음"
    return "`" + (text if len(text) <= LIMIT else text[:LIMIT] + "…") + "`"


def cells(row):
    return [
        ", ".join(VIEW[v] for v in row["viewsShown"]),
        str(row["sessionRouteAfterwards"]),
        line(row["statusLine"]),
        "`" + row["focus"] + "`",
        str(row["idsOfThePersonInTheDocument"]),
        LOAD[row.get("load")],
    ]


print("| 경우 | | 보이는 화면 | 그 뒤 세션 경로의 답 | 상태 줄의 첫 줄 | focus | 문서에 남은 그 사람의 id | 문서 |")
print("| --- | --- | --- | --- | --- | --- | --- | --- |")
for b, a in zip(before, after):
    print(f"| {CASE[b['case']]} | 전 | " + " | ".join(cells(b)) + " |")
    print("| | 후 | " + " | ".join(cells(a)) + " |")
