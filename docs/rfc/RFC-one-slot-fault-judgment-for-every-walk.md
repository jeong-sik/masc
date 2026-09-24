---
rfc: "one-slot-fault-judgment-for-every-walk"
title: "다음 후보로 넘길지는 한 곳에서 정한다 — exact 걸음과 Keeper 걸음이 같은 오류에 같은 답을 한다"
status: Draft
created: 2026-09-24
updated: 2026-09-24
author: claude
related: ["librarian-lifecycle", "0440", "0454", "typed-terminal-reason"]
---

# 다음 후보로 넘길지는 한 곳에서 정한다

- Status: **Draft (2026-09-24).** §3 의 결정 셋은 운영자 확인이 필요하다.
- 한 줄: "이 실패는 이 후보(바인딩)의 사정이라, 다음 후보가 같은 입력을 받아도 되는가"를
  exact 걸음과 Keeper 걸음이 따로 답한다. 같은 오류에 둘의 답이 다른 자리가 일곱이다.
  agent_core 에 판정 하나를 두고 두 걸음이 그것을 읽는다.
- 기준: main `aea919b42c`. 계기: #38472.

## 1. 지금 모양

### 1.1 두 걸음은 같은 분류에서 출발한다

두 걸음 모두 provider 응답을 `Llm_provider.Retry.classify_refusal` 로 읽어 `Retry.api_error` 를 만든다.
그 뒤 "다음 후보로 넘길까"를 따로 정한다.

- **exact 걸음** (Librarian, verifier, HITL 판정, Board attention):
  - `exact_output.ml:1673` `provider_refusal_of_api_error` 가 `api_error` 를 `provider_refusal` 로 1:1 로 옮긴다.
    `InvalidRequest` 만 셋으로 나뉜다.
  - `exact_output.ml:1816` `execution_failure_may_advance` 가 `provider_refusal × effect phase` 표 하나로 정한다.
- **Keeper 걸음** (Keeper 턴의 lane):
  - `keeper_turn_driver.ml:510` `lane_should_retry` 가 predicate 여섯 개를 차례로 묻는다.
    `Keeper_required_tools.should_try_next`, `accept_no_progress_should_try_next`,
    `context_overflow_should_try_next`(`keeper_turn_driver_try_runtime.ml:112`),
    `attempt_rejected_should_try_next`(`:63`), `Keeper_recovery_transmission.should_try_next`,
    `candidate_access_should_try_next`(`:37`).
  - 어디에도 걸리지 않으면 `keeper_runtime_attempt.ml:100` 이 오류를 HTTP 오류로 다시 만들고,
    `runtime_attempt_fsm.ml:24` `should_try_next` 가 상태 코드로 정한다 (408·409·429·5xx, 네트워크, 시간 초과).
  - `Keeper_runtime_failure_route` 는 같은 사실을 telemetry 용 route 로 또 가른다.
    `candidate_access_should_try_next` 주석이 "route 가 `NotFound` 를 `Model_unavailable` 로 보내니 walk 도 맞춰야 한다"고
    손으로 맞춘다는 것을 적어 둔다.

### 1.2 같은 오류, 다른 답

응답을 받은 뒤의 판정이다. "넘김"은 다음 후보가 같은 입력으로 불린다는 뜻이다.

| `api_error` | exact 걸음 | Keeper 걸음 |
|---|---|---|
| `AuthError` (401) | 멈춤 | 넘김 (`candidate_access_should_try_next`) |
| `AuthorizationError` (403) | 멈춤 | 넘김 (같은 곳) |
| `NotFound` (404) | 멈춤 | 넘김 (같은 곳) |
| `InvalidRequest` 중 `Refusal_body_not_received` | 멈춤 | 넘김 (`attempt_rejected_should_try_next`) |
| `InvalidRequest` 중 `Request_body_refused_by_provider` | 넘김 | 멈춤 (400 으로 다시 만들어져 FSM 이 멈춤) |
| `ContextOverflow` | 멈춤 | 넘김 (`context_overflow_should_try_next`) |
| `NetworkError`·`Timeout` (보낸 뒤) | 멈춤 | 넘김 (다시 보내도 되는지는 `allow_retry` 가 effect 로 정함) |

같은 답을 하는 칸: `PaymentRequired`(402)·`RateLimited`(429)·`Overloaded`(529)·`ServerError`(5xx) 는 둘 다 넘기고,
그 밖의 `InvalidRequest` 와 `InputCapacity` 는 둘 다 멈춘다.

첫 줄 셋이 #38472 의 증상이다. Librarian lane 이나 `verifier_exact` 의 첫 슬롯 키가 폐기되면(401)
두 번째 슬롯이 멀쩡해도 부르지 않는다. 같은 오류에서 Keeper 턴은 다음 후보로 간다.

### 1.3 왜 이렇게 됐나

두 쪽 모두 "이 실패가 바인딩의 사정인가"를 묻는다. 답을 적는 곳이 둘이라, 한쪽을 넓혀도 다른 쪽은 그대로다.

- exact 표는 오류 종류마다 PR 로 넓혀 왔다: #37319 (5xx), #38262 (402).
  열린 #38437 (보낸 뒤 헤더·전체 기한), #38454 (창 초과, 창에서 멈춘 빈 답)도 같은 방식이다.
  #38449 (본문 없는 5xx)는 같은 칸을 하나 더 제안한다.
  RFC-librarian-lifecycle D8 이 이 결함을 적었고, 위 PR 들이 칸 단위로 그것을 메운다.
