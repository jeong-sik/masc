# Rondo Tool-Only Budget Exhaustion Report

- `작성일시`: 2026-07-01T19:02:58+09:00
- `대상`: MASC keeper runtime, `rondo` on `ollama_cloud.deepseek-v4-flash`
- `GitHub issue`: https://github.com/jeong-sik/masc/issues/22910
- `상태`: 코드 수정 및 focused regression 통과

## 요약

라이브 `~/me/.masc`에서 `rondo`가 budget-exhausted tool-only turn을 반복했고, 화면에는 `Tool-only turn ended without a final reply.`가 보였다. 문제는 provider가 반복 tool call을 만든 것만이 아니라, MASC success path가 `TurnBudgetExhausted + response_text_present=false + execution-classified tool`을 `satisfied_execution` 및 `Disp_pass`로 받아들일 수 있었다는 점이다.

이번 수정은 두 경계를 고정한다.

1. `TurnBudgetExhausted`에서는 raw text가 있어도 visible reply가 suppressed 되므로 completion contract 판정에서도 visible reply 없음으로 취급한다.
2. budget-exhausted turn이 completion tool 없이 execution-classified tool만 남기면 `satisfied_execution`이 아니라 `needs_execution_progress`가 된다.
3. 그렇게 내려온 `alert_exhausted + needs_execution_progress` 결과는 success handler에서 `Terminal_checkpoint`로 세탁되지 않고 completion-contract failure로 종료된다.

## 근거

- `GitHub issue #22910`: live evidence archived. `gh issue view 22910 --repo jeong-sik/masc --json number,title,state,url,createdAt,updatedAt,body`, 확인일시 2026-07-01T19:02:58+09:00, 신뢰도 High.
- `focused build`: `scripts/dune-local.sh build test/test_keeper_unified_claim_progress.exe test/test_no_progress_loop_detector.exe`, 확인일시 2026-07-01T19:11:39+09:00, 신뢰도 High.
- `regression run`: `_build/default/test/test_keeper_unified_claim_progress.exe` passed 13 tests, 확인일시 2026-07-01T19:11:39+09:00, 신뢰도 High.
- `regression run`: `_build/default/test/test_no_progress_loop_detector.exe` passed 32 tests, 확인일시 2026-07-01T19:11:39+09:00, 신뢰도 High.

## 변경 내용

- `lib/keeper/keeper_agent_run_contract_helpers.ml`
  - `observed_completion_contract_status`에 `stop_reason`을 전달한다.
  - `TurnBudgetExhausted`이면 raw response text를 visible response evidence로 보지 않는다.
  - `TurnBudgetExhausted + Contract_satisfied_execution`을 `Contract_needs_execution_progress`로 낮춘다.
  - explicit completion tool은 여전히 `satisfied_completion`으로 인정한다.

- `lib/keeper/keeper_agent_run.ml`
  - contract helper 호출에 runtime `stop_reason`을 전달한다.

- `lib/keeper/keeper_unified_turn_success.ml`
  - `Disp_alert_exhausted + Reason_turn_budget_exhausted`가 unsatisfied completion contract를 동반하면 terminal failure reason으로 승격한다.
  - `Contract_passive_only`는 기존처럼 no-progress detector 입력으로 남기고 completion-contract auto-failure로 승격하지 않는다.

- `test/test_keeper_unified_claim_progress.ml`
  - `turn_budget_exhausted + tool_execute + no visible reply`가 `satisfied_execution`으로 통과하지 못하는 회귀 테스트를 추가했다.
  - raw text가 있어도 budget exhaustion으로 visible text가 suppressed 되는 경우를 같이 고정했다.
  - completion tool은 차단하지 않는 것을 고정했다.

- `test/test_no_progress_loop_detector.ml`
  - `alert_exhausted + needs_execution_progress + TurnBudgetExhausted`가 `Terminal_checkpoint`/`ContractOk`로 끝나지 않는 것을 고정했다.

## 적대적 검증

- OAS 책임으로만 돌릴 수 있는가: 아니다. OAS가 `stop=tools_executed`를 반복하더라도, MASC가 completion contract와 terminal FSM에서 이를 pass로 바꾸면 MASC boundary 문제다.
- 모든 budget-exhausted tool turn을 실패시키는가: 아니다. explicit completion tool은 `satisfied_completion`으로 유지된다.
- passive idle/no-work 경로를 깨는가: 아니다. `Contract_passive_only`는 기존처럼 no-progress detector 경로에 남는다.
- raw text가 있는 provider 응답이면 안전한가: 아니다. 기존 finalize path는 budget exhaustion에서 visible response를 suppress 하므로, contract도 raw text가 아니라 visible reply semantics를 따라야 한다.
- `Disp_pass`만 막으면 충분한가: 아니다. terminal success path가 `Terminal_checkpoint`로 `ContractOk`를 낼 수 있어, `alert_exhausted + attention contract`도 terminal failure로 고정했다.

## 검증 결과

```text
scripts/dune-local.sh build test/test_keeper_unified_claim_progress.exe test/test_no_progress_loop_detector.exe
=> exit 0

_build/default/test/test_keeper_unified_claim_progress.exe
=> 13 tests run, Test Successful

_build/default/test/test_no_progress_loop_detector.exe
=> 32 tests run, Test Successful
```

## 남은 리스크

- 라이브 `~/me/.masc` 런타임에는 아직 이 branch가 배포되지 않았다. 이 보고서는 source-level fix와 focused regression 결과다.
- material progress identity의 장기 개선은 여전히 필요하다. 이번 패치는 “no visible final reply인데 execution tool만으로 pass 되는” 즉시 루프를 막는 좁은 방어다.
- `rondo`가 같은 provider에서 다른 형태의 반복을 만들 수 있으므로, 배포 후 live receipts에서 `operator_disposition=pass`가 사라졌는지 재측정해야 한다.
