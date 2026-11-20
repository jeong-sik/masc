---
rfc: "response-failure-text-comes-from-a-closed-type"
title: "응답의 실패 글은 route 의 닫힌 합타입에서만 나온다"
status: Draft
created: 2026-11-15
updated: 2026-11-15
author: claude
supersedes: []
superseded_by: null
related: ["0106", "0126", "0518", "typed-route-auth"]
---

# RFC: 응답의 실패 글은 route 의 닫힌 합타입에서만 나온다 (response-failure-text-comes-from-a-closed-type)

- 상태: 초안.
- 이슈: #51903. 관련 이슈: #51908, #48500.
- 먼저 있는 변경:
  - #51902 가 ingress 의 500 을 `Http_error_body` 의 고정 문구로 바꾸고 예외는 `Log.Http.error` 로 남긴다.
  - 열린 PR #52174 가 workspace route 의 Git 읽기 실패를 같은 식으로 고친다.
  - 로컬 커밋 `10d9b799ab37`(올리지 않음)이 #51908 의 REST 인증 거절을 고친다. `/mcp` 거절은 고치지 않는다(§6 의 L2a).
- 먼저 있는 결정:
  - RFC-0106: `Eio.Cancel.Cancelled` 는 switch 경계까지 가야 한다.
  - 헌법 `build_and_ci`: 기능 고장과 연결되지 않는 검사를 만들지 않는다. 실제 API·프로토콜·보안·자원 경계의 권위 있는 제한값만 검사한다.
  - #40298(2026-09-30): bulk source-style lint 와 예외 허용 개수 예산은 release gate 가 아니다(`docs/CI-REVIEW-WORKFLOW.md`).
- 코드 좌표는 `origin/main` `807a5e46ab99` 에서 읽었다. 운영 데이터는 읽지 않았다. 자리마다 실제로 어떤 예외 글이 나가는지는 재현하지 않았다.

## 0. 요약

route 의 catch-all 이 `Printexc.to_string exn` 을 응답에 싣는다. 예외 글에는 서버의 파일 경로와 OS 오류가 들어갈 수 있다. 같은 원인을 이슈와 PR 다섯 개가 자리마다 따로 다뤘다(§1.1). 그 뒤에도 확인한 자리만 16곳(9개 파일)이 남았다. 예외 글 14곳과, 인증 거절이 저장소 오류 글을 싣는 2곳이다(부록 A).

자리마다 고치면 다시 생긴다. 응답을 만드는 함수가 `string` 과 `Yojson.Safe.t` 를 받고, 예외를 글로 바꾸는 식은 한 줄이라서다.

이 RFC 는 다섯 가지를 정한다.

1. 응답의 실패 글은 route 가 선언한 닫힌 합타입에서만 만든다(R1).
2. 서버 안에서 난 실패의 진단은 로그로만 보내고, 응답에는 그 로그 줄을 찾는 `incident_id` 를 싣는다(R2).
3. 예외는 글로 꺼낼 수 없는 `Diagnostic.t` 로만 응답 경로에 들어간다. `private_failure` 를 일반화한 `Server_refusal.Private` 만 그 값을 읽는다(§3).
4. 운영자 진단 화면(C)에 예외 글을 둘지는 운영자가 정한다(§4).
5. 남은 자리는 L1~L4 층으로 고치고, L4 가 typed tree 로 새 자리를 잡는다(§6).

## 1. 사건

### 1.1 같은 원인을 자리마다 고쳤다

| 번호 | 종류·상태 | 무엇이 일어났나 |
|---|---|---|
| #50488 | 이슈, 2026-11-14 닫힘 | HTTP/2 오류 처리기(`server_h2_gateway.ml`)가 handler 예외 글을 500 본문에 썼다 |
| #50613 | 이슈, 2026-11-14 닫힘 | HTTP/1.1 오류 처리기가 예외를 로그에 남기지 않았다 |
| #51902 | PR, 2026-11-14 병합 | 위 둘과 handler·본문 콜백 경로까지 네 길을 `Http_error_body` 의 고정 문구로 바꿨다 |
| #52174 | PR, 열림 | workspace route 의 Git 읽기 실패 500 이 Git 출력을 본문에 싣는 것을 고친다 |
| #51908 | 이슈, 열림 | 인증 정보 저장소를 읽지 못하면 503 본문에 저장소 오류 글이 실린다. 로컬 커밋 `10d9b799ab37` 이 REST 쪽만 고쳤다 |

#51902 은 ingress 에 닿은 예외만 고쳤다. route 가 먼저 잡아 글로 바꾼 예외는 ingress 에 닿지 않는다. #51903 은 2026-11-13 에 그런 자리 여덟 곳을 셌다.

### 1.2 그 뒤에도 남은 자리

`rg -n 'Printexc.to_string' lib/server lib/dashboard` 는 266곳(101개 파일)이다. 대부분은 로그 인자이거나 서버 안 상태다. 응답으로 가는 자리를 다섯 묶음으로 나눴다(부록 A).

