---
rfc: "0461"
title: "SSE 알림 종류는 닫힌 타입 하나다 — 이름과 '누가 한 일인가'를 한 곳에"
status: Draft
created: 2026-09-23
updated: 2026-09-23
author: dancer + claude
supersedes: []
superseded_by: null
related: ["toml-as-declarative-system-and-vocabulary-authority"]
---

# RFC-0461: SSE 알림 종류는 닫힌 타입 하나다

## 0. 결정

1. 서버가 SSE 로 보내는 알림 종류를 OCaml 닫힌 variant 하나(`Sse_push_kind.t`)로
   정한다. 각 종류는 wire 이름과 **누가 한 일인가**(키퍼의 행동 / 서버의 상태 알림 /
   측정값)를 같이 가진다.
2. 보내는 쪽은 `"type"` 문자열을 직접 쓰지 않고 이 타입으로 프레임을 만든다.
3. TUI 는 종류마다 해석 갈래를 하나씩 더하지 않는다. 이 타입으로 이름을 해석하고,
   "누가 한 일인가"로 Activity 필터를 정한다. payload 를 읽어야 하는 종류만 전용
   생성자를 둔다.
4. 모르는 이름은 지금처럼 숨기지 않고 보여준다. 다만 그 경우는 "이 TUI 보다 새 서버"
   뿐이게 된다.

## 1. 기준선 (2026-09-23, main `a7517b0ebb`)

| 사실 | 값 | 확인 방법 |
|---|---|---|
| `Sse.broadcast` 를 부르는 줄 | 42 줄, 23 파일 | `rg -n 'Sse\.broadcast' lib -g '!*.mli'` |
| 알림 이름 | 호출하는 곳마다 문자열 리터럴 | 같은 검색 |
| 공용 표 `Dashboard_event_slices` | 6 종류 (slice 라우팅용) | `lib/dashboard_event_slices.ml` |
| 대시보드 고정 목록 `FIXED_SSE_EVENT_TYPES` | 30 이름 | `dashboard/src/schemas/sse.ts` |
| 그중 TUI observer 가 해석하는 것 | 9 이름 + slice 표의 5 | `bin/masc_tui_observer.ml` `event_of_json` |
| 나머지 | 21 이름 → `Observer.Other` | 위 두 목록의 차 |

`Observer.Other` 는 Activity 의 세 필터(turns · actions · everything) 모두에 `?` 표시로
그려진다(`Masc_tui_acting.visible`). 모르는 것을 숨기지 않으려는 설계라 그 자체는
맞다. 문제는 모르는 종류가 "이 TUI 보다 새 서버"가 아니라 "처음부터 있던 서버
알림"이라는 데 있다.

라이브에서 본 모습(170칸, 필터 `turns` — "키퍼 턴당 한 줄"):

```
23:25:38 server  ? internal_agent_runs_changed
23:25:38 server  ? internal_agent_runs_changed
00:02:04 server  ? keeper_tool_call_evidence_committed
00:02:04 server  ? keeper_tool_call_evidence_committed
00:02:04 server  ? keeper_tool_call_evidence_committed
```

## 2. 지금 고치는 방식이 틀린 이유

지금까지는 모르는 종류가 화면에 보일 때마다 TUI 에 하나씩 가르쳤다.

- #37891 `internal_agent_runs_changed` — 서버 상태 알림으로 분류
- `tui-activity-telemetry` 브랜치 — `agent_core_telemetry_sample` 을 측정값으로 분류
  (PR 로 열지 않고 이 RFC 의 예시로 남긴다)
- 다음 차례는 `keeper_tool_call_evidence_committed` 였다

한 번에 한 종류씩 고칠 때마다 비용이 같다. observer 생성자 하나, `Masc_tui_acting` 의
exhaustive match 일곱 곳, `masc_tui.ml` 두 곳, `masc_tui_render.ml` 한 곳, 테스트 두
벌. 그리고 이름은 여전히 보내는 쪽 리터럴을 받는 쪽이 따로 맞춘다. 같은 변환을
사이트마다 따로 하는 N-of-M 패턴이고, 21 개가 남아 있다.

바뀌어야 하는 건 TUI 가 아니라 "알림 종류"라는 개념이 코드에 없는 것이다.

## 3. 설계

