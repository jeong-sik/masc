"""Prints the two result files of console-layer.sh as Markdown tables.
usage: python3 console-table.py ANSWERS_JSON MEASURE_JSON"""
import json
import sys

answers = json.load(open(sys.argv[1]))
rows = json.load(open(sys.argv[2]))

SERVER = {"with the console": "콘솔이 든 bundle", "without a bundle": "빈 bundle"}

print("| 서버 | 무엇 | 주소 | 보낸 header | 상태 | content-type | cache-control | content-encoding | 바이트 |")
print("|---|---|---|---|---|---|---|---|---|")
for a in answers:
    if "status" not in a:
        continue
    h = a["headers"]
    sent = ", ".join(f"`{k}`" for k in a["sent"]) or "-"
    print(
        f'| {SERVER[a["server"]]} | {a["what"]} | `{a["path"]}` | {sent} | {a["status"]} '
        f'| {h.get("content-type", "-")} | {h.get("cache-control", "-")} | {h.get("content-encoding", "-")} | {a["bytes"]} |'
    )
print()
for a in answers:
    if "holds" in a:
        print(f'- {a["what"]}: {a["holds"]} ({a["bytes"]} bytes in the style element)')
policies = sorted({(a["server"], a["path"], a["status"], a["headers"]["content-security-policy"]) for a in answers if "status" in a and "content-security-policy" in a["headers"]})
for server, path, status, policy in policies:
    print(f"- policy of `{path}` ({SERVER[server]}, {status}): `{policy}`")
print()
print("| 상태 | 도착한 주소 | axe 위반 | incomplete | CSS 규칙 | 정책 위반 | `style` 속성 | 24px 미만 대상 | 가장 낮은 대상 | 보이는 조작 대상 | 첫 Tab | 320px 가로 넘침 | 시도 |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for r in rows:
    # What the page itself was refused: the count before axe-core ran in it.
    violations = r["policyViolationsBeforeAxe"]
    violations = len(violations) if isinstance(violations, list) else violations
    tab = r["firstTabStop"].split(" ")[0]
    lowest = "-" if r["smallestControlHeight"] is None else f'{r["smallestControlHeight"]}px'
    print(
        f'| {r["state"]} | `{r["finalPath"]}` | {r["axeViolations"]} | {len(r["axeIncomplete"])} | {r["styleRules"]} | {violations} '
        f'| {r["styleAttributes"]} | {r["targetsUnder24px"]} | {lowest} | {r["visibleControls"]} | `{tab}` | {r["horizontalScrollAt320"]} | {r.get("attempts", "-")} |'
    )
print()
for r in rows:
    if isinstance(r["policyViolations"], list) and r["policyViolations"]:
        print(f'- 정책 위반({r["state"]}): axe 전 {r["policyViolationsBeforeAxe"]}, 측정이 끝난 뒤 {len(r["policyViolations"])}건, 규칙을 못 읽은 sheet {r["sheetsWithoutRules"]}개')
    if r["axeRules"] or r["axeIncomplete"]:
        print(f'- axe({r["state"]}): {r["axeRules"]} {r["axeIncomplete"]}')
print("- lang/title:", sorted({(r["lang"], r["title"]) for r in rows}))