| 묶음 | 뜻 | 자리 |
|---|---|---|
| A1 | 오류 응답(4xx·5xx·JSON-RPC error)이나 실패 항목에 예외 글이 실린다. 직접 읽어 확인했다 | 14곳, 7개 파일 |
| A2 | 인증 거절이 저장소 오류 글(`masc_error_to_string`)을 싣는다. 직접 읽어 확인했다 | 2곳, 2개 파일 |
| B | 타입이 정해진 실패 값이 예외 글을 `string` 필드로 담는다. 응답까지 끝까지 따라가지 못했다 | 21곳, 3개 파일 |
| C | 운영자 진단 화면의 필드(`last_error` 등)가 예외 글을 보여 준다 | 18곳, 15개 파일 |
| D | 본문은 고정 문구지만 예외 글이 로그에도 남지 않는다 | 1곳 |
| 미확인 | `Error (Printexc.to_string exn)` 이 응답에 닿는지 따라가지 못했다 | 6곳, 5개 파일 |

A1 의 일곱 파일 가운데 넷은 #51903 의 목록에 없었다(`server_routes_http_dashboard_handlers.ml`, `server_routes_http_keeper_control.ml`, `server_mcp_transport_http.ml`, `server_routes_http_routes_msx.ml`). 그 가운데 `/api/v1/keepers/turns` 는 `Public_read` 라 기본 설정에서 인증 없이 열린다.

A2 는 `Printexc.to_string` 이 아니라 아래 층이 돌려준 오류 글이다. REST 거절은 #51908 이다. `/mcp` 거절도 같은 글을 401 JSON-RPC `error.message` 로 싣는다. 둘 다 bearer 를 실은 요청이 저장소 읽기에 실패할 때 경로가 나간다.

### 1.3 자리마다 고치면 다시 생기는 이유

- 응답을 만드는 함수가 글을 그대로 받는다. `Server_refusal.json` 의 문장 인자는 `string` 이다(60곳, 18개 파일). `Http.Response.json_value` 는 아무 `Yojson.Safe.t` 나 받는다. `~status:` 에 실패 상태를 리터럴로 넘기는 호출만 503곳(57개 파일)이다.
- 예외를 글로 바꾸는 식은 `Printexc.to_string exn` 한 줄이다. 이 식을 막는 것은 리뷰뿐이다.
- 바른 모양이 이미 한 곳에 있다. `server_dashboard_http_keeper_memory_history_resolution.ml:64-68` 의 `private_failure` 는 진단을 `incident_id` 와 함께 로그로 보내고 본문에는 `code` 와 `incident_id` 만 싣는다. 다른 모듈은 이 함수를 쓰지 않는다.
- 고정 문구는 ingress 에만 있다. `lib/http_error_body.mli` 는 「어떤 route 도 답하지 않은 요청」의 본문이다.

## 2. 규칙

- **R1.** 응답(HTTP 본문, SSE 이벤트, JSON-RPC `error`)에 실리는 실패 글은 route 가 선언한 닫힌 합타입의 생성자에서 만든다. 생성자는 `string` 을 담지 않는다.
- **R2.** 서버 안에서 난 실패의 진단은 로그로만 간다. 진단은 예외 글과 아래 층이 `Error detail` 로 돌려준 오류 글이다. 응답에는 그 로그 줄의 `incident_id` 를 싣는다.
- **R3.** 요청 때문에 난 실패(검증 실패)는 route 작성자가 쓴 문장으로 답한다. 요청이 보낸 값(필드 이름, 요청한 keeper 이름)은 문장에 넣어도 된다.
- **R4.** handler 의 catch-all `| exn ->` 은 응답을 만들지 않는다. 응답 전이면 #51902 의 ingress 가 고정 500 과 로그로 받는다. 효과가 이미 났을 수 있는 자리는 그 사실을 닫힌 실패(`Outcome_unknown`)로 답한다. 400 으로 답하지 않는다.
- **R5.** 예외 글을 지우거나 가리는 식(sanitize, redact)으로 R1·R2 를 대신하지 않는다. `keeper_stream.ml:2489` 의 `redact_text` 는 Keeper 비밀값을 가리는 장치이고, 경로와 OS 오류는 그대로 지나간다.

## 3. 경계는 타입으로 막는다

### 3.1 무엇을 막고 무엇을 막지 않나

응답 쪽(sink) 함수를 모두 닫힌 타입만 받게 바꾸려면 실패 상태 응답 503곳을 고쳐야 한다. 이 RFC 는 그 대신 출처(source)를 닫는다.

- 예외는 `Diagnostic.t` 로만 응답 경로에 들어간다. `Diagnostic.t` 에는 글로 꺼내는 함수가 없다.
- 실패 응답은 route 의 닫힌 실패 타입과 `Diagnostic.t` 를 받는 `Server_refusal.Private` 로 만든다.
- 남는 탈출구는 `Printexc.to_string` 을 직접 불러 아무 `string` 자리에 넣는 것이다. L4 검사가 이 흐름을 잡는다(§6).

### 3.2 `.mli` 초안

`lib/server/server_refusal.mli` 에 더하는 부분이다.

