"""Prints the rows of two runs of invite-reopen.mjs side by side, as a
Markdown table. usage: invite-reopen-table.py BEFORE_JSON AFTER_JSON
A cell holds, in order: whether the browser loaded a document for the step,
how long the fragment of the address is afterwards, the heading the page
shows, and whose token the form would send."""
import json
import pathlib
import sys

before, after = (json.loads(pathlib.Path(p).read_text(encoding="utf-8")) for p in sys.argv[1:3])
assert [(r["sequence"], r["step"]) for r in before] == [(r["sequence"], r["step"]) for r in after]

LOAD = {"a document was loaded": "읽음", "no document was loaded": "안 읽음"}
TOKEN = {"the first link": "첫 링크", "the second link": "둘째 링크", "none": "없음"}
STEP = {
    ("reopen", "1_open_the_first_link"): "첫 링크를 연다",
    ("reopen", "2_load_the_tab_again"): "탭을 다시 읽는다",
    ("reopen", "3_open_the_first_link_again"): "같은 탭에서 첫 링크를 다시 연다",
    ("reopen", "4_open_the_second_link"): "같은 탭에서 둘째 링크를 연다",
    ("replace", "1_open_the_first_link"): "(새로 시작) 첫 링크를 연다",
    ("replace", "2_open_the_second_link"): "같은 탭에서 둘째 링크를 연다",
}


def cell(row):
    return f"{LOAD[row['load']]} · {row['fragmentLength']} · {row['heading']} · {TOKEN[row['tokenInTheForm']]}"


print("| 걸음 | 전 (문서 · `#` 뒤 길이 · 제목 · 양식의 token) | 후 |")
print("| --- | --- | --- |")
for b, a in zip(before, after):
    same = cell(b) == cell(a)
    print(f"| {STEP[(b['sequence'], b['step'])]} | {cell(b)} | {'전과 같음' if same else cell(a)} |")
