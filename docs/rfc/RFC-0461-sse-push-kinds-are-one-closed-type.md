---
rfc: "0461"
title: "SSE 알림 종류는 닫힌 타입 하나다 — 이름과 'Activity 에 어떻게 보이나'를 한 곳에"
status: Draft
created: 2026-09-23
updated: 2026-09-23
author: dancer + claude
supersedes: []
superseded_by: null
related: ["0004", "toml-as-declarative-system-and-vocabulary-authority"]
---

# RFC-0461: SSE 알림 종류는 닫힌 타입 하나다

## 0. 결정

RFC-0004 는 SSE 의 `type` 구분자를 "각 경계에서 닫힌 어휘"로 두고, `Sse_event`
라이브러리(`lib/sse_event`, `masc.sse_event`)를 SSE 계약의 주인으로 정했다. 코드는
아직 그렇지 않다. `type` 은 보내는 곳마다 문자열 리터럴이다(§1). 이 RFC 는 그 원칙을
`type` 에 대해 구현하는 방법을 정한다.

1. 서버가 SSE 로 보내는 알림 종류를 `Sse_event` 안의 닫힌 variant 하나
   (`Sse_event.Push_kind.t`)로 정한다. 각 종류는 wire 이름과 **Activity 화면의 어느
   필터에 보이나**(`activity_row`, §3)를 같이 가진다.
2. 보내는 쪽은 `"type"` 문자열을 직접 쓰지 않는다. 프레임을 받는 함수(§1 의 "싱크")가
   `Yojson.Safe.t` 대신 이 타입으로만 만들 수 있는 프레임 타입을 받는다. 그래서 옮기지
   않은 자리는 컴파일이 안 된다.
3. TUI 는 종류마다 해석 갈래를 하나씩 더하지 않는다. 이 타입으로 이름을 해석하고,
   `activity_row` 로 Activity 필터를 정한다. payload 를 읽어야 하는 종류만 전용
   생성자를 둔다.
4. 모르는 이름은 지금처럼 숨기지 않고 보여준다. 다만 그 경우는 "이 TUI 보다 새 서버"
   뿐이게 된다.

## 1. 기준선 (2026-09-23, main `ba869ef8cf`)

### SSE 프레임이란

이 RFC 에서 "SSE 프레임" 은 아래 싱크 중 하나로 넘어가는 JSON 이다. 세는 단위는
호출하는 곳이 아니라 이 싱크로 들어가는 프레임의 `"type"` 값이다. `lib` 에는
`"type", `String` 리터럴이 355 개 있고 대부분은 SSE 와 무관하므로(MCP 스키마 등),
리터럴을 통째로 세지 않고 싱크에서 거슬러 올라가 센다.

| 싱크 | 호출하는 줄 (`lib`, `*.ml`) | 무엇이 들어가나 |
|---|---|---|
| `Sse.broadcast` | 34 | `type` 프레임, 그리고 JSON-RPC 알림(`bin/main_eio.ml:802` 의 `notifications/shutdown` 등) |
| `Sse.broadcast_to` | 4 | `type` 프레임 |
| `Sse.broadcast_presence` | 4 | `type` 프레임 |
| `Sse.broadcast_encoded_to` | 1 | 이미 문자열로 만든 `type` 프레임. `type` 값은 인자로 받은 문자열이다(`server_dashboard_http_execution_surfaces.ml:142`) |
| `Mcp_server.sse_broadcast` | 4 | `Sse.broadcast` 로 이어진다(`server_runtime_bootstrap.ml:769`). 예: `mcp_tool_runtime_board.ml:295` 의 `"masc/board_post"` |
| `Progress` 콜백 | 콜백 하나 | `Sse.broadcast` 로 이어진다(`server_bootstrap_loops.ml:1404`) |
| `Subscriptions.push_event_to_sessions` | 5 (+ `Tool_task_handlers.push_event_to_sessions_fn` 1) | 에이전트 세션 큐로 가는 `type` 프레임. 예: `verification_protocol.ml:267` |
| 세션 레지스트리 `push_fn` 직접 호출 | `subscriptions.ml:207` (`"masc/notification"`), `session.ml:178` (`"masc/message"`) | 에이전트 세션 큐로 가는 `type` 프레임 |

범위 밖이고 이유가 있는 것:

- `Sse.send_to` (2 줄). JSON-RPC 만 받고, 그렇지 않은 payload 는 버린다(`sse.ml:1161`).
  `type` 구분자가 없다.
- `Sse.format_event ~event_type` (4 줄). SSE 프로토콜의 `event:` 줄("message",
  "evicted")이다. JSON 안의 `type` 과 다른 층이다.
- agent-core Custom 이벤트(`masc.lane.resource.*` 등). §3 끝에 적는다.

### 받는 쪽

| 사실 | 값 | 확인 방법 |
|---|---|---|
| 공용 표 `Dashboard_event_slices` | 6 종류, 그중 `whole_projection` 이 5 | `lib/dashboard_event_slices.ml` |
| 대시보드 고정 목록 `FIXED_SSE_EVENT_TYPES` | 47 항목(문자열 43 + `SSE_APPROVAL_*` 상수 4). `masc/` 가 붙은 별칭도 한 항목으로 센다 | `dashboard/src/schemas/sse.ts:48` |
| 그중 TUI observer 가 해석하는 것 | 이름으로 9 개 + slice 표에서 `whole_projection` 인 5 개 | `bin/masc_tui_observer.ml` `event_of_json`, `carries_whole_projection` |
| 나머지 | `Observer.Other` 로 떨어진다 | 위 두 목록의 차 |

## 2. 지금 고치는 방식이 틀린 이유

지금까지는 모르는 종류가 화면에 보일 때마다 TUI 에 하나씩 가르쳤다.

- #37891 `internal_agent_runs_changed` — 서버 상태 알림으로 분류
- `tui-activity-telemetry` 브랜치 — `agent_core_telemetry_sample` 을 측정값으로 분류
  (PR 로 열지 않고 이 RFC 의 예시로 남긴다)
- 다음 차례는 `keeper_tool_call_evidence_committed` 였다

한 번에 한 종류씩 고칠 때마다 비용이 같다. observer 생성자 하나, `Masc_tui_acting` 의
exhaustive match 일곱 곳, `masc_tui.ml` 두 곳, `masc_tui_render.ml` 한 곳, 테스트 두
벌. 그리고 이름은 여전히 보내는 쪽 리터럴을 받는 쪽이 따로 맞춘다. 같은 변환을
사이트마다 따로 하는 N-of-M 패턴이다.

바뀌어야 하는 건 TUI 가 아니라 "알림 종류"라는 개념이 코드에 없는 것이다.

## 3. 설계

```ocaml
(* lib/sse_event/sse_event.mli 의 Push_kind *)
type activity_row =
  | Keeper_action  (* 키퍼가 한 일: turns · actions · everything 에 보인다 *)
  | Background     (* 서버 상태 알림, 측정값, 운영자에게 가는 알림: everything 에만 *)
  | Per_frame      (* 종류만으로 못 정한다(키퍼도 운영자도 낸다). TUI 가 payload 로 정한다 *)

