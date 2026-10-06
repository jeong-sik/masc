# Dashboard aggregate read status evidence

## 공통 헤더

- 날짜(ISO8601): 2026-10-03T07:54:06.192222+00:00
- 작성자: Codex
- 결정 ID: tui-dashboard-reading-status
- 적용 대상: bin/masc_tui_home.ml approval summary label
- 결정 상태: 확정

## 근거 (Evidence)

- 항목: Lead with aggregate unread status once, then list unread source names.
- 출처: `test/test_tui_keyboard_overview_pty.py`; `test/test_tui_home_decision_cards_pty.py`; original and final candidate fixture PTY
- 확인일시: 2026-10-03T07:54:06.192222+00:00
- 신뢰도: High
- 제한조건: Candidate fixtures; production rendering unverified. Existing extra partial-state and Python type problems remain tracked.

## 검증 (Verification)

- 1차: Independent source review found no P0/P1/P2 in label change; typed read/freshness/current-card logic untouched, hidden-filter note preserved.
- 2차: Focused TUI build and Ruff passed. Pyright has63 pre-existing diagnostics identical after source line mapping; no new diagnostics, not a green type check. Issue#40984.
- 3차: Full Dashboard overview suite passed after previously stalling at generic unread marker. Unread is distinct from confirmed empty, known held/gate requests survive confirmqueue failure. Three browser replay frames match every row. Keepers rosters suite also passed on the final candidate.
- 재현 결과: PASS for aggregate marker and overview flow. All-source isolated failure and receipt checks remain FAIL#40989; original fixture/earlier candidate reproduce coupled unread source case. No claim of complete partial-failure or receipt behavior.

## 불확실성 (Uncertainty)

- 미확인 항목: Production; full source isolation and receipt behavior; broader remaining surface audit.
- 영향: Existing operator Home loading/fixture problem may hide initial operator cards or leave confirm queue unread; cause not isolated.
- 추가 확인 필요: Investigate#40989 before full Dashboard completion; address fixture types#40984 independently.

## 적용범위 (Scope)

- 영향 받는 영역: Compact Home read-status label and equivalent test wording.
- 제약/배제: No read-state gating, request identity, approval authority or runtime mutation changes.
- 롤백 조건: Revert if aggregate marker masks source evidence or changes request behavior.
