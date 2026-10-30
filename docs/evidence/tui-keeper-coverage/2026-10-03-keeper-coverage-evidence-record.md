# Keeper unread-row visibility

Historical pre-stack candidate evidence only. The recorded hashes and frames precede current decoder/rendering integration, including suppression of comparison bars for partial windows. No current-head binary, PTY run or browser replay has been produced; the old PASS results do not cover these repairs.


## 공통 헤더

- 날짜(ISO8601): 2026-10-03T06:34:24.781724+00:00
- 작성자: Codex
- 결정 ID: tui-keeper-coverage
- 적용 대상: lib/tui_decode_usage.ml and Usage Keepers renderer
- 결정 상태: 확정

## 근거 (Evidence)

- 항목: Preserve unread turn rows as partial coverage rather than a complete read.
- 출처: `lib/dashboard/dashboard_http_keeper_feeds.ml` producer; `test/test_tui_usage_studio_pty.py`; `test/test_tui_usage_rows_pty.py`; focused TUI build
- 확인일시: 2026-10-03T06:34:24.781724+00:00
- 신뢰도: High
- 제한조건: Candidate fixture PTY and isolated candidate replay of a read-only live snapshot. No installed production claim.

## 검증 (Verification)

- 1차: Independent source review found no P0/P1/P2; producer emits malformed_rows and unread_turn_rows for every read.
- 2차: Focused `bin/masc_tui.exe` build, Ruff and Pyright passed. Source and binary SHA256 in manifest.
- 3차: Same updated fixture fails on previous candidate due to missing unread counts. Final candidate passes six Usage journeys and narrow coverage at60/80/120 columns plus scrolling. Mixed and unread-only coverage both visible as partial lower bounds; complete, failed and zero remain distinct. Four browser replay frames match every terminal row. Current live snapshot28 rows,0 unread turn rows, decoded/replayed successfully.
- 재현 결과: Before expected FAIL; after PASS. Broader surface audit separately stopped at narrow Work summary clipping#40947; no Workspace/System completion claimed.

## 불확실성 (Uncertainty)

- 미확인 항목: Production install; real live rows with unread counts; broader top-nav audit unfinished.
- 영향: Fixture proves unread-row presentation; current live snapshot has no affected row.
- 추가 확인 필요: Fix#40947 then resume full surface audit.

## 적용범위 (Scope)

- 영향 받는 영역: Typed Keeper coverage, partial label and fixture contracts.
- 제약/배제: No aggregation/quota/runtime data mutation or invented totals.
- 롤백 조건: Revert unit if complete or unread-only coverage is misclassified.
