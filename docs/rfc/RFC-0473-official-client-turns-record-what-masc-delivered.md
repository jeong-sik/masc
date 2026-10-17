---
rfc: "0473"
title: "공식 클라이언트 턴도 masc 가 대화에 더한 입력을 기록한다"
status: Draft
created: 2026-10-17
updated: 2026-10-17
author: vincent + claude
supersedes: []
superseded_by: null
related: ["#37752", "#43561", "#43564", "#43583", "#43597", "RFC-0390", "RFC-0460"]
implementation_prs: []
---

# RFC-0473 — 공식 클라이언트 턴도 masc 가 대화에 더한 입력을 기록한다

## 1. 문제

채팅에서 Ctrl-X 로 여는 Context 화면에는 탭이 세 개 있다. `1:stack`, `2:request`, `3:proof` 다.
공식 클라이언트 lane(Claude Code, Codex, Muse, Antigravity)을 쓰는 Keeper 에서는 세 탭 모두 쓸모 있는 내용을 보여 주지 못한다.

운영자 화면에서 본 것(2026-10-17, 코드가 아니라 관측이다):

- Keeper 33명 중 최소 16명이 공식 클라이언트 lane 이었다. Claude Code 9명, Codex 2명, Muse 5명이다. 여러 lane 을 섞어 쓰는 Keeper 는 세지 않았다.
- code-reviewer(Claude Code) turn #6936 에서 본 화면이다.
  - stack 탭: 맨 위는 #6936 인데 "WHAT WENT IN" 표는 39턴 전 #6897 의 숫자였다. keeper metrics 를 보면 구성을 잰 턴은 서버를 다시 시작한 직후의 #6897 하나뿐이고, 나머지는 모두 `client_session_holds_input` 이었다.
  - request 탭: `Exact input unavailable: provider-input: HTTP 404: no provider-input snapshot for …#6897` 한 줄만 나왔다.
  - proof 탭: `[ NO EXACT INPUT JOIN ]`, 같은 404, 모든 줄이 `BYTES ONLY`·`DIGEST ONLY` 였다.
  - 한 시간 뒤에는 #6897 이 50턴 페이지 밖으로 밀려나서, stack·proof 탭에 "No turn on this page recorded an exact input composition" 만 나왔다.
- mad-scientist(glm, Agent Core)는 stack·request 탭이 제대로 나왔다.

탭 화면이 아니라, lane 에 따라 남는 기록이 다른 것이 문제다.
화면 배치 버그 세 개(줄 어긋남 두 개, proof 탭의 키와 화면이 서로 다른 턴을 보는 문제)는 기록과 상관없어서 #43561 로 따로 고친다.

## 2. 원인

### 2.1 공식 클라이언트에 넘기는 것

공식 클라이언트 lane 에서는 masc 가 provider 요청을 만들지 않는다. masc 는 클라이언트에게 이번 턴의 입력을 넘기고, 요청은 클라이언트가 만든다.
세션을 새로 여는지, 이어 가는지에 따라 넘기는 것이 다르다.

| lane | 새 세션 | 이어 가는 세션 |
|---|---|---|
| Claude Code | `--system-prompt-file` 에 system prompt 와 System 메시지. stdin 에 `initial_turn_prompt`(history + goal)와 이미지 | 대화 칸(stdin)에는 `resume_prompt`(들고 가는 맥락 + goal)와 이미지. `--system-prompt-file` 도 다시 쓰지만, 클라이언트는 `--system-prompt-snapshot on` 이라 다음 compaction 때까지 읽지 않는다(`keeper_claude_code_runtime.ml:858`) |
| Codex | `thread/start` 에 `developerInstructions` 와 `dynamicTools`. `thread/inject_items` 로 history 를 `Host.encode_history_message` 로 바꾼 `history_message{role; text}` 로(Tool 메시지는 User 가 된다). `turn/start` 로 goal 과 이미지 | `thread/resume` 에 `developerInstructions` 를 다시 보내지만 Codex 는 다음 compaction 때 적용한다(`keeper_codex_runtime.ml:1013`). `turn/start` 로 `resume_prompt` 와 이미지 |
| Muse | system 지시 + history + goal 을 한 텍스트로(`prompt_for_turn`) | `resume_prompt` 만 |
| Antigravity | Muse 와 같다. 이미지는 거절한다 | `resume_prompt` 만. 들고 가는 맥락을 매번 모두 보낸다(`held:[]`) |

