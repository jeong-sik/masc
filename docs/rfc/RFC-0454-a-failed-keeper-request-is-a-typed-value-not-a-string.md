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

- Status: **Draft (2026-09-15).** 결정은 §0, 구현 순서는 §5.
- 한 줄: keeper 턴이 실패하면 지금은 에러를 문자열로 바꿔 채팅 row 의 `content` 에 넣고, TUI 는 그 문자열에서 부분 문자열을 찾아 원인을 짐작한다. 실패를 닫힌 합타입 `Keeper_request_failure.t` 로 만들어 row 와 stream 에 그대로 싣고, 화면은 그 값으로 그린다.
- 이슈: #36663. 계기: 2026-09-15 20:09 KST msx-retro-mania 채팅 에러(§1.1).

## 0. 결정 요약

- **D1 중첩 에러는 문자열로 감싸지 않는다.** `Provider_attempt_effect_fenced` 와 `Tool_correction_lost` 의 `diagnostic : string` 을 typed 원인으로 바꾼다. `Terminal_effect_failed` 의 `diagnostic : string` 은 무엇이 실패했는지 말하는 합타입으로 바꾼다. JSON 으로 내보낼 때도 안쪽은 JSON 객체다. escape 된 JSON 문자열이 아니다.
- **D2 요청 실패는 한 곳에서 한 번 typed 값이 된다.** `keeper_turn.ml` 의 `Error err` 분기(지금 `user_message_of_core_error` 로 문자열이 되는 곳)가 `Agent_core.Error.t` 를 빠짐없는 match 로 `Keeper_request_failure.t` 로 바꾼다. 문자열 파싱은 없다.
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

### 1.2 문자열이 세 번 겹친다

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

`lib/keeper_runtime/keeper_internal_error.ml`:

```ocaml
type fenced_cause =
  | Fenced_masc of masc_internal_error          (* carrier 로 온 masc 에러 *)
  | Fenced_core of Keeper_request_failure_core.t (* §2.2 의 agent-core 투영 *)

and terminal_effect_detail =
  | Composition_node_failed of
      { composition_tool : string
      ; node_id : string
      ; tool_name : string
      ; message : string
      ; payload : Yojson.Safe.t   (* 지금의 failure_data. 문자열이 아니다 *)
      }
  | Terminal_tool_failed of { tool_name : string; message : string }
  | Terminal_receipt_missing of { tool_name : string }
  | Output_artifact_storage_failed of { detail : string }
  | Composition_evidence_persistence_failed of { detail : string }

and masc_internal_error =
  | ...
  | Terminal_effect_failed of
      { failure_class : Tool_result.tool_failure_class
      ; effect_disposition : Tool_result.failure_effect_disposition
      ; detail : terminal_effect_detail
      }
  | Provider_attempt_effect_fenced of
      { runtime_id : string
      ; effect_disposition : Keeper_provider_attempt_effect_core.t
      ; cause : fenced_cause
      }
  | Tool_correction_lost of
      { runtime_id : string
      ; effect_disposition : Keeper_provider_attempt_effect_core.t
      ; reject_count : int
      ; cause : fenced_cause
      }
```

- `terminal_effect_detail` 의 생성자 목록은 지금 `diagnostic` 을 채우는 곳에서 나왔다: composition 실패, terminal tool 실패 메시지, "terminal tool completed without a typed effect receipt", "tool output artifact storage failed", "composition recovery evidence persistence failed". P1 에서 생산자를 전수 확인하고 목록을 맞춘다.
- `masc_internal_error_to_json` 은 `cause`·`detail` 을 JSON 객체로 쓴다. `parse_masc_internal_error_json` 도 같이 바꾼다.
- `keeper_turn_driver.ml` fence 분기는 `Agent_core.Error.to_string error` 대신, carrier 가 있으면 `Fenced_masc`, 없으면 §2.2 투영으로 `Fenced_core` 를 만든다.

### 2.2 D2 — `Keeper_request_failure.t`

새 모듈 둘. `Keeper_request_failure_core`(agent-core 투영)는 P1 에서 `keeper_internal_error` 와 같은 층에 만든다. fence 원인이 쓰기 때문이다. `Keeper_request_failure`(요청 실패 전체)는 P2 에서 의존 방향을 보고 위치를 정한다:

```ocaml
type t =
  { cause : cause
  ; summary : string   (* cause 에서 만든 한 줄. 파싱하지 않는다 *)
  }

and cause =
  | Core of Keeper_request_failure_core.t   (* agent-core 에러의 typed 투영 *)
  | Masc of Keeper_internal_error.masc_internal_error
  | Server_restarted                         (* keeper_owner_registry 의 재시작 row *)
  | Server_exception of { site : string; detail : string }
```

