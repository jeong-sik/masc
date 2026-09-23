---
rfc: "0454"
title: "실패한 keeper 요청은 문자열이 아니라 typed 값으로 남긴다"
status: Draft
created: 2026-09-15
revised: 2026-09-15
author: claude
related: ["0371", "0412"]
---

# RFC-0454 — 실패한 keeper 요청은 문자열이 아니라 typed 값으로 남긴다

- Status: **Draft (2026-09-15).** 결정은 §0, 구현 순서는 §5. 2026-09-15 적대적 리뷰 반영 1차(#36704 이후).
- 한 줄: keeper 턴이 실패하면 지금은 에러를 문자열로 바꿔 채팅 row 의 `content` 에 넣고, TUI 는 그 문자열에서 부분 문자열을 찾아 원인을 짐작한다. 실패를 닫힌 합타입 `Keeper_request_failure.t` 로 만들어 row 와 stream 에 그대로 싣고, 화면은 그 값으로 그린다.
- 이슈: #36663. 계기: 2026-09-15 20:09 KST msx-retro-mania 채팅 에러(§1.1).

## 0. 결정 요약

- **D1 중첩 에러는 문자열로 감싸지 않는다.** `Provider_attempt_effect_fenced` 와 `Tool_correction_lost` 의 `diagnostic : string` 을 typed 원인으로 바꾼다. `Terminal_effect_failed` 의 `diagnostic : string` 은 무엇이 실패했는지 말하는 합타입으로 바꾼다. JSON 으로 내보낼 때도 안쪽은 JSON 객체다. escape 된 JSON 문자열이 아니다.
- **D2 실패를 만드는 곳마다 typed 생성자를 쓴다.** 실패 row 를 만드는 곳은 한 곳이 아니라 열여덟 곳이 넘는다(§2.2 표). 각자 `Keeper_request_failure.t` 를 만든다. `Agent_core.Error.t` 를 받는 경로는 빠짐없는 match 로 투영하고, 문자열을 그대로 받는 생성자는 두지 않는다.
- **D3 채팅 row 의 실패는 값을 가진다.** `Row_kind.Transport_failure` 가 `Keeper_request_failure.t` 를 싣는다. 파일에는 `"kind":"transport_failure"` 옆에 `"failure":{...}` 로 쓴다. `content` 는 사람이 읽는 한 줄 요약이다.
- **D4 live stream 도 같은 값을 싣는다.** 요청 실패 이벤트가 `failure` 를 함께 보낸다.
- **D5 화면은 값으로 그린다.** TUI 의 `interruption_of_failure` 부분 문자열 해석기를 지운다. 에러 블록은 요약 한 줄을 그리고, 상세는 metadata 토글로 연다. 대시보드 실패 카드도 같은 값을 읽는다.
- **D6 hard cut.** `failure` 가 없는 옛 `transport_failure` row 를 읽는 코드는 만들지 않는다(§4).

## 1. 문제

### 1.1 한 줄이면 될 에러가 20줄 넘게 찍혔다

2026-09-15 20:09 KST, msx-retro-mania TUI 채팅 에러 블록:

```
Keeper request failed: Internal error: [masc_agent_core_error]
{"kind":"provider_attempt_effect_fenced","runtime_id":"claude_code.claude-sonnet-5",...,"diagnostic":"Internal error: [masc_agent_core_error]
{\"kind\":\"terminal_effect_failed\",...,\"diagnostic\":\"{\\\"composition_tool\\\":\\\"keeper_compose_sangokushi-2-end-command\\\",...
```

사람이 알아야 할 내용은 이것뿐이었다. composition 의 `press` 노드(`masc_msx_press`)가 "no MSX machine is loaded: call masc_msx_load first" 로 실패했다. 이 한 문장이 `\\\"` 사이에 묻혔고, 같은 노드 JSON 이 `cause` 와 `settled` 에 두 번 들어갔다. (그 실패가 턴을 끝낸 원인은 #36665 에서 따로 고쳤다.)

### 1.2 문자열이 세 번 겹친다 (필드는 다섯 곳)

| 층 | 위치 | 하는 일 |
|---|---|---|
| 3 (안쪽) | `keeper_tool_composition_surface.ml` inline 실행 분기 | composition `failure_data` 를 `Yojson.Safe.to_string` 해서 `Terminal_effect_failed.diagnostic` 에 넣는다 |
| 2 | `keeper_turn_driver.ml` fence 분기 | 앞 에러를 `Agent_core.Error.to_string` 해서 `Provider_attempt_effect_fenced.diagnostic` 에 넣는다. 안쪽 typed carrier 는 여기서 버려진다 |
| 1 (바깥) | `keeper_turn.ml` `Error err` 분기 | `Keeper_agent_error.user_message_of_core_error` 가 요약을 못 만들면 `Agent_core.Error.to_string` 으로 떨어진다. `summary_of_masc_internal_error` 는 fenced·terminal 을 포함한 10개 kind 에 `None` 이다 |

`core_error_of_masc_internal_error` 는 typed 값을 `Internal_carried` carrier 에 싣지만(RFC-0371 B12), 메시지는 `[masc_agent_core_error] ` 접두어 + JSON 문자열이다. 층 2 가 그 메시지를 다시 `diagnostic` 문자열에 넣으니 escape 가 한 겹씩 늘어난다.

그 뒤로는 문자열만 흐른다. 서버 stream 은 `Tool_result.message` 를 받아 `persisted_error_reply` 로 `"Keeper request failed: "` 를 붙이고, `Row_kind.Transport_failure` row 의 `content` 에 저장한다(`server_routes_http_keeper_stream.ml`). row 에는 `content : string` 과 `kind` 만 있고 구조화된 실패 필드가 없다(`keeper_chat_store.ml` `chat_message`).

### 1.3 문자열에서 원인을 거꾸로 짐작한다

TUI `bin/masc_tui_keeper_chat_history.ml` `interruption_of_failure` 는 row 의 `content` 에서 다음을 찾는다.

- `"MASC runtime shutdown interrupted the active Codex turn"`
- `"Provider 'codex_app_server' unavailable: stdout closed"`
- `"[masc_agent_core_error]"` 뒤 JSON 의 `kind = "provider_attempt_effect_fenced"`, 그 `diagnostic` 안의 `"runtime shutdown interrupted"`
- `effect_disposition = "effect_attempted"`

첫 문장은 `lib/runtime/runtime_codex_app_server.ml` 의 typed 값 `Runtime_shutting_down` 을 문자열로 바꾼 것이다. `stdout closed` 도 런타임의 `Process_exited` 계열 값에서 나온다. typed 값을 문자열로 만들고, 화면이 그 문자열을 다시 typed 값으로 되돌리려 한다. 런타임이 문구를 한 글자만 바꿔도 화면 판정이 조용히 틀린다.

`keeper_internal_error.ml` 의 `classify_masc_internal_error_of_string`·`has_masc_agent_core_error_prefix` 도 같은 모양이다. carrier 가 없는 경로(persisted 문자열)에서 접두어를 찾아 JSON 을 다시 파싱한다.

### 1.4 규모 (운영 workspace `.masc/keeper_chat/*.jsonl`, 2026-09-15 측정)

- `transport_failure` row 256개. `content` 길이 p50 141자, p90 383자, 최대 5,932자.
- escape 된 따옴표(`\"`)가 든 row 39개. `[masc_agent_core_error]` 가 든 row 28개(`provider_attempt_effect_fenced` 21, `terminal_effect_failed` 7).
- 나머지 대부분은 agent-core 의 typed 에러를 `to_string` 한 문장이다. 많은 순서: `Rate limited: ...` 57(+주간 한도 8, 시간 한도 4), `Invalid request (request_body_too_large ...)` 14, `Payment required: Insufficient Balance` 13, `{"error":"keeper_turn_resources_unavailable",...}` 11, `queued turn ended with a continuation checkpoint and no delivered reply` 10, `Invalid config 'multimodal_input' ...` 10, `checkpoint sink failed ...` 8, context window 7, `Parse error: result event ...` 7.

중첩 JSON 만 고치면 256개 중 28개만 나아진다. 나머지도 원래는 typed 값이었다(`Retry.api_error` 의 `RateLimited`·`PaymentRequired`·`InvalidRequest`·`ContextOverflow`·`Timeout`·`NetworkError` 등). 그래서 이 RFC 는 중첩만이 아니라 요청 실패 전체를 다룬다.

### 1.5 constitution

- `closed_sum_over_string`: "wire 문자열을 비교해서 분기하지 않는다." §1.3 이 정확히 이것이다.
- `forbidden#string_matching`: "String / SubString / RegEx 비교로 다음 로직을 결정하지 않는다."
- `evidence`·관측성: 운영자가 원인을 못 읽는 에러는 관측이 아니다.

## 2. 설계

### 2.1 D1 — 중첩 원인은 typed 값

D1 은 두 단계로 들어간다. terminal effect 쪽은 P1a, fence 두 kind 는 P1b 다.

`lib/keeper_runtime/keeper_internal_error.ml`:

```ocaml
type fenced_cause =                              (* P1b, 구현됨 *)
  | Fenced_masc of masc_internal_error          (* carrier 로 온 masc 에러 *)
  | Fenced_core of Keeper_request_failure_core.t (* §2.2 의 agent-core 투영 *)

and masc_internal_error =
  | ...
  | Terminal_effect_failed of                    (* P1a *)
      { failure_class : Tool_result.tool_failure_class
      ; effect_disposition : Tool_result.failure_effect_disposition
      ; detail : Keeper_terminal_effect_detail.t
      }
  | Provider_attempt_effect_fenced of             (* P1b *)
      { runtime_id : string
      ; effect_disposition : Keeper_provider_attempt_effect_core.t
      ; cause : fenced_cause
      }
  | Tool_correction_lost of                       (* P1b *)
      { runtime_id : string
      ; effect_disposition : Keeper_provider_attempt_effect_core.t
      ; reject_count : int
      ; cause : fenced_cause
      }
```

- `Keeper_terminal_effect_detail.t` 의 생성자와 JSON 모양은 `lib/keeper_runtime/keeper_terminal_effect_detail.mli` 가 정본이다. 이 문서에 다시 적지 않는다.
- `diagnostic : string` 은 다섯 곳에 있었다. terminal 쪽 세 곳(`Keeper_internal_error.Terminal_effect_failed`, `Keeper_tools_agent_core.terminal_effect_failure`, `Runtime_official_client_tool.Terminal_failed` 와 그 re-export)은 P1a 가 바꿨다. fence 쪽 두 곳(`Provider_attempt_effect_fenced`, `Tool_correction_lost`)은 P1b 가 바꾼다.
- terminal detail 의 생성자는 `diagnostic` 을 채우던 생산자에서 나왔다: composition 실패·결과 manifest·복구 증거(composition surface), 도구가 돌려준 `message`(handler), receipt 누락과 도구 출력 투영 실패(bundle), 결과 전달 실패와 경계 관찰 실패(official-client host), 복구 제안 거절(recovery worker), agent-core `TerminalTool{Effect,Durability}Failed.detail`.
- composition detail 은 JSON 이 아니라 typed `Executor.failure` 에서 만든다. plan 실행 에러는 종류만 담는다. `Composition_failed.cause` 가 투영하는 `Executor.cause` 는 다음과 같다(P1b 에서 정리).
  - `Tool_did_not_complete` 는 노드가 **실패**한 경우와 **미룬**(`Deferred`) 경우를 함께 싣는다. 미룬 노드는 실패한 것이 아니고 그 payload 는 미룸 데이터의 JSON 이라, `Node_failed` 가 아니라 `Node_deferred { node_id; model_tool_name; deferral }` 로 투영한다. `deferral` 은 `Keeper_tool_execution.deferred_kind` 를 종류만 옮긴 닫힌 값이고, 미룸 데이터 자체는 `payload` 에만 남는다.
  - `Outer_completion_mismatch` 는 terminal detail 로 투영하지 않는다. 실행기가 노드를 하나도 돌리기 전에 `Proven_pre_effect` 로 결정하는 값인데(`keeper_tool_plan_executor.ml` 505-513), composition surface 가 terminal 실패를 표시하는 분기는 `Proven_post_effect`/`Effect_outcome_unknown` 일 때만 들어간다. 즉 이 경로로는 생산자가 없다. 같은 자리의 `prepare_inputs` 실패(`Plan_execution_failed`, 387-410)도 `Proven_pre_effect` 지만, 같은 생성자가 노드 실행 중(`execute_one`, 201/284)에도 만들어지고 그쪽은 post-effect 일 수 있어서 `Plan_execution_failed` 는 남는다.
  - 대신 투영 함수는 닫힌 두 갈래(`Terminal_cause` / `Pre_effect_only`)를 돌려준다. 옵션으로 두면 새 `Executor.cause` 가 조용히 `None` 이 되어 실패가 아무 데도 안 남는다. 두 갈래면 새 생성자가 컴파일 에러가 되고, `Pre_effect_only` 가 post-effect 분기에 도달하면 — 실행기가 결정하는 disposition 이 바뀌었다는 뜻이다 — 턴을 이어가지 않고 `invalid_arg` 로 멈춘다. 효과가 일어났는데 표시할 원인이 없는 상태로 계속 가는 것보다 낫다.
- `payload : Yojson.Safe.t` 는 화면 표시용이다. 판정에 쓰지 않는다. `cause` 는 원인을 typed 로 투영한 값이지 노드 JSON 의 세 번째 사본이 아니다. 실패 객체 안에서 같은 노드가 `cause` 와 `settled` 에 두 번 들어가는 중복과 크기 제한 없는 `settled` 는 P2 에서 다룬다. 그 객체가 도구 결과 row 와 모델이 읽는 내용이기도 해서다.
- `masc_internal_error_to_json` 은 `detail`(P1a)·`cause`(P1b)를 JSON 객체로 쓴다. `parse_masc_internal_error_json` 도 같이 바꾼다.
- `keeper_turn_driver.ml` fence 분기는 `Agent_core.Error.to_string error` 대신, carrier 가 있으면 `Fenced_masc`, 없으면 §2.2 투영으로 `Fenced_core` 를 만든다(P1b).
- `Keeper_terminal_effect_detail.Boundary_observation_failed` 도 `message : string` 이 `Agent_core.Error.to_string` 이었다(`keeper_official_client_host.ml` 1136). 같은 이유로 `cause : Keeper_request_failure_core.t` 로 바꾼다(P1b). `Keeper_request_failure_core.t` 는 masc 에러를 실을 수 없으므로, 호스트는 넣기 전에 `classify_masc_internal_error` 로 걸러 carrier 로 온 masc 에러는 한 줄 요약(없으면 kind)만 남긴다. 안 그러면 접두어 붙은 JSON 이 다시 `message` 안으로 들어간다.
- `cap_blocker_detail` 의 2000자 상한은 이제 어떤 variant 도 통째로 담는다고 말할 수 없다. terminal effect 실패가 composition 실패 객체를, fence 가 그걸 담은 cause 를 싣기 때문이다. 상한 자체는 blob 천장으로 남기고, composition 객체를 생산자에서 자르는 일은 P2 다.
- `fenced_cause` 는 별도 모듈이 아니라 `keeper_internal_error.ml` 안에서 `masc_internal_error` 와 `and` 로 같이 선언한다. fence 가 terminal effect 실패를 실을 수 있어 재귀가 실재하고, OCaml 은 recursive module 없이는 모듈 사이의 재귀를 표현하지 못한다. `Keeper_request_failure_core` 는 반대로 masc 에러를 전혀 싣지 않아서 별도 모듈로 둘 수 있고, 그래야 아래 층인 `Keeper_terminal_effect_detail` 이 순환 없이 쓴다.

### 2.2 D2 — `Keeper_request_failure.t`

새 모듈 둘. `Keeper_request_failure_core`(agent-core 투영)는 P1b 에서 `keeper_internal_error` 와 같은 층에 만든다. fence 원인이 쓰기 때문이다. `Keeper_request_failure`(요청 실패 전체)는 P2 에서 의존 방향을 보고 위치를 정한다:

```ocaml
type cause =
  | Core of Keeper_request_failure_core.t   (* agent-core 에러의 typed 투영 *)
  | Masc of Keeper_internal_error.masc_internal_error
  | Operator_cancelled
  | Reply_contract_rejected of { field : reply_contract_field }
  | No_visible_reply of { had_blocks : bool }
  | Keeper_not_registered of { keeper : string }
  | Turn_resources_unavailable of { resource : turn_resource }
  | Server_restarted
  | Raised of { site : failure_site; exn : string }

type t = { cause : cause }

val summary : t -> string   (* 저장하지 않는다. cause 에서 계산한다 *)
```

- `summary` 는 필드가 아니라 함수다. 파생 상태를 파일에 다시 저장하지 않는다.
- `failure_site` 는 닫힌 변형이다(`Stream_dispatch`, `Stream_submit`, `Turn_run`, …). `Raised` 는 잡은 예외에서만 만든다. 문자열을 받아 아무 데나 담는 자리가 아니다.
- **실패 생성자가 아니라 문자열을 받는 생성자는 만들지 않는다.** 이 규칙이 없으면 `Server_exception of { detail : string }` 한 칸이 §1.4 의 문장 전부를 다시 빨아들인다.

#### 생산자 표 (P2 에서 전수 확인)

실패 row 를 만드는 경로는 다음과 같다. 리뷰에서 확인한 것만 적는다.

| 생산자 | 위치 | 생성자 |
|---|---|---|
| 턴 실행 실패 | `keeper_turn.ml` `Error err`(현 965-976) | `Core` / `Masc` |
| 턴 경로의 다른 `tool_result_error` 8곳 | `keeper_turn.ml` 452, 468, 496, 570, 593, 932, 955, 1029 | 각자 확인 후 배정. 593 은 `Agent_core.Error.to_string` 을 직접 쓴다 |
| 운영자 중단 | stream 1191-1215 | `Operator_cancelled` |
| dispatch 불가 / 미초기화 | stream 1191-1215 | `Turn_resources_unavailable` |
| 스트리밍·제출 예외 | stream 2091, 2412 | `Raised` |
| 응답 계약 거절 | `finish_projection_failure`(2003/2115), `direct_reply_terminal_error`(2137) | `Reply_contract_rejected` |
| 보이는 답 없음 | stream 2240-2249 | `No_visible_reply` |
| keeper 미등록 / user row append 실패 | stream 2046-2060 → 2342 | `Keeper_not_registered` 등 |
| 서버 재시작 | `keeper_owner_registry.ml` 161-165 | `Server_restarted` |

`Keeper_request_failure_core.t` 는 `Agent_core.Error.t` 를 **생성자 단위로 빠짐없이** match 해서 만든다. 가장 많이 본 실패(§1.4)부터:

| agent-core 생성자 | 투영 | 요약 예 |
|---|---|---|
| `Api (RateLimited { retry_after; message })` | `Rate_limited { runtime; retry_after }` (runtime 은 에러가 아니라 턴의 attempt 에서 온다) | `Rate limited by <runtime>; retry after <n>s` |
| `Api (PaymentRequired _)` | `Payment_required { runtime }` | `<runtime> has no balance left` |
| `Api (InvalidRequest _)` | `Invalid_request { runtime; reason }` | 원래 reason |
| `Api (ContextOverflow _)` | `Context_overflow { limit }` | 지금 `context_overflow_user_message` |
| `Api (NetworkError _)` / `Provider (NetworkError _)` | `Network { runtime; kind }` | 지금 `provider_network_user_message` |
| `Api (Timeout _)` | `Timeout { runtime; phase }` | |
| `Api (Overloaded / ServerError / AuthError / AuthorizationError / NotFound / InputCapacity)` | 생성자별 | P2 |
| `Provider _` 계열 전부 | 생성자별 | P2 |
| `Config _` · `Serialization _` · `Agent _` · `Mcp _` · `Io _` · `Orchestration _` | 생성자별 | P2 |
| `Internal_carried { carrier = Masc_internal e; _ }` | `Masc e` 로 올린다 | `summary_of_masc_internal_error` 를 모든 kind 로 넓힌다 |
| `Internal msg` · carrier 없는 `Internal_carried` | `Core_internal { message }` | message |

- 표의 투영 필드는 `Retry.api_error` 의 `RateLimited` 만 확인했다. 나머지는 P2 에서 확인해 맞춘다.
- `Core_internal` 은 임시 자리다. agent-core 안에서 문자열로 나는 실패(예: `packages/agent_core/lib/pipeline/pipeline_checkpoint.ml` 의 checkpoint sink)는 P5 에서 agent-core 에 typed 값을 넣어 없앤다. P2 는 `Internal` 을 만드는 생산자 목록을 RFC 에 적고 끝낸다. 목록에 없는 새 `Internal` 이 들어오면 lint 로 막는다.
- `summary_of_masc_internal_error` 는 9개 kind(`Resumable_cli_session`, `Internal_*` 셋, `Incomplete_tool_transcript`, `Provider_attempt_effect_fenced`, `Tool_correction_lost`, `Receipt_persistence_failed`, `Gate_replay_repair_required`)에 `None` 을 돌려준다. 모든 kind 에 한 줄을 만들게 한다. fenced 는 안쪽 cause 요약에 "tool effect may have happened" 를 붙인다. `Terminal_effect_failed` 는 P1a 부터 `Terminal tool effect failed (effect_disposition=<disposition>): <detail 요약>` 한 줄이고, detail 요약은 `Keeper_terminal_effect_detail.summary` 가 만든다.
- **typed 값은 dispatch 경계를 그대로 건넌다.** 지금 `Tool_result` 로 내보내고 서버가 JSON 으로 다시 읽는 모양은 같은 프로세스 안에서의 왕복이라 경계가 아니다. `` `Ran (disposition, body) `` 가 `data` 를 이미 버린다(stream 1191, 1273). P2 에서 dispatch 반환 타입에 실패 값을 실어 보낸다.

### 2.3 D3 — 채팅 row

```ocaml
module Row_kind : sig
  type t =
    | Utterance
    | Transport_failure of Keeper_request_failure.t
end
```

- 파일: `{"kind":"transport_failure","failure":{"cause":{...},"summary":"..."},"content":"<summary>",...}`.
- `content` 는 `"Keeper request failed: " ^ summary` 가 아니라 `summary` 다. "요청이 실패했다"는 `kind` 가 이미 말한다.
- watermark 규칙(실패 row 는 lane watermark 를 올리지 않음)은 그대로다. `kind` 의 생성자만 보고 판정하는 코드(`keeper_world_observation_message_scope.ml`, `keeper_chat_store.ml`, `keeper_chat_journal_audit.ml`)는 `Transport_failure _` 로 패턴만 바뀐다.
- `keeper_owner_registry.ml` 재시작 row 는 `Server_restarted` 를 싣는다. 이미 operation store 가 `Interrupted_by_restart` 로 알고 있다.
- **wire 는 자동으로 따라가지 않는다.** 아래 다섯 곳이 row 를 통째로 보내지 않고 필드를 하나씩 다시 만든다. 각각 손으로 넓힌다.
  - history JSON (`keeper_chat_store.ml` 3067)
  - transcript JSON (`keeper_chat_store.ml` 3191)
  - keeper surface read (`keeper_surface_read.ml` 40-43) — 모델이 읽는 자리다. P2 에서 `summary` 만 줄지 `failure` 까지 줄지 정한다
  - SSE `keeper_chat_appended` (`keeper_chat_broadcast.ml` `do_broadcast`) — name / connector / ts / blocks 만 보낸다
  - Slack (`keeper_chat_slack.ml` 711), Discord (`keeper_chat_discord.ml` 433)
- `Row_kind.equal` 은 생성자가 값을 실으면 그대로 못 쓴다(`keeper_chat_journal_audit.ml` 148, 158). 실패 여부만 묻는 술어를 따로 둔다.

### 2.4 D4 — live stream

요청 실패 이벤트(`Event_error`, AG-UI `RUN_ERROR`)에 `failure` 를 싣는다. TUI `Run_failed` 와 대시보드 `keeper-stream.ts` 는 `message` 대신 `failure.summary` 를 그린다. 두 곳이 따로 `"Keeper request failed: ..."` 를 붙이는 코드는 지운다.

### 2.5 D5 — 화면

- TUI: `interruption_of_failure`·`present_delivery_failure` 의 부분 문자열 탐색을 지우고 `cause` 로 match 한다.
  - host shutdown·provider 연결 끊김은 런타임에서 이미 더 앞에서 뭉개진다. `keeper_codex_runtime.ml` 340-344 가 `Spawn_failed` 와 `Process_exited` 를 함께 `ProviderUnavailable` 로 바꾸고, 405-409 가 `Runtime_shutting_down` 을 `Internal` 문자열로 바꾼다. 그래서 `cause` 에 `Host_shutdown` 과 `Runtime_connection_closed` 를 **P2 에서** 넣고, 런타임이 그 값을 잃지 않게 고친다. P3 에서 스키마를 다시 바꾸지 않기 위해서다.
  - 에러 블록은 `summary` 한 줄. `Ctrl-F:metadata` 에서 `failure` 전체 JSON 을 들여쓰기해 보여 준다.
- 대시보드 `ChatFailureCard`: 제목 옆에 `summary`, "오류 상세 보기"는 `failure` JSON, 복사 버튼은 JSON 을 복사한다.

## 3. 지우는 것 / 남기는 것

지운다:
- `diagnostic : string` 다섯 필드와, 에러를 `to_string` 해서 그 필드에 넣는 코드.
- `persisted_error_reply` 의 `"Keeper request failed: "` 접두어, 대시보드·TUI 의 같은 접두어.
- TUI `interruption_of_failure` 의 부분 문자열 탐색 전부.
- 지운 동작을 고정하던 테스트.

남긴다:
- `[masc_agent_core_error] ` 접두어 메시지(`Internal_carried.message`). 로그·receipt·persisted turn state 가 문자열로만 기록하는 곳이다(RFC-0371 B12 주석). 이 RFC 는 그 문자열을 **읽어서 판정하는** 경로를 줄이는 것이지, 로그 문구를 없애는 것이 아니다. `classify_masc_internal_error_of_string` 을 쓰는 남은 호출처는 P2 에서 목록으로 적고, carrier 로 대체 가능한 곳만 바꾼다.
- `Transport_failure` 의 watermark 규칙과 operation ledger 의 `Failed { kind; detail }`.

## 4. hard cut

- `failure` 없는 옛 `transport_failure` row 를 읽는 호환 코드는 만들지 않는다(constitution `legacy_residue`).
- 새 decoder 는 그런 row 를 **버린다**. 지금 모르는 `kind` 라벨은 `Utterance` 로 읽혀 watermark 를 올리므로(`keeper_chat_store.ml` 2108-2123) 같은 방식을 쓰면 안 된다. 실패 row 는 watermark 를 올리지 않으니 버려도 대기 중인 사용자 메시지 판정은 바뀌지 않는다. 화면에서 옛 실패 기록이 사라진다.
- **이벤트 저널도 같이 자른다.** `keeper_chat_event_log.ml` 684-704 는 한 줄이라도 envelope 로 안 읽히면 저널 전체를 `Journal_corrupt` 로 만들고, 775-787 의 `next_sequence` 가 재개를 거절한다. 저널은 30일 보관이다. 그래서 D4 로 `Event_error` 모양이 바뀌면 옛 저널은 읽히지 않는다. 선택지는 둘이다.
  1. 배포 시 저널을 비운다(constitution `runtime_data`). RFC-0412 의 soak 은 그 시점부터 다시 센다.
  2. `failure` 를 저널에 저장하는 `Event_error` 에는 싣지 않고 live SSE 에만 싣는다.
  P2 는 1번으로 간다. 2번은 저널을 읽는 화면이 다시 문자열만 보게 되기 때문이다. 배포 시 지울 파일 경로와 줄 수를 PR 에 적는다.
- 운영 workspace 의 옛 `transport_failure` 줄은 256줄이다(§1.4).

## 5. PR 스택

| 단계 | 내용 | 주 파일 | 검증 |
|---|---|---|---|
| P0 | 이 RFC (이 수정 포함) | `docs/rfc/` | 인덱스 `--check` |
| P1a | D1 중 `Terminal_effect_failed` 의 `diagnostic` 을 `Keeper_terminal_effect_detail.t` 로 (생성자 목록은 `lib/keeper_runtime/keeper_terminal_effect_detail.mli` 가 정본) | `keeper_internal_error.ml`, 새 detail 모듈, composition surface, bundle, handler, official-client host, recovery worker, `keeper_agent_run.ml`, `keeper_tools_agent_core.ml`, `runtime_official_client_tool` | 사고 composition 재현 테스트에서 실패 객체가 escape 되지 않은 객체로 직렬화된다 |
| P1b | D1 중 `Provider_attempt_effect_fenced`·`Tool_correction_lost` 의 원인 + `Boundary_observation_failed` 의 원인 + `Keeper_request_failure_core` 투영 + `diagnostic` 을 읽는 TUI 갱신 | `keeper_internal_error.ml`, 새 core 투영 모듈, `keeper_terminal_effect_detail.ml`, `keeper_turn_driver.ml`, `keeper_official_client_host.ml`, `keeper_tool_composition_surface.ml`, `bin/masc_tui_keeper_chat_history.ml` | 사고 에러의 JSON 에 escape 된 JSON 문자열이 0개. TUI 의 host-shutdown 표시가 유지된다 |
| P2 | D2·D3 + 런타임 typed 원인 + wire 다섯 곳 + composition 실패 객체의 `cause`/`settled` 노드 중복과 `settled` 크기 경계 | `keeper_turn.ml`, stream, `keeper_chat_store.ml`, owner registry, `keeper_codex_runtime.ml`, surface read, broadcast, Slack·Discord | §2.2 생산자 표의 각 경로마다 fixture → 생성자 고정. 옛 row·저널 hard cut 테스트 |
| P3 | D5 TUI | `bin/masc_tui*.ml` | PTY 시나리오: 사고 에러가 3줄 이하 |
| P4 | D5 대시보드 | `dashboard/` | 컴포넌트 테스트 + 브라우저 스크린샷 |
| P5 | agent-core 안의 `Internal` 문자열 생산자를 typed 로 | `packages/agent_core/` | `Core_internal` 로 떨어지는 경로 0개 |

### P1a 가 실제로 바꾼 동작 (#36752)

이 RFC 는 표시와 기록만 다룬다고 했지만(§7), P1a 는 한 경로에서 동작도 바꿨다. 기록해 둔다.

턴은 성공했는데 닫는 도구의 terminal effect 가 실패한 채 남은 경우(`keeper_agent_run.ml`), 전에는 타입 없는 `Internal` 에러를 돌려줬다. 그래서 `Internal_opaque` 로 라우팅되고 receipt 는 `Reason_internal_error` / `Disp_fail_open_next_runtime` 로 읽었다 — 다음 런타임으로 넘어가는 처리다. 지금은 typed `Terminal_effect_failed` carrier 를 돌려주므로 `Terminal_effect_<class>` 로 라우팅되고 receipt 는 `Reason_terminal_effect_failed` / `Disp_effect_review_required` 이다 (`keeper_execution_receipt.ml` 의 `operator_disposition`, `keeper_runtime_failure_route.ml`).

결과로 그 턴은 `needs_operator_broadcast` 가 참이 되고(`Disp_effect_review_required`), 이어질 HITL continuation 을 다시 보내지 않고 정리한다(`keeper_heartbeat_loop.ml` 479). 닫는 도구가 바깥에 이미 뭔가 했을 수 있으니 자동으로 다시 돌리지 않고 사람이 판단하게 두는 쪽이 맞다.

### P2 첫 조각이 한 일 — 런타임 정지 원인의 typed 화

P2 는 표의 한 줄이지만 한 번에 들어가지 않는다. 첫 조각은 §1.3 의 두 문장을 없앴다.

- `Keeper_internal_error.masc_internal_error` 에 `Host_stopped_turn { runtime_id; stop }`
  와 `Runtime_connection_closed { runtime_id; detail; turn_accepted }` 를 넣었다.
  `stop` 은 `Host_graceful_shutdown | Runtime_reported_interrupt` 닫힌 값이다.
  `Spawn_failed` 는 `ProviderUnavailable` 로 남겨서 `Process_exited` 와 구분된다.
  둘은 회수 경로(`Transient_spawn_failed` vs `Transport_interrupted`)가 다르다.
- 생산자: `keeper_codex_runtime.ml` 의 `Runtime_shutting_down` · `Turn_interrupted` ·
  `Process_exited`, `keeper_claude_code_runtime.ml` 의 `Process_exited`.
- **회전은 그대로 둔다.** 닫힌 연결은 전에 `ProviderUnavailable` 로 회전했으므로
  `Keeper_runtime_attempt.core_error_to_runtime_outcome` 이 같은 provider 에러를 다시
  만들고, `Keeper_runtime_failure_route.route_of_error` 는 경계와 무관하게
  `observe_retry Server_error` 를 주며, `Keeper_error_classify` 의 유예 런타임 레인도
  `Server_error` 로 남는다. host 정지는 전에도 회전이 없었고(`Internal` 은 `None`)
  지금도 없다.
- TUI `bin/masc_tui_keeper_chat_history.ml` 의 두 문장 검색과 leaf 순회를 지웠다.
  `[masc_agent_core_error]` 표식을 찾는 부분은 남고(P3 가 지운다), 찾은 JSON 은
  `parse_masc_internal_error_json` 으로 읽어 생성자로 판단한다. fence 안에 들어간
  원인도 `Fenced_masc` 를 따라 내려가며 찾는다.
- `summary_of_masc_internal_error` 는 두 kind 에 `None` 을 돌려준다. fence 두 개가
  `None` 인 이유와 같다. row 가 원인을 담는 곳은 아직 글자뿐이고
  `user_message_of_core_error` 는 요약이 있으면 봉투 대신 그걸 넣는다. 요약을 주면
  화면은 값 대신 문장을 받게 되는데, 그게 이 RFC 가 되돌리려는 거래다. P3 에서 row 가
  `failure` 필드를 가지면 그때 한 줄을 돌려준다. 그래서 fence 없는 host 정지·연결
  끊김 row 도 지금 그대로 lifecycle 배지를 그린다.

### P2 두 번째 조각이 한 일 — 실패를 만드는 곳이 값을 만든다

`Keeper_request_failure` 를 `lib/keeper_runtime/` 에 만들고, 실패 row 를 만드는
경로가 전부 이 값을 만들게 했다. row 형식·SSE payload·Slack·Discord·TUI 는
그대로다. 실패는 아직 글자로 row 에 닿고, 값이 row 에 실리는 건 D3 다.

- `cause` 는 닫힌 합타입이고 `summary` 는 필드가 아니라 함수다. 문자열을 이유로
  받는 생성자는 없다. `Raised` 는 잡은 예외에서만 만들고 자리(`failure_site`)를
  닫힌 값으로 적는다.
- agent-core 에러를 사람이 읽을 문장으로 바꾸던 곳은 `Keeper_agent_error` 하나뿐이었다.
  그 네 갈래(`Api NetworkError`, `Api ContextOverflow`, `Api InputCapacity`,
  `Provider NetworkError`)를 생성자로 올렸고, 나머지는 `Core`(= `Keeper_request_failure_core`)
  와 `Masc` 로 간다. `Keeper_agent_error.user_message_of_core_error` 는 이제
  `Keeper_request_failure.summary` 를 부르는 한 줄이다. §2.2 두 번째 표의 나머지
  생성자(`Rate_limited`, `Payment_required` 등)는 아직 `Core` 에 남아 있다.
- 값은 dispatch 경계를 값으로 건넌다. `Keeper_turn.dispatch` 가
  `Turn_settled | Turn_failed { result; failure }` 두 생성자이고,
  `Keeper_tool_surface.dispatch_keeper_msg_stream_admitted` 가 그대로 돌려준다.
  `Tool_result.data` 로 JSON 을 실어 서버가 다시 읽는 왕복은 없다.
- `summary_of_masc_internal_error` 가 `None` 인 kind 는 그대로 봉투를 돌려준다.
  채팅 pane 이 아직 그 봉투를 읽어 배지를 그리기 때문이다(D3 에서 바뀐다).

P1a 와 P1b 는 각각 혼자 들어갈 수 있다. 단 P1b 는 fenced `diagnostic` 을 읽는 TUI 두 곳을 같은 PR 에서 함께 고쳐야 한다. 안 그러면 host-shutdown 표시가 조용히 사라진다(`bin/masc_tui_keeper_chat_history.ml` 170, 테스트는 손으로 만든 옛 모양을 쓰므로 초록으로 남는다: `test/test_tui_keeper_chat_history.ml` 358).

## 6. 성공 기준

- 2026-09-15 사고와 같은 실패가 TUI 에러 블록에서 요약 한 줄로 보인다. 상세 JSON 에 escape 된 JSON 문자열이 없다.
- `bin/` 과 `dashboard/` 에 실패 원인을 고르려고 row `content` 를 부분 문자열로 검사하는 코드가 0곳이다.
- **문자열을 그대로 받는 실패 생성자가 없다.** `Raised` 는 잡은 예외에서만, `Core_internal` 은 P5 까지의 임시 목록에서만 나온다.
- §2.2 생산자 표의 모든 경로가 자기 생성자로 투영된다. §1.4 의 상위 문구 중 `Core_internal` 로 남는 것은 목록에 이름이 적혀 있다.

## 7. 범위 밖

- agent-core `Agent_core.Error.t` 자체에 JSON 코덱을 넣는 일. 투영은 masc 쪽에서 한다. agent-core 는 host 개념을 모른다(RFC-0371). agent-core 안에서 나는 실패에 typed 값을 주는 일은 범위 밖이 아니라 P5 다.
- 실패 원인별 재시도·failover 정책. 이 RFC 는 표시와 기록만 다룬다. 정책은 이미 typed 값(`Keeper_runtime_failure_route`)을 읽는다.
- operation ledger 의 `"turn_failed: " ^ detail` 문자열. 같은 모양이지만 소비자가 다르다. P2 에서 목록만 남긴다.

## 8. 건드리지 않는 것

- `Transport_failure` row 가 watermark 를 올리지 않는 규칙.
- `Internal_carried` carrier 설계와 `[masc_agent_core_error]` 로그 문구. `cap_blocker_detail` 의 2000자 절단도 그대로 둔다.
- `lib/keeper_runtime/dune` 는 모듈을 나열하므로 새 모듈을 거기에 추가한다(작업 항목이지 설계는 아니다).
- #36665 가 고친 MSX 거절 disposition, #36662 의 composition 실패 경계 정책.