type t =
  | Internal_agent_runs_changed
  | Agent_core_telemetry_sample
  | Keeper_tool_call_evidence_committed
  | Keeper_phase_changed
  | Post_created
  | Agent_core of Agent_core_kind.t   (* wire 이름 "agent_core:<이름>" *)
  | (* … §1 의 싱크로 들어가는 종류 전부 *)

val all : t list
val wire_name : t -> string
val activity_row : t -> activity_row
val of_wire_name : string -> t option   (* all 을 wire_name 으로 훑는다 *)

type frame   (* 추상 타입. 아래 두 함수로만 만든다 *)
val frame : t -> (string * Yojson.Safe.t) list -> frame
val json_rpc : method_:string -> params:Yojson.Safe.t -> frame
val to_json : frame -> Yojson.Safe.t
```

- `wire_name`, `activity_row` 는 생성자마다 한 줄인 exhaustive match 다. 종류를
  더하면 컴파일러가 두 곳을 다 요구한다.
- 축 이름을 `actor` 로 하지 않는다. `actor` 는 이미 "이벤트를 낸 엔티티" 라는 뜻으로
  쓰인다(`lib/activity_graph/activity_graph_types.mli:58`). 이 값이 실제로 정하는 것은
  "Activity 의 어느 필터에 보이나" 하나라서, 그 이름을 쓴다. 서버 상태 알림과 측정값은
  필터에서 똑같이 다뤄지므로(`bin/masc_tui_acting.ml`) 한 값 `Background` 로 합친다.
- §1 의 싱크는 모두 `Yojson.Safe.t` 대신 `frame` 을 받는다. `broadcast_encoded_to` 는
  `frame` 에서 만든 인코딩만 받고, `type` 을 문자열 인자로 받지 않는다.
  `Mcp_server.sse_broadcast`, `Progress` 콜백, `push_event_to_sessions`, 세션
  레지스트리 `push_fn` 도 같다. 그러면 `"type", `String "…"` 을 직접 만든 자리는 싱크에
  넘길 수 없어 컴파일이 안 된다. 리터럴을 찾는 가드가 따로 필요 없다.
- JSON-RPC 알림은 `json_rpc` 로 만든다. `type` 이 없는 프레임이 이 길 하나로만 나간다.
- `Dashboard_event_slices` 는 이 타입을 키로 삼는다. slice 와 whole-projection 은
  종류의 또 다른 속성일 뿐이다.
- `agent_core:*` 도 이 타입 안이다. 지금은 `keeper_event_bridge.ml:184` 가
  `"agent_core:" ^ event_type` 으로 문자열을 잇고, `Sse_event.envelope_meta` 의
  `event_type : string`(`lib/sse_event/sse_event.mli:20`)도 같은 문자열을 든다. 둘 다
  닫힌 `Agent_core_kind.t` 로 바꾼다. wire 모양(`type` 과 `event_type` 두 필드)은 그대로다.
