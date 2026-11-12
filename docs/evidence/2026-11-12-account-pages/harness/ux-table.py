"""Prints the rows of a measurement file as a Markdown table.
usage: python3 ux-table.py MEASURE_JSON"""
import json
import sys

rows = json.load(open(sys.argv[1]))
print("| 상태 | HTTP | axe 위반 | incomplete | CSS 규칙 | 정책 위반 | `style` 속성 | 24px 미만 대상 | 가장 낮은 대상 | 보이는 경로 답 원문 | 자유 입력 칸 | 첫 Tab | 320px 가로 넘침 |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for r in rows:
    violations = r["policyViolations"]
    violations = len(violations) if isinstance(violations, list) else violations
    tab = r["firstTabStop"].split(" ")[0]
    lowest = "-" if r["smallestControlHeight"] is None else f'{r["smallestControlHeight"]}px'
    print(
        f'| {r["state"]} | {r["httpStatus"]} | {r["axeViolations"]} | {len(r["axeIncomplete"])} | {r["styleRules"]} | {violations} '
        f'| {r["styleAttributes"]} | {r["targetsUnder24px"]} | {lowest} | {r["rawServerTextBlocks"]} '
        f'| {r["freeTextFields"]} | `{tab}` | {r["horizontalScrollAt320"]} |'
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
