#!/usr/bin/env python3
"""Render the MASC progress dashboard from extracted measurements.

Reads the JSON that extract_progress.py emits plus the scenario/mission map,
and writes a self-contained HTML page.  No figure in the output is authored
here: every count is derived from the payload, so refreshing the page means
re-running the extractor, not editing prose.
"""

from __future__ import annotations

import argparse
import html
import json
from datetime import datetime, timezone, timedelta


KST = timezone(timedelta(hours=9))

STATUS_CLASS = {
    "PARTIAL": "partial",
    "NOT RUN": "notrun",
    "GREEN": "green",
    "PASS": "green",
}


def esc(value: str) -> str:
    return html.escape(value or "", quote=True)


def bar(passed: int, total: int, label: str, detail: str) -> str:
    pct = (passed / total * 100) if total else 0.0
    tone = "green" if total and passed == total else ("partial" if passed else "notrun")
    return f"""      <div class="metric">
        <div class="metric-head"><span class="metric-label">{esc(label)}</span><span class="metric-count">{passed} / {total}</span></div>
        <div class="track"><div class="fill {tone}" style="width:{pct:.1f}%"></div></div>
        <p class="metric-detail">{esc(detail)}</p>
      </div>"""


def render_scenarios(payload: dict, mapping: dict) -> str:
    have = {m["id"] for m in payload["missions"]}
    by_row = {s["row"]: s["missions"] for s in mapping["scenarios"]}
    out = []
    for row in payload["scenario_rows"]:
        ids = by_row.get(row["name"], [])
        chips = []
        for mid in ids:
            exists = mid in have
            cls = "chip" if exists else "chip planned"
            title = "카탈로그에 있음" if exists else "미정의 — 이 계획에서 신설"
            chips.append(f'<span class="{cls}" title="{esc(title)}">{esc(mid)}</span>')
        if not chips:
            chips.append('<span class="chip planned">미매핑</span>')
        cls = STATUS_CLASS.get(row["status"], "notrun")
        out.append(
            f"""        <tr>
          <td class="row-name">{esc(row['name'])}</td>
          <td><span class="badge {cls}">{esc(row['status'])}</span></td>
          <td class="chips">{''.join(chips)}</td>
          <td class="muted">{esc(row['needs'])}</td>
          <td class="muted small">{esc(row['missing_execution'])}</td>
        </tr>"""
        )
    return "\n".join(out)


def render_rounds(payload: dict) -> str:
    out = []
    for rnd in payload["rounds"]:
        failed = ", ".join(rnd["failed_missions"]) or "—"
        out.append(
            f"""        <tr>
          <td class="row-name">{esc(rnd['run_id'])}</td>
          <td class="num">{rnd['assertions_passed']} / {rnd['assertions_total']}</td>
          <td class="num">{rnd['missions_passed']} / {rnd['missions_total']}</td>
          <td class="muted small">{esc(failed)}</td>
        </tr>"""
        )
    return "\n".join(out)


def render_missing_axes(payload: dict) -> str:
    out = []
    for row in payload["feature_rows"]:
        if not row["missing"]:
            continue
        axes = " ".join(
            f'<span class="axis">{esc(a)}</span>' for a in row["missing"]
        )
        out.append(
            f"""        <tr>
          <td class="muted">{esc(row['domain'])}</td>
          <td class="row-name">{esc(row['feature'])}</td>
          <td class="chips">{axes}</td>
        </tr>"""
        )
    return "\n".join(out)


def render_parity(payload: dict) -> str:
    parity = payload["parity"]
    if not parity.get("available"):
        return '<p class="muted">parity 매트릭스가 이 트리에 없다 — 아직 병합 전이다.</p>'
    out = []
    for row in parity["rows"]:
        out.append(
            f"""        <tr>
          <td class="row-name">{esc(row['id'])}</td>
          <td>{esc(row['item'])}</td>
          <td class="muted small"><code>{esc(row['evidence'])}</code></td>
          <td><span class="badge {'green' if row['status'] == '완료' else 'notrun'}">{esc(row['status'])}</span></td>
        </tr>"""
        )
    return f"""      <table>
        <thead><tr><th>ID</th><th>항목</th><th>근거</th><th>상태</th></tr></thead>
        <tbody>
{chr(10).join(out)}
        </tbody>
      </table>"""


