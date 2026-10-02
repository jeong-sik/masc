# Workspace economics scope

## 공통 헤더

- 날짜(ISO8601): 2026-10-02T07:52:02.765967+00:00
- 작성자: Codex
- 결정 ID: tui-workspace-currency-scope-20261002
- 적용 대상: native TUI over parent d27a59cf67c9e9cbcb84f37984bd51e282009551
- 결정 상태: 추적 필요

Workspace Candle supply/status now appears above Keeper economics in Usage, separated by a full-width divider. Personal Info retains the selected Keeper balance. Technical queue pressure remains in Usage / Telemetry; its duplicate in economics is removed.

## 근거 (Evidence)

- 항목: personal versus workspace information ownership
- 출처: focused native build, native PTY logs in checks/, economics-24/manifest.json and candidate-source.patch
- 확인일시: 2026-10-02T07:52:02.765967+00:00
- 신뢰도: High for synthetic fixtures
- 제한조건: native fixture PTY; no installed or production session

Captured fixed binary SHA-256: `96c0836bbd3addfddfa1eb4606c3f8954692405528a3a759608c05a35963d26f`. It was built from an uncommitted source overlay over the parent, not the final committed PR head. All 30 PNG/text hash pairs were verified. Actual terminal sizes are 80/120/240 columns by 24 rows. Earlier capture attempts are excluded. The usage fixture intentionally returns an unavailable Keeper usage endpoint, so this image proves scope, wrapping and status rendering rather than a populated usage table.

## 검증 (Verification)

- 1차: Focused `scripts/dune-local.sh build bin/masc_tui.exe` passed with process-local opam switch 5.5.1.
- 2차: New scope PTY fails on the parent with workspace supply leaking into personal Info, then passes on the candidate. It checks personal balance, global totals, removal of duplicate pressure and retained Telemetry pressure.
- 3차: Independent source review found no P0/P1/P2; this is advisory review, not GitHub approval.
- Capture helper Ruff passes. Currency helper has the same four Ruff and 36 Pyright diagnostics as its unchanged baseline. `git diff --check` passes.
- 재현 결과: Full currency PTY suite still fails ready-to-booting Help authority withdrawal. The same focused authority scenario fails on the parent. Recorded at https://github.com/jeong-sik/masc/issues/40598#issuecomment-5947660316 . This is not a full-suite pass.

## 불확실성 (Uncertainty)

- 미확인 항목: exact committed-head execution, installed/production behavior, remaining sub-tabs and overlays
- 영향: whole layout goal #40806 remains active; no release readiness claim
- 추가 확인 필요: broader boundary audit and integrated evidence

## 적용범위 (Scope)

- 영향 받는 영역: Info and Usage presentation, regression fixture, capture readiness
- 제약/배제: account authority and runtime state transitions
- 롤백 조건: workspace status disappears or personal balance is lost
