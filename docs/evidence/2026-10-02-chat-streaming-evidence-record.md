# Cross-runtime text streaming protocol evidence

## 공통 헤더

- 날짜(ISO8601): 2026-10-02T12:01:05+09:00
- 작성자: Codex
- 결정 ID: chat-streaming-continuity-40735
- 적용 대상: lib/runtime/runtime_claude_code.ml; lib/runtime/runtime_codex_app_server.ml; lib/keeper/keeper_antigravity_runtime.ml
- 결정 상태: 추적 필요

## 근거 (Evidence)

- 항목: Claude token-level partial messages require an explicit flag; completed assistant blocks arrive before their stop event. Codex completed items finalize token deltas.
- 출처: https://code.claude.com/docs/en/headless; https://code.claude.com/docs/en/agent-sdk/streaming-output; https://openai.com/index/unlocking-the-codex-harness/
- 확인일시: 2026-10-02T12:01:05+09:00
- 신뢰도: High
- 제한조건: Official live protocol documentation; installed CLI versions and provider delivery not measured in this session.

## 검증 (Verification)

- 1차: Official streaming documentation read and compared with current CLI invocation and protocol parsers.
- 2차: Source paths inspected across all runtime kinds; local `claude --version` reports 2.1.287, `claude --help` declares --include-partial-messages, and `codex --version` reports 0.160.0.
- 3차: Regression fixtures added for partial/complete text and optional identities; syntax parsing and diff whitespace checks pass.
- 재현 결과: Source defects identified and corrected; executable regressions are not run.

## 불확실성 (Uncertainty)

- 미확인 항목: Runtime executable tests, actual provider calls, actual TUI screenshot.
- 영향: Source review does not certify compiled or production behavior.
- 추가 확인 필요: Focused runtime/TUI test suites on exact PR head; isolated actual TUI before/after-input frames.

## 적용범위 (Scope)

- 영향 받는 영역: Text event forwarding and TUI output continuity.
- 제약/배제: No scheduling, provider entitlement, credentials, Keeper declarations, server/TUI restart, installation or release changes.
- 롤백 조건: Protocol fixtures show conflicting/duplicated text or existing runtime invariants fail.