`Keeper_request_failure_core.t` 는 `Agent_core.Error.t` 를 **생성자 단위로 빠짐없이** match 해서 만든다. 가장 많이 본 실패(§1.4)부터:

| agent-core 생성자 | 투영 | 요약 예 |
|---|---|---|
| `Api (RateLimited { retry_after; message })` | `Rate_limited { runtime; retry_after }` (runtime 은 에러가 아니라 턴의 attempt 에서 온다) | `Rate limited by <runtime>; retry after <n>s` |
| `Api (PaymentRequired _)` | `Payment_required { runtime }` | `<runtime> has no balance left` |
| `Api (InvalidRequest _)` | `Invalid_request { runtime; reason }` | 원래 reason |
| `Api (ContextOverflow _)` | `Context_overflow { limit }` | 지금 `context_overflow_user_message` |
| `Api (NetworkError _)` / `Provider (NetworkError _)` | `Network { runtime; kind }` | 지금 `provider_network_user_message` |
| `Api (Timeout _)` | `Timeout { runtime; phase }` | |
| `Config _` · `Serialization _` · `Agent _` · `Mcp _` · `Io _` · `Orchestration _` | 생성자별 | P2 에서 전수 |
| `Internal_carried { carrier = Masc_internal e; _ }` | `Masc e` 로 올린다 | `summary_of_masc_internal_error` 를 모든 kind 로 넓힌다 |
| `Internal msg` · carrier 없는 `Internal_carried` | `Internal { message }` | message |

- 표의 투영 필드는 `Retry.api_error` 의 `RateLimited` 만 확인했다. 나머지 생성자의 필드는 P2 에서 확인해 맞춘다.
- `summary` 는 `cause` 에서 결정적으로 만든다. `summary_of_masc_internal_error` 는 지금 10개 kind(`Resumable_cli_session`, `Internal_*` 셋, `Incomplete_tool_transcript`, `Terminal_effect_failed`, `Provider_attempt_effect_fenced`, `Tool_correction_lost`, `Receipt_persistence_failed`, `Gate_replay_repair_required`)에 `None` 을 돌려준다. 모든 kind 에 한 줄을 만들게 한다. fenced 는 안쪽 cause 요약에 "tool effect may have happened" 를 붙인다. terminal 의 `Composition_node_failed` 는 `<composition_tool>: <node_id> (<tool_name>) failed: <message>` 다.
- §1.4 의 `keeper_turn_resources_unavailable`·continuation checkpoint·checkpoint sink 문구는 agent-core 밖 생산자가 만든다. P2 에서 각 생산자를 찾아 `cause` 생성자를 붙인다. 찾지 못한 경로는 `Server_exception` 에 두지 말고 RFC 에 적어 되돌아온다.
- 턴 경로는 `Tool_result.Failed` 의 `data` 에 `Keeper_request_failure.to_json` 을, `message` 에 `summary` 를 싣는다. 서버 stream 은 `data` 를 decode 해서 typed 값으로 받는다. 이 decode 는 경계 파싱이다. `kind` 에 모르는 값이 오면 `Error` 이고 기본값으로 누르지 않는다.

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
- history API(`/api/v1/keepers/<name>/chat/history`, `/page`)와 SSE `chat_appended` 는 row JSON 을 그대로 내보내므로 `failure` 가 따라간다.

### 2.4 D4 — live stream

요청 실패 이벤트(`Event_error`, AG-UI `RUN_ERROR`)에 `failure` 를 싣는다. TUI `Run_failed` 와 대시보드 `keeper-stream.ts` 는 `message` 대신 `failure.summary` 를 그린다. 두 곳이 따로 `"Keeper request failed: ..."` 를 붙이는 코드는 지운다.

### 2.5 D5 — 화면

- TUI: `interruption_of_failure`·`present_delivery_failure` 의 부분 문자열 탐색을 지우고 `cause` 로 match 한다.
  - host shutdown·provider 연결 끊김은 런타임 typed 값이 요청 실패까지 올라와야 한다(`Runtime_shutting_down`, `Process_exited`). 지금 이 값이 어디서 문자열이 되는지는 P3 에서 확인한다. 이 RFC 는 "문자열로 된 뒤 되찾지 않는다"만 정한다.
  - 에러 블록은 `summary` 한 줄. `Ctrl-F:metadata` 에서 `failure` 전체 JSON 을 들여쓰기해 보여 준다.
- 대시보드 `ChatFailureCard`: 제목 옆에 `summary`, "오류 상세 보기"는 `failure` JSON, 복사 버튼은 JSON 을 복사한다.

## 3. 지우는 것 / 남기는 것