새 세션인지는 `claim_plan.previous_settlement` 로 정한다. Muse 와 Antigravity 는 그 전에 `reconcile_context` 가 snapshot hash 가 바뀐 settlement 를 버리므로, 이전 settlement 가 있어도 새 세션이 될 수 있다.
도구는 모든 lane 이 매 턴 넘긴다. 클라이언트가 받는 것은 `Agent_core.Tool.t` 가 아니라 loading 방식(`Upfront`/`On_demand`)이 붙은 투영이다(`runtime_official_client_tool.mli`).

### 2.2 넘긴 것이 기록되지 않는다

lane 은 넘긴 뒤 `report_transmitted_input` 으로 알린다. 그런데 알리는 값은 두 가지뿐이다.

```ocaml
type transmitted_model_input =
  | Whole_input_transmitted of Agent_core.Types.message list
  | Held_by_client_session
```

- 이어 가는 세션은 `Held_by_client_session` 이라 아무것도 싣지 않는다. 그래서 `record_transmitted_model_input`(`keeper_agent_run.ml:1608`)은 `Client_session_holds_input` 을 남기고, turn record 의 `input_components` 는 `None` 이 된다.
- 새 세션은 `prepared.messages` 를 싣는다. 이것은 클라이언트에게 실제로 쓴 텍스트가 아니라 그 재료다.
- 정확한 입력 기록(`Keeper_provider_input_snapshot`)은 Agent Core 가 요청 본문을 직렬화할 때만 쓴다(`keeper_agent_run.ml:2679`). 공식 클라이언트 lane 은 새 세션이든 이어 가는 세션이든 기록이 없다.
- raw trace 의 `Run_started.prompt` 에는 lane 이 보낸 prompt 문자열이 남지만, 비밀값을 가린 사본이고 system prompt·주입한 history·도구·이미지는 없다.
- Codex 만 `codex_context_submission` hook 으로 칸(slot)마다 실제로 쓴 바이트 수와 sha256 을 남긴다(`Keeper_context_submission_link`). 텍스트는 없다.

### 2.3 TUI 는 다른 턴의 기록을 빌려 온다

`Masc_tui_context_inspector.decode_turn_records` 는 `input_components` 가 있는 가장 최근 행을 `attributed` 로 고른다.
`turn_back = 0` 이면 TUI 는 이 행의 provider-input 을 가져오고, stack 탭은 이 행의 구성을 지금 턴 아래에 그린다.
공식 클라이언트 lane 에서는 이 행이 세션을 새로 연 턴이다. 그 턴에도 provider-input 이 없어서 404 가 난다.

## 3. 무엇을 보여 줄지 먼저 정한다

공식 클라이언트 턴에서 provider 가 받은 요청 전체는 masc 가 알 수 없다. 클라이언트 세션이 이전 대화를 들고 있고, 클라이언트가 자기 내용을 더하기 때문이다.
masc 가 정직하게 말할 수 있는 것은 "이번 턴에 masc 가 대화에 더한 입력"이다. 이것을 기록하고 보여 준다.

- **이번 턴에 읽히는 것:** 새 세션이면 지시, 세션에 넣은 history, 이번 턴 입력이다. 이어 가는 세션이면 들고 가는 맥락과 goal 이다. 이미지와 도구 목록은 두 경우 모두 들어간다.
- **다음 compaction 때 읽히는 것:** 이어 가는 세션에서 masc 가 다시 쓰는 system prompt 파일(Claude Code)과 `developerInstructions`(Codex)다. 기록은 하되 "대기 중인 지시"로 따로 둔다. 이번 턴 구성에 넣지 않는다. 넣으면 이어 가는 턴마다 모델이 읽지 않은 바이트가 "새로 넘긴 것"에 섞인다.

## 4. 다른 방법

| 방법 | 안 고른 이유 |
|---|---|
| TUI 만 고친다. 기록이 없으면 요청하지 않고 "기록 없음"이라고 쓴다 | 화면은 정직해지지만 운영자는 이번 턴에 무엇이 들어갔는지 여전히 볼 수 없다 |
| 클라이언트의 세션 파일을 읽는다(`~/.claude/projects/…`, Codex rollout, Muse `session.jsonl`) | 회사마다 형식이 다르고 예고 없이 바뀐다. 파일이 샌드박스나 microVM 안에 있다. masc 가 넘긴 것과 클라이언트가 더한 것이 섞인다. 범위 밖으로 둔다 |
| raw trace 의 `Run_started.prompt` 를 보여 준다 | 가린 사본이고 지시·history·도구·이미지가 빠진다 |
| 클라이언트에 쓴 문자열을 통째로 저장한다 | 새 세션 prompt 는 history 전체를 담아 수 MB 가 된다(Antigravity 주석에 11.4 MB 기록). 매번 다른 문자열이라 blob 중복 제거가 안 된다. #37752 의 "본문 통째로 받기" 문제가 공식 클라이언트 Keeper 16명에게 번진다 |

