# Four-request streaming adversarial evidence

## 공통 헤더
- 날짜(ISO8601): 2026-10-02T12:30:41.582459+09:00
- 작성자: Codex
- 결정 ID: four-request-streaming-repair
- 적용 대상: TUI source selection and Claude/Codex/Antigravity text forwarding
- 결정 상태: 추적 필요

## 근거 (Evidence)
- 항목: Exact parent source and executed text reconciliation counterexamples
- 출처: PR #40736 head 601a14d2a503cb980ab64f4d94c624efc397ebde; docs/evidence/2026-10-02-adversarial-streaming/text-reconciliation-before.txt; text-reconciliation-after.txt
- 확인일시: 2026-10-02T12:30:41.582459+09:00
- 신뢰도: High
- 제한조건: Interpreter execution proves shared helper cases; added native fixtures and live provider behavior are unexecuted.

## 검증 (Verification)
- 1차: Three specialist source reviews of TUI flow, runtime structure and implementation counterexamples.
- 2차: Actual helper interpreter execution passes 51 assertions across 16 four-message tool-boundary masks.
- 3차: Eleven touched source/interface files syntax parse; git diff --check passes.
- 재현 결과: Old helper loses terminal suffix/new final; repaired helper returns expected output. Native tests are added but not executed.

## 불확실성 (Uncertainty)
- 미확인 항목: Exact-head native suites, integrated PTY, real providers, screenshot.
- 영향: Source verdict and helper execution do not certify installed runtime behavior.
- 추가 확인 필요: Run focused runtime/TUI fixtures and live before/after input frames in a permitted lane; tracked by #40714 and #40735.

## 적용범위 (Scope)
- 영향 받는 영역: Source selection, history memo and text completion forwarding.
- 제약/배제: No restart, release, credentials, scheduling or provider configuration.
- 롤백 조건: Revert this child PR if exact-head regressions show output loss or duplication.