- agent-core Custom 이벤트(`masc.lane.resource.*` 등)는 이 RFC 밖이다. 그쪽은
  이미 생산자 목록(`Lane_addon_resource_events.all`)과 브리지 표기
  (`Keeper_event_bridge.public_custom_event_type`)로 알아본다(#37898).

TUI observer:

```ocaml
| Pushed of { kind : Sse_event.Push_kind.t; at : float }
```

payload 를 읽을 필요가 없는 종류는 전부 이 한 생성자로 온다. `Masc_tui_acting.visible`
은 `Sse_event.Push_kind.activity_row kind` 로 정한다. `Keeper_heartbeat`, `Keeper_tool_call` 처럼
payload 를 읽는 종류는 지금의 전용 생성자를 그대로 둔다. `activity_row` 가 `Per_frame` 인
종류(`post_created`, `comment_added`)도 작성자를 payload 에서 읽어야 하므로 전용 생성자를
둔다. `Pushed` 로는 받지 않는다.

#37891 의 `Internal_agent_runs_changed` 생성자와 `Internal_agent_runs_event` 모듈은
3단계에서 `Pushed { kind = Internal_agent_runs_changed }` 로 흡수된다.

## 4. 단계

| 단계 | 내용 | 끝났다는 기준 |
|---|---|---|
| 1 | `Sse_event.Push_kind` 모듈. §1 의 싱크로 들어가는 종류 전부와 `activity_row` | `all` 이 §1 의 싱크마다 거슬러 올라가 모은 `type` 값 목록과 같다는 테스트. 목록은 1단계 PR 이 싱크별로 적는다 |
| 2 | §1 의 싱크가 `Yojson.Safe.t` 대신 `frame` 을 받게 바꾸고, 모든 보내는 자리를 옮긴다 | 싱크의 시그니처가 `frame` 이고 빌드가 된다. 옮기지 않은 자리가 있으면 빌드가 깨지므로, 한 PR 에 다 옮긴 것이 곧 기준이다 |
| 3 | TUI `Pushed` 생성자와 `activity_row` 기준 필터 | 서버의 `all` 을 전부 넣어도 `Observer.Other` 가 0 개인 테스트 |
| 4 | 대시보드 `FIXED_SSE_EVENT_TYPES` 를 `all` 에서 만든 목록과 비교 | TOML RFC 의 `sse_events` 를 이 타입에서 생성하거나 대조 |

2 단계는 한 PR 에 모든 싱크와 보내는 자리를 옮긴다. 싱크 하나라도 `Yojson.Safe.t` 를
계속 받으면 그 싱크로 리터럴이 다시 들어올 수 있고, 이 RFC 가 고치려는 N-of-M 이 된다.

## 5. 검증

- 라이브: 현재 서버에 붙인 TUI 의 Activity `turns` 에 `?` 줄이 0 개.
- 테스트: `Sse_event.Push_kind.all` 의 모든 종류를 `frame` → observer 로 흘렸을 때 `Other` 가
  나오지 않는다. `activity_row` 가 `Keeper_action` 인 것만 `turns` 에 보인다.
  `Per_frame` 인 종류는 모두 observer 에 전용 생성자가 있다.
- 가드: 따로 두지 않는다. 싱크가 `frame` 만 받으므로 컴파일러가 막는다(§3).

## 6. RFC-0004 와의 관계

- RFC-0004 가 원칙(정확한 계약, 닫힌 구분자, `Sse_event` 소유)을 정한다. 이 RFC 는
  그중 `type` 구분자를 한 타입으로 만드는 구체적 방법이다.
- payload 는 계속 RFC-0004 대로 `Sse_event` 의 ATD 타입(`agent_failed_payload` 등)이
  맡는다. `Push_kind` 는 종류와 `activity_row` 만 가진다.
- RFC-0004 의 "닫힌 구분자" 는 이 RFC 의 2단계가 끝나면 싱크의 타입으로 지켜진다.

## 7. 하지 않는 것

- 모르는 이름을 숨기지 않는다. 새 서버와 옛 TUI 조합에서는 지금처럼 `?` 로 보인다.
- payload 스키마를 이 RFC 에서 정하지 않는다. 종류와 `activity_row` 만 정한다.
- TOML 어휘 RFC 를 대체하지 않는다. OCaml 쪽 권위를 이 타입으로 두고, TOML 목록은
  여기서 만들거나 대조하는 쪽으로 이어진다.

## 8. 열린 질문

- 없음. 앞 판에서 열어 두었던 셋은 이렇게 정했다.
  - `post_created`, `comment_added` 처럼 키퍼도 운영자도 내는 종류는 `Per_frame` 이다.
    TUI 가 payload 의 작성자로 정한다(§3).
  - `masc/board_post` 같은 `masc/` 이름은 서버가 지금도 보낸다(`mcp_tool_runtime_board.ml:295`
    → `Mcp_server.sse_broadcast`). 목록에서 빼지 않고 `all` 에 넣는다.
  - `approval:*` 네 종류는 운영자에게 가는 알림이라 키퍼의 행동이 아니다. `Background` 다.
