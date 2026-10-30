# Work source timestamp visibility

## 공통 헤더

- 날짜(ISO8601): 2026-10-03T07:15:41.276265+00:00
- 작성자: Codex
- 결정 ID: tui-work-baseline-time
- 적용 대상: Work summary renderer
- 결정 상태: 확정

## 근거 (Evidence)

- 항목: Server snapshot generation time is distinct from TUI receive/process time.
- 출처: `bin/masc_tui.ml` planning_baseline assignment; `bin/masc_tui_render.ml`; `test/test_tui_surface_studio_pty.py`
- 확인일시: 2026-10-03T07:15:41.276265+00:00
- 신뢰도: High
- 제한조건: Candidate fixture PTY; no installed production or new live provider measurement.

## 검증 (Verification)

- 1차: Independent source review confirmed both source timestamps sanitized, baseline preserved on refresh, workspace switch resets baseline and row budget keeps context/deltas together. No P0/P1/P2.
- 2차: Focused TUI build, Ruff and Pyright passed; manifest source/binary hashes pin capture provenance.
- 3차: Color and no-color surface scenarios plus actual refresh journey passed,35 captures. Baseline remains2026-08-22, current becomes2026-08-23; counts change+2/+3/+1 and labels match both. Three browser replay frames match every row. Existing Board80column vote hint and Recent pane content-floor scenarios also passed.
- 재현 결과: PASS; a freshly opened TUI no longer labels an old server snapshot as42days of process age. Optional timestamp/delta section remains grouped and may be absent on short screens; selected Goal remains reachable.

## 불확실성 (Uncertainty)

- 미확인 항목: Installed production; full Board/Recent state audit and remaining top-nav subviews.
- 영향: Narrow vote hint and panel geometry proof do not establish all Board/Recent behavior.
- 추가 확인 필요: Continue pending audit rows; rollout separately.

## 적용범위 (Scope)

- 영향 받는 영역: Work baseline/current source time and change caption.
- 제약/배제: No new clock-state field, counter changes, time window changes or runtime mutation.
- 롤백 조건: Revert if baseline is mislabeled or refresh loses its comparison context.
