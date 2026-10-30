# TUI login and quota visibility

## 공통 헤더
- 날짜(ISO8601): 2026-10-03T03:22:13.297602+00:00
- 작성자: Codex
- 결정 ID: tui-login-usage-visibility
- 적용 대상: bin/masc_tui_account_login.ml, bin/masc_tui_overview_providers.ml
- 결정 상태: 확정

## 근거 (Evidence)
- 항목: Connected models remain visible without duplicate addition; retained connections are summarized; each quota window identifies its last report.
- 출처: Candidate source, focused executable tests, isolated fixture PTY captures in this directory; issue https://github.com/jeong-sik/masc/issues/40855
- 확인일시: 2026-10-03T03:22:13.297602+00:00
- 신뢰도: High
- 제한조건: Local candidate binary and fixture data. PNGs render captured PTY text without ANSI colors. They do not show the installed binary or production.

## 검증 (Verification)
- 1차: Independent source and delta review: no remaining P0/P1/P2 findings. Removed a guidance line that would hide verification failures on short terminals.
- 2차: `opam exec --switch=5.5.1 -- scripts/dune-local.sh build test/test_tui_account_login.exe test/test_tui_overview_providers.exe bin/masc_tui.exe` passed. The first attempt found a split opam environment; selecting the coherent switch resolved it.
- 3차: `test_tui_account_login.exe`: 31/31; `env -u NO_COLOR TERM=xterm-256color test_tui_overview_providers.exe`: 15/15. The initial color assertion failed with inherited NO_COLOR=1; the colored run passed. Ruff and Pyright passed on both changed Python fixtures. Ruff format reports pre-existing formatting differences in both base files; no whole-file formatting changes were made.
- 재현 결과: PASS — existing-account fixture showed both connected models and selected only the new one without starting login. Usage journey passed 220x48, 80x30, 80x16 scrolling, view switching and no-data views. A separate full-frame capture attempt using unchanged terminal dimensions timed out; capturing the already emitted PTY buffer completed instead. Source and binary hashes are in manifest.json. Original captured frames are retained as .ansi and decoded rows as .txt.

## 불확실성 (Uncertainty)
- 미확인 항목: Installed/production UI, current real account quota, complete release CI, GitHub independent approval.
- 영향: Reports retain their real values and existing alarm colors; no arbitrary freshness threshold or inferred quota reset is introduced.
- 추가 확인 필요: Independent PR approval and normal integration/release before claiming production availability.

## 적용범위 (Scope)
- 영향 받는 영역: TUI model picker, successful save summary, Plan quota cards, related fixtures.
- 제약/배제: Provider discovery, credentials, actual usage refresh and quota state are unchanged.
- 롤백 조건: Revert the visibility change if integration shows selection or rendering regressions.

[Connected models](connected-models.png) · [Wide usage](plan-wide.png) · [Compact usage](plan-compact.png)
