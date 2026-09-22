---
rfc: "typed-terminal-reason"
title: "Keeper 턴 종료 사유를 끝까지 타입으로 나른다"
status: Draft
created: 2026-09-22
updated: 2026-09-22
author: claude
related: ["0454", "0371", "0004"]
---

# Keeper 턴 종료 사유를 끝까지 타입으로 나른다

- Status: **Draft (2026-09-22).** §1 의 결정은 초안이다. 운영자 확인이 필요하다.
- 한 줄: 턴이 왜 끝났는지는 지금 문자열 하나로 저장된다. 읽는 쪽은 그 문자열을 접두어로 다시 나눈다.
  종료 사유를 닫힌 합타입 `Keeper_turn_end.t` 로 만들어 영수증(receipt)과 decision log 에 그대로 싣는다.
  문자열은 화면과 metric label 로 내보낼 때만 만든다.
- 기준: main `7755743ea7`. 라이브 데이터는 `~/me/.masc/keepers` 를 읽기만 했다.

## 1. 결정 (초안, 운영자 확인 필요)

- **D1 원천은 typed 값 하나다.** receipt 의 `terminal_reason_code : string` 을 `terminal_reason : Keeper_turn_end.t` 로 바꾼다.
  파일에는 `"terminal_reason": {"kind": ...}` 객체로 쓴다. `terminal_reason_code` 필드는 없어진다.
- **D2 다시 나누는 코드를 지운다.** `Keeper_terminal_reason` 모듈 전체를 지운다.
  `of_wire` 의 접두어 분류와 `is_transient_provider_runtime_failure` 의 접두어 비교가 여기 있다.
  `Keeper_internal_error.wire_kind_of_string` 과 `Keeper_provider_runtime_boundary` 의 timeout 접두어 파서도 지운다.
  `operator_disposition` 은 `Keeper_turn_end.t` 를 빠짐없이 match 한다.
- **D3 공식 클라이언트 실패는 `ProviderReportedError` 를 떠난다.** claude_code·codex·antigravity 런타임이 스스로 판단한 실패가 있다.
  `turn_failed`, `rpc_error`, 활동 뒤 context window 초과다. 이것들은 masc 가 가진 닫힌 값
  `Keeper_internal_error.Official_client_failed` 로 carrier 에 싣는다.
  `ProviderReportedError` 에는 제3자 provider 가 보낸 오류 봉투만 남는다.
- **D4 agent-core 에러 투영은 하나만 둔다.** `Keeper_turn_end` 의 agent-core 쪽은 RFC-0454 §2.2 의
  `Keeper_request_failure_core.t`(생성자별 투영)를 그대로 쓴다. 두 번째 투영을 만들지 않는다.
- **D5 hard cut.** 옛 receipt 줄과 옛 decision log 의 `terminal_reason` 은 decode 실패로 읽는다.
  호환 reader·converter·migration 은 만들지 않는다. 옛 줄이 어떻게 되는지는 §3.6 에 적었다.
- **D6 모르는 값은 decode 실패다.** OCaml `of_yojson` 도 대시보드 decoder 도 모르는 `kind`, 빠진 필드, 남는 필드를 거절한다.
  `Unknown { raw_error }` 같은 편리한 칸은 없앤다.
- **D7 흐름은 바꾸지 않는다.** 모든 PR 은 keeper 턴 흐름(route, rotation, retry, lane walk)의 답을 main 과 같게 둔다.
  운영자 broadcast 가 나가는 경우의 집합도 같게 둔다. 바뀌는 것은 저장 형식과 라벨이다. PR 마다 §4 표에 적는다.
  D3 은 흐름을 바꿀 수 있는 유일한 변경이다. masc 분류 뒤에 `Some _` catch-all 이 있어서 컴파일러가 빠뜨림을 못 잡는다(§3.3).
  그래서 첫 PR 은 그 catch-all 을 명시 갈래로 바꾸는 일이다.
- **D8 클라이언트는 wire 문자열로 판정하지 않는다.** 서버가 typed 값으로 내린 판정(막힘, severity, 다음 행동)을 그린다.
  막힘은 실패 종류일 때만이고, 서버는 그것을 `Keeper_turn_end.t` 의 exhaustive match 로 정한다(§3.8).
- **D9 RFC-0159 파일을 이 커밋에서 지운다.** 그 문서는 지금 없는 `Disp_pause_human` 과 문자열 갈래를 전제로 쓰였다.
  그 문서가 원한 것, 곧 내부 실패의 출처를 구별하는 일은 D1 의 typed 값이 싣는다(§3.2).

운영자에게 확인받을 것:

- **Q1** D3 을 어디에 둘지. masc_internal_error 에 싣는 안(A)을 권한다. 다른 두 안을 기각한 이유는 §3.3 에 있다.
- **Q2** D4 는 RFC-0454 P2 와 같은 일이다. 어느 쪽이 먼저 PR 을 열지 정해야 한다. 같은 투영을 두 번 만들지 않는다.
- **Q3** 배포할 때 옛 receipt 디렉터리를 지울지. 2026-09-22 기준 keeper 27개, 파일 335개, 77,625줄, 207MB 다.
  지우지 않아도 부팅은 막히지 않는다(§3.6).
- **Q4** 열린 PR #37580 을 닫고 PR-1 로 흡수할지. #37580 은 `"turn_failed:" ^ reason` 콜론 코드를 새로 만든다.
  이 RFC 는 같은 정보를 typed 필드로 싣는다.
  열린 PR #37584 는 `ProviderReportedError` 의 route 를 rotation 으로 바꾼다. 이건 흐름 변경이다.
  #37584 가 먼저 들어가면 PR-1 은 그 route 를 그대로 옮긴다.
- **Q5** §3.8 의 막힘 표. `Registry_phase_missing` 과 runtime build 실패를 막힘으로, supervisor stop·external cancel·실행 불가 phase 를 막힘 아님으로 두는 안이다.

## 2. 문제와 실측

### 2.1 한 사실을 여러 형태로 들고 다니는데, 저장되는 건 문자열이다

"턴이 왜 끝났나" 라는 사실 하나가 여섯 가지 형태로 돌아다닌다. 그런데 파일에 남는 것은 문자열뿐이다.

| 형태 | 위치 | 하는 일 |
|---|---|---|
| `terminal_reason_code : string` | `Keeper_execution_receipt_types.t` | 저장되는 유일한 값 |
| `Keeper_turn_terminal_code.t` (생성자 8개) | producer 층 | `Agent_core_error { wire; timeout }` 가 문자열을 싸서 나른다 |
| `Keeper_turn_disposition.t` (6개) | 운영자 층 | `Provider_error of code`, `Unknown { raw_error }`. 문자열에서 되살리면 대부분 `Unknown` 이 된다 |
| `Keeper_turn_terminal.t` (레코드) | decision log | disposition 옆에 source·severity·summary·next_action 문자열을 저장한다. 전부 파생값이다 |
| `Keeper_terminal_reason.t` (14개) | receipt 소비자 | 저장된 문자열을 접두어로 다시 나눈다. 14개 생성자가 전부 원래 문자열을 payload 로 든다 |
| `Keeper_internal_error.wire_kind` (16개) | masc 내부 에러 | `of_wire` 가 문자열을 되맞히려고 만든 열거다. mli 가 그렇게 적는다(`keeper_internal_error.mli:268-277`) |

사슬은 이렇다.

```
Agent_core.Error.t                      원인을 아는 곳은 여기뿐이다
 └ Keeper_agent_error.terminal_reason_code_of_core_error        typed → 문자열
    ├ receipt.terminal_reason_code  → execution-receipts/*.jsonl
    │   └ Keeper_terminal_reason.of_wire                          문자열 → 14 버킷 (접두어)
    │       └ operator_disposition → broadcast 여부, 라벨
    ├ Keeper_turn_terminal_code.Agent_core_error { wire }
    │   └ Keeper_turn_terminal.t → <keeper>.decisions.jsonl
    │       └ of_json → Keeper_turn_disposition.of_wire          대부분 Unknown
    └ Keeper_registry.Provider_runtime_error { code = wire }
        └ classify_provider_runtime_error_record                  timeout 접두어
```

`Keeper_terminal_reason` 은 소비자 쪽에 닫힌 합을 만들었다. 하지만 원천은 여전히 문자열이다.
그래서 소비자는 문자열을 다시 파싱할 수밖에 없고, 접두어 순서가 동작을 가른다(`keeper_terminal_reason.ml:140-158`).
인증 코드 두 개가 `api_error_` 로, 두 개가 `provider_error_` 로 시작한다. 그래서 인증 검사가 provider 검사보다 먼저 와야 한다.