```ocaml
(** 서버 안에서 난 실패의 진단. 예외와, 아래 층이 글로 돌려준 실패를 담는다.
    글로 꺼내는 함수가 없다. [Private] 만 이 값을 읽고, 읽은 값은 로그로만 간다. *)
module Diagnostic : sig
  type t

  val of_exn : exn -> Printexc.raw_backtrace -> t
  val of_detail : string -> t
  (** [Error detail] 처럼 아래 층이 글로 돌려준 실패. *)
end

(** route 작성자가 쓴 문장. 형식이 리터럴일 때만 타입이 맞는다.
    구멍에는 요청이 보낸 값만 넣는다(R3). *)
module Sentence : sig
  type t

  val v : ('a, unit, string, t) format4 -> 'a
  val to_string : t -> string
end

module Incident_id : sig
  type t

  val to_string : t -> string
end

(** route 하나의 서버 쪽 실패 종류. *)
module type Failure = sig
  type t
  (** 닫힌 합타입. 생성자는 [string] 을 담지 않는다. *)

  val status : t -> [ Httpun.Status.client_error | Httpun.Status.server_error ]
  val code : t -> string
  (** 생성자마다 리터럴 하나. 클라이언트는 이 값으로 갈래를 나눈다. *)

  val sentence : t -> Sentence.t

  val fields : t -> (string * Yojson.Safe.t) list
  (** 생성자가 정하는 추가 필드. 값은 리터럴이다
      (예: ["durable_acceptance", `String "unconfirmed"]). *)
end

module Private (F : Failure) : sig
  val record : site:string -> F.t -> Diagnostic.t -> Incident_id.t
  (** [site]·[code]·incident id·진단을 [Log.Http.error] 한 줄로 남긴다. *)

  val json : F.t -> Incident_id.t -> Yojson.Safe.t
  (** [{"error": sentence, "code": code, "incident_id": id}] 에 [F.fields] 를 더한다. *)

  val respond :
    site:string
    -> ?request:Httpun.Request.t
    -> Http_reqd.t
    -> F.t
    -> Diagnostic.t
    -> unit
  (** [record] 한 뒤 [F.status t] 와 [json] 으로 답한다. *)
end
```

route 쪽은 이렇게 쓴다.

```ocaml
module Turns_failure = struct
  type t = Census_unreadable

  let status Census_unreadable = `Internal_server_error
  let code Census_unreadable = "keeper_census_unreadable"
  let sentence Census_unreadable = Server_refusal.Sentence.v "keeper name census failed"
  let fields Census_unreadable = []
end

module Turns_refusal = Server_refusal.Private (Turns_failure)
```

### 3.3 왜 이 모양인가

- **functor 로 route 마다 타입을 받는 이유.** `status`·`code`·`sentence` 가 닫힌 합타입 위의 전체 함수가 된다. 생성자를 더하면 컴파일러가 세 함수의 빠진 갈래를 잡는다. `code` 를 `string` 인자로 받으면 그 자리에 예외 글이 다시 들어갈 수 있다.
- **`Diagnostic` 에 `to_string`·`pp` 가 없는 이유.** 꺼내는 함수가 있으면 route 가 꺼내 본문에 넣는다. 로그로 보내는 일은 `Private.record` 하나가 한다.
- **`Sentence.v` 가 `format4` 를 받는 이유.** 문장은 route 모듈 안에 리터럴로 적힌다. 구멍(`%s`)에 예외 글을 넣는 것까지 타입이 막지는 못한다. 그 흐름은 L4 가 잡는다.
- **`incident_id` 를 싣는 이유.** 운영자가 응답 하나에서 로그 한 줄로 갈 수 있어야 진단이 사라지지 않는다. 값은 `Random_id.uuid_v7` 로 만든다. `private_failure` 와 같다.
- **`error` 키를 남기는 이유.** `Server_refusal` 의 계약은 `error` 가 사람이 읽는 문장이다. TUI(`Tui_decode.http_status_error`)와 dashboard 가 그 키를 보여 준다. 키는 그대로 두고 값만 고정 문장으로 바꾼다.

### 3.4 응답 종류별 모양

| 응답 | 모양 |
|---|---|
| HTTP 4xx·5xx 본문 | `Private.respond`. 본문 `{"error", "code", "incident_id"}` |
| HTTP 2xx 안의 실패 항목(link preview 의 `errors`, msx receipt 의 `message`) | 항목마다 `{"code", "incident_id"}`. 진단은 `Private.record` 로 로그에 남긴다 |
| JSON-RPC `error` | `message` 는 `F.sentence`, `data` 에 `{"code", "incident_id"}`. `code` 숫자는 지금의 `Mcp_error_code` 를 그대로 쓴다 |
| SSE 실패 이벤트 | 이벤트의 글은 `F.sentence`, `code`·`incident_id` 필드를 더한다 |
| 저장되는 실패 기록(receipt, operation) | 닫힌 사유와 `incident_id` 만 저장한다. 진단은 저장하지 않는다 |

## 4. C: 운영자 진단 화면 — 운영자가 정한다

C 는 dashboard projection 이 실패를 보여 주는 필드다(`snapshot_error`, `last_error`, `repositories_error`, health 구성 요소의 `error`, runtime probe 의 `errors`). #51903 은 runtime probe `errors` 를 「운영자에게 일부러 보여 주는 값」이라 범위에서 뺐다.

확인한 예: `server_repository_pulls.ml:750·830` 의 글은 `/api/v1/repositories/pulls`(`Public_read`)로 나간다. `tool_pull_requests.ml:298` 이 같은 필드를 도구 결과에도 싣는다. `Public_read` 는 기본 설정에서 인증 없이 열린다. 기본 bind 는 `127.0.0.1` 이다(`Masc_network_defaults.masc_http_default_host`).