```ocaml
(* lib/sse_push_kind.mli *)
type actor =
  | Keeper_act    (* 키퍼가 한 일: turns · actions 에 보인다 *)
  | Server_state  (* 서버가 상태가 바뀌었다고 알림: everything 에만 *)
  | Telemetry     (* 호출 하나의 측정값: everything 에만 *)

type t =
  | Internal_agent_runs_changed
  | Agent_core_telemetry_sample
  | Keeper_tool_call_evidence_committed
  | Keeper_phase_changed
  | Post_created
  | (* … 보내는 곳이 있는 종류 전부 *)

val all : t list
val wire_name : t -> string
val actor : t -> actor
val of_wire_name : string -> t option   (* all 을 wire_name 으로 훑는다 *)
val frame : t -> (string * Yojson.Safe.t) list -> Yojson.Safe.t
```

- `wire_name`, `actor` 는 생성자마다 한 줄인 exhaustive match 다. 종류를 더하면
  컴파일러가 두 곳을 다 요구한다.
- 보내는 쪽 42 줄은 `Sse.broadcast (Sse_push_kind.frame kind fields)` 로 바뀐다.
  `"type", `String "…"` 리터럴은 `lib` 에서 SSE 프레임에 남지 않는다.
- `Dashboard_event_slices` 는 이 타입을 키로 삼는다. slice 와 whole-projection 은
  종류의 또 다른 속성일 뿐이다.
- agent-core Custom 이벤트(`masc.lane.resource.*` 등)는 이 RFC 밖이다. 그쪽은
  이미 생산자 목록(`Lane_addon_resource_events.all`)과 브리지 표기
  (`Keeper_event_bridge.public_custom_event_type`)로 알아본다(#37898).

TUI observer:

```ocaml
| Pushed of { kind : Masc.Sse_push_kind.t; at : float }
```

payload 를 읽을 필요가 없는 종류는 전부 이 한 생성자로 온다. `Masc_tui_acting.visible`
은 `Sse_push_kind.actor kind` 로 정한다. `Keeper_heartbeat`, `Keeper_tool_call` 처럼
payload 를 읽는 종류는 지금의 전용 생성자를 그대로 둔다.

#37891 의 `Internal_agent_runs_changed` 생성자와 `Internal_agent_runs_event` 모듈은
Phase 2 에서 `Pushed { kind = Internal_agent_runs_changed }` 로 흡수된다.

## 4. 단계

| 단계 | 내용 | 끝났다는 기준 |
|---|---|---|
| 1 | `Sse_push_kind` 모듈. 지금 보내는 종류 전부와 `actor` | `all` 이 `rg` 로 찾은 리터럴 집합과 같다는 테스트 |
| 2 | 보내는 쪽 42 줄을 `frame` 으로 | `lib` 의 SSE 프레임에 `"type"` 리터럴 0 개 (ast-grep 가드) |
| 3 | TUI `Pushed` 생성자와 `actor` 기준 필터 | 서버의 `all` 을 전부 넣어도 `Observer.Other` 가 0 개인 테스트 |
| 4 | 대시보드 `FIXED_SSE_EVENT_TYPES` 를 `all` 에서 만든 목록과 비교 | TOML RFC 의 `sse_events` 를 이 타입에서 생성하거나 대조 |

2 단계는 한 PR 에 42 줄을 다 옮긴다. 일부만 옮기면 이 RFC 가 고치려는 N-of-M 이 된다.

## 5. 검증

- 라이브: 현재 서버에 붙인 TUI 의 Activity `turns` 에 `?` 줄이 0 개.
- 테스트: `Sse_push_kind.all` 의 모든 종류를 `frame` → observer 로 흘렸을 때 `Other` 가
  나오지 않는다. `actor` 가 `Keeper_act` 인 것만 `turns` 에 보인다.
- 가드: `lib/**/*.ml` 에서 `Sse.broadcast` 인자에 `"type"` 문자열 리터럴이 있으면 실패.

## 6. 하지 않는 것

- 모르는 이름을 숨기지 않는다. 새 서버와 옛 TUI 조합에서는 지금처럼 `?` 로 보인다.
- payload 스키마를 이 RFC 에서 정하지 않는다. 종류와 행위자만 정한다.
- TOML 어휘 RFC 를 대체하지 않는다. OCaml 쪽 권위를 이 타입으로 두고, TOML 목록은
  여기서 만들거나 대조하는 쪽으로 이어진다.

## 7. 열린 질문

- `post_created`, `comment_added` 는 키퍼가 할 수도, 운영자가 할 수도 있다. `actor` 를
  종류로 정할지, 프레임의 필드(작성자)로 정할지 정해야 한다.
- `masc/board_post` 처럼 `masc/` 가 붙은 이름은 대시보드 목록에만 있다. 서버가 아직
  보내는지 확인하고, 보내지 않으면 목록에서 뺀다.
- `approval:*` 네 종류는 운영자에게 가는 알림이다. 세 `actor` 중 어디에도 딱 맞지
  않으면 네 번째 값이 필요하다.
