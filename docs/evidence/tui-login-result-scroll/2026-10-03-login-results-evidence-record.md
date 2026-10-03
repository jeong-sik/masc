# Login result visibility evidence

## 공통 헤더

- 날짜(ISO8601): `2026-10-03T05:59:15.750821+00:00`
- 작성자: Codex
- 결정 ID: tui-login-result-scroll
- 적용 대상: bin/masc_tui_account_login.ml
- 결정 상태: 확정

## 근거 (Evidence)

- 항목: Long results remain reachable from the summary on a small terminal.
- 출처: `test/test_tui_account_login_pty.py` existing-account result scroll scenario; `_build/default/test/test_tui_account_login.exe`
- 확인일시: `2026-10-03T05:59:15.750821+00:00`
- 신뢰도: High
- 제한조건: Candidate executable with isolated fixture HTTP responses, not installed production.

## 검증 (Verification)

- 1차: Independent source review found no P0/P1/P2 issue in result scrolling.
- 2차: Focused build of login test and TUI executable passed; 32 login tests passed; Ruff and Pyright passed.
- 3차: Actual 80x16 PTY keyboard flow saved a fixture receipt with 12 limited runtimes, scrolled to the last reason and back to the summary. Resizing at the bottom preserved reachable content. Browser terminal replay matched every captured row.
- 재현 결과: PASS for the focused result journey. See manifest.json, login-result-top.png and login-result-bottom.png with matching ANSI/text frames.

## 불확실성 (Uncertainty)

- 미확인 항목: Production rollout, live account login or provider quota refresh.
- 영향: Fixture proves rendering and keyboard behavior only.
- 추가 확인 필요: Installed candidate check belongs to a rollout; full TUI surface audit is tracked separately.

## 적용범위 (Scope)

- 영향 받는 영역: Finished/Failed login result viewport and hints.
- 제약/배제: Provider selection, quota values and runtime availability are unchanged.
- 롤백 조건: Revert this unit if result rows become unreachable.