| | 안 1: 허용한다 | 안 2: 금지한다 |
|---|---|---|
| 규칙 | C 필드는 진단을 그대로 보여 준다. R1·R2 의 예외로 적는다 | C 필드도 R1·R2 를 따른다. 필드는 `{code, incident_id}` 가 되고 진단은 로그로 간다 |
| 장점 | 운영자가 로그를 열지 않고 dashboard 에서 원인을 본다. 화면과 cache 타입이 바뀌지 않는다 | 규칙이 하나다. L4 검사에 예외 표시가 없다. `Public_read` route 와 도구 결과로 경로·OS 오류가 나가지 않는다 |
| 단점 | 인증 없이 열린 route 로 파일 경로와 OS 오류가 나간다. 같은 글이 도구 결과로 Keeper 모델 문맥에도 들어간다. L4 가 C 자리를 예외로 알아야 한다 | 원인을 보려면 `incident_id` 로 로그를 찾아야 한다. `Cache_state.Warming { last_error }` 같은 cache 타입과 dashboard·TUI 가 그 필드를 읽는 코드가 바뀐다. 파일 수가 늘어난다 |
| 층 | 바뀌는 층 없음. L4 가 C 자리를 따로 표시한다 | L5 를 더한다 |

인증한 요청에만 진단을 보여 주는 셋째 안은 내지 않는다. 필드마다 인증 갈래가 생기고, 그 갈래가 새 Gate 가 된다.

결정 전까지 L2·L3 은 C 자리를 바꾸지 않는다.

## 5. `msx.ml:446` 의 Cancelled

`server_routes_http_routes_msx.ml:446` 은 MSX checkpoint worker 에서 `Eio.Cancel.Cancelled _ as exn` 을 잡아 `Checkpoint_receipt.Unknown (Printexc.to_string exn)` 으로 바꾼다. 다시 던지지 않는다. :447 은 다른 예외를 같은 값으로 바꾼다.

지금 코드에서 읽은 사실:

- 이 `try` 는 `Eio.Cancel.protect` 안에 있다(:432). 그래서 HTTP 호출자의 문맥이 취소돼도 이 갈래에 닿지 않는다. 닿는 것은 worker 안쪽 하위 문맥에서 난 `Cancelled` 다. `Cancel_safe.is_internal_race_cancel` 이 같은 경우를 「하위 문맥에서 온 취소」로 판정한다.
- 바로 뒤의 `Checkpoint_receipt.settle` 도 같은 `protect` 안에서 돈다. 취소된 문맥에서 저장이 다시 끊기지는 않는다.
- 이 갈래에 실제로 닿는 경로는 확인하지 않았다.

정하는 것:

1. 두 갈래 모두 receipt 에 `Unknown` 을 닫힌 사유로 남긴다. `Worker_cancelled` 와 `Worker_raised` 다. 예외 글은 `Private.record` 로 로그에만 남긴다.
2. `Cancelled` 갈래는 receipt 를 정리한 뒤 같은 backtrace 로 다시 던진다(RFC-0106). 정리를 먼저 하는 이유는 receipt 가 `pending` 으로 남지 않게 하려는 것이다. 지금 주석(「HTTP 호출자가 기다림을 멈춰도 worker 가 발행한다」)이 지키려는 것이 이것이다.
3. 다시 던진 `Cancelled` 는 `Executor_pool_ref.submit_strict` 에서 `Work_failed` 로 돌아온다. 그 응답은 §3.4 의 고정 문장 500 이다. 지금은 `strict_submit_error_to_string failure` 를 그대로 싣는다(:469).

확인: worker 가 `Eio.Fiber.first` 의 진 쪽 하위 문맥에서 `Cancelled` 를 내는 시험을 L2c 에 둔다. receipt 는 `Unknown Worker_cancelled` 로 정리되고, 본문에는 예외 글이 없다. 그 경로를 시험으로 만들 수 없으면 `Cancelled` 갈래를 지우고 `Cancel_safe.protect` 로 바꾼다.

## 6. 층

L0 이 Draft 인 동안 L1 부터 같은 native stack 으로 묶는다(헌법 `work_unit`).

