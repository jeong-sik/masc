# Usage charts and reported headroom

## 공통 헤더
- 날짜(ISO8601): 2026-10-03T05:15:01.973586+00:00
- 작성자: Codex
- 결정 ID: tui-usage-charts
- 적용 대상: bin/masc_tui_overview_providers.*, bin/masc_tui_usage_trend.*, bin/masc_tui_render.ml
- 결정 상태: 확정

## 근거 (Evidence)
- 항목: Understand account quota reports with shaded remaining meters, exact-window mini trends, fixed 0–100% UTC daily bar charts, and separate reported-limit versus observed-blocked counts.
- 출처: Candidate source, executable tests, isolated PTY and browser replay frames in this directory. Read-only `/api/v1/runtime/resolved` and `/api/v1/dashboard/provider-usage-history?days=14` snapshots. Issue https://github.com/jeong-sik/masc/issues/40893.
- 확인일시: 2026-10-03T05:15:01.973586+00:00; live GET snapshot captured 2026-10-03T03:41:29.941104+00:00.
- 신뢰도: High
- 제한조건: Public screenshots use fixture data. Two private screenshots replay actual GET snapshots through the candidate binary against an isolated fixture server. Neither is installed/production TUI proof. History contains latest reports per UTC day, not measured daily consumption.

## 검증 (Verification)
- 1차: Independent source review and delta reviews: no remaining P0/P1/P2 findings. Corrected compact-zero semantics, narrow meter allocation, and wide chart pairing after accounting for Recent sidebar width.
- 2차: `opam exec --switch=5.5.1 -- scripts/dune-local.sh build test/test_tui_overview_providers.exe bin/masc_tui.exe` passed. Pin checks intermittently exited silently in the sandbox; the same guarded command outside it passed. No dependency guards were bypassed.
- 3차: `env -u NO_COLOR TERM=xterm-256color _build/default/test/test_tui_overview_providers.exe`: 16/16 passed. Ruff/Pyright passed for the modified Python fixture. Ruff format still reports the existing base-file formatting differences; whole-file reformatting was avoided.
- 재현 결과: PASS. Plan 220x80 and 80x30; 80x16 scrolling; Trend 220x60 side-by-side account headings and 80x30; color/no-color; 1/7/14-day navigation; unavailable-source state. Zero, missing days, exact quota-window joins, unknown catalogue state and 44-column card meter width are covered. Four public and two private browser captures matched every source PTY row. The live GET snapshots contain 15 quota scopes, 11 reporting scopes, 95 history points in a 14-day window, and 0 unreadable reports. A temporary Python `inspect.py` shadowed the standard library during the first browser capture attempt; final probes and captures use `python3 -P` to isolate imports. No file belonging to another session was modified.

## 불확실성 (Uncertainty)
- 미확인 항목: Installed/production TUI behavior, fresh provider quota re-query, re-login behavior, complete release CI, independent GitHub approval.
- 영향: Remaining percentages describe the last provider report. History gaps remain absent, timestamps are preserved, and chart drawing clips at 0–100% while original latest values remain visible. Report age is not guessed into an availability status.
- 추가 확인 필요: Independent PR approval, normal integration and release before production availability claims.

## 적용범위 (Scope)
- 영향 받는 영역: Usage Plan account cards and summaries; Usage Trend daily charts; related executable and PTY fixtures.
- 제약/배제: No provider/login/quota mutations. Raw live HTTP bodies and private live screenshots remain local, not published in this PR.
- 롤백 조건: Revert this bounded UI change if integration shows quota-identity or viewport regressions.

[Plan](plan-compact.png) · [Wide Plan](plan-wide.png) · [Trend](trend.png) · [Compact Trend](trend-compact.png) · [Manifest](manifest.json) · [Checks](tests.log)
