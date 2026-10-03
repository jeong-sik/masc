# Keeper usage comparison evidence

Historical evidence only: these frames precede the unread-turn decoder and partial-window comparison repair. Their bars and recorded hashes describe the old candidate. No new binary, PTY or browser replay verifies the corrected source.


## 공통 헤더

- 날짜(ISO8601): 2026-10-03T06:16:08.661479+00:00
- 작성자: Codex
- 결정 ID: tui-keeper-usage-comparison
- 적용 대상: bin/masc_tui_render.ml Usage Keepers
- 결정 상태: 확정

## 근거 (Evidence)

- 항목: Independent token/cost scales preserve unavailable values and show aggregate time.
- 출처: `opam exec --switch=5.5.1 -- scripts/dune-local.sh build bin/masc_tui.exe`; `test/test_tui_usage_studio_pty.py` keeper_comparison; GET `/api/v1/dashboard/keeper-costs?window=1440`
- 확인일시: 2026-10-03T06:16:08.661479+00:00
- 신뢰도: High
- 제한조건: Candidate fixture PTY and candidate replay of a read-only live snapshot. Production executable unchanged.

## 검증 (Verification)

- 1차: Independent source review found no P0/P1/P2 in final comparison logic.
- 2차: Focused TUI build, Ruff and Pyright passed.
- 3차: Full six-journey Usage PTY suite passed, including three Keeper journeys: color, no color, entirely unreported cost. Exact browser replay matched wide, compact and scrolled-bottom frames. Live response had28 Keepers,22 reported token totals and0 reported costs; candidate replay passed with cost unreported rather than zero.
- 재현 결과: PASS for comparisons, missing versus zero, independent metric scales, failed-row exclusion, partial/missing evidence, stale refresh failure and80x20 scrolling. Fixture cache state initially used invalid stale; corrected to protocol stale_refreshing and reran all Keeper journeys successfully.

## 불확실성 (Uncertainty)

- 미확인 항목: Installed production rendering. Existing decoder omits unread_turn_rows, tracked #40931 for next unit.
- 영향: Unread turn rows may understate coverage even though current live snapshot has0 unread rows.
- 추가 확인 필요: Complete #40931 and remaining TUI audit; rollout separately.

## 적용범위 (Scope)

- 영향 받는 영역: Keeper Usage relative bars, scale and generated UTC timestamp.
- 제약/배제: No quota, provider or runtime state mutation; no daily Keeper history is fabricated.
- 롤백 조건: Revert this unit if unavailable metrics draw zero bars or relative scales become inconsistent.