| 층 | 내용 | 확인 |
|---|---|---|
| L0 | 이 RFC | `python3 scripts/rfc-generate-index.py --check` |
| L1 | `Server_refusal` 에 `Diagnostic`·`Sentence`·`Incident_id`·`Failure`·`Private` 를 더한다. `keeper_memory_history_resolution.ml` 의 `private_failure` 를 이 모듈로 옮긴다 | 경로가 든 `Sys_error` 로 만든 `Diagnostic.t` 를 넘긴 응답에 그 경로가 없고 `code`·`incident_id` 가 있다. 로그 한 줄에 같은 `incident_id` 와 경로가 있다. 옮긴 route 의 응답 모양은 그대로다 |
| L2a | A2: 인증 거절. 첫 커밋은 `10d9b799ab37` 이고, 분류를 `Server_refusal` 로 옮겨 `/mcp` 도 같이 쓴다(아래 「L2a」) | bearer 를 실은 요청이 저장소 읽기에 실패하면 REST 503 본문과 `/mcp` 401 `error.message` 에 경로가 없다. 거절 로그 줄 하나에 같은 `incident_id` 와 원문이 있다. 상태 코드와 `auth_error_code` 는 그대로다. 고치기 전 코드에서는 `/mcp` 시험이 실패한다 |
| L2b | A1: `routes_activity`(4곳), `dashboard_http_keeper_api_post`(1곳), `dashboard_handlers`(1곳), `keeper_control`(1곳) | route 마다 예외를 내는 입력을 넣는다. 본문에 예외 글이 없고 정한 상태·`code` 가 온다. 고치기 전 코드에서는 같은 시험이 실패한다 |
| L2c | A1·D: `link_preview`(3곳, `Preview_error of string` 을 닫힌 사유로), `mcp_transport_http`(2곳), `routes_msx`(2곳, §5), `oauth_http`(1곳, 로그만 더한다) | L2b 와 같다. link preview 는 cache 에 저장된 실패 항목에도 예외 글이 없다. MCP 는 JSON-RPC `error.data.incident_id` 와 로그 한 줄이 짝이 된다. oauth 는 본문이 그대로이고 로그에 예외 글이 남는다 |
| L3 | B: `Keeper_request_failure.Raised.exn`, `skill_editor` 의 `Write_failed`·`Source_root_create_failed`·`Recovery_operation_failed`·`Package_directory_remove_failed`, `dashboard_dev_token` 의 `detail`. 미확인 6곳을 먼저 끝까지 따라가 A·B·로그로 다시 나눈다 | 묶음마다 응답과 저장된 기록에 예외 글이 없다. 저장 모양은 hard cut 이다(헌법 `legacy_residue`) |
| L4 | typed-tree 검사(아래) | L3 head 에서 위반 0. `origin/main` 에 돌리면 A1 가운데 함수 안에서 응답 함수에 닿는 9곳(`routes_activity` 4, `keeper_api_post` 1, `dashboard_handlers` 1, `keeper_control` 1, `mcp_transport_http` 2)을 찾는다. A1 의 나머지 5곳과 A2 는 아래 4 의 흐름이라 찾지 못하는 것이 맞다 |
| L5 | §4 에서 안 2 를 고르면 C 를 고친다 | C 필드에 예외 글이 없고 `incident_id` 가 로그와 짝이 된다 |

### L2a: 인증 거절 (#51908 과 `/mcp`)

지금 상태(`origin/main`):