### 2.2 생산자 — 문자열을 만드는 곳

| # | 위치 | 만드는 값 | 원천 |
|---|---|---|---|
| G1 | `keeper_agent_error.ml:60-85` `api_error_terminal_reason_code` | `api_error_*` 13종. `api_error_server:%d` 는 매개변수를 문자열에 굽는다 | `Retry.api_error` 12개 생성자 |
| G2 | `keeper_agent_error.ml:97-130` `agent_error_terminal_reason_code` | `agent_error_*` 7종 + `terminal_effect_failed:tool_use_id=…` | `Agent_core.Error.agent_error` 8개 |
| G3 | `keeper_agent_error.ml:140-185` `provider_error_terminal_reason_code` | `provider_error_*` 21갈래. `provider_error_reported:%s` 가 `error_type` 을 그대로 붙인다(150-151) | `Llm_provider.Error.provider_error` 20개 |
| G4 | `keeper_agent_error.ml:187-203` `terminal_reason_code_of_core_error` | `mcp_error`·`config_error`·`serialization_error`·`io_error`·`orchestration_error`·`internal_error` + masc kind | `Agent_core.Error.t` |
| G5 | `keeper_internal_error.ml:856-858` `kind_of_masc_internal_error` | masc kind 16종 | `masc_internal_error` 16개 |
| G6 | `keeper_execution_receipt_types.ml:151-189` | `success`, `input_required`, `yielded_*` 4종(매개변수 포함) | `Runtime_agent.stop_reason` |
| G7 | `keeper_agent_run_receipt.ml:108` | `success` (stop_reason 관측 없음) | 없음 |
| G8 | `keeper_unified_turn_phase_gate.ml:60, 90, 116` | `supervisor_stop`, `non_executable_phase:<phase>`, `registry_phase_missing` | 리터럴 |
| G9 | `keeper_unified_turn_types.ml:438-440` | `supervisor_stop`, `external_cancel` | `streaming_cancellation_source` |
| G10 | `keeper_unified_turn.ml:647-648` | G4 결과 | `Agent_core.Error.t` |
| G11 | `keeper_turn_terminal_code.ml:32-41` `to_wire` | `healthy`, `stale_termination_storm` 등 | `Keeper_turn_terminal_code.t` |
| G12 | `keeper_turn_disposition.ml:54-61` `to_wire` | `success`, `input_required`, `external_cancel`, `runtime_attempts_exhausted` | `Keeper_turn_disposition.t` |
| G13 | `keeper_unified_metrics_decision.ml:113-117` | `unknown_error` 기본값 | 없음. 호출자 2곳이 모두 값을 넘겨 이 갈래는 도달하지 않는다 |

- 문자열을 만드는 함수: 13곳, 파일 8개.
- receipt 레코드를 만드는 곳은 2곳이다. `keeper_agent_run_receipt.ml:151-200` 과 `keeper_turn_helpers.ml:189-231`.
  여기에 값을 넘기는 호출자는 6곳이다(agent run 1곳 + pre-dispatch 5곳: G8 셋, G9, G10).
- `Keeper_terminal_reason` 의 `Pre_dispatch_success` 버킷은 `"pre_dispatch_success"` 를 기다린다.
  이 값을 receipt 에 쓰는 생산자는 없다. 같은 글자는 manifest 의 `routing_reason` 에만 있다(`keeper_unified_turn.ml:705`). 30일 데이터에서도 0줄이다.

### 2.3 저장 — 어디에 남나

| # | 저장소 | 필드 | 크기 (2026-09-22) |
|---|---|---|---|
| S1 | `<base>/.masc/keepers/<k>/execution-receipts/YYYY-MM/DD.jsonl` | `terminal_reason_code` + 파생 라벨 `operator_disposition`, `operator_disposition_reason` | keeper 27개, 파일 335개, 77,625줄, 207MB. 2026-08-23 ~ 2026-09-22 |
| S2 | `<base>/.masc/keepers/<k>.decisions.jsonl*` | `terminal_reason{code, disposition, source, severity, summary, next_action}` + `terminal_reason_code` + `terminal_reason_severity` + `terminal_reason_source` + telemetry `error_category` | 파일 44개, 262MB. `terminal_reason` 이 있는 줄 39,692 |
| S3 | runtime manifest 의 decision payload | `terminal_reason_code` (`keeper_turn_helpers.ml:256, 299`, `keeper_agent_run_receipt.ml:224, 316`) | OCaml 에서 읽는 곳 없음. 스크립트 하나가 읽는다 |
| S4 | activity graph event payload | `keeper.turn_blocked`·`turn_cancelled`·`turn_skipped` (`keeper_turn_helpers.ml:316`), `keeper.operator_broadcast_required` (`keeper_execution_receipt.ml:497`) | OCaml 에서 읽는 곳 없음 |
| S5 | 메모리 안 registry | `Keeper_registry.Provider_runtime_error.code` (`keeper_unified_turn_types.ml:299-300`) | JSON codec 없음. 프로세스와 함께 사라진다 |
| S6 | agent event SSE | `error_code`, `error_detail.code` (`keeper_event_bridge_error_json.ml:499-530`) | 표시용 |

라이브 receipt 는 코드 버전 여러 세대가 섞여 있다.

- 30일 77,625줄, 모양 390종(숫자를 N 으로 접은 뒤). 최근 7일은 18,724줄, 73종이다.
- 지금 코드가 만들지 않는 값이 남아 있다. `awaiting_external_effect:N` 2,190줄(마지막 2026-09-03), `agent_error_terminal_tool_effect_failed` 167줄이다.
- decision log 에서 `source = typed_error` 인 줄은 9,047줄(22.8%)이다. 쓸 때는 typed 값(`Provider_error` 등)이었다.
  다시 읽으면 9,047줄 전부 `Unknown { raw_error }` 가 된다. `Keeper_turn_disposition.of_wire` 가 정확히 아는 값 9개에 없어서다.

### 2.4 소비자 — 누가 읽고, 무엇이 바뀌나

소비자를 세 층으로 나눈다.

- **흐름**: keeper 턴이 다음에 무엇을 하는지 바뀐다(route, rotation, retry, lane walk, pause, claim).
- **부수효과**: 흐름은 그대로인데 밖에 무언가를 남긴다(activity event, metric).
- **라벨**: 사람이 보는 글자와 색만 바뀐다.

| # | 위치 | 읽는 방법 | 층 |
|---|---|---|---|
| C1 | `keeper_execution_receipt.ml:117-353` `operator_disposition` | `Keeper_terminal_reason.of_wire` 1회, `Keeper_turn_disposition.of_wire` 로 `input_required` 확인(128-137), `is_transient_*` (229) | 부수효과 + 라벨 |
| C2 | `keeper_runtime_trust_snapshot.ml:85-93` | receipt 는 `Keeper_turn_terminal.of_code`, decision 은 `of_json` | 라벨 |
| C3 | `server_dashboard_http_composite_claims.ml:371-377, 475` | `Keeper_turn_disposition.of_wire` → `is_success` 가 아니면 전부 막힘, 원문을 reason 으로 표시 | 라벨 |
| C4 | `dashboard_execution.ml:365-392` | `Keeper_turn_disposition.of_wire` → attention, queue severity | 라벨 |
| C5 | `dashboard_http_keeper_types.ml:31-34` → `dashboard_http_keeper_feeds.ml:273, 393` | decision 의 `terminal_reason.code` | 라벨 |
| C6 | `keeper_provider_runtime_boundary.ml:168-222` ← `keeper_status_bridge_blocker.ml:206-243` | registry `code` 의 timeout 접두어 | 라벨(요약 문장만 다르다) |
| C7 | `dashboard_http_keeper_trust.ml:48`, `telemetry_unified.ml:606`, `dashboard_goals.ml:46` | 그대로 넘긴다 | 라벨 |
| C8 | `bin/masc_trace.ml:117` | 표시 | 라벨 |

- **흐름 소비자는 0곳이다.** route·rotation·retry 는 문자열이 아니라 `Agent_core.Error.t` 를 직접 본다
  (`Keeper_runtime_failure_route`, `Keeper_runtime_attempt`, `Keeper_error_classify`, carrier 의 `classify_masc_internal_error`).
- 부수효과는 C1 하나다. `needs_operator_broadcast`(475) 가 `Disp_operator_action_required` 와 `Disp_unknown` 에서
  activity event `keeper.operator_broadcast_required` 를 쓰고 SSE 로 민다. 이 event 를 읽어 동작을 바꾸는 코드는 없다(rg 0건).
  generic 갈래 끝의 unmapped 는 metric 두 개를 올린다(336-352).
