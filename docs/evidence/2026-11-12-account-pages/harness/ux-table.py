"""Prints the rows of a measurement file as a Markdown table.
usage: python3 ux-table.py MEASURE_JSON"""
import json
import sys


def login_cell(row):
    """The login as the browser held it. Rows of an older measurement have no
    such field."""
    if "login" not in row:
        return "-"
    login = row["login"]
    if login is None:
        return "form 없음"
    if not login["rendered"]:
        return "숨김"
    if login["submitButtons"] != 1:
        return f'submit button {login["submitButtons"]}개'
    if login["disabled"][0]:
        return f'`disabled`, 보이는 설명 {login["describedVisibleChars"][0]}자'
    return "누를 수 있음"

rows = json.load(open(sys.argv[1]))
print("| 상태 | HTTP | axe 위반 | incomplete | CSS 규칙 | 정책 위반 | `style` 속성 | 24px 미만 대상 | 가장 낮은 대상 | 보이는 경로 답 원문 | 자유 입력 칸 | 로그인 단추(DOM) | 첫 Tab | 320px 가로 넘침 | 시도 |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for r in rows:
    violations = r["policyViolations"]
    violations = len(violations) if isinstance(violations, list) else violations
    tab = r["firstTabStop"].split(" ")[0]
    lowest = "-" if r["smallestControlHeight"] is None else f'{r["smallestControlHeight"]}px'
    print(
        f'| {r["state"]} | {r["httpStatus"]} | {r["axeViolations"]} | {len(r["axeIncomplete"])} | {r["styleRules"]} | {violations} '
        f'| {r["styleAttributes"]} | {r["targetsUnder24px"]} | {lowest} | {r["rawServerTextBlocks"]} '
        f'| {r["freeTextFields"]} | {login_cell(r)} | `{tab}` | {r["horizontalScrollAt320"]} | {r.get("attempts", "-")} |'
    )
policies = sorted({r["policy"] for r in rows})
print()
for p in policies:
    print("policy:", p)
langs = sorted({(r["lang"], r["title"]) for r in rows})
print("lang/title:", langs)
bad = [r["state"] for r in rows if r["axeRules"] or r["axeIncomplete"]]
for r in rows:
    if r["axeRules"] or r["axeIncomplete"]:
        print("axe:", r["state"], r["axeRules"], r["axeIncomplete"])