지운다:
- `diagnostic : string` 세 필드와, 에러를 `to_string` 해서 그 필드에 넣는 코드.
- `persisted_error_reply` 의 `"Keeper request failed: "` 접두어, 대시보드·TUI 의 같은 접두어.
- TUI `interruption_of_failure` 의 부분 문자열 탐색 전부.
- 지운 동작을 고정하던 테스트.

남긴다:
- `[masc_agent_core_error] ` 접두어 메시지(`Internal_carried.message`). 로그·receipt·persisted turn state 가 문자열로만 기록하는 곳이다(RFC-0371 B12 주석). 이 RFC 는 그 문자열을 **읽어서 판정하는** 경로를 줄이는 것이지, 로그 문구를 없애는 것이 아니다. `classify_masc_internal_error_of_string` 을 쓰는 남은 호출처는 P2 에서 목록으로 적고, carrier 로 대체 가능한 곳만 바꾼다.
- `Transport_failure` 의 watermark 규칙과 operation ledger 의 `Failed { kind; detail }`.

## 4. hard cut

- `failure` 없는 옛 `transport_failure` row 를 읽는 호환 코드는 만들지 않는다(constitution `legacy_residue`).
- 새 decoder 는 그런 row 를 persistence read drop 으로 보고한다. 보고 경로는 지금 모르는 `kind` 라벨을 다루는 방식과 같다. 실패 row 는 watermark 를 올리지 않으므로 빠져도 대기 중인 사용자 메시지 판정은 바뀌지 않는다. 화면에서 옛 실패 기록이 사라진다.
- 운영 workspace 에서 옛 row 가 필요 없으면 P2 배포 전에 `keeper_chat/*.jsonl` 의 `transport_failure` 줄을 지워도 된다(constitution `runtime_data`). 256줄(§1.4)이다.

## 5. PR 스택

| 단계 | 내용 | 주 파일 | 검증 |
|---|---|---|---|
| P0 | 이 RFC | `docs/rfc/` | 인덱스 `--check` |
| P1 | D1 + §2.2 의 `Keeper_request_failure_core` 투영: fenced cause·terminal detail typed, JSON 코덱, fence 분기 | `keeper_internal_error.ml`, 새 core 투영 모듈, `keeper_turn_driver.ml`, composition surface, bundle | 인코딩 결과에 escape 된 JSON 문자열이 없다. 2026-09-15 사고 composition 을 재현한 테스트의 JSON 에 `\"` 가 0개 |
| P2 | D2·D3: `Keeper_request_failure`, 턴 경계, `Tool_result.data`, row `failure`, history·SSE, 재시작 row | `keeper_turn.ml`, `keeper_agent_error.ml`, stream, `keeper_chat_store.ml`, owner registry | §1.4 상위 8종 각각 fixture → `cause` 생성자와 `summary` 고정. 옛 row read drop 테스트 |
| P3 | D4·D5 TUI: live stream `failure`, 에러 블록·metadata, `interruption_of_failure` 제거, 런타임 typed 원인 | `bin/masc_tui*.ml`, 런타임 | PTY 시나리오: 사고 에러가 3줄 이하로 그려진다 |
| P4 | D5 대시보드 | `dashboard/` | 컴포넌트 테스트 + 브라우저 스크린샷 |

P1 은 P2 없이 먼저 들어가도 된다. 화면에 찍히는 문자열이 한 겹짜리 JSON 이 되기 때문이다. P2 부터는 스택이다.

## 6. 성공 기준

- 2026-09-15 사고와 같은 실패가 TUI 에러 블록에서 요약 한 줄로 보인다. 상세 JSON 에 escape 된 JSON 문자열이 없다.
- `bin/` 과 `dashboard/` 에 실패 원인을 고르려고 row `content` 를 부분 문자열로 검사하는 코드가 0곳이다.
- §1.4 의 상위 8종이 모두 `Server_exception` 이 아닌 생성자로 투영된다.

## 7. 범위 밖

- agent-core `Agent_core.Error.t` 자체에 JSON 코덱을 넣는 일. 투영은 masc 쪽에서 한다. agent-core 는 host 개념을 모른다(RFC-0371).
- 실패 원인별 재시도·failover 정책. 이 RFC 는 표시와 기록만 다룬다. 정책은 이미 typed 값(`Keeper_runtime_failure_route`)을 읽는다.
- operation ledger 의 `"turn_failed: " ^ detail` 문자열. 같은 모양이지만 소비자가 다르다. P2 에서 목록만 남긴다.

## 8. 건드리지 않는 것

- `Transport_failure` row 가 watermark 를 올리지 않는 규칙.
- `Internal_carried` carrier 설계와 `[masc_agent_core_error]` 로그 문구.
- #36665 가 고친 MSX 거절 disposition, #36662 의 composition 실패 경계 정책.