- `Keeper_agent_result.result.operator_disposition` 은 쓰기만 하고 읽는 곳이 없다(`keeper_agent_run_receipt.ml:205-212`).
- C3 의 막힘 판정은 너무 넓다. `success` 가 아니면 전부 막힘이다. 그래서 오류 없이 끝난 턴도 막힘으로 읽힌다.
  `yielded_to_*:N`, `yielded_after_*`(`keeper_execution_receipt_types.ml:151-189`), `input_required` 가 그렇다.
  생산자가 없는 `pre_dispatch_success` 도 마찬가지다. 30일 receipt 중 `yielded_*` 가 7,758줄(10.0%)이다.
  C4 도 같은 모양이다. disposition 이 `Success` 가 아니면 attention 이다(`dashboard_execution.ml:378-392`).

**브리프와 다른 점.** `is_transient_provider_runtime_failure` 는 `Disp_retry_later` 를 가르지 않는다.
transient 갈래(226-236)도, 아닌 갈래(237-241)도 `Disp_retry_later` 다. reason 라벨만
`transient_runtime_retry` 와 `provider_runtime_error` 로 다르다. 그리고 `Disp_retry_later` 는 아무것도 예약하지 않는다.
broadcast 도 없다. 이 판정은 라벨이다.

대시보드 TS 와 스크립트:

| 위치 | 읽는 방법 |
|---|---|
| `fsm-hub.ts:95-97` | receipt 색을 `includes('config')`, `includes('exhausted')`, `=== 'completed'` 로 정한다. 성공 receipt 는 `"success"` 라 `'completed'` 와 맞지 않는다 |
| `fsm-hub-types.ts:407-460` | 정확 일치 라벨 표 + 접두어 `api_error_server:` |
| `fsm-hub-types.ts:310-324` `TURN_TERMINAL_FAILURE_CODES` → `keeper-detail-alert-strip.ts:150, 217, 342` | 손으로 베낀 wire 8개와 같음 비교. `turn_timeout` 은 `lib/` 어디에도 없는 글자다. `heartbeat_consecutive_failures`·`turn_consecutive_failures` 를 괄호 없이 그대로 쓰는 곳도 `lib/` 에 없다. registry 는 `heartbeat_consecutive_failures(3)` 처럼 쓴다(`keeper_registry_types_failure.ml:83-85`) |
| `cost-dashboard.ts`, `stop-cause.ts`, `telemetry-unified.ts`, `turn-fsm-detail-panel.ts`, `fleet-telemetry-utils.ts`, 정규화·스키마 파일 | 표시·전달 |
| `scripts/analysis/prefix-cache-first-round.py:364` | 모델별 집계 |
| `scripts/harness/workload/keeper_continuity_validation.sh:389` | manifest decision 의 값 |
| `scripts/keeper-runtime-truth-gate.sh:139` | fixture |
| `scripts/check-boundary-guard.sh:282-287` (V7r) | 지울 파일 목록 |

- TS 는 테스트가 아닌 파일 14개가 이 값을 받고, 2개 파일이 값으로 분기한다.
  클라이언트가 서버의 wire 를 다시 분류하는 것이 문제의 모양이다. 서버와 클라이언트가 같은 어휘를 따로 베끼고, 한쪽이 바뀌면 다른 쪽은 조용히 틀린다.
- 막힘 판정의 소비자는 서버의 C3 `composite_execution_blocked` 하나다. `fleet-fsm-matrix.ts` 는 서버의 `runtime_attention` 만 그린다(b58ddba17b).
- TUI 는 이 값을 읽지 않는다.
- 테스트: masc `test/` 19개 파일, agent_core 테스트 4개 파일이 닿는다.

### 2.5 `ProviderReportedError` 에 서로 다른 사실이 섞여 있다

`Llm_provider.Error.ProviderReportedError { provider; error_type : string option; detail }` 의 생산자는 10곳이다.

| 생산자 | 위치 | `error_type` | 누구 어휘인가 |
|---|---|---|---|
| claude_code `Turn_failed`, `Turn_failed_with_observation` | `keeper_claude_code_runtime.ml:319-324` | `"turn_failed"` | masc |
| claude_code `Context_window_exceeded` (활동 있음) | `keeper_claude_code_runtime.ml:350-358` | `"context_window_exceeded_after_observed_activity"` | masc |
| codex `Context_window_exceeded` (tool effect 뒤) | `keeper_codex_runtime.ml:336-343` | `"context_window_exceeded_after_tool_effect"` | masc |
| codex `Rpc_error` | `keeper_codex_runtime.ml:372-383` | `"rpc_error"` | masc |
| codex `Turn_failed` | `keeper_codex_runtime.ml:392-398` | `"turn_failed"` | masc |
| antigravity `Turn_failed` | `keeper_antigravity_runtime.ml:19-25` | `"turn_failed"` | masc |
| OpenAI 호환 오류 객체 (complete) | `packages/agent_core/lib/llm_provider/complete_sync.ml:117-127` | 오류 객체의 `type` 또는 OpenRouter `metadata.error_type` | 제3자 provider |
| 같은 봉투 (stream) | `complete_stream_error.ml:203-221` | 같음 | 제3자 provider |
| `Http_client.Provider_reported_error` 변환 | `llm_provider/error.ml:334-335` | 그대로 | 위 둘 |
| polymorphic variant 왕복 | `error_domain.ml:231-233` | 그대로 | 위 둘 |

`error_type` 을 읽는 곳은 7곳이고 전부 라벨이다.

- `keeper_agent_error.ml:150-153` → receipt 문자열. 어떤 값이 와도 `provider_error_` 버킷이라 disposition 은 같다.
- `keeper_event_bridge_error_json.ml:361-367` → event JSON.
- `keeper_runtime_attempt.ml:71-75` → rotation 입력으로 넘긴다. `Runtime_attempt_fsm.should_try_next` 는 모든 `ProviderFailure` 에 `true` 다. `error_type` 은 `to_user_message` 문장에만 들어간다.
- `llm_provider/error.ml:159-166`, `http_client.ml:217-219` → 문장.
- `provider_failure_attribution.ml:367-370` → `error_type_known` bool.
- route(`keeper_runtime_failure_route.ml:280`), `keeper_error_classify.ml:125, 443`, `keeper_provider_runtime_boundary.ml:266`, `is_retryable` 은 `ProviderReportedError _` 로 받고 `error_type` 을 보지 않는다.