## 5. 제안

### 5.1 lane 이 넘기는 것을 닫힌 값으로 만든다

이름은 구현 때 정하고, 모양은 아래와 같다. 이어 가는 세션의 맥락 종류는 이미 있는 `Keeper_official_client_session_store.carried_context` 를 그대로 쓴다.

```ocaml
type turn_input =
  { goal : string
  ; images : Keeper_official_client_host.image_block list }

type delivery =
  | Session_start of
      { instructions : string
      ; seeded_history : string list   (* 클라이언트에 쓴 인코딩 그대로, 메시지마다 하나 *)
      ; turn : turn_input }
  | Session_resume of
      { carried : (Session_store.carried_context * string) list
      ; turn : turn_input
      ; staged_instructions : string option }  (* 다음 compaction 때 읽힌다 *)
```

- 세션 구분은 이 타입 자체가 한다. `context_delivery` 는 쓰지 않는다. Muse·Antigravity 는 두 경우 모두 `Canonical_source_guard` 를 남겨서 구분하지 못한다(`keeper_muse_runtime.ml:1023`, `keeper_antigravity_runtime.ml:684`).
- 새 세션에 `carried` 가 없고, 이어 가는 세션에 `seeded_history` 가 없다. 타입이 막는다.
- 도구는 이 값에 넣지 않는다. Claude Code·Muse·Antigravity 는 클라이언트가 MCP `tools/list` 로 가져가고, turn record 에는 이미 `tool_surface_ref` 가 있다. request 탭의 도구 줄은 이것을 읽는다.
- `Host.resume_prompt` 는 지금 합친 prompt 하나를 돌려준다(`keeper_official_client_host.mli:256`). 맥락마다 텍스트를 돌려주도록 고쳐야 `carried` 를 채울 수 있다. 합치는 일은 그대로 이 함수가 한다.

### 5.2 기록은 runtime 이 실제로 쓴 바이트에 묶는다

클라이언트에 쓰는 코드는 `lib/runtime` 안에 있다. Codex 는 `thread/start` 응답의 `threadId` 와 그 뒤에 정해지는 요청 id 를 넣어 쓰고(`runtime_codex_app_server.ml:2226`), Claude Code 는 프로세스가 사는 동안 system prompt 파일을 유지하며 stdin 에 쓴다(`runtime_claude_code.ml:2942`).
그래서 host 가 미리 렌더해서 쓰는 방식은 실제로 쓴 바이트를 알 수 없다. 대신 이미 있는 방식을 넓힌다.

- Codex 는 이미 쓰기가 끝난 메시지마다 `context_submission` 을 남긴다. 칸마다 바이트 수와 sha256 이다(`runtime_codex_app_server.mli:469`). keeper 쪽 `Keeper_context_submission_link` 가 이것을 masc 가 만든 조각과 맞춰 `verified`·`partial`·`unavailable` 로 판정한다.
- 나머지 세 runtime 은 쓰기 끝을 내용 없이 알린다. Muse·Antigravity 는 `on_prompt_sent : unit -> unit` 이고, Claude Code 는 `Runtime_claude_input_attribution` 의 `Written`·`Write_unknown` 단계만 있다.
- **세 runtime 도 쓰기가 끝난 바이트의 칸·바이트 수·sha256 을 같은 타입으로 알린다.** Codex 의 기록 타입과 칸 찾기를 공통 모듈 `Runtime_official_client_write` 로 옮기고, 세 runtime 도 Codex 처럼 `on_context_submission` 콜백으로 알린다. `on_prompt_sent` 는 디스패치 표시로 그대로 둔다. 그래야 기록이 실패해도 턴이 실패하지 않는다. Claude Code 는 system prompt 파일과 stdin 의 user message 두 번 쓴다.
- keeper 쪽은 네 lane 모두 `Keeper_context_submission_link` 로 5.1 의 조각과 쓴 바이트를 맞춘다. 판정 결과를 기록에 같이 남긴다.

"기록 = 쓴 것"을 약속하지 않는다. 기록은 masc 가 만든 조각과, 그중 얼마가 실제로 쓴 바이트와 맞는지를 함께 말한다. Claude Code 처럼 쓰기 결과를 모르는 경우(`Write_unknown`)도 그대로 남는다.

