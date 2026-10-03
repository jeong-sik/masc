# Narrow Work summary evidence

## 공통 헤더

- 날짜(ISO8601): 2026-10-03T06:55:47.485567+00:00
- 작성자: Codex
- 결정 ID: tui-work-summary-wrap
- 적용 대상: bin/masc_tui_render.ml planning summaries
- 결정 상태: 확정

## 근거 (Evidence)

- 항목: Full Work counters survive narrow summary wrapping without obscuring selected Goal.
- 출처: `test/test_tui_surface_studio_pty.py`; `opam exec --switch=5.5.1 -- scripts/dune-local.sh build bin/masc_tui.exe`; GET `/api/v1/dashboard/planning`
- 확인일시: 2026-10-03T06:55:47.485567+00:00
- 신뢰도: High
- 제한조건: Local candidate fixture PTY and isolated replay of read-only live response. No installed production proof.

## 검증 (Verification)

- 1차: Independent source review identified lost SGR across wrapped rows; response agent switched to existing wrap_styled_words, and reviewer confirmed no P0/P1/P2 remains.
- 2차: Focused TUI build, Ruff and Pyright passed; final source/binary hashes in manifest.
- 3차: Color and no-color surface journeys passed,34 actual captures. Six backlog counters visible at60x24/80x24, full net-change counters at80x24, selected Goal navigation/detail at80x16. Workspace error/path/paging and System selected-document comparison/paging also passed. Five fixture browser frames match every row. Live snapshot27 goals and done317/cancelled217 replayed at60/80 columns, all six backlog counters visible.
- 재현 결과: Before narrow frame omitted done15/cancelled16 in prior unit; after both visible with complete wrapping. Short-height priority keeps current counts before optional trend and reserves Goal detail. Full summaries are optional when physical rows do not fit; no claim they all appear at16 rows.

## 불확실성 (Uncertainty)

- 미확인 항목: Installed production; full Work/Workspace/System feature audit; baseline snapshot age semantic issue#40959.
- 영향: Tested repository/settings fixture cases do not prove every Workspace/System subview. Existing age label remains ambiguous until next unit.
- 추가 확인 필요: Fix#40959 and continue remaining top-nav audit.

## 적용범위 (Scope)

- 영향 받는 영역: Styled planning summary wrapping and physical-row priority.
- 제약/배제: No domain counter mutation, aggregation changes or runtime write.
- 롤백 조건: Revert if summary wrapping obscures selected Goal or loses evidence/style.