- Keeper 쪽은 predicate 를 하나씩 더했다: #37563, #37584, #37631 (접근 오류).

## 2. 제안

### 2.1 판정 하나

agent_core 에 닫힌 판정 하나를 둔다. 오류가 **누구의 사정**인지만 답한다. 넘길지는 걸음이 정한다.

```ocaml
(* packages/agent_core/lib/llm_provider/candidate_fault.mli *)

(** 이 후보(provider·모델·자격 증명·계정의 묶음)에만 있는 사정 *)
type binding_fact =
  | Credential      (** 401, 403 *)
  | Account         (** 402 *)
  | Model_absent    (** 404 *)
  | Quota           (** 429 *)
  | Capacity        (** 529, provider capacity pool *)
  | Server          (** 5xx *)
  | Window          (** context overflow, 창에서 멈춘 빈 답 *)
  | Deadline        (** 보낸 뒤 헤더·전체 기한 초과 *)
  | Output_dialect  (** 답을 내용 칸이 아닌 곳에 둠 *)
  | Refusal_unread  (** 상태는 왔는데 거절 본문이 기한 안에 안 옴 *)

type t =
  | Binding of binding_fact
      (** 다음 후보가 같은 입력을 받아도 된다 *)
  | Input
      (** 입력의 사정이다. 다음 후보도 같은 이유로 거절한다 *)
  | Unknown_after_dispatch
      (** 보냈고 결과를 모른다. 다시 보내도 되는지는 걸음의 효과 규칙이 정한다 *)

(** 보냈는지. [Exact_output.generation_dispatch_fact] 를 이 모듈로 내린다.
    Exact_output 이 이 모듈을 읽으므로, 넘겨받는 사실의 타입은 이 아래에 있어야 한다. *)
type dispatch =
  | Not_dispatched
  | Dispatched

val of_api_error : Retry.api_error -> t
val of_transport_error : Http_client.http_error -> dispatch:dispatch -> t
```

### 2.2 두 걸음이 읽는 법

| 판정 | exact 걸음 | Keeper 걸음 |
|---|---|---|
| `Binding _` | 넘김 | 넘김. 다시 보내도 되는지는 지금처럼 `allow_retry` 가 effect fence 로 정한다 |
| `Input` | 멈춤 | 멈춤 |
| `Unknown_after_dispatch` | 멈춤. 지금 규칙 그대로다 (§5) | `allow_retry` (checkpoint·effect 규칙) |

두 걸음의 차이는 "보냈는데 결과를 모름"을 어떻게 다루는지 하나만 남는다. 이건 오류 분류가 아니라 걸음의 효과 규칙이다.

`Keeper_runtime_failure_route` 의 rotate·retry 분류도 `binding_fact` 에서 나오게 해서, 손으로 맞추는 곳을 없앤다.

## 3. 정해야 할 것

1. **`Request_body_refused_by_provider` 는 `Binding` 인가 `Input` 인가.**
   응답이 "provider 가 이 입력을 생성 전에 거절했다"를 증명한다. exact 는 지금 넘기고 Keeper 는 멈춘다.
   다른 provider 가 같은 본문을 받을 수 있다면 `Binding`, 본문 자체가 잘못이면 `Input` 이다.
2. **`InputCapacity` 는 `Window` 와 같은 `Binding` 인가.**
   입력이 이 바인딩의 한도를 넘었다는 뜻이다. 한도가 더 큰 후보가 있으면 받을 수 있다. 지금은 둘 다 멈춘다.
3. **exact 걸음도 401·403·404 에서 넘길지.**
   넘기면 폐기된 키 하나가 lane 전체를 멈추지 않는다 (#38472). Keeper 는 이미 넘긴다.
   exact 요청은 도구가 없어서 넘겨도 효과가 겹치지 않는다.

## 4. 단계

1. agent_core 에 `Candidate_fault` 와 표 테스트를 둔다. `Retry.api_error` 의 모든 생성자와 전송 오류마다 기대 판정을 적는다.
   흐름은 바꾸지 않는다.
2. exact `execution_failure_may_advance` 가 이 판정을 읽는다. 지금 테스트는 그대로 통과해야 한다.
   §3 결정으로 바뀌는 칸만 기대값이 바뀐다.
3. Keeper `lane_should_retry` 의 접근·창·거절 predicate 를 이 판정으로 바꾼다.
   `Runtime_attempt_fsm.should_try_next` 의 상태 코드 표도 같은 판정에서 나오게 한다.
4. `Keeper_runtime_failure_route` 의 rotate·retry 분류를 `binding_fact` 에서 만든다.

열린 PR 과의 관계:

- #38437, #38454 는 1단계 전에는 지금 표에 칸을 더하는 방식으로 들어간다. 들어가면 2단계가 그 칸을 이 판정으로 옮긴다.
- #38449 는 이 RFC 의 결정 뒤에 `Refusal_unread` 한 칸으로 들어간다.

## 5. 하지 않는 것

- 재시도 지연, 쿼터 창, 후보 순서 선호는 다루지 않는다 (RFC-0440, RFC-0458).
- 새 Gate 를 만들지 않는다. 판정은 관찰이고, 넘길지는 지금처럼 각 걸음이 정한다.
- "보낸 뒤 모름"을 다시 보내도 되는지는 이 RFC 가 바꾸지 않는다. 걸음마다 지금 규칙을 그대로 쓴다.