**흐름 소비자는 0곳이다.** 섞여 있는 대가는 라벨에서 나온다.
2026-09-21 03~06Z 에 한 keeper 가 같은 콘텐츠 정책 거절을 50번 연속 받았다(#37580 본문).
운영자 화면에는 50번 모두 `provider_error_reported:turn_failed` 였다. 다른 turn_failed 와 구별되지 않았다.

30일 데이터:

- `provider_error_reported:turn_failed` 1,133줄(최근 7일 557줄).
- masc 의 나머지 세 값(`context_window_exceeded_after_*` 둘, `rpc_error`)은 0줄이다.
  활동 뒤 실패는 driver 가 fence 로 감싸서 `provider_attempt_effect_fenced` 로 남는다. 안쪽 원인은
  `Fenced_core { category; message }` 문장 안에만 있다.
- 제3자 provider 봉투는 4줄이다(`invalid_request` 2, `insufficient_quota` 1, 값 없음 1).

### 2.6 문자열 왕복이 실제로 깨진 기록

- **#29929** pre-dispatch 경로가 `"pre_dispatch_"` 접두어를 붙였다. `of_wire` 는 `"config_error"` 를 같음으로 비교한다.
  그래서 pre-dispatch 설정 실패가 전부 unmapped 로 운영자에게 갔다(`keeper_unified_turn.ml:636-646` 주석).
- **#29929** `terminal_effect_failed:tool_use_id=…` 는 kind 뒤에 매개변수를 붙인다. `wire_kind_of_string` 이 문자열 전체를 비교했다.
  2026-09-01 하루에 178개 receipt 가 unmapped 로 떨어졌다(`test_keeper_terminal_reason_typed.ml:1998-2002`).
  고친 방법은 `:` 앞을 자르는 또 하나의 파싱이다(`keeper_internal_error.ml:845-854`).
- **#26584** 코드 이름을 바꾸자 분류기가 보는 값이 바뀌었는데 매칭하는 값은 그대로였다(`keeper_terminal_reason.ml:26-31`).
- 30일 receipt 중 unmapped 가 209줄이다. `agent_error_terminal_tool_effect_failed` 164, `success` 30, `io_error` 9,
  `agent_error_hook_execution_failed` 4, 기타 2. 전부 2026-09-02 이전이다. 첫 줄은 지금 코드가 쓰지 않는 옛 철자다.
  철자가 바뀔 때마다 분류기가 따라가야 했다는 뜻이다.
- 성공 receipt 는 `"success"` 를 쓴다(G6, G7). `"completed"` 는 `stop_reason` 필드에만 있다.
  대시보드가 `'completed'` 와 비교해 막힘을 다시 정하던 코드는 성공한 keeper 를 "정체" 로 그렸다. b58ddba17b 가 그 재분류를 지웠다.
  `fsm-hub.ts` 의 receipt 색은 아직 같은 비교를 쓴다.

### 2.7 같은 뿌리의 다른 자리

- `server_dashboard_http_composite_claims.ml:370` 은 서버가 자기가 쓴 JSON 을 다시 읽으며 `"pause_human"` 과 비교한다.
  지금 `operator_disposition_kind` 에 그 값은 없다. 다른 PR 이 처리 중이라 이 RFC 는 건드리지 않는다.
- `Keeper_internal_error.classify_masc_internal_error_of_string` 과 `[masc_agent_core_error]` 접두어 메시지는 RFC-0454 가 목록으로 다룬다.

## 3. 설계

### 3.1 `Keeper_turn_end.t`

위치는 `lib/keeper` 다. receipt 와 같은 라이브러리다.

```ocaml
(** 턴을 끝낸 사실. receipt 와 decision log 의 원천이다. *)
type t =
  | Turn_ok
      (** 오류 없이 끝났다. 어디서 멈췄는지는 receipt 의 [stop_reason] 이 말한다. *)
  | Turn_failed of failure
      (** runtime 이 [Agent_core.Error.t] 로 끝났다. *)
  | Not_dispatched of not_dispatched
      (** provider 에 보내기 전에 끝났다. *)

and not_dispatched =
  | Supervisor_stop
  | External_cancel
  | Non_executable_phase of Keeper_state_machine.phase
  | Registry_phase_missing
  | Runtime_build_failed of failure

and failure =
  | Masc of Keeper_internal_error.masc_internal_error
      (** carrier 로 온 masc 값. §3.3 의 [Official_client_failed] 도 여기 온다. *)
  | Core of Keeper_request_failure_core.t
      (** RFC-0454 §2.2 의 생성자별 agent-core 투영. *)

val of_core_error : Agent_core.Error.t -> failure
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, decode_error) result
val label : t -> string   (* 표시와 metric label 용. 읽어서 판정하지 않는다 *)
val summary : t -> string
```

- `Turn_ok` 에 stop_reason 을 싣지 않는다. receipt 에 이미 typed `stop_reason` 필드가 있다.
  지금 문자열은 그 필드를 한 번 더 굽는다(G6). 같은 사실을 두 번 저장하지 않는다.
- 생성자마다 원래 typed 값이 가진 매개변수를 그대로 든다. 상태 코드, timeout phase, repeating shape, config field 가 그렇다.
  지금은 이것들이 `:` 뒤 문자열로 붙는다.
- `of_core_error` 는 carrier 에 masc 값이 있으면 `Masc`, 없으면 `Core` 를 만든다. 결정하는 곳은 여기 한 곳이다.
  carrier 만 본다. `[masc_agent_core_error]` 접두어 문자열은 파싱하지 않는다.
  지금 `terminal_reason_code_of_core_error` 는 `classify_masc_internal_error` 를 거쳐 접두어 문자열도 읽는다(`keeper_agent_error.ml:196-202`).
  접두어를 만드는 곳은 `core_error_of_masc_internal_error` 하나이고 항상 carrier 를 같이 싣는다(`keeper_internal_error.ml:969-975`).
  다만 중간에 carrier 를 잃고 문자열로 다시 감싸는 곳이 있는지는 확인하지 못했다. PR-3b 전에 전수로 본다.
  있으면 그 자리를 carrier 로 고치는 것이 먼저다. RFC-0454 P2 가 같은 목록을 만든다.
- `classify_masc_internal_error` 는 carrier 가 없는 `Agent TerminalToolEffectFailed`·`TerminalToolDurabilityFailed` 도 masc 값으로 바꾼다.
  `of_core_error` 는 이 변환을 하지 않는다. 두 생성자는 `Core (Agent _)` 로 남는다.
  receipt 분류에서 둘을 다르게 다루던 지금 동작(§3.2 표)을 생성자 arm 으로 그대로 옮기기 위해서다.
- `of_yojson` 은 엄격하다. 모르는 `kind`, 빠진 필드, 남는 필드, 틀린 모양은 `Error` 다. 기본값을 채우지 않는다.

### 3.2 receipt 와 `operator_disposition`

- `Keeper_execution_receipt_types.t` 의 `terminal_reason_code : string` 을 `terminal_reason : Keeper_turn_end.t` 로 바꾼다.
- 생산자 6곳은 문자열 대신 값을 만든다.

  | 호출자 | 값 |
  |---|---|
  | agent run `Ok _` | `Turn_ok` |
  | agent run `Error err` | `Turn_failed (of_core_error err)` |
  | phase gate supervisor stop, streaming cancel | `Not_dispatched Supervisor_stop` / `External_cancel` |
  | phase gate 실행 불가 phase | `Not_dispatched (Non_executable_phase phase)` |
  | phase gate registry phase 없음 | `Not_dispatched Registry_phase_missing` |
  | runtime build 실패 | `Not_dispatched (Runtime_build_failed (of_core_error err))` |

- `input_required` 는 문자열 대신 `receipt.stop_reason = Some (InputRequired _)` 로 본다. 지금과 같은 경우를 고른다.
  지금 `"input_required"` 는 `Ok` + `InputRequired` 에서만 만들어진다.
- 지금 `of_wire` 의 버킷을 생성자로 옮긴다. 생성자끼리 겹치지 않으니 버킷 순서에 기대던 우선순위가 사라진다.

  | 지금 버킷 | 새 match |
  |---|---|
  | `Config_invalid` | `Core` 의 `Config _` 전부, `Provider InvalidConfig` |
  | `Authorization_refused` | `Api AuthError`, `Api AuthorizationError`, `Provider AuthError`, `Provider AuthorizationError` |
  | `Provider_runtime_failure` | 나머지 `Api _`, 나머지 `Provider _`, `Masc Runtime_connection_closed`, `Masc Official_client_failed` |
  | `Internal_error` | `Core` 의 carrier 없는 internal, `Masc` 의 `Internal_*` 셋, `Masc Host_stopped_turn` |
  | `Terminal_effect_failed` | `Masc Terminal_effect_failed`, `Core (Agent TerminalToolEffectFailed)`. 뒤의 것은 지금 wire 가 `terminal_effect_failed:` 로 시작해서 이 버킷에 온다(G2) |
  | 나머지 masc 버킷 7개 | `Masc` 의 해당 생성자 |
  | `Unknown` 으로 가던 값 | `Core` 의 나머지 `Agent _` 7개(`TerminalToolDurabilityFailed` 포함)·`Mcp _`·`Serialization _`·`Io _`·`Orchestration _`, `Masc` 의 `Resumable_cli_session`·`Receipt_persistence_failed`·`Gate_replay_repair_required`, `Turn_ok`, `Not_dispatched` 의 phase·cancel 넷. 생성자 이름을 적고 지금의 generic 갈래로 보낸다 |

- `Internal_error` 버킷에는 출처가 넷이다. carrier 없는 internal, `Internal_unhandled_exception { site; ... }`,
  `Internal_bridge_exception { caller; ... }`, `Internal_contract_rejected` 다. 이 출처는 receipt 의 typed 값에 그대로 남는다.
  출처를 가르려고 reason 라벨을 쪼갤 필요가 없다. 지운 RFC-0159 가 원한 구별은 이것으로 된다.
- `is_transient_provider_runtime_failure` 는 typed 판정이 된다.
  `Api Timeout`, `Api NetworkError`, `Provider Timeout`, `Provider NetworkError { kind = Timeout }` 이 `true` 다.
  지금 접두어가 고르는 집합과 같다. `Provider NetworkError` 의 다른 kind 는 phase 가 있어도 지금처럼 `false` 다.
- 이 변경은 어떤 경우의 `(disposition, reason)` 도 바꾸지 않는다. `Unknown` 으로 가던 생성자도 지금처럼 generic 갈래로 간다.
  agent 계열 생성자 7개가 여기 해당한다. 30일 데이터에서 실제로 나온 것은 `agent_error_hook_execution_failed` 4줄뿐이고,
  이 줄들은 unmapped 로 broadcast 됐다(마지막 2026-09-02). 이것을 바꿀지는 따로 정한다. 이 RFC 범위가 아니다.
- `wire_kind_of_string` 의 호출자는 `of_wire` 하나다. 같이 지운다.
- `check-boundary-guard.sh` V7r 은 지운 파일 대신 새 금지 패턴을 본다(§5).

### 3.3 공식 클라이언트 실패 (D3)

`Keeper_internal_error.masc_internal_error` 에 생성자 하나를 더한다.

```ocaml
type observed_activity =
  | Tool_effect_attempted
  | Response_emitted
  | Tool_effect_and_response

type official_client_failure =
  | Client_turn_failed of { cli_terminal_reason : string option }
      (** 클라이언트가 턴 실패를 보고했다. [cli_terminal_reason] 은 claude CLI 가 준
          terminal_reason 값이다. 데이터로만 싣는다. 비교하지 않는다. *)
  | Client_rpc_error of { method_ : string; code : int option }
      (** codex app-server 가 JSON-RPC 오류를 돌려줬다. *)
  | Context_window_exceeded_after_activity of { activity : observed_activity }
      (** 활동이 있은 뒤 context window 를 넘었다. 활동이 없으면
          [Api ContextOverflow] 로 가므로 여기 오지 않는다. *)

(* masc_internal_error 에 더하는 생성자 *)
  | Official_client_failed of
      { runtime_id : string
      ; failure : official_client_failure
      ; detail : string
      }
```

생산자 대응:

| 생산자 | 새 값 |
|---|---|
| claude_code `Turn_failed`, `Turn_failed_with_observation` | `Client_turn_failed`. observation 쪽은 CLI 의 `Other_terminal_reason` 값을 `cli_terminal_reason` 에 싣는다 |
| claude_code `Context_window_exceeded` (둘 중 하나라도 true) | `Context_window_exceeded_after_activity`. bool 두 개를 세 생성자로 옮긴다. 둘 다 false 인 모양은 표현되지 않는다 |
| codex `Context_window_exceeded` (tool effect 뒤) | `Context_window_exceeded_after_activity { activity = Tool_effect_attempted }` |
| codex `Rpc_error` | `Client_rpc_error` |
| codex `Turn_failed`, antigravity `Turn_failed` | `Client_turn_failed { cli_terminal_reason = None }` |

- claude CLI 의 `terminal_reason` 은 이미 `Runtime_claude_code.terminal_reason` 으로 typed 다(#37667).
  context limit 셋은 앞에서 `Context_window_exceeded` 로 갈라진다. `Turn_failed_with_observation` 에 오는 값은 `Other_terminal_reason` 뿐이다.
  그래서 runtime 쪽 필드도 `string option` 하나로 둔다. CLI 가 가진 열린 어휘라서 masc 가 닫을 수 없다.
- #37580 이 원한 것은 콘텐츠 정책 거절을 운영자 화면에서 구별하는 일이다.
  이 값이 `summary` 와 `label` 에 들어가면 같은 목적을 이룬다. `"turn_failed:" ^ reason` 을 만들지 않는다.

흐름을 그대로 두려면 `ProviderReportedError _` 를 받던 자리가 새 생성자에 같은 답을 줘야 한다.

| 자리 | 지금 답 | 새 생성자의 답 |
|---|---|---|
| `Keeper_runtime_failure_route` (280) | `exhaust_failure Provider_integration` | 같은 route. `route_of_error` 첫 갈래에 둔다. #37584 가 먼저 들어가면 그 route 를 옮긴다 |
| `Keeper_runtime_attempt.core_error_to_runtime_outcome` | `ProviderFailure (Provider_reported_error _)` → 다음 후보 | 같은 `ProviderFailure` 를 다시 만든다. `Runtime_connection_closed` 가 쓴 방식이다(`keeper_runtime_attempt.ml:128-141`). 빠뜨리면 레인이 멈춘다(아래) |
| `Keeper_error_classify` (125, 443) | `false` / `None` | 같음 |
| `Keeper_provider_runtime_boundary` (266) | 같은 갈래 | 같음 |
| `Keeper_unified_turn_types.registry_failure_reason_of_internal_error` | `None` → disposition 경로로 `Provider_runtime_error` | `None` |
| `Keeper_status_bridge_blocker` blocker class | `None` | `None` |
| 지금 receipt 분류 | `provider_error_` → `Provider_runtime_failure` | `Provider_runtime_failure` |

**컴파일러가 못 잡는 자리.** 새 생성자를 더해도 아래 자리들은 컴파일 오류가 나지 않는다. masc 분류 결과를 catch-all 로 받기 때문이다.

- `keeper_runtime_attempt.ml:142-143` 의 `| Some _ | None ->`. 새 생성자는 이 갈래로 떨어진다.
  안쪽 match 는 `Internal_carried` 에 `None` 을 준다(201-208). 그러면 `lane_should_retry` 가 `false` 가 되고 레인이 거기서 멈춘다.
  지금은 `ProviderReportedError` → `ProviderFailure` → `should_try_next = true` 로 다음 후보에 간다.
  영향을 받는 것은 codex(`rpc_error`, `turn_failed`), claude_code(`turn_failed`), antigravity(`turn_failed`) 의 실패 중
  effect 가 관측되지 않은 것이다. effect 가 관측된 실패는 driver 가 먼저 fence 로 감싼다.
- `keeper_runtime_failure_route.ml:325-328` 의 `| Some internal ->`. `Agent_core_execution` 경계에서는 `route_of_error_family` 로 가고,
  `Internal_carried` 는 `Internal_opaque` 로 끝난다(310-311). 지금 답은 `Provider_integration` 이다.
  둘 다 `Exhausted_visible_alive` 의 terminal class 라서 이 차이는 라벨이다.
  `next_dispatch_after_failure`(`keeper_direct_runtime_continuation.ml:109-118` 가 부른다)는 두 값에 같은 답을 준다.
  그래도 route telemetry 가 바뀌므로 첫 갈래에 둔다. `Runtime_connection_closed` 가 같은 자리에 있다(316-324).
- `keeper_error_classify.ml:212-214` 의 `| Some _ | None -> false` 는 새 생성자에도 지금과 같은 답(`false`)을 준다. 하지만 같은 모양의 catch-all 이다.

그래서 PR-1 앞에 PR-0 을 둔다. PR-0 은 `classify_masc_internal_error` 를 부르는 23곳(`lib/`)을 전부 보고,
결과를 catch-all 로 받는 자리를 `masc_internal_error` 16개 생성자를 모두 적는 match 로 바꾼다. 각 생성자의 답은 지금과 같다.
PR-0 뒤에는 새 생성자가 이 자리들에서 컴파일 오류가 된다. PR-1 은 그 오류를 main 의 `ProviderReportedError` 답으로 채운다.

다시 만드는 `Provider_reported_error` 의 `error_type` 은 `None` 이다.
`to_user_message` 문장과 attribution 의 `error_type_known` 이 바뀐다. 둘 다 라벨이다.

`Agent_core.Error.category` 는 `Provider` 에서 `Internal` 로 바뀐다. 그래서 receipt `error_kind`, event `domain`,
채팅 row 의 실패 생성자(`Core` → `Masc`), registry `Provider_runtime_error.code` 글자가 바뀐다. 전부 라벨이다.
`summary_of_masc_internal_error` 는 새 생성자에 한 줄을 만든다.

위 표는 `ProviderReportedError` 를 이름으로 받는 자리만 센 것이다. 값이 `Provider _` 에서 `Internal_carried _` 로 옮겨 가므로
두 갈래를 통째로 받는 자리도 답이 같아야 한다. `lib/` 에 `Agent_core.Error.Provider _` 를 통째로 받는 자리가 18곳,
`Internal_carried` 를 받는 자리가 28곳 있다.

- `Provider _` 18곳은 전부 열어 봤다. 16곳은 `Internal_carried _` 와 답이 같다(`false` 또는 `None`).
  `keeper_turn_driver.ml:652-664, 840-844`, `keeper_turn_driver_try_runtime.ml:52, 97, 122`, `keeper_turn_driver_try_provider.ml:1986`,
  `keeper_error_classify.ml:84, 140, 179, 196, 595`, `keeper_turn_runtime_budget.ml:108`, `runtime_agent_core_runner.ml:54`,
  `keeper_runtime_failure_route.ml:81`, `keeper_agent_error.ml:36`, `keeper_event_bridge_error_json.ml:126` 이다.
  나머지 두 곳은 masc 값이면 carrier 분류로 먼저 빠진다. `keeper_status_bridge_blocker.ml:92` 는 새 생성자에 blocker class 없음(`None`)을 줘야 지금과 같다.
  `keeper_request_failure.ml:97` 은 채팅 row 생성자가 `Core` 에서 `Masc` 로 바뀐다(라벨).
- `Internal_carried` 28곳은 확인하지 못했다. PR-0 이 `classify_masc_internal_error` 23곳과 함께 표로 적는다.
  답이 다른 자리가 있으면 PR-1 이 새 생성자 arm 을 따로 두고 main 의 `Provider _` 답을 낸다.

기각한 안:

- **B. agent_core `ProviderReportedError` 에 extensible 칸을 연다.** masc 가 `+=` 로 자기 값을 넣는다.
  소비자마다 `| _ ->` 갈래가 생기고, 그 갈래가 결국 `Unknown` 자리가 된다. carrier 는 이미 masc_internal_error 가 쓰고 있다.
- **C. agent_core 에 공식 클라이언트 어휘를 넣는다.** claude_code·codex·antigravity 는 masc 런타임이다.
  agent_core 가 masc 를 알게 된다. RFC-0371 §6.1(1) 이 같은 이유로 sub-sum split 을 기각했다.

`ProviderReportedError` 에 남는 `error_type : string option` 은 제3자 provider 가 준 값이다.
provider 마다 어휘가 다르고 masc 가 정하지 않는다. 데이터로 싣고 비교하지 않는다. 지금도 비교하는 곳은 없다.

### 3.4 agent-core 투영 (D4)

`Keeper_turn_end.failure` 의 `Core` 는 `Keeper_request_failure_core.t` 다.
지금 이 타입은 `{ category; message }` 뿐이다. RFC-0454 §2.2 가 이것을 생성자별로 넓히기로 했다.
이 RFC 는 그 넓힌 값을 쓴다. 따로 만들면 투영이 둘이 되고 서로 어긋난다.

`operator_disposition` 이 지금과 같은 답을 내려면 넓힌 투영이 최소한 다음을 구별해야 한다.

- `Config _` 전부 / `Provider InvalidConfig` / `Provider MissingApiKey` (마지막은 설정이 아니라 provider 버킷이다)
- 인증 넷
- `Api Timeout`, `Api NetworkError`, `Provider Timeout`, `Provider NetworkError` 의 `kind`
- 그 밖의 `Api _`, `Provider _` 생성자 각각
- `Agent _`, `Mcp _`, `Serialization _`, `Io _`, `Orchestration _`, carrier 없는 internal

RFC-0454 의 "생성자별" 이 이것을 모두 덮는다.

### 3.5 문자열이 남는 곳

- `Keeper_turn_end.label` 이 표시와 metric label 과 로그 글자를 만든다. 읽어서 판정하는 코드는 없다.
- provider 와 CLI 가 준 열린 어휘는 데이터로 남는다. `ProviderReportedError.error_type`, `cli_terminal_reason`, 각 `detail` 문장이다.
- manifest decision payload(S3), activity event payload(S4), event SSE(S6)는 `to_yojson` 객체나 `label` 을 쓴다.
  OCaml 에서 읽는 곳이 없어서 계약이 바뀌는 쪽은 스크립트뿐이다.

### 3.6 hard cut — 옛 줄은 어떻게 되나

**receipt (S1, PR-3c).** `Dated_jsonl` 은 JSON 으로 파싱되지 않는 줄만 건너뛴다(`dated_jsonl.ml:1005-1041`).
옛 줄은 JSON 으로는 멀쩡하니 `Yojson.Safe.t` 로 올라온다. 그 뒤 `Keeper_turn_end.of_yojson` 이 `terminal_reason` 이 없다고 거절한다.

- 부팅은 막히지 않는다. receipt 를 읽는 곳은 trust snapshot, composite claims, dashboard trust·goals, telemetry,
  `masc_keeper_status` 도구(`keeper_status_detail.ml:567`)뿐이다. 부팅 경로에서 읽는 곳은 없다.
- `latest_json` 은 최신 줄 하나를 준다. keeper 가 배포 뒤 턴을 한 번 돌면 최신 줄이 새 모양이 된다.
  그 전까지 그 keeper 는 "receipt 를 읽을 수 없음" 으로 보인다. 이 상태는 typed 로 표현한다. "receipt 없음" 과 구별한다.
- 목록을 보여주는 곳(telemetry)은 줄마다 decode 한다. 한 줄의 실패가 목록 전체를 비우지 않게 한다.
  `let*` 로 줄을 한꺼번에 훑으면 한 줄이 화면 전체를 끈다. 그렇게 짜지 않는다.
- decode 실패는 site label 을 붙여 센다. 고치는 장치가 아니라 hard cut 을 보이게 하는 관측이다.
- Q3 에서 지우기로 하면 배포 때 `<base>/.masc/keepers/*/execution-receipts/` 를 지운다. constitution `runtime_data` 가 허용한다.
  지금 남은 줄은 이미 여러 세대 어휘가 섞여 있다(§2.3). 지금 분류기도 일부를 모른다.

**decision log (S2).** 옛 줄의 `terminal_reason` 은 `{code, disposition, ...}` 모양이다. 새 decoder 는 거절한다.

- 이 필드를 읽는 곳은 trust snapshot(C2)과 dashboard feeds(C5) 둘이다. model inference metrics, memory, telemetry 는 다른 필드를 읽어서 영향이 없다.
- trust snapshot 은 decision 이 안 읽힌다고 receipt 로 조용히 넘어가지 않는다. 읽을 수 없다는 상태를 보여준다.
- decision log 는 다른 데이터도 들고 있어서 지우지 않는다.

**registry (S5).** 메모리에만 있다. 프로세스를 다시 띄우면 비어서 시작한다. 옛 값이 남을 자리가 없다.

**채팅 row.** PR-2 가 `Keeper_request_failure_core` 의 JSON 모양을 바꾼다. RFC-0454 D6 의 hard cut 이 그대로 적용된다.
`Fenced_core` 가 들어간 다른 저장값이 있는지는 PR-2 에서 전수로 확인한다. 지금은 확인하지 못했다.

### 3.7 decision log, registry, trust snapshot

- decision log 는 `terminal_reason` 에 `Keeper_turn_end.to_yojson` 을 쓴다.
  `terminal_reason_code`, `terminal_reason_severity`, `terminal_reason_source` 문자열은 지운다. severity 와 summary 는 읽을 때 계산한다.
- `append_decision_record` 의 `?terminal_reason` 을 필수 인자로 바꾼다. `"unknown_error"` 기본값(G13)은 호출자 2곳이 이미 값을 넘겨서 쓰이지 않는다.
- checkpoint 에서 `Yielded_*` 로 멈춘 턴을 지금은 `Input_required` 로 적는다(`keeper_unified_turn_success.ml:444-460`).
  `Turn_ok` 와 typed `stop_reason` 이 되면서 이 라벨이 고쳐진다.
- registry `Provider_runtime_error { code; agent_core_timeout; ... }` 는 `{ failure : Keeper_turn_end.failure; ... }` 가 된다.
  timeout 여부는 `failure` 에서 바로 읽는다.
  `classify_provider_runtime_error_record` 의 접두어 갈래는 이보다 먼저 PR-3b 에서 지운다.
  typed `agent_core_timeout` 이 이미 접두어가 고르는 경우를 전부 덮는다(`keeper_agent_error.ml:217-233`).
  `agent_core_timeout = None` 인 registry 값은 masc kind, `runtime_attempts_exhausted`, timeout 이 아닌 agent-core wire 뿐이다(`keeper_unified_turn_types.ml:186-203, 299-321`).
  이 중 timeout 접두어로 시작하는 것은 없다. 접두어 갈래가 답을 바꾸는 입력은 없다.
  이 갈래만 고정하던 `test_keeper_provider_timeout_labels` 의 문자열 파싱 케이스도 같이 지운다.
- trust snapshot 의 "최신 종료 사유" 는 두 출처가 있다. runtime blocker 와 턴이다.
  지금은 blocker class 문자열을 `Agent_core_error { wire }` 에 넣어 섞는다(`keeper_runtime_trust_snapshot.ml:103-134`).
  `Blocker of Keeper_meta_contract.blocker_class | Turn_end of Keeper_turn_end.t` 로 나눈다.
- 이 단계가 끝나면 `Keeper_turn_terminal_code`, `Keeper_turn_disposition`, `Keeper_turn_terminal` 이 쓰이지 않는다. 지운다.
  `registry_failure_reason_of_raw_error` 로 가는 `core_error = None` 갈래도 호출자가 없다(유일한 호출자가 `~core_error:err` 를 넘긴다). 같이 지운다.

### 3.8 막힘 판정은 서버가 typed 값으로 내리고, 클라이언트는 그린다 (D8)

- 서버는 `Keeper_turn_end.t` 를 빠짐없이 match 해서 막힘 여부를 정한다. 막힘은 실패 종류일 때만이다.
  - 막힘: `Turn_failed _`, `Not_dispatched Registry_phase_missing`, `Not_dispatched (Runtime_build_failed _)`
  - 막힘 아님: `Turn_ok`(yield, input_required 포함), `Not_dispatched` 의 `Supervisor_stop`·`External_cancel`·`Non_executable_phase`
  - 새 생성자는 컴파일 오류로 이 표에 자리를 요구한다. `is_success` 가 아니면 전부 막힘인 지금 규칙(C3)은 지운다.
- C4 의 attention·queue severity 도 같은 규칙을 쓴다. 문자열 `disposition` 을 다시 파싱하지 않는다.
- 서버가 대시보드로 보내는 JSON 에는 판정 결과를 typed 필드로 싣는다(막힘 여부, severity, 다음 행동). 클라이언트는 그것을 그린다.
  클라이언트에 wire 문자열 목록이나 비교(`TURN_TERMINAL_FAILURE_CODES`, `fsm-hub.ts` 의 `'completed'`·`includes('config')`)를 두지 않는다.
  라벨 글자는 서버의 `label`·`summary` 를 그대로 쓴다.
- 이 규칙은 라벨만 바꾼다. 대시보드가 보여주는 상태가 바뀌고 keeper 흐름은 바뀌지 않는다.
  30일 기준으로 `yielded_*` 7,758줄이 막힘에서 빠진다.

## 4. PR 단위 이행 순서

각 PR 의 출력은 20k token 이하로 잡는다. 넘으면 표에 적은 대로 나눈다.
쓰는 쪽과 읽는 쪽은 같은 PR 에 둔다. 중간 main 에서 읽는 쪽이 없는 필드를 찾는 일이 없게 한다.

| PR | base | 내용 | 흐름 | 부수효과 | 라벨 | 크기 |
|---|---|---|---|---|---|---|
| PR-0 | main | §3.3 "컴파일러가 못 잡는 자리". `classify_masc_internal_error` 를 부르는 23곳을 표로 적고, 결과를 catch-all 로 받는 자리(`keeper_runtime_attempt.ml:142-143`, `keeper_runtime_failure_route.ml:325-328`, `keeper_error_classify.ml:212-214` 등)를 16개 생성자를 모두 적는 match 로 바꾼다 | 없음. 생성자마다 지금 답을 그대로 적는다 | 없음 | 없음 | 약 10k |
| PR-1 | PR-0 | §3.3. `Official_client_failed` 추가, 어댑터 3개, PR-0 이 드러낸 자리마다 arm, claude runtime 필드. #37580 흡수. RFC-0159 를 가리키던 코드 주석 8곳 정리 | **흐름을 바꿀 수 있는 유일한 PR.** 의도한 답은 main 과 같다. `keeper_runtime_attempt` arm 을 틀리면 공식 클라이언트 실패에서 레인이 멈춘다(route arm 을 틀리면 route 라벨만 `Internal_opaque` 로 바뀐다). PR-0 이 먼저 들어가야 컴파일러가 빠뜨림을 잡는다 | 없음. disposition 이 같다 | receipt 코드 `provider_error_reported:turn_failed` → `official_client_failed`, `error_kind` provider → internal, 채팅 row 실패 생성자, registry `code`, rotation 문장, attribution `error_type_known` | lib 12개 안팎 + 테스트. 약 15k |
| PR-2a | main | `Keeper_request_failure_core` 안에 `Retry.api_error` 전체 투영 + codec + summary. 아직 `t` 를 바꾸지 않는다 | 없음 | 없음 | 없음 | 약 10k |
| PR-2b | PR-2a | `Llm_provider.Error.provider_error` 전체 투영 + codec + summary | 없음 | 없음 | 없음 | 약 12k |
| PR-2c | PR-2b | 나머지 family 투영, `Keeper_request_failure_core.t` 를 닫힌 합으로 바꿈, `Fenced_core`·`Keeper_request_failure` 소비자 | 없음 | 없음 | 채팅 row 요약 문장, 채팅 row JSON (RFC-0454 D6 hard cut) | 약 15k |
| PR-3a | PR-2c | `Keeper_turn_end` 타입, 엄격 codec, `label`, `summary`, 테스트 | 없음 | 없음 | 없음 | 약 10k |
| PR-3b | PR-3a, PR-1 | receipt 레코드 필드를 `Keeper_turn_end.t` 로, 생산자 6곳, `operator_disposition` 재작성. `Keeper_agent_error` 의 문자열 렌더는 `Keeper_turn_end.label` 로 옮긴다. `Keeper_provider_runtime_boundary` 의 timeout 접두어 갈래는 답을 바꾸지 않으므로(§3.7) 여기서 지운다. 그래야 `Keeper_terminal_reason` 을 상수까지 지울 수 있다. `wire_kind_of_string` 도 삭제. `is_transient_provider_runtime_failure` 와 그 틀린 주석(`keeper_terminal_reason.ml:187`, "두 상수와 같음 비교" 라고 적혀 있지만 실제로는 비교 6개와 접두어 2개)도 이때 함께 사라진다. 파일에는 아직 `terminal_reason_code` 를 `label` 로 쓴다. `label` 은 지금 문자열과 바이트가 같다 | 없음 | 없음. golden 표로 broadcast 집합이 같음을 보인다 | 없음. 파일 글자가 같다 | 약 18k |
| PR-3c | PR-3b | receipt 파일 모양 전환(`terminal_reason` 객체, `terminal_reason_code` 제거), OCaml 에서 receipt JSON 을 읽는 곳(C2·C3·C7·C8)을 엄격 decode 로, C3 막힘 판정을 §3.8 규칙으로, 서버 JSON 에 typed 판정 필드, manifest·activity payload. 대시보드로 나가는 JSON 에는 PR-4 까지 `terminal_reason_code` 를 `label` 로 계산해 같은 이름으로 낸다 | 없음 | decode 실패 metric 이 새로 생긴다 | receipt 파일 모양(hard cut), "receipt 를 읽을 수 없음" 상태, yield·input_required 가 막힘에서 빠짐 | 약 15k |
| PR-4 | PR-3c | 대시보드가 서버 판정만 그린다: `terminal_reason` 객체 decoder(모르는 kind 는 decode 실패), `TURN_TERMINAL_FAILURE_CODES` 와 `fsm-hub.ts` 의 `includes`·`'completed'` 분기와 라벨 표를 지우고 서버의 판정·`label` 을 쓴다, 서버 JSON 의 `terminal_reason_code` 라벨 제거, fixture 를 실제 값으로(`'completed'`·`'api_error'` fixture 는 생산자가 쓰지 않는 값이다), 스크립트 3개. b58ddba17b 위에 쌓는다 | 없음 | 없음 | 대시보드 receipt 색과 라벨, alert strip 의 종료 실패 표시 | 약 15k |
| PR-5 | PR-3c | decision log 에 `Keeper_turn_end`, trust snapshot 출처 분리, dashboard feeds, C4 를 §3.8 규칙으로, `append_decision_record` 필수 인자, `registry_failure_reason_of_terminal_reason` 의 입력을 `Keeper_turn_end.t` 로, `Keeper_turn_terminal`·`Keeper_turn_disposition` 삭제 | 없음. registry 가 같은 경우에 같은 생성자를 잡는다 | 없음 | decision log 모양(hard cut), checkpoint yield 라벨, trust severity·next_action 문장, attention 판정 | 약 18k |
| PR-6 | PR-5 | registry `Provider_runtime_error` 에 `failure`, status bridge 요약, `Keeper_turn_terminal_code` 삭제, 도달하지 않는 raw_error 갈래 삭제 | 없음. registry 가 같은 경우에 같은 생성자를 잡는다 | 없음 | status bridge 요약 문장 | 약 12k |

의존:

```
main ─ PR-0 ─ PR-1 ─────────────────────────┐
main ─ PR-2a ─ PR-2b ─ PR-2c ─ PR-3a ─ PR-3b ─ PR-3c ─┬─ PR-4
                                                        └─ PR-5 ─ PR-6
```

- 흐름을 바꿀 수 있는 PR 은 PR-1 하나다. 나머지는 저장 형식과 라벨만 바꾼다.
  PR-1 은 PR-0 없이 들어가면 안 된다. PR-0 이 catch-all 을 없애야 컴파일러가 새 생성자의 자리를 전부 요구한다.
- PR-0·PR-1 줄기와 PR-2 줄기는 서로 독립이다. 동시에 열 수 있다. PR-3b 는 둘 다 필요하다.
- PR-2a·2b 는 아직 쓰이지 않는 코드를 들여온다. 각 투영은 자기 원천 타입을 빠짐없이 덮는다. 반쯤 바꾼 상태로 production 에 들어가는 값은 없다. PR-2c 에서 한 번에 전환한다.
- PR-3b 는 값의 흐름만 바꾸고 파일 글자는 그대로 둔다. 그래서 읽는 쪽을 같이 고칠 필요가 없다.
  파일 모양은 PR-3c 가 쓰는 쪽과 읽는 쪽을 함께 바꾼다.
- PR-3c 와 PR-4 사이에는 서버 JSON 의 `terminal_reason_code` 가 label 로 남는다. PR-4 가 지운다. 두 PR 은 붙여서 머지한다.
- RFC-0454 P2 가 PR-2 와 같은 일을 먼저 열면 PR-3a 는 그 위에 쌓는다(Q2).

## 5. 검증

**golden 표 (PR-3b).**

- PR-3b 를 만들기 전에 main 의 문자열 분류기로 표를 뽑아 테스트 데이터로 둔다.
- 말뭉치: 투영의 모든 생성자 fixture, masc kind 16개(+ PR-1 의 새 생성자), `Not_dispatched` 다섯, `Turn_ok` × stop_reason 6개.
- 각 항목에 receipt 의 라우팅 사실 조합을 곱한다. `outcome`, `runtime_outcome`, `runtime_fallback_applied`, degraded retry 두 칸이다.
- 새 `operator_disposition` 이 표와 같아야 한다. `needs_operator_broadcast` 가 참인 집합도 같아야 한다.
  다른 줄이 있으면 PR 본문에 의도한 변경으로 적는다. PR-3b 에서 예상하는 다른 줄은 없다.
- 지금 `test_keeper_terminal_reason_typed.ml` 의 독립 oracle 을 이 표로 바꾼다.

**PR-0.**

- `classify_masc_internal_error` 23곳과 `Internal_carried` 를 받는 28곳의 표를 PR 본문에 싣는다.
  자리마다 catch-all 이었는지, 바꾼 뒤 생성자별 답이 무엇인지, `Provider _` 와 답이 같은지 적는다.
- PR-0 뒤 `classify_masc_internal_error` 결과를 `Some _` 로 받는 갈래가 `lib/` 에 0건이어야 한다.
- 동작은 바뀌지 않으므로 새 테스트보다 기존 스위트(`test_keeper_runtime_attempt`, `test_keeper_runtime_failure_route`, `test_keeper_turn_driver_failover`)가 그대로 초록인지가 증거다.

**PR-1.**

- 어댑터 생성자 6개마다 fixture 를 둔다. 같은 입력을 main 의 `ProviderReportedError` 로 만든 값과 비교한다.
- route, runtime attempt outcome, `Keeper_error_classify` 답, status bridge blocker class, receipt `(disposition, reason)` 이 같아야 한다.
- lane walk 를 직접 돌린다. effect 가 관측되지 않은 codex `Rpc_error`·`Turn_failed`, claude_code `Turn_failed`,
  antigravity `Turn_failed` 가 후보 둘 이상인 레인에서 다음 후보로 넘어가는지 본다. 이것이 레인이 멈추는 실수를 잡는 테스트다.
- `test_keeper_rotation_eligibility_census` 에 새 생성자를 넣는다.

**codec (PR-2, PR-3a).**

- 생성자마다 `of_yojson (to_yojson v) = Ok v`.
- 모르는 `kind`, 빠진 필드, 남는 필드, 틀린 모양이 각각 `Error` 인지 본다.

**label 바이트 (PR-3b).** golden 표의 모든 항목에서 `Keeper_turn_end.label` 이 main 의 문자열과 바이트가 같아야 한다.
PR-3b 는 파일 글자를 바꾸지 않는다고 약속하므로 이 비교가 그 약속의 증거다.

**hard cut (PR-3c, PR-5).**

- 옛 모양 receipt 한 줄 → `Error`. trust snapshot 이 "receipt 를 읽을 수 없음" 을 보여준다. "receipt 없음" 과 다르다.
- 옛 줄 하나와 새 줄 하나가 섞인 목록 → 한 줄은 읽을 수 없음, 한 줄은 정상. 목록이 비지 않는다.
- 옛 모양 decision 줄 → trust snapshot 이 receipt 로 넘어가지 않는다.

**금지 패턴 (V7r 교체).** PR-3b 뒤 `lib/` `bin/` 에서 0건이어야 한다.

- `String.starts_with ~prefix:"api_error_"`, `~prefix:"provider_error_"`, `wire_provider_error_*` 상수
- `Keeper_terminal_reason`, `wire_kind_of_string`, `provider_runtime_error_looks_like_timeout`

PR-4 뒤 `terminal_reason_code` 0건. PR-5 뒤 `Keeper_turn_disposition`, `Keeper_turn_terminal` 0건. PR-6 뒤 `Keeper_turn_terminal_code` 0건.
`rg` 는 무매치에 1, 오류에 2 로 끝난다. 가드 스크립트에서 `|| true` 로 둘을 함께 지우지 않는다.

**테스트 실행.** masc PR check 는 테스트를 컴파일만 하고 돌리지 않는다. 바꾼 스위트는 `test.yml` 로 따로 dispatch 한다.

- `test_keeper_terminal_reason_typed`, `test_keeper_core_error_typed_bridge`, `test_keeper_runtime_trust_snapshot`,
  `test_keeper_execution_receipt_observation_wire`, `test_keeper_runtime_observation_boundaries`, `test_keeper_provider_timeout_labels`,
  `test_keeper_claude_code_runtime`, `test_keeper_codex_error_carriage`, `test_keeper_runtime_attempt`,
  `test_keeper_rotation_eligibility_census`, `test_dashboard_http_core`, `test_dashboard_k2_feeds`,
  `test_operator_control_snapshot`, `test_official_client_claim_cause`, `test_keeper_turn_disposition`(PR-5 에서 지움),
  `test_keeper_turn_terminal_disposition_field`(PR-5 에서 지움)
- masc CI 는 대시보드 테스트를 돌리지 않는다. PR-4 는 로컬에서 vitest 를 돌리고 결과를 PR 에 붙인다.

**실측 (배포 뒤).**

- 새 바이너리가 쓴 receipt 에 `terminal_reason.kind` 가 있고 새 줄의 decode 실패가 0 인지 센다.
- `ReceiptUnmappedDisposition` metric 이 배포 전과 같은 경우에만 오르는지 본다.
- 대시보드 fleet matrix 와 fsm-hub 를 브라우저로 열어 성공 receipt, yield 로 끝난 receipt, 실패 receipt 를 하나씩 찍는다(constitution `evidence`).
  앞의 둘은 막힘이 아니고 마지막 것만 막힘이어야 한다.
- PR-4 뒤 `dashboard/src` 에서 wire 문자열과 같음·포함 비교(`=== 'completed'`, `includes('config')`, `TURN_TERMINAL_FAILURE_CODES`)가 0건이어야 한다.

## 6. 건드리지 않는 것

- **route·rotation·retry 판단.** `Keeper_runtime_failure_route`, `Runtime_attempt_fsm`, `Keeper_error_classify` 의 답은 그대로다.
  `ProviderReportedError` 의 route 는 #37584 가 따로 정한다.
- **`operator_disposition` 의 판단.** 어떤 경우에 어떤 `(disposition, reason)` 이 나오는지는 그대로다.
  generic 갈래로 가던 agent 계열의 unmapped broadcast 를 바꾸는 일도 범위 밖이다.
- **receipt 의 다른 필드.** `outcome`, `runtime_outcome`, `completion_contract_result`, `stop_reason`,
  파생 라벨 `operator_disposition`·`operator_disposition_reason` 은 그대로 둔다.
  `outcome` 은 `Keeper_turn_end.t` 에서 계산할 수 있다. 없앨지는 후속으로 따로 본다.
- **제3자 provider 어휘.** agent_core 의 `ProviderReportedError.error_type`, OpenAI·OpenRouter·Ollama 봉투 파서는 그대로다.
- **runtime blocker.** `Keeper_meta_contract.blocker_class` 와 그 직렬화 문자열은 그대로다. trust snapshot 이 그것을 disposition 에 섞는 부분만 PR-5 에서 나눈다.
- **`"pause_human"`**(`server_dashboard_http_composite_claims.ml:370`). 다른 브랜치가 처리한다.
- **RFC-0454 의 채팅 row 작업.** 공유하는 agent-core 투영(PR-2)만 겹친다.
- **manifest·activity event 의 나머지 필드와 event kind.**