### 5.3 저장: 조각을 주소로 저장하고, 행에는 목록만 둔다

- `provider-inputs/` 에 같은 날짜별 jsonl 로 쓴다. 행의 출처를 닫힌 타입으로 나눈다.

  ```ocaml
  type origin =
    | Serialized_request of Llm_provider.Request_wire_observer.observation
    | Client_delivery of { manifest : delivery_manifest; submissions : submission_binding list }
  ```

  `delivery_manifest` 는 5.1 의 값에서 텍스트를 sha256 주소로 바꾼 것이다. 지금 행의 `wire` 칸은 그대로 `Serialized_request` 로 읽힌다. 새 행은 `client_delivery` 를 쓴다. 둘 다 있거나 둘 다 없는 행은 거절한다.
- 조각마다 `Tool_blob_store` 에 sha256 주소로 넣는다. 지시와 history 는 턴마다 거의 같아서 한 번만 저장된다. 클라이언트에 쓴 합친 문자열은 저장하지 않는다. 그 바이트 수와 sha256 은 5.2 의 쓰기 기록에 있다.
- 30일 보관과 blob 정리는 지금 규칙을 따른다.

### 5.4 turn record

- `input_components` 의 뜻은 바꾸지 않는다. "provider 요청 전체의 구성"이다. Agent Core 턴과 공식 클라이언트의 새 세션 턴만 채우고, 계산도 지금처럼 `build_ctx_segments`(`keeper_agent_run.ml:2623`) 하나가 한다. 다음 요청 예측(`keeper_next_request_forecast.ml` 의 `readings_of_records`·`read_composition`)이 이 값을 prompt block id 가 붙은 요청 전체로 읽기 때문이다.
- 새 칸 `client_delivery` 를 더한다.
  - `session`: `Started` 또는 `Resumed`. 5.1 의 값에서 나온다.
  - `resume_components`: 이어 가는 세션에서만 있다. 들고 간 맥락마다 한 줄(`Context_block` 은 그 prompt block 의 구성 id 로, `Librarian_working_state`·`Historical_task_reference`·`Context_carrier` 는 각자의 id 로)과 goal 한 줄이다. 새 세션의 구성은 `input_components` 에만 있다. 두 곳에 같은 숫자를 두지 않는다.
  - `stored`: provider-input 기록을 썼는지(`Stored`, `Store_failed`). 지금 `write_best_effort` 는 실패를 로그로만 남긴다. 결과를 돌려주게 바꾸고, TUI 는 `Store_failed` 행에 요청을 보내지 않는다.
- `request_wire_observation` 과 `client_delivery` 는 한 행에 둘 다 있을 수 없다. JSON 을 읽을 때 닫힌 타입 하나로 만들고, 둘 다 있으면 거절한다.
- `Client_session_holds_input` 은 남긴다. 이어 가는 세션에서 "요청 전체 구성은 클라이언트가 들고 있다"는 사실은 그대로이고, 이 값은 `input_components` 에 대한 말이다. `client_delivery` 는 masc 가 더한 부분에 대한 말이라 두 값이 서로 어긋나지 않는다. 대시보드의 `ctx_attribution` 그래프도 뜻이 바뀌지 않는다.

### 5.5 provider-input 은 목록을 먼저 준다 (#37752)

