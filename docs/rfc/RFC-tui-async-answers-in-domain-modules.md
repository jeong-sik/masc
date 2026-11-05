---
rfc: "tui-async-answers-in-domain-modules"
title: "TUI 비동기 답은 그 답의 묶음 모듈이 받아서 반영한다"
status: Draft
created: 2026-11-05
updated: 2026-11-05
author: vincent + claude
supersedes: []
superseded_by: null
related: []
implementation_prs: ["#48685", "#48721"]
---

# RFC: TUI 비동기 답은 그 답의 묶음 모듈이 받아서 반영한다

## 0. 요약

TUI 가 서버에서 받은 답(`async_msg`)은 `bin/masc_tui.ml` 의
`apply_async_message_body` 한 함수가 모두 상태에 반영한다. 지금 254갈래, 5,896줄이다.

열린 스택 #48627 → #48637 → #48638 은 답 타입을 묶음마다 나눈다. 그래서 `async_msg` 의
인자 있는 생성자가 한도 244개(#48617)에서 56개로 줄어든다. 하지만 나뉘는 것은 타입뿐이다.
답을 반영하는 코드와 답을 만드는 코드는 그대로 한가운데에 있다. 묶음 생성자로 감싸는 일도
사용처마다 흩어져 있다. 감싸서 만드는 곳이 369곳, 감싼 채 match 하는 곳이 779곳이다.

이 RFC 는 묶음 모듈이 세 가지를 함께 갖게 한다.

1. 자기 답 타입 `msg`
2. 답을 상태에 반영하는 함수 `apply`. 터미널·네트워크 IO 는 하지 않고, 남은 할 일을 값으로
   돌려준다.
3. 프로토콜과 루프가 답을 어떻게 다룰지 정하는 kind(`answer_kind`). 읽기 답인가, 입력을
   기다려야 하는가 같은 질문은 답마다가 아니라 kind 로 정한다.

요청 함수는 자기 묶음 답만 받는 `deliver` 를 받는다. `masc_tui.ml` 은 묶음마다
한 갈래로 넘기고, 돌려받은 할 일을 실행한다.

동작은 바꾸지 않는다. `state` 레코드를 묶음별로 나누는 일은 이 RFC 범위 밖이다.

## 1. 배경 (실측)

측정 대상은 #48638 머리 `360b56ae34d` 이다(2026-11-05). compiler-libs 로 파싱만 했고
컴파일하지 않았다. 세는 방법은 부록 A 에 있다.

### 1.1 지금 모양

- `async_msg` 는 인자 있는 생성자 56개다. 묶음 생성자 38개, 답이 하나뿐인 묶음의 답 14개,
  다른 `async_msg` 를 싣는 생성자 4개다.
- `apply_async_message_body` 는 254갈래, 5,896줄이다. `bin/masc_tui.ml` 은 42,229줄이고
  맨 위 값이 943개다.
- 상태는 `Masc_tui_types.state` 레코드 하나이고 필드가 979개다. `bin/masc_tui_types.ml` 은
  26,180줄이다.
- 의존 방향: `masc_tui_async_protocol` 은 `masc_tui_types` 를 본다. `masc_tui_types` 와
  `masc_tui_code_results` 는 프로토콜을 보지 않는다. 그래서 묶음 모듈에 답 타입을 두고
  프로토콜이 그 타입을 가리켜도 순환이 생기지 않는다.

### 1.2 새 답은 대부분 이미 있던 묶음에 더해진다

10월 18일 이후 더해진 생성자 59개 중 50개, 10월 5일 이후 94개 중 75개가 이미 있던 묶음의
답이다. 묶음 모듈이 답을 받으면 새 답은 대부분 그 모듈 안에서 끝난다. 프로토콜과
`masc_tui.ml` 은 새 묶음이 생기거나 새 종류의 할 일이 생길 때만 바뀐다.

### 1.3 묶음마다 `masc_tui.ml` 에 묶인 정도

- **`masc_tui.ml` 함수**: 갈래 본문이 모듈 이름 없이 부르는 `bin/masc_tui.ml` 의 맨 위 값.
  묶음 모듈은 `masc_tui.ml` 보다 아래에 있어서 이 값들을 부를 수 없다. 옮기기 전에 아래
  라이브러리로 내리거나, 묶음 모듈이 돌려주는 할 일 값으로 바꿔야 한다.
- **직접 바꾸는 필드**: 갈래 본문의 `state.f <- …`. 다른 모듈 함수 안에서 바꾸는 필드는
  세지 않았다. 0 이면 이미 다른 모듈이 바꾸고 있다는 뜻이다.
- **그 묶음만 바꾸는 필드**: 다른 묶음의 갈래는 바꾸지 않는 필드.

묶음 38개 중 17개(60갈래, 444줄)는 `masc_tui.ml` 함수를 3개 이하로 부른다. Approvals,
Artifact, Chat, Code, Context, Exact, Fleet, Github, Harness, Identity, Machine, Memory,
Original, Repository, Schedule, Task, Workspace 이다.

나머지 21개는 아래와 같다.

| 묶음 | 갈래 | 줄 | `masc_tui.ml` 함수 | 직접 바꾸는 필드 | 그 묶음만 바꾸는 필드 |
|---|---:|---:|---:|---:|---:|
| Keeper | 51 | 1,579 | 62 | 77 | 73 |
| Observer | 7 | 680 | 52 | 23 | 19 |
| Runtime | 8 | 290 | 9 | 29 | 27 |
| Http | 12 | 243 | 27 | 4 | 2 |
| Lane | 9 | 218 | 8 | 15 | 13 |
| Board | 10 | 211 | 13 | 2 | 2 |
| Voice | 12 | 193 | 14 | 10 | 10 |
| Preset | 6 | 173 | 5 | 11 | 10 |
| Resource | 6 | 156 | 6 | 7 | 7 |
| Msx | 4 | 155 | 6 | 7 | 7 |
| Play | 4 | 134 | 7 | 4 | 4 |
| Browser | 8 | 117 | 6 | 2 | 2 |
| Goal | 5 | 112 | 5 | 4 | 4 |
| Account | 3 | 104 | 6 | 1 | 1 |
| Tools | 8 | 103 | 4 | 14 | 14 |
| Verification | 4 | 89 | 5 | 11 | 11 |
| Gate | 4 | 77 | 4 | 8 | 6 |
| Connectors | 3 | 50 | 5 | 5 | 3 |
| Local | 2 | 28 | 8 | 0 | 0 |
| Fusion | 5 | 27 | 4 | 0 | 0 |
| Ask | 5 | 23 | 4 | 0 | 0 |

세 곳 이상의 묶음(답 하나짜리 포함)이 같이 부르는 `masc_tui.ml` 함수는 13개다.
`server_peer_host`(9곳), `failed_read`(7곳), `chat_notice`(5곳), `start_http_refresh`·
`workspace_enqueue`(4곳), `drain_queued_message`·`launch_lanes_reread`·`monotonic_now_s`·
`read_authority`·`render_spectator`·`resolve_opening_chat`·
`resume_reads_after_authority_change`·`withdraw_resource_diagram_pending`(3곳).

### 1.4 Code 는 이미 거의 이 모양이다

Code 를 반영하는 11갈래는 모두 합쳐 27줄이다. 10갈래는 `Code_results.apply_*` 를 부르기만
하고, `Code_draft_saved` 만 저장한 파일을 다시 읽는다. `bin/masc_tui_code_results.mli` 는
맨 앞 주석에 "These functions perform no terminal or network IO; the caller executes layout
and file-read followups." 라고 적는다.

Code 를 감싸는 곳은 32곳이다.

- `bin/masc_tui_code_requests.ml` 이 답을 만들며 13곳. 요청 함수가 모두
  `~deliver:(Masc_tui_async_protocol.async_msg -> unit)` 을 받는다.
- `apply_async_message_body` 12곳
- 프로토콜 분류 함수 5곳: `workspace_message_is_read` 2곳, `message_waits_for_input`,
  `retired_operation_observation`, `project_workspace_operation_reply`
- 시험 2곳

### 1.5 이름과 주인

이름 첫 단어로 나눈 묶음은 대부분 상태의 주인과 맞는다. Keeper 는 직접 바꾸는 필드 77개 중
73개, Runtime 은 29개 중 27개, Voice 는 10개 중 10개를 그 묶음만 바꾼다. 이름 첫 단어가
주인이 아닌 답 둘은 #48638 에서 주인 이름(Keeper)으로 바꿨다.

`Http_*` 는 한 묶음의 상태가 아니라 새로고침 흐름이다. 직접 바꾸는 필드는 4개뿐이고, 다른
묶음의 반영 함수(`apply_approvals_read`, `apply_keeper_roster_load` 등)를 부른다.

## 2. 앞선 사례

- **Jane Street Incr_dom (OCaml)**: 컴포넌트마다 `Action.t` 와 `apply_action` 이 있다.
  액션을 보내는 `schedule_action` 도 그 컴포넌트의 `Action.t` 만 받는다.
- **Elm, elm-spa-example**: 페이지 모듈이 `Msg` 와 `update` 를 갖고, `Main` 은
  `GotHomeMsg` 로 감싸서 넘긴다. 감싸는 일은 `Cmd.map`·`Sub.map` 으로 경계에서 한 번 한다.
  URL 변경과 세션처럼 모든 페이지에 걸친 메시지는 `Main` 이 직접 처리한다.
- **Richard Feldman, "Scaling Elm Apps" (Elm Europe 2017, 요약 글 기준)**: `update` 가
  큰 것은 괜찮다. 나눌 때는 갈래 본문을 함수로 빼고, 인자는 가장 좁게, 돌려주는 값은 필요한
  것만으로 한다. 모델·메시지·update 를 따로 두는 것은 자기 상태가 있는 덩어리에만 한다.
- **D. L. Parnas, "On the Criteria To Be Used in Decomposing Systems into Modules" (1972)**:
  모듈은 바뀌기 쉬운 설계 결정을 하나씩 숨긴다. 여기서 숨길 결정은 "이 묶음의 상태를 어떻게
  바꾸나"다.

이 RFC 는 Incr_dom 과 Elm 의 모양을 따른다. 묶음이 메시지와 반영 함수를 함께 갖고, 감싸는
일은 경계에서 한 번 한다. Feldman 의 조언대로 `state` 는 나누지 않고, 반영 함수가 필요한
것만 돌려주게 한다.

## 3. 제안

### 3.1 묶음 모듈이 갖는 것

Code 를 예로 들면 `Masc_tui_code_results` 가 아래를 갖는다(L1, #48685).

```ocaml
type msg =
  | Code_catalog_loaded of …
  | …                                (* 전에 Masc_tui_async_protocol.code_msg *)

type answer_kind = Read | Save       (* 읽기 10개, 초안 저장 1개 *)

type answer_followup =
  | No_answer_followup
  | Reload_saved_file of string      (* Code_draft_saved 뒤 저장한 파일 다시 읽기 *)

val answer_kind : msg -> answer_kind
val apply : Masc_tui_types.state -> msg -> answer_followup
```

- `msg` 는 프로토콜에서 이 모듈로 옮긴다. 프로토콜은 `| Code_msg of
  Masc_tui_code_results.msg` 로 가리킨다.
- `apply` 의 본문은 지금 `apply_async_message_body` 의 Code 갈래 본문이다. 터미널·네트워크
  IO 는 하지 않는다. 할 일이 남으면 `answer_followup` 값으로 돌려준다.
- 로그는 `apply` 안에서 남긴다. 로그를 남기는 데는 `masc_tui.ml` 이 필요 없다. 할 일 값으로
  빼면 한가운데는 받은 문자열을 찍기만 한다. 254갈래 중 15갈래가 로그를 남긴다. 그중 묶음
  모듈로 옮길 갈래는 Runtime 4개, Keeper 2개, Fleet 1개다.
- 프로토콜과 루프는 Code 답에 다섯을 묻는다. 읽기인가, 입력을 기다리는가, 작업 영수증을
  싣는가, 작업 공간이 바뀌면 치울 것이 있는가, 작업 공간 도장을 찍는가. 묶음 모듈은 답마다
  kind 를 정하고, 묻는 쪽은 kind 를 빠짐없이 match 한다.

  ```ocaml
  | Code_msg answer ->
      (match Masc_tui_code_results.answer_kind answer with
       | Masc_tui_code_results.Read -> true
       | Masc_tui_code_results.Save -> false)
  ```

  답마다 bool 함수를 두면 Code 에서는 같은 11줄 나열이 다섯 벌 생긴다. `Code_msg _` 로
  줄이면 새 답이 생겨도 컴파일러가 알려 주지 않는다. kind 를 쓰면 새 답은 `answer_kind` 에서
  kind 를 골라야 컴파일된다. 이미 있는 kind 를 고르면 다섯 질문의 답도 그 kind 를 그대로
  따른다. 이때 컴파일러는 묻는 곳을 알려 주지 않는다. 다섯 중 하나라도 다르게 다뤄야 하면
  kind 를 더한다. 그러면 그 kind 를 따지는 곳이 모두 컴파일 오류로 알려 준다.
- 답에 실린 작업 영수증과 관찰을 고쳐 쓰는 일(`project_workspace_operation_reply`)처럼 답의
  내용이 필요한 질문은 kind 로 답할 수 없다. 그런 질문은 그 묶음 모듈의 함수로 둔다. Code
  답에는 이런 질문이 없다.
- 할 일 타입과 kind 는 묶음마다 닫힌 variant 다. 문자열이나 콜백으로 열어 두지 않는다.

### 3.2 답을 보내는 쪽

요청 함수는 자기 묶음 답만 받는 `deliver` 를 받는다.

```ocaml
(* 지금 *)
val launch_file_load : … -> deliver:(Masc_tui_async_protocol.async_msg -> unit) -> …
(* 바꾼 뒤 *)
val launch_file_load : … -> deliver:(Masc_tui_code_results.msg -> unit) -> …
```

`masc_tui.ml` 은 감싸는 함수를 한 번 만든다. 도장을 찍을지도 kind 로 정한다.

```ocaml
let deliver_code state =
  let enqueue = workspace_enqueue state in    (* 요청을 보내는 순간 권한을 잡는다 *)
  fun mailbox answer ->
    match Code_results.answer_kind answer with
    | Code_results.Read -> enqueue mailbox (Code_msg answer)
    | Code_results.Save -> enqueue_async mailbox (Code_msg answer)
```

`workspace_enqueue state` 는 부분 적용하는 순간 작업 공간 권한을 잡는다. 감싸는 함수도 같은
때 잡아야 한다. `let deliver_code state mailbox msg = workspace_enqueue state mailbox
(Code_msg msg)` 로 쓰면 답이 도착할 때 잡는다. 그러면 옛 작업 공간의 늦은 답이 새 작업 공간
것으로 들어온다.

초안 저장 답(`Save`)은 도장 없이 보낸다. 이미 보낸 쓰기의 결과라서, 작업 공간을 옮겨도
잃으면 안 된다. 이 답만 저장 호출 자리에서 따로 감싸면 두 `deliver` 의 타입이 같다. 그래서
저장에 `deliver_code` 를 넘겨도 컴파일되고, 작업 공간이 바뀐 뒤 저장 결과가 버려진다. kind
로 정하면 어느 요청이든 `deliver_code` 를 받고, 도장은 답의 종류가 정한다.

Incr_dom 의 `schedule_action`, Elm 의 `Cmd.map` 이 하는 일이다. 요청 함수는 자기 묶음의
답만 만든다. 한 요청 모듈에 다른 묶음의 요청 함수가 있으면 함수마다 그 묶음의 `deliver` 를
받는다. 예를 들어 `Masc_tui_identity_requests.launch_github_view` 는 Github 답을 보내므로
Github 의 `deliver` 를 받는다.

### 3.3 `masc_tui.ml` 에 남는 것

- 묶음마다 한 갈래. Code 는 아래처럼 된다. 지금 코드와 같은 순서로 판단한다. 저장을 먼저
  끝내고, 그다음 입력이 밀려 있는지 본다.

  ```ocaml
  | Code_msg answer -> (
      match Code_results.apply state answer with
      | Code_results.No_answer_followup -> ()
      | Code_results.Reload_saved_file path ->
          if not (input_pending ()) then
            Masc_tui_code_requests.launch_file_load ~intent:Refresh_code_file state
              ~host:server_peer_host ~deliver:(deliver_code state mailbox) ~path)
  ```

- 받지 않는 답의 갈래도 묶음마다 하나다. 작업 공간이 바뀐 뒤 도착한 답은
  `workspace_message_admitted` 를 통과하지 못한다. 그래도 치울 것이 있으면 이 갈래에서
  치운다. Code 는 치울 것이 없어서 kind 만 묻는다.

  ```ocaml
  | Code_msg answer ->
      (match Code_results.answer_kind answer with
       | Code_results.(Read | Save) -> ())
  ```

  치울 일이 답의 내용에 달린 묶음은 그 일을 묶음 모듈의 함수로 둔다. 3.1 의
  `project_workspace_operation_reply` 와 같은 경우다. 예를 들어 Keeper 는 목록·행 읽기
  자리를 비우고, 채팅 전송을 기다리는 promise 를 resolve 한다.
- 다른 `async_msg` 를 싣는 생성자 4개, 새로고침 흐름(`Http_*`), 답이 하나뿐인 묶음의 답
  14개. 여러 묶음에 걸친 일이라 Elm 의 `Main` 처럼 한가운데가 맡는다.
- 돌려받은 할 일의 실행(IO).

### 3.4 경계를 정하는 법

- 묶음은 답이 바꾸는 상태의 주인이다. 1.3 의 "그 묶음만 바꾸는 필드"로 확인한다.
- 이름 첫 단어가 주인이 아니면 이름을 주인에 맞게 바꾼다.
- 두 곳 이상이 같이 바꾸는 필드는 옮기기 전에 주인을 정한다. 갈래 본문이 직접 바꾸는 필드
  중 12개가 그렇다. 세는 방법은 1.3 과 같다. 한가운데 갈래는 3.3 대로 `masc_tui.ml` 에 남는
  갈래다.

  | 필드 | 묶음 갈래 | 한가운데 갈래 |
  |---|---|---|
  | `approval_cursor`·`approval_flow` | Keeper, Gate | 없음 |
  | `connector_unbind_offer_origin`·`connector_unbind_offer_pending` | Keeper, Connectors | 없음 |
  | `runtime_lane_replacement_selection` | Runtime, Lane | 없음 |
  | `config_scroll` | Preset, Runtime | `Librarian_input_loaded` |
  | `connection_status` | Workspace, Observer | `Http_*` |
  | `acting_pane_changes`·`acting_pane_changes_at`·`acting_pane_changes_loss_followup` | Observer | `Acting_pane_changes_loaded` |
  | `lane_nested_read_resume` | Lane | `Workspace_scoped` |
  | `http_surface_reads` | 없음 | `Http_*`, `System_logs_loaded` |

### 3.5 하지 않는 것

- `state` 레코드를 묶음별로 나누지 않는다.
- 동작을 바꾸지 않는다. 갈래 본문은 자리만 옮긴다.
- 답이 하나뿐인 묶음은 모듈로 만들지 않는다.
- 새 Gate·상태·필드를 만들지 않는다.

## 4. 층 계획

층마다 gh stack 의 작은 PR 하나이고, 묶음 하나를 끝까지 옮긴다. 얇은 묶음도 하나씩 옮긴다.
묶음 모듈을 새로 만드는 층은 파일 10개를 바꾼다. 새 파일 다섯(묶음 모듈 `.ml`·`.mli`, 시험,
시험 stanza, changelog)과 고치는 파일 다섯(`bin/dune`, 프로토콜 `.ml`·`.mli`,
`bin/masc_tui.ml`, `test/dune`)이다. 묶음 둘을 한 층에 넣으면 14개다.

| 층 | 하는 일 | 끝난 기준 |
|---|---|---|
| L1(#48685) | Code 시범. `code_msg`·`apply`·`answer_kind` 를 `Masc_tui_code_results` 로 옮기고, `deliver` 를 `msg -> unit` 으로 바꾼다 | Code 를 반영하는 갈래 11 → 1, Code 생성자를 나열하던 분류 자리 5곳(프로토콜 함수 넷, 받지 않는 답의 갈래) → 0, `masc_tui_code_requests` 의 감싸기 13 → 0, 시험이 생성자마다 `apply` 를 부른다 |
| L2(#48721)~ | 나머지 얇은 묶음 16개. L2 는 Context | L1 과 같은 기준 |
| Ls | 1.3 의 공용 함수 13개를 `masc_tui.ml` 아래 라이브러리로 내리거나 할 일 값으로 바꾼다 | 두꺼운 묶음이 그 함수를 모듈 이름 없이 부르지 않는다 |
| Lt | 두꺼운 묶음(Runtime, Lane, Voice, Board, Observer 등) | L1 과 같은 기준 |
| 마지막 | Keeper(51갈래, 1,579줄, `masc_tui.ml` 함수 62개) | L1 과 같은 기준 |

## 5. 검증

- **컴파일러**: `apply` 와 `answer_kind` 는 자기 `msg` 를 와일드카드 없이 빠짐없이 match
  한다. 새 답을 더하면 두 곳이 컴파일 오류로 알려 준다. kind 를 더하면 그 kind 를 따지는
  곳이 모두 알려 준다. Code 는 프로토콜 함수 넷, 받지 않는 답의 갈래, `deliver_code`, 여섯
  곳이다.
- **시험**: 묶음마다 모든 생성자를 나열해 `apply`·분류 함수를 부르는 시험을 둔다.
  `test/test_tui_code_msg.ml` 이 이미 `code_msg` 를 생성자마다 나열한다.
- **파싱 검사(층마다)**: `apply_async_message_body` 의 맨 위 갈래와 받지 않는 답의 match 에
  그 묶음 갈래가 하나씩만 있는지 센다. 그 묶음 생성자가 쓰인 곳이 모두 자기 묶음 생성자
  안에 있는지도 센다.
- CI type-check 와 그 묶음의 시험 suite.

## 6. 비용과 위험

- `apply_async_message_body` 는 열린 PR 이 자주 건드린다. 층마다 묶음 하나만 옮겨서 충돌
  범위를 줄인다.
- 프로토콜이 묶음 모듈을 보게 된다. Code 는 반영 모듈에 둔다(L1). `masc_tui_code_results`
  가 받는 라이브러리 8개는 프로토콜이 이미 받는다. 그래서 프로토콜의 의존은 이 라이브러리
  하나만 는다. 다른 묶음도 같은 방법으로 잰다. 묶음 모듈이 프로토콜이 받지 않는 라이브러리를
  받으면 그때 타입만 담은 모듈을 검토한다. 여기서 받는다는 것은 링크된다는 뜻이다. stanza 에
  직접 적지 않았어도 다른 라이브러리를 거쳐 링크되면 받는 것이다.
- 묶음 모듈은 dune 라이브러리여야 한다. 프로토콜이 라이브러리(`masc_tui_async_protocol`)라서
  `masc_tui` 실행 파일의 모듈을 볼 수 없다. `masc_tui_code_results` 는 이미 라이브러리다.
  `masc_tui_identity_requests` 는 실행 파일의 모듈이라 Identity 의 `msg` 를 둘 수 없다.
- `dune-project` 가 `(implicit_transitive_deps false)` 다. 묶음 타입의 생성자를 쓰는 stanza 는
  그 묶음 라이브러리를 직접 적어야 한다. L1 은 시험 stanza 에 더했다.
- 옮기는 동안 두 모양이 섞인다. 층마다 묶음 하나를 끝까지 옮겨서, 반쯤 옮긴 묶음은 남기지
  않는다.
- 층이 하나씩이라 스택이 높아진다. main 이 `bin/masc_tui.ml` 을 바꾸면 위 층마다 충돌을 다시
  푼다. 리뷰를 마친 층까지 먼저 병합해서 높이를 줄인다.

## 7. 열린 질문

1. 3.4 표의 필드는 누가 주인인가. `approval_cursor`·`approval_flow` 는 Approvals 화면의
   자리라서 Gate, Approvals, Keeper 가 모두 후보다. 한가운데 갈래도 바꾸는 필드는 한가운데가
   주인일 수도 있다.
2. 답이 하나뿐인 묶음 중 주인이 분명한 답은 그 주인 묶음으로 옮길까.

## 부록 A. 세는 방법

`compiler-libs` 의 `Parse.implementation`·`Parse.interface` 로 파싱만 한다. 컴파일하지 않는다.

- 읽는 파일: 0·1.4 의 감싸는 곳은 저장소의 OCaml 파일 8,609개(.ml·.mli)에서 센다. 갈래·필드·
  맨 위 값은 `bin/masc_tui.ml` 과 `bin/masc_tui_types.ml` 에서 센다.
- `state` 필드: `Masc_tui_types` 의 `type state = { … }` 레코드 필드.
- 맨 위 값: `bin/masc_tui.ml` 의 맨 위 `let` 이 묶는 이름.
- 줄: 함수는 정의 전체의 줄 수다(5,896). 갈래는 패턴 첫 줄부터 본문 끝 줄까지다. 묶음의 줄은
  그 묶음 갈래의 줄을 더한 값이다. 254갈래를 모두 더하면 5,888줄이다. 함수 머리와 갈래 사이
  주석은 들어가지 않는다.
- 갈래마다 패턴의 바깥 생성자를 묶음으로 본다. 본문이 모듈 이름 없이 부르는 맨 위 값 중
  그 갈래 안에서 다시 묶지 않은 이름을 "`masc_tui.ml` 함수"로 센다. `state.f <- e` 와
  `state.f.g <- e` 를 "직접 바꾸는 필드 `f`"로 센다.
- 감싸는 곳은 묶음 생성자(`<묶음>_msg`)를 만드는 식과 match 하는 패턴을 센다. 만드는 곳
  369곳 중 274곳, match 779곳 중 339곳이 `bin/masc_tui.ml` 이다. 프로토콜은 match 405곳이다.
- 로그 갈래: 본문에 `Log.<모듈>.warn`·`info`·`debug`·`err`·`error` 를 부르는 줄이 하나라도
  있는 갈래를 센다.
- 한계: 다른 모듈 함수 안에서 바꾸는 필드는 세지 않는다. 갈래 안에서 같은 이름을 다시 묶으면
  그 이름은 세지 않는다. 측정 도구는 저장소에 넣지 않았다.

## 참고

- [Incr_dom `App_intf.S`](https://ocaml.org/p/incr_dom/v0.17.0/doc/incr_dom/Incr_dom/App_intf/module-type-S/index.html)
- [rtfeldman/elm-spa-example `Main.elm`](https://github.com/rtfeldman/elm-spa-example/blob/23dee34dd7a8c26229a03bc8e9f0e034f6222f13/src/Main.elm)
- [Summarising Elm scaling strategy](https://dev.to/elmupdate/summarising-elm-scaling-strategy-1bjn)
- [Parnas 1972, CACM 15(12)](https://dl.acm.org/doi/10.1145/361598.361623)