ROLE_LABEL = {
    "operational": "운영",
    "campaign_round": "캠페인 라운드",
    "canary_sweep": "카나리아 스윕",
    "admission_probe": "admission 프로브",
}


def render_keepers(payload: dict) -> str:
    census = payload["keepers"]
    out = []
    for key, label, tone in (
        ("live", "활동 중", "green"),
        ("idle", "정지", "notrun"),
    ):
        rows = census.get(key, [])
        for rec in sorted(rows, key=lambda r: (r["role"], r["name"])):
            idle = rec["idle_hours"]
            when = f"{idle:.1f}h 전" if isinstance(idle, (int, float)) else "턴 기록 없음"
            flags = []
            if rec.get("paused"):
                flags.append("paused")
            note = (" · ".join(flags)) if flags else ""
            out.append(
                f"""        <tr>
          <td class="row-name">{esc(rec['name'])}</td>
          <td><span class="badge {tone}">{esc(label)}</span></td>
          <td class="muted">{esc(ROLE_LABEL.get(rec['role'], rec['role']))}</td>
          <td class="num muted">{esc(when)}</td>
          <td class="muted small">{esc(note)}</td>
        </tr>"""
            )
    return "\n".join(out)


def build(payload: dict, mapping: dict, generated_at: str, live: dict) -> str:
    scenarios = payload["scenario_rows"]
    green_scenarios = sum(1 for s in scenarios if s["status"] in ("GREEN", "PASS"))
    feature_rows = payload["feature_rows"]
    complete_rows = sum(1 for r in feature_rows if not r["missing"])
    have = {m["id"] for m in payload["missions"]}
    planned = {
        mid
        for s in mapping["scenarios"]
        for mid in s["missions"]
        if mid not in have
    }
    parity_rows = payload["parity"].get("rows", [])
    parity_done = sum(1 for r in parity_rows if r["status"] == "완료")
    census = payload["keepers"]
    operational = len(census.get("live", []))
    residue = len(census.get("idle", []))
    latest = payload["rounds"][-1] if payload["rounds"] else None

    metrics = "\n".join(
        [
            bar(
                green_scenarios,
                len(scenarios),
                "제품 시나리오",
                "헌법 target_scenarios 와 1:1 대응하는 행. GREEN 만 센다.",
            ),
            bar(
                len(have),
                len(have) + len(planned),
                "RW 미션 카탈로그",
                f"카탈로그에 실재하는 미션 {len(have)}개, 이 계획에서 신설할 미션 {len(planned)}개.",
            ),
            bar(
                complete_rows,
                len(feature_rows),
                "기능 매트릭스 축",
                "required 축이 evidence 로 전부 채워진 행.",
            ),
            bar(
                parity_done,
                len(parity_rows),
                "헌법↔코드 격차",
                "constitution-code parity matrix 의 완료 건수.",
            ),
            bar(
                operational,
                operational + residue,
                "keeper 위생",
                f"활동 {operational} · 정지 {residue}. 이름이 아니라 마지막 턴으로 가른다.",
            ),
        ]
    )

    latest_line = (
        f"최근 라운드 <strong>{esc(latest['run_id'])}</strong> — assertion {latest['assertions_passed']}/{latest['assertions_total']} · 미션 {latest['missions_passed']}/{latest['missions_total']}"
        if latest
        else "라운드 기록 없음"
    )

    return f"""<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MASC 진행률</title>
<style>
  :root {{
    --bg: #fbfbfa; --panel: #ffffff; --ink: #1b1b19; --muted: #6b6b66;
    --line: #e3e3df; --green: #2f7a4f; --partial: #b7791f; --notrun: #a33a3a;
    --chip: #eeeeea; --accent: #2c5f8a;
  }}
  @media (prefers-color-scheme: dark) {{
    :root:not([data-theme="light"]) {{
      --bg: #16161a; --panel: #1e1e23; --ink: #e8e8e4; --muted: #9a9a94;
      --line: #32323a; --green: #63b98a; --partial: #d9a441; --notrun: #d97070;
      --chip: #2a2a31; --accent: #7fb0d8;
    }}
  }}
  :root[data-theme="dark"] {{
    --bg: #16161a; --panel: #1e1e23; --ink: #e8e8e4; --muted: #9a9a94;
    --line: #32323a; --green: #63b98a; --partial: #d9a441; --notrun: #d97070;
    --chip: #2a2a31; --accent: #7fb0d8;
  }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0; background: var(--bg); color: var(--ink);
    font: 15px/1.62 -apple-system, BlinkMacSystemFont, "Pretendard", "Apple SD Gothic Neo", sans-serif;
  }}
  .wrap {{ max-width: 1180px; margin: 0 auto; padding: 40px 24px 80px; }}
  header {{ border-bottom: 1px solid var(--line); padding-bottom: 20px; margin-bottom: 28px; }}
  h1 {{ font-size: 26px; margin: 0 0 6px; letter-spacing: -0.01em; }}
  h2 {{ font-size: 18px; margin: 40px 0 12px; letter-spacing: -0.01em; }}
  .sub {{ color: var(--muted); font-size: 13px; margin: 0; }}
  .metrics {{ display: grid; gap: 18px; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); }}
  .metric {{ background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 16px 18px; }}
  .metric-head {{ display: flex; justify-content: space-between; align-items: baseline; gap: 12px; }}
  .metric-label {{ font-weight: 600; font-size: 14px; }}
  .metric-count {{ font-variant-numeric: tabular-nums; font-size: 15px; color: var(--muted); }}
  .track {{ height: 7px; background: var(--chip); border-radius: 4px; margin: 10px 0 8px; overflow: hidden; }}
  .fill {{ height: 100%; border-radius: 4px; }}
  .fill.green {{ background: var(--green); }}
  .fill.partial {{ background: var(--partial); }}
  .fill.notrun {{ background: var(--notrun); }}
  .metric-detail {{ margin: 0; font-size: 12.5px; color: var(--muted); }}
  .scroll {{ overflow-x: auto; border: 1px solid var(--line); border-radius: 10px; background: var(--panel); }}
  table {{ border-collapse: collapse; width: 100%; font-size: 13.5px; }}
  th, td {{ text-align: left; padding: 10px 14px; border-bottom: 1px solid var(--line); vertical-align: top; }}
  th {{ font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); font-weight: 600; }}
  tr:last-child td {{ border-bottom: none; }}
  .row-name {{ font-weight: 600; white-space: nowrap; }}
  .num {{ font-variant-numeric: tabular-nums; white-space: nowrap; }}
  .muted {{ color: var(--muted); }}
  .small {{ font-size: 12.5px; }}
  .badge {{ display: inline-block; padding: 2px 9px; border-radius: 999px; font-size: 12px;
           font-weight: 600; white-space: nowrap; }}
  .badge.green {{ background: color-mix(in srgb, var(--green) 18%, transparent); color: var(--green); }}
  .badge.partial {{ background: color-mix(in srgb, var(--partial) 20%, transparent); color: var(--partial); }}
  .badge.notrun {{ background: color-mix(in srgb, var(--notrun) 16%, transparent); color: var(--notrun); }}
  .chips {{ white-space: nowrap; }}
  .chip {{ display: inline-block; padding: 2px 8px; margin: 1px 3px 1px 0; border-radius: 5px;
           background: var(--chip); font-size: 12px; font-variant-numeric: tabular-nums; }}
  .chip.planned {{ border: 1px dashed var(--notrun); color: var(--notrun); background: transparent; }}
  .axis {{ display: inline-block; padding: 1px 7px; margin: 1px 3px 1px 0; border-radius: 5px;
           background: color-mix(in srgb, var(--notrun) 14%, transparent); color: var(--notrun); font-size: 12px; }}
  code {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }}
  .note {{ background: var(--panel); border: 1px solid var(--line); border-left: 3px solid var(--accent);
           border-radius: 0 8px 8px 0; padding: 12px 16px; font-size: 13px; margin: 14px 0; }}
  footer {{ margin-top: 48px; padding-top: 18px; border-top: 1px solid var(--line);
            color: var(--muted); font-size: 12.5px; }}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>MASC 진행률</h1>
    <p class="sub">생성 {esc(generated_at)} · {latest_line} · 라이브 {esc(live.get('version', '?'))} <code>{esc(live.get('binary_commit', '?'))[:10]}</code></p>
  </header>

  <section class="metrics">
{metrics}
  </section>

  <h2>제품 시나리오 12행</h2>
  <p class="sub">헌법 <code>target_scenarios</code> 와 1:1 대응한다. 점선 칩은 아직 카탈로그에 없는 미션이다.</p>
  <div class="scroll">
    <table>
      <thead><tr><th>시나리오</th><th>상태</th><th>미션</th><th>필수 조합</th><th>빠진 실행</th></tr></thead>
      <tbody>
{render_scenarios(payload, mapping)}
      </tbody>
    </table>
  </div>

  <h2>E0 라운드 이력</h2>
  <div class="note">
    두 축을 함께 본다. 미션 단위는 assertion 하나만 떨어져도 전체가 fail 이라 크게 흔들리고,
    assertion 단위가 실제 전진을 더 잘 나타낸다. 미션 수만 보면 표본 분산을 회귀로 오독한다.
  </div>
  <div class="scroll">
    <table>
      <thead><tr><th>라운드</th><th>assertion</th><th>미션</th><th>실패 미션</th></tr></thead>
      <tbody>
{render_rounds(payload)}
      </tbody>
    </table>
  </div>

  <h2>기능 매트릭스 결손 축</h2>
  <p class="sub">required 로 선언됐지만 evidence 가 없는 축이다.</p>
  <div class="scroll">
    <table>
      <thead><tr><th>도메인</th><th>기능</th><th>비어 있는 축</th></tr></thead>
      <tbody>
{render_missing_axes(payload)}
      </tbody>
    </table>
  </div>

  <h2>헌법 ↔ 코드 격차</h2>
  <div class="scroll">
{render_parity(payload)}
  </div>

  <h2>keeper 위생</h2>
  <p class="sub">이름이 아니라 마지막 턴으로 가른다 — adm-race 는 테스트 잔재처럼 읽히지만 실제로 계속 돌고 있었다.</p>
  <div class="scroll">
    <table>
      <thead><tr><th>keeper</th><th>상태</th><th>역할</th><th>마지막 턴</th><th>비고</th></tr></thead>
      <tbody>
{render_keepers(payload)}
      </tbody>
    </table>
  </div>

  <footer>
    이 페이지의 모든 수치는 <code>scripts/progress/extract_progress.py</code> 가 측정 산출물에서 뽑는다.
    갱신은 추출기를 다시 돌려서 한다 — 문장을 고쳐서 하지 않는다.<br>
    소스: <code>{esc(payload['sources']['matrix'])}</code> · <code>{esc(payload['sources']['reports_dir'])}</code> · <code>{esc(payload['sources']['masc_root'])}</code>
  </footer>
</div>
</body>
</html>
"""


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--payload", required=True)
    parser.add_argument("--mapping", default="scripts/progress/scenario-missions.json")
    parser.add_argument("--out", required=True)
    parser.add_argument("--generated-at")
    parser.add_argument("--live-version", default="?")
    parser.add_argument("--live-commit", default="?")
    args = parser.parse_args()

    with open(args.payload, encoding="utf-8") as handle:
        payload = json.load(handle)
    with open(args.mapping, encoding="utf-8") as handle:
        mapping = json.load(handle)

    generated_at = args.generated_at or datetime.now(KST).strftime("%Y-%m-%d %H:%M KST")
    live = {"version": args.live_version, "binary_commit": args.live_commit}

    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write(build(payload, mapping, generated_at, live))
    print(args.out)


if __name__ == "__main__":
    main()