지금 `/provider-input` 은 본문 전체를 한 번에 준다(#37752: 19.6 MB 에 2.1초, 57 MB 에 8.6초). 공식 클라이언트 턴까지 기록하면 404 로 바로 끝나던 Keeper 들의 화면이 큰 응답을 받게 된다.
그래서 이 스택의 맨 아래에서 응답을 바꾼다.

- `/provider-input?turn_ref=…` 는 목록만 준다. 칸·조각마다 종류, 바이트, sha256 이다. 스키마 이름은 `masc.provider-input-manifest.v1` 이다.
- 조각 본문은 `/provider-input/part?turn_ref=…&index=N` 으로 따로 받는다(`masc.provider-input-part.v1`). 서버는 그 행의 목록에 있는 조각만 준다. `Tool_blob_store` 는 workspace 전체가 같이 쓰므로, sha256 만 받아 아무 blob 이나 내주지 않는다.
- Agent Core 기록도 같은 응답을 쓴다. #37752 가 같이 닫힌다.

### 5.6 TUI 세 탭

TUI 는 행마다 `request_wire_observation`·`client_delivery`·둘 다 없음을 보고 정한다.

- **Agent Core 행:** 지금처럼 그린다. 본문은 5.5 처럼 Enter 로 열 때 받는다.
- **공식 클라이언트 행:**
  - stack: "WHAT MASC ADDED" 에 masc 가 더한 구성을 그린다. 새 세션이면 `input_components`, 이어 가는 세션이면 `resume_components` 다. 대기 중인 지시는 따로 한 줄로 "다음 compaction 때 적용"이라고 쓴다. 그 아래에 provider 가 센 입력·cache read·출력을 그 숫자의 범위(요청 하나인지 턴 전체인지, `Runtime_usage_scope`)와 함께 그린다. 두 숫자의 차이는 계산하지 않는다.
  - request: 조각을 순서대로 보여 준다. `F` 지시, `H` 세션에 넣은 history, `C` 들고 간 맥락, `N` goal, `S` 도구(`tool_surface_ref`)다. 대기 중인 지시는 따로 묶는다. 머리 줄에 "Delivered to Claude Code · resumed session" 처럼 누구에게 어떤 세션으로 넘겼는지 쓴다.
  - proof: 같은 턴의 기록이라 `[ EXACT TURN JOIN ]` 이 된다. 조각의 증거 등급은 5.2 의 판정을 그대로 쓴다. `verified` 면 `VERIFIED`, 나머지는 바이트만 맞춘 등급이다. Codex 는 JSON 으로 감싼 값의 sha256 을 남기므로, 조각 텍스트의 sha256 과 바로 비교하지 않고 `Keeper_context_submission_link` 의 판정만 쓴다.
- **기록이 없는 행:** provider-input 을 요청하지 않는다. 세 탭 모두 "이 턴은 입력 기록이 없다"를 한 줄로 쓴다. 넘기기 전에 실패한 턴(`Dispatch_not_reached`), 조각을 풀지 못한 턴(`Input_provenance_unresolved`), 이 RFC 배포 전에 남은 행이 여기에 들어간다. `Store_failed` 행은 "입력 기록을 쓰지 못했다"로 따로 쓴다.

**`attributed`(구성이 있는 가장 최근 행을 빌려 오는 규칙)를 지운다.** 이것은 Agent Core 화면도 바꾼다. 지금 Agent Core 에서도 가장 최근 턴이 넘기기 전에 실패하면 이전 턴의 구성을 빌려 그린다. 바뀐 뒤에는 그 턴은 기록이 없다고 쓰고, `[`/`]` 로 이전 턴을 직접 보게 한다. 다른 턴의 숫자를 지금 턴 아래에 그리지 않는 것이 이 변경의 목적이라, Agent Core 도 같은 규칙을 따른다.

### 5.7 같이 바꿔야 하는 곳과 배포

turn record 와 provider-input JSON 을 읽는 곳은 모르는 키가 있으면 행이나 페이지 전체를 거절한다.

- `lib/types/turn_record.ml(i)`: `of_json` 이 키를 정확히 맞춘다.
- `lib/keeper/keeper_durable_store.ml`: `Provider_inputs`·`Turn_records` 를 배포 전 검사(`Preflight_only`)에서 행마다 읽는다.
- `dashboard/src/api/dashboard-turn-records.ts`: `hasNoUnknownKeys` 와 전부 아니면 전무인 `decodeArray` 때문에, 새 행 하나가 페이지 전체를 비운다.
- `dashboard/src/api/dashboard-provider-input.ts`, `keeper-turn-inspector.ts`(`snapshot.wire.*` 를 읽는다).
- `lib/keeper/keeper_next_request_forecast.ml`, `keeper_context_observation_projection.ml`, `keeper_turn_driver.ml`(window 관측).
- `bin/masc_tui_context_inspector.ml`, `masc_tui_http.ml`, `masc_tui_render_prim.ml`, `masc_tui.ml`(proof 탭 키), `masc_tui_memory_usage.ml`, `masc_tui_token_scale.ml`.

배포 조건:

- 서버, TUI, 대시보드를 한 번에 배포한다.
- 새 행이 한 번 쓰이면 옛 바이너리로 되돌릴 수 없다. 옛 바이너리의 배포 전 검사가 새 행을 거절해서 배포가 멈춘다. 되돌려야 하면 새 행이 쓰이기 전 시점의 저장소로 같이 되돌려야 한다. 운영자가 한 명이라 이 조건을 받아들이고, 배포 전에 알린다.

## 6. 바꾸지 않는 것

- 클라이언트의 세션 파일은 읽지 않는다.
- Agent Core 의 기록 방식은 바꾸지 않는다. 응답 모양(5.5)과 빌려 오기 제거(5.6)만 바뀐다.
- raw trace 는 그대로 둔다. Codex 의 `codex_context_submission` hook 은 5.2 의 공통 쓰기 기록과 같은 정보를 남기게 되는데, 지울지는 구현 때 정한다.
- 이 RFC 는 한 턴의 마지막 전달만 기록한다. 기록하지 않는 masc 입력이 셋 있다.
  - `turn/steer` 알림
  - dynamic tool 결과
  - Claude Code 가 크기를 줄여 다시 보낼 때(`keeper_claude_code_runtime.ml:588`) 먼저 보낸 것

  앞의 두 개는 채팅 기록에 이미 있다.
- 비밀값: provider-input 기록은 지금도 가리지 않고 저장하고, raw trace 는 가린다. 이 차이는 #43564 에서 따로 정한다. 공식 클라이언트 기록은 그 결정을 따른다.

## 7. 검증

- 쓰기 기록: 네 runtime 이 쓰기가 끝난 바이트의 sha256 을 남기는지, 쓰기 결과를 모르면 그렇게 남기는지 본다.
- lane 마다 가짜 클라이언트로 새 세션과 이어 가는 세션 두 경우를 돌린다. 받은 바이트와 쓰기 기록이 같아야 하고, 조각 판정이 `verified` 여야 한다. 이어 가는 세션의 대기 중인 지시가 `resume_components` 에 들어가지 않아야 한다. 기존 `test_runtime_codex_app_server`, Claude Code, Muse, Antigravity 테스트 하네스에 더한다.
- 저장: 같은 history 를 두 턴 넘겨도 blob 이 한 번만 생기는지 본다. `wire` 만 있는 지금 행이 그대로 읽히는지, 둘 다 있는 행을 거절하는지 본다.
- turn record: 세 경우가 왕복 직렬화되는지, `request_wire_observation` 과 `client_delivery` 가 둘 다 있는 행을 거절하는지 본다.
- 다음 요청 예측: 이어 가는 세션 행이 예측 입력에 들어가지 않는지 본다.
- provider-input 목록 응답: 본문 없이 목록만 오는지, 그 행의 목록에 없는 조각은 내주지 않는지 본다.
- TUI 디코드: 공식 클라이언트 행이 자기 기록을 고르는지, 기록 없는 행과 `Store_failed` 행에 요청을 보내지 않는지, 다른 턴을 빌려 오지 않는지 본다. 화면 문구나 배치를 고정하는 테스트는 쓰지 않는다.
- 배포 뒤: Claude Code, Codex, Muse, glm Keeper 하나씩 Ctrl-X 세 탭을 찍는다. 이어 가는 세션 턴에서 request 탭에 goal 과 들고 간 맥락이 보이고, 404 가 없어야 한다.

## 8. 구현 순서

MASC Native Stack 하나로 올리고, 맨 위 PR 로 한 번에 병합한다.

1. provider-input 목록 응답과 조각 받기(5.5). Agent Core 기록으로 먼저 바꾸고, TUI·대시보드도 같이 바꾼다. #37752 가 닫힌다. #43583(스택 #43584, #43561 위)이다.
2. 쓰기 기록: Codex 의 `context_submission` 을 공통 모듈로 옮기고, Claude Code·Muse·Antigravity 가 같은 값을 남긴다(5.2). #43597 이다.
3. 타입: `delivery`, `Host.resume_prompt` 의 맥락별 텍스트, provider-input `origin`, turn record `client_delivery`, `write_best_effort` 의 결과, JSON 읽기·쓰기. 5.7 의 소비처를 같이 고친다.
4. lane 네 곳: `delivery` 를 만들고 쓰기 기록과 맞춰 provider-input 과 turn record 를 쓴다.
5. TUI: 행마다 기록 종류로 고르기, 세 탭 그리기, `attributed` 지우기.

## 9. 남은 질문

- Antigravity 는 이어 가는 세션에서도 맥락을 매번 모두 보낸다. 그대로 "들고 간 맥락"으로 보여 준다. 줄일지는 범위 밖이다.
- Codex 의 `codex_context_submission` hook 을 공통 쓰기 기록으로 대신하고 지울지 구현 때 정한다.
- 이미지를 조각으로 저장할 때 Agent Core 기록이 이미지 블록을 다루는 방식을 따를지 구현 때 정한다.