- REST: `server_auth.ml:882` 의 `auth_error_json` 이 `masc_error_to_string` 원문을 `error` 에 싣는다. 저장소 읽기가 실패하면 `System (IoError _)` 의 글에 workspace 아래 파일 경로와 OS 오류가 들어간다. bearer 를 실은 요청이면 읽기 권한을 확인하기 전에 503 으로 나간다(#51908).
- `/mcp`: `server_mcp_transport_http_types.ml:12-15` 의 `auth_failure_of_masc_error` 가 같은 원문을 `message` 에 담는다. `server_mcp_transport_http_respond.ml:137` 이 그 글을 JSON-RPC `error.message` 로 싣는다. 상태는 401 이다(`Mcp_error_code.to_http_status Auth_error`).
  - 이 변환은 `server_routes_http_common.ml:115-133` 의 verifier 넷이 쓴다(`/mcp`, observer stream, operator, seat).
  - 같은 글은 `MCP auth rejected` 로그 줄(`server_mcp_transport_http_respond.ml:121`)에도 남는다.

로컬 커밋 `10d9b799ab37`(worktree `.worktrees/fix/51908-auth-refusal-fixed-body`, 올리지 않음)이 REST 쪽을 고쳤다.

- `server_auth.ml` 의 `auth_refusal_text` 가 `masc_error` 의 모든 생성자를 이름으로 가른다.
- `System` 갈래는 상태의 고정 문구(`Http_error_body.service_unavailable`·`bad_request`)를 본문에 싣는다. 원문은 거절 로그의 `server_error` 로 보낸다.
- `Auth`·`Task`·`Agent` 갈래는 코드가 쓴 문장이라 그대로 싣는다(R3).
- 상태 코드와 `auth_error_code` 는 바뀌지 않는다.
- `auth_refusal_text` 는 `.mli` 에 없다. `/mcp` 는 이 커밋의 범위 밖이다.

의존 순서:

- `Server_auth` 는 `Server_mcp_transport_http_headers` 를 쓴다(`server_auth.ml:826`). `_headers` 는 `Server_mcp_transport_http_types` 를 쓴다.
- 그래서 `_types` 가 `Server_auth` 의 분류를 부르면 순환이 생긴다.
- `Server_refusal` 은 지금 `Workspace` 만 쓰고, 세 모듈 어느 것도 부르지 않는다. 분류를 `Server_refusal` 로 옮기면 `Server_auth` 와 `_types` 가 같은 분류를 부른다.

정하는 것:

1. 이 커밋은 L1 이 아니다. `auth_refusal_text` 는 `Masc_domain.masc_error` 하나에 묶인 분류이고 `incident_id` 를 만들지 않는다. route 마다 닫힌 타입을 받는 L1 의 공용 함수 자리를 채우지 못한다.
2. 이 커밋을 L2a 의 첫 커밋으로 쓴다. L1 위로 다시 올린 뒤 같은 층에서 셋을 더한다.
   - `auth_refusal_text` 를 `Server_refusal` 로 옮기고 `.mli` 에 낸다. `server_error : string option` 은 `Diagnostic.t option` 이 된다.
   - `auth_failure_of_masc_error` 가 같은 분류를 쓴다. `auth_failure.message` 는 분류의 문장이 되고, 원문은 `Diagnostic.t` 로 `record_mcp_auth_reject` 의 로그 줄에만 간다.
   - REST 와 `/mcp` 의 거절 로그 줄에 `incident_id` 를 남긴다. REST 본문에도 싣는다. JSON-RPC 쪽은 §8 의 4 를 따른다.
3. L2a 를 L2b 보다 먼저 두는 이유: A2 는 bearer 하나로 닿고, 고칠 커밋이 이미 있다.

### L4 검사와 RFC-0106 P3

지금 상태:

- RFC-0106 P3(ppxlib AST lint)은 만들지 않았다. 진행 표가 「`scripts/lint/cancel-guard-ast*` 없음」이라 적는다.
- 그 표가 「아직 돈다」고 적은 regex lint `scripts/lint-cancel-guard.sh` 는 #37495(2026-09-21)가 `scripts/ci/check-cancel-guard.py` 로 바꿨다. 그 파일도 #40298(2026-09-30)이 bulk lint driver 와 함께 지웠다. 지금 main 에는 cancel guard 검사가 없다. 코드의 `cancel-guard-ok` 주석을 읽는 것도 없다.
- typed tree 를 읽는 틀은 `tools/ocaml_boundary_audit` 하나다. compiler-libs 로 `.cmt` 를 읽고 이름을 해석된 경로로 비교한다. 모듈 별칭으로 `Printexc` 를 가려도 찾는다. `.github` 에서 이 도구를 부르는 workflow 는 없다.

정하는 것:

1. L4 는 `tools/ocaml_boundary_audit` 에 범주 하나를 더한다. ppxlib 틀은 새로 만들지 않는다. RFC-0106 P3 도 같은 틀에 `Texp_try` 의 갈래를 읽는 범주로 들어갈 수 있다. typed tree 라서 `Eio.Cancel.Cancelled` 생성자도 해석된 경로로 판정한다.
2. 범주는 흐름을 본다. 해석된 `Stdlib.Printexc.to_string` 의 결과가 같은 함수 본문 안에서 응답 함수의 인자에 닿으면 위반이다.
   - 함수 본문 안에서는 `let` 묶음, `match`, 다른 함수 호출의 결과를 거쳐도 따라간다(`routes_activity.ml:1327` 은 `Tool_result.make_err` 를 거친다).
   - 응답 함수는 해석된 경로로 선언한다. 바탕은 `Http_server_eio.Response` 의 함수, `Server_sse_response.send`, `Server_refusal.json`, `Server_mcp_transport_http_respond.respond_mcp_error`, `Keeper_chat_events.publish` 다.
   - 인자를 응답 함수에 넘기는 함수도 응답 함수로 친다. 이 요약은 더 늘지 않을 때까지 넓힌다. `Server_auth.respond_json_value_with_cors`, 지역 함수 `bad_request`(`routes_activity.ml:477`), `stream_post_sse_json` → `send_post_sse` → `Server_sse_response.send`(`mcp_transport_http.ml:175`)가 여기에 든다.
3. 위반 0 을 기준으로 한다. 기준선 파일도, 예외 개수 예산도 두지 않는다. 그래서 #40298 이 지운 「예외 허용 개수 예산」과 모양이 다르다. 로그 인자와 서버 안 상태의 `Printexc.to_string` 은 응답 함수에 닿지 않으니 위반이 아니다.
4. 이 검사는 값이 함수 밖으로 나가는 흐름을 보지 못한다. 함수의 반환값이나 생성자에 담겨 다른 함수의 응답 함수에 닿는 흐름이다. A1 의 `link_preview` 3곳과 `msx` 2곳, A2, B 전부, 아래 층의 `Error detail` 이 그렇다. 이 흐름은 L2a·L2c·L3 이 생성자를 닫힌 사유로 바꿔 닫는다.

어디서 돌릴지는 운영자가 정한다(§8 의 2).

## 7. 하지 않는 것

- `lib/server`·`lib/dashboard` 밖의 `Printexc.to_string`(1,089곳, 448개 파일). 도구 결과(`Tool_result`)에 실리는 예외 글이 여기에 있다. 이 RFC 의 `Diagnostic` 을 쓸 수 있지만 따로 다룬다.
- `Server_refusal.json` 의 문장 인자를 `Sentence.t` 로 바꾸는 일(60곳, 18개 파일). 검증 문장은 요청 값을 담아 R3 에 맞는다. 바꾸는 이득이 이 RFC 의 문제와 다르다.
- 아래 층이 `Error detail` 로 돌려준 글이 본문으로 가는 자리의 목록. R2 는 이 자리에도 적용된다. 예: `server_dashboard_http_keeper_api_post.ml:192·197`, `server_routes_http_keeper_control.ml:157`. 함수를 건너는 흐름이라 `rg` 로 셀 수 없어서 세지 않았다. 인증 거절 2곳(A2)만 따로 확인해 L2a 에 넣었다.
- ingress 의 고정 500 에 `incident_id` 를 싣는 일. #51902 은 H2 응답 원장 예약을 고정 문구 길이로 잡는다. 길이가 바뀌는 값을 넣으려면 그 예약을 다시 봐야 한다.
- workspace route. #52174 가 다룬다.
- 예외 글을 지우거나 가리는 장치(R5).

## 8. 운영자가 정할 것

1. **C 를 허용하나.** §4 의 안 1·안 2. 결정 전까지 C 는 바뀌지 않는다.
2. **L4 검사를 어디서 돌리나.** 헌법은 보안 경계의 검사를 허용한다. #40298 은 bulk source-style lint 를 release gate 에서 뺐다. L4 는 흐름을 증명하는 범주라 source-style lint 와 다르다. 다만 gate 로 둘지는 운영자 결정이다.
   - 가: Release 검증의 필수 목록(`config/release-behavior.json` 옆의 명시 검사)에 넣는다.
   - 나: 리뷰어가 `lib/server` 를 바꾼 PR 에서 돌리는 도구로 둔다. 강제하지 않는다.
3. **catch-all 이 400 이던 route 의 상태 코드.** `routes_activity` 의 네 자리는 효과가 났을 수 있는 예외를 400 으로 답한다. R4 를 따르면 500(`Outcome_unknown`)이 된다. 400 을 실패로 읽는 클라이언트가 있으면 그 쪽도 같은 층에서 고친다.
4. **JSON-RPC `error.data` 에 `incident_id` 를 싣나.** MCP 의 `error.data` 는 서버가 정하는 자리다. 싣지 않으면 MCP 클라이언트는 로그로 갈 수 없다.

## 부록 A. 자리 표

셈: `rg -n 'Printexc.to_string' lib/server lib/dashboard` 는 266곳(101개 파일)이다(`807a5e46ab99`). A1·B·C·D·미확인 표가 그 가운데 60곳이다. A2 의 2곳은 `masc_error_to_string` 자리라 이 셈 밖이다. `server_routes_http_routes_workspace.ml` 의 8곳은 #52174 가 다루는 파일이라 표에 넣지 않았다. 나머지 198곳은 로그 호출의 인자이거나 서버 안 상태(시작 인계, bootstrap, gRPC, gateway)다. 줄마다 끝까지 따라가지 않았고, 근처에 응답을 만드는 코드가 없는 것을 보고 나눴다.

인증은 `Route_access` 의 종류다. 「확인 못함」은 route 등록까지 따라가지 못한 것이다.

### A1. 오류 응답이나 실패 항목에 예외 글이 실린다 (14곳, 7개 파일)

| 파일:줄 | route | 인증 | 응답 |
|---|---|---|---|
| `lib/server/server_routes_http_routes_activity.ml:230` | `POST /api/v1/tools/masc_schedule_create`, `…/masc_schedule_update` | `Tool_actor` | 400 `{ok:false, message}` |
| `lib/server/server_routes_http_routes_activity.ml:491` | `POST /api/v1/tools/masc_board_vote`, `…/masc_board_comment`, `…/masc_board_comment_vote`, `…/masc_goal_transition` | `Tool_actor` | 400 `{ok:false, message}` |
| `lib/server/server_routes_http_routes_activity.ml:1327` | `POST /api/v1/tools/masc_board_post` | `Tool_actor` | 400, 도구 결과 글(`Effect_outcome_unknown`) |
| `lib/server/server_routes_http_routes_activity.ml:1437` | `POST /api/v1/tools/masc_schedule_cancel` | `Tool_actor` | 400 `{ok:false, message}` |
| `lib/server/server_dashboard_http_keeper_api_post.ml:186` | `/api/v1/keepers/` 아래 `Keeper_post_github_token` | `Token_permission CanAdmin` | 400 `respond_error` |
| `lib/server/server_dashboard_http_link_preview.ml:329` | `POST /api/v1/dashboard/link-previews` | `Permission CanReadState` | 200 `errors` 항목(:399). `Eio.Time.Timeout` 의 글이다 |
| `lib/server/server_dashboard_http_link_preview.ml:332` | 같음 | 같음 | 200 `errors` 항목(:399), cache 에 저장되는 실패 미리보기(:382) |
| `lib/server/server_dashboard_http_link_preview.ml:386` | 같음 | 같음 | 200 `errors` 항목(:399) |
| `lib/server/server_routes_http_dashboard_handlers.ml:53` | `POST /api/v1/broadcast`, `POST /broadcast` | `Token_permission CanBroadcast` | 200 `{ok:false, error}` |
| `lib/server/server_routes_http_keeper_control.ml:155` | `GET /api/v1/keepers/turns` | `Public_read` | 500 `{error: "keeper name census failed: <예외>"}` |
| `lib/server/server_mcp_transport_http.ml:705` | `POST /mcp`, 응답을 SSE 로 보내는 중 | `Self_authenticated Mcp_transport` | SSE 의 JSON-RPC error `Internal error: <예외>`. 이 갈래는 로그를 남기지 않는다 |
| `lib/server/server_mcp_transport_http.ml:716` | `POST /mcp` | 같음 | JSON-RPC error `Internal error: <예외>`. 로그 없음 |
| `lib/server/server_routes_http_routes_msx.ml:446` | `POST /api/v1/msx/save`, `/api/v1/msx/restore`(`operation_id` 가 있을 때) | `Tool` | 200 receipt `message`(:369). 저장된 receipt 를 `POST /api/v1/msx/checkpoint-operation`(`Read_auth`)이 다시 읽는다 |
| `lib/server/server_routes_http_routes_msx.ml:447` | 같음 | 같음 | 같음 |

### A2. 인증 거절이 저장소 오류 글을 싣는다 (2곳, 2개 파일)

| 파일:줄 | route | 인증 | 응답 |
|---|---|---|---|
| `lib/server/server_auth.ml:882` (`auth_error_json`) | 인증하는 route 의 공용 거절 응답 | 거절 응답 자체. bearer 를 실은 요청이면 읽기 권한 확인 전에 닿는다 | 503 `{error: <저장소 오류 글>}`(#51908). 로컬 커밋 `10d9b799ab37` 이 고쳤고 올리지 않았다 |
| `lib/server/server_mcp_transport_http_types.ml:13` (`auth_failure_of_masc_error`) | `/mcp` 와 그 profile, observer stream(`server_routes_http_common.ml:115-133` 의 verifier 넷) | `Self_authenticated Mcp_transport` | 401 JSON-RPC `error.message`(`server_mcp_transport_http_respond.ml:137`) |

### B. 실패 값의 `string` 필드가 예외 글을 담는다 (21곳, 3개 파일)

응답이나 저장된 기록까지 끝까지 따라가지 못했다.

| 파일:줄 | 담는 값 | 인증 |
|---|---|---|
| `lib/server/server_routes_http_keeper_stream.ml:811`·`2152`·`2172` | `Keeper_request_failure.Raised.exn`. 글로는 `summary_of_cause`(`keeper_request_failure.ml:324`), JSON 으로는 `"exn"`(:489) | 확인 못함 |
| `lib/server/server_routes_http_keeper_stream.ml:2489` | SSE `Event_error { message }`, `redact_text` 를 거친다 | 확인 못함 |
| `lib/server/server_routes_http_keeper_stream.ml:2668`·`3082` | `settle_delivery (Error _)`, `skipped _` | 확인 못함 |
| `lib/server/server_skill_editor.ml:764`·`800`·`826`·`882`·`935`·`988`·`1016`·`1108`·`1161`·`1226` | `Source_root_create_failed`·`Write_failed`·`Recovery_operation_failed`·`Package_directory_remove_failed` 등. 글은 :193·:204·:268 에서 만든다 | 확인 못함 |
| `lib/server/server_routes_http_dashboard_dev_token.ml:210`·`228`·`238`·`247`·`260` | `detail`. 글은 `token_error_to_string`(:59-83) | `Self_authenticated Loopback_dev_token` |

### C. 운영자 진단 화면 (18곳, 15개 파일)

| 파일:줄 | 필드 |
|---|---|
| `lib/dashboard/dashboard_goals.ml:17` | `snapshot_error` |
| `lib/dashboard/dashboard_http_keeper.ml:172`·`294` | keeper 행을 만들지 못했을 때 대신 내는 행의 오류 글 |
| `lib/dashboard/dashboard_briefing_sections.ml:259` | `last_error` |
| `lib/server/server_dashboard_json_cache.ml:70` | `Cache_state.Warming { last_error }` |
| `lib/server/server_dashboard_http_cache.ml:74` | cached surface 의 `last_error` |
| `lib/server/server_repository_pulls.ml:750`·`830` | `repositories_error`. `GET /api/v1/repositories/pulls`(`Public_read`), `tool_pull_requests.ml:298` |
| `lib/server/server_routes_http_runtime.ml:343` | health 구성 요소의 `error` |
| `lib/server/server_routes_http_runtime_health_fleet.ml:15` | fleet health 의 keeper census 오류 |
| `lib/server/server_dashboard_http_runtime_info.ml:1246` | runtime probe `errors`. #51903 이 일부러 뺀 자리다 |
| `lib/server/server_dashboard_http_execution_surfaces.ml:555` | 실행 화면 관측의 실패 글 |
| `lib/server/server_dashboard_http_core_operator_digest_http.ml:19` | digest 관측의 실패 글 |
| `lib/server/server_dashboard_http_core_digest_refresh.ml:72` | 같음 |
| `lib/server/server_dashboard_http_core_mission.ml:99`·`120` | mission 관측의 실패 글 |
| `lib/server/server_dashboard_http_core_snapshot_refresh.ml:75` | operator snapshot 관측의 실패 글 |
| `lib/server/server_dashboard_http_core_operator_snapshot_http.ml:64` | 같음 |

관측의 실패 글(`publish_failure_message`)이 화면까지 가는 길은 `.mli` 의 계약(「실패한 읽기는 본문을 unavailable 로 바꾼다」)까지만 읽었다. 인증은 `repositories/pulls` 말고는 확인하지 못했다.

### D. 진단이 사라진다 (1곳)

| 파일:줄 | route | 인증 | 지금 |
|---|---|---|---|
| `lib/server/server_oauth_http.ml:29` | OAuth 끝점의 요청 본문 읽기 실패 | `Self_authenticated Oauth_protocol` | 본문은 고정 문구다(`server_oauth_service.ml:52`). 예외 글은 `Store_error` 에 담긴 뒤 어디에도 남지 않는다 |

### 미확인 (6곳, 5개 파일)

| 파일:줄 | 지금 |
|---|---|
| `lib/server/server_play_skills.ml:132` | `protect_io` 가 `Error (Printexc.to_string exn)` 을 돌려준다 |
| `lib/server/server_pending_confirm_expiry.ml:210` | 같은 모양 |
| `lib/server/server_dashboard_official_client_session.ml:241` | 같은 모양 |
| `lib/server/builtin_skill_package.ml:202` | `Io_error` 에 담는다 |
| `lib/server/server_dashboard_http_delete_actions.ml:38` | `path_error`. 이 파일 안 9곳이 부른다 |
| `lib/server/server_dashboard_http_delete_actions.ml:296` | `unbind_exact_workspace_agents` 의 `Error` |

`delete_actions` 는 결과가 `Error` 로 올라가는 것과, 이 파일의 응답이 `error`·`errors` 에 글을 싣는 것까지 확인했다. 같은 글이 응답에 닿는 길은 따라가지 못했다.
