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

- Status: **Draft (2026-09-24).** §3 의 결정 넷은 운영자가 2026-09-24 에 정했다.
- 한 줄: "이 실패는 이 후보(바인딩)의 사정이라, 다음 후보가 같은 입력을 받아도 되는가"를
  exact 걸음과 Keeper 걸음이 따로 답한다. 같은 오류에 둘의 답이 다른 자리가 여섯이다.
  agent_core 에 판정 하나를 두고 두 걸음이 그것을 읽는다.
- 기준: main `39a4173e41`. 계기: #38472.

## 1. 지금 모양

### 1.1 두 걸음은 같은 분류에서 출발한다

두 걸음 모두 provider 응답을 `Llm_provider.Retry.classify_refusal` 로 읽어 `Retry.api_error` 를 만든다.
그 뒤 "다음 후보로 넘길까"를 따로 정한다.

- **exact 걸음** (Librarian, verifier, HITL 판정, Board attention):
  - `exact_output.ml:1670` `provider_refusal_of_api_error` 가 `api_error` 를 `provider_refusal` 로 1:1 로 옮긴다.
    `InvalidRequest` 만 셋으로 나뉜다.
  - `exact_output.ml:1824` `execution_failure_may_advance` 가 `provider_refusal × effect phase` 표 하나로 정한다.
- **Keeper 걸음** (Keeper 턴의 lane):
  - `keeper_turn_driver.ml:508` `lane_should_retry` 가 predicate 여섯 개를 차례로 묻는다.
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
| `InvalidRequest` 중 `Unknown_invalid_request` (400·422 등) | 멈춤 | 넘김 (같은 곳) |
| `NetworkError`·`Timeout` (보낸 뒤) | 멈춤. 헤더·전체 기한 초과만 넘긴다 (#38437) | 넘김 (다시 보내도 되는지는 `allow_retry` 가 effect 로 정함) |

같은 답을 하는 칸:

- 둘 다 넘긴다: `PaymentRequired`(402)·`RateLimited`(429)·`Overloaded`(529)·`ServerError`(5xx)·`ContextOverflow`·
  `InvalidRequest` 중 `Request_body_refused_by_provider`(413).
- Keeper 는 `ContextOverflow`·413·`Unknown_invalid_request` 에서 넘기기 전에, 같은 후보에 보내는 범위를 줄여 다시 보낸다
  (`keeper_turn_driver_try_provider.ml` `refusal_evicts`, `boundary_resend_on`).

보내기 전에 Keeper 파이프라인(`pipeline_stage_route.ml`)만 만드는 오류가 셋 있다. exact 걸음은 응답에서 이 셋을 받지 않는다.

- `InvalidRequest` 중 `Attempt_rejected` (준비된 요청을 이 바인딩이 받지 않음): 넘김.
- `InputCapacity` (선언된 입력 용량 초과, 입력을 잴 수 없음): 멈춤.
- `InvalidRequest` 중 `Json_parse_error` (입력 측정 응답이 깨짐): 멈춤.

첫 줄 셋이 #38472 의 증상이다. Librarian lane 이나 `verifier_exact` 의 첫 슬롯 키가 폐기되면(401)
두 번째 슬롯이 멀쩡해도 부르지 않는다. 같은 오류에서 Keeper 턴은 다음 후보로 간다.

`Unknown_invalid_request` 는 응답이 이유를 기계가 읽는 모양으로 주지 않은 거절이다. 2026-09-21~22 system log 에서
exact 걸음이 이것으로 멈춘 53번은 모두 Librarian lane 이었고, 응답 문장은 모두 창 초과를 말했다.

- ollama `deepseek-v4-1-flash` 41번: `"code": null`, "The prompt is too long: …, model maximum context length: 1048576" (#37836)
- glm `glm-5.3-flash` 12번: `"code": "1261"`. 09-21 09:13Z 까지만 있었다. 09:16Z 부터 같은 응답 103번은 `ContextOverflow` 로 읽혔다.

### 1.3 왜 이렇게 됐나

두 쪽 모두 "이 실패가 바인딩의 사정인가"를 묻는다. 답을 적는 곳이 둘이라, 한쪽을 넓혀도 다른 쪽은 그대로다.

- exact 표는 오류 종류마다 PR 로 넓혀 왔다: #37319 (5xx), #38262 (402), #38437 (보낸 뒤 헤더·전체 기한),
  #38454 (창 초과, 창에서 멈춘 빈 답). #38449 (본문 없는 5xx)는 같은 칸을 하나 더 제안한다.
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
  | Account         (** 402. 계정이 결제하지 못한다. 같은 quota scope 의 후보가 함께 본다 *)
  | Model_absent    (** 404 *)
  | Rate_limit      (** 429. 이 후보에게 늦추라는 답이다. 무엇이 바닥났는지는 말하지 않는다 *)
  | Capacity        (** 529, provider capacity pool *)
  | Server          (** 5xx *)
  | Window          (** context overflow, 창에서 멈춘 빈 답 *)
  | Body_limit      (** 413. 이 바인딩이 받는 요청 본문 크기 한도 *)
  | Admission       (** 보내기 전에 이 바인딩의 단계가 받지 않음:
                        선언된 입력 용량 초과, 입력을 잴 수 없음, 준비된 요청 거절 *)
  | Deadline        (** 보낸 뒤 헤더·전체 기한 초과 *)
  | Output_dialect  (** 답을 내용 칸이 아닌 곳에 둠 *)
  | Refusal_unread  (** 상태는 왔는데 거절 본문이 기한 안에 안 옴 *)

type t =
  | Binding of binding_fact
      (** 이 바인딩의 사정이다. 다음 후보가 같은 입력을 받아도 된다 *)
  | Unattributed
      (** 거절은 왔지만, 누구의 사정인지 응답이 기계가 읽는 모양으로 말하지 않는다 *)
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

`of_api_error` 는 `InvalidRequest` 를 이유마다 나눈다.

- `Request_body_refused_by_provider` → `Binding Body_limit`
- `Refusal_body_not_received` → `Binding Refusal_unread`
- `Attempt_rejected`·`Json_parse_error` → `Binding Admission`. `InputCapacity` 도 `Binding Admission` 이다.
- `Unknown_invalid_request` → `Unattributed`

지금 어떤 응답도 "입력 탓"을 증명하지 않는다. 그런 응답이 생기면 그때 판정을 더한다.

판정이 읽는 오류는 두 계열이다. provider 응답(`Retry.api_error`)과 전송 오류(`Http_client.http_error`)다.
공식 클라이언트가 만드는 provider 오류(`Llm_provider.Error.provider_error`)는 이 판정 밖이다 (#38776).

- `keeper_runtime_attempt.ml` 의 `provider_error_to_http_error` 는 `RateLimit` 과 `HardQuota` 를 같은
  `Capacity_exhausted` 전송 값으로 접는다. 접힌 값으로는 계정 quota 와 후보 하나의 속도 제한을 가를 수 없다.
- 그래서 provider 오류는 접기 전의 값으로 읽는다. 걸음 판정은 지금 길 그대로 두고(§4 의 3단계), route 도 지금처럼
  provider 오류를 직접 읽는다(§4 의 4단계).

### 2.2 두 걸음이 읽는 법

| 판정 | exact 걸음 | Keeper 걸음 |
|---|---|---|
| `Binding _` | 넘김 | 넘김. 다시 보내도 되는지는 지금처럼 `allow_retry` 가 effect fence 로 정한다 |
| `Unattributed` | 넘김 | 넘김 (같은 fence) |
| `Unknown_after_dispatch` | 멈춤. 지금 규칙 그대로다 | `allow_retry` (checkpoint·effect 규칙). 지금 규칙 그대로다 |

두 걸음의 차이는 "보냈는데 결과를 모름"을 어떻게 다루는지 하나만 남는다. 이건 오류 분류가 아니라 걸음의 효과 규칙이라, 이 RFC 는 어느 쪽도 바꾸지 않는다.
넘기기 전에 같은 후보에서 하는 일(같은 후보 재시도, 범위를 줄여 다시 보내기)도 바꾸지 않는다.

`Keeper_runtime_failure_route` 의 rotate·retry 분류도 `binding_fact` 에서 나오게 해서, 손으로 맞추는 곳을 없앤다.

## 3. 정한 것 (운영자, 2026-09-24)

1. **`Request_body_refused_by_provider` 는 `Binding Body_limit` 이다.**
   이 이유는 HTTP 413 에서만 만들어진다 (`retry.ml` `classify_refusal` 의 `| 413 ->`).
   413 은 그 바인딩(게이트웨이·provider)의 본문 크기 한도다. 한도가 더 큰 후보는 같은 본문을 받을 수 있다.
   두 걸음 모두 지금도 넘긴다. 동작은 바뀌지 않는다.
2. **`InputCapacity` 는 `Binding` 이다 (`Admission`).**
   보내기 전에 이 바인딩의 선언된 입력 용량을 넘었거나, 입력을 잴 수 없었다는 뜻이다.
   같은 단계의 `Attempt_rejected` 처럼, 이 바인딩은 못 받아도 다른 바인딩은 받을 수 있다.
   Keeper 걸음이 멈춤에서 넘김으로 바뀐다. 같은 단계의 `Json_parse_error`(입력 측정 응답이 깨짐)도 같은 판정이라 함께 바뀐다.
3. **exact 걸음도 401·403·404 에서 넘긴다.**
   셋 다 그 바인딩에만 있는 사정이다 (키, 권한·한도, 모델 없음). exact 요청은 도구가 없어서 넘겨도 효과가 겹치지 않는다.
   #38472 (폐기된 키 하나가 lane 전체를 멈춤)가 이것으로 풀린다.
4. **`Unknown_invalid_request` 는 `Unattributed` 이고, 두 걸음 모두 넘긴다.**
   Keeper 걸음은 지금도 넘긴다. exact 걸음이 멈춤에서 넘김으로 바뀐다.
   §1.2 의 ollama 41번은 다음 슬롯의 창이 더 컸다면 받을 수 있었다. 입력 탓인 400 이라면 후보마다 한 번씩 더 보낸다.
   판정은 `Binding` 이 아니다. 응답이 이유를 말하지 않았으니, 기록에도 모른다고 남긴다.

## 4. 단계

1. agent_core 에 `Candidate_fault` 와 표 테스트를 둔다. `Retry.api_error` 의 모든 생성자와 전송 오류마다 기대 판정을 적는다.
   흐름은 바꾸지 않는다.
   - `of_api_error` 는 `Retry.api_error` 를 `_` 없이 match 한다. 생성자가 늘면 컴파일이 멈춘다.
   - 표 테스트는 기대 판정을 자기 `match` 로 따로 적는다 (`_` 없음). 그래서 생성자가 늘면 테스트도 컴파일에서 멈추고, 새 생성자의 기대값을 테스트 쪽에서 정하고 리뷰한다.
2. exact `execution_failure_may_advance` 가 이 판정을 읽는다. 지금 테스트는 그대로 통과해야 한다.
   기대값이 바뀌는 칸: 401·403·404 (§3.3), `Unknown_invalid_request` (§3.4), `Refusal_body_not_received` (§2.1 `Refusal_unread`).
3. Keeper `lane_should_retry` 의 접근·창·거절 predicate 를 이 판정으로 바꾼다. `Agent_core.Error.Api` 만 이 판정을 읽는다.
   provider 오류(`Agent_core.Error.Provider`)는 지금 길 그대로다. `candidate_access_should_try_next` 가 먼저 읽고,
   나머지는 `keeper_runtime_attempt.ml` 이 접은 값을 `Runtime_attempt_fsm.should_try_next` 가 읽는다 (#38776).
   기대값이 바뀌는 칸: `InputCapacity`·`Json_parse_error` (§3.2).
4. `Keeper_runtime_failure_route` 의 rotate·retry 분류를 `binding_fact` 에서 만든다.
   - `Account` 는 `Hard_quota`(scope 전체의 quota 창, `note_quota`), `Rate_limit` 은 `Rate_limited`(그 후보 하나의
     backpressure, `note_rate_limit`)가 된다.
   - provider 오류는 route 가 지금처럼 접기 전에 직접 읽는다.
   - `test/test_keeper_runtime_failure_route.ml` 의 `test_provider_quota_family_threads_hint`(provider `HardQuota` →
     `Hard_quota`, provider `RateLimit` → `Rate_limited`)와 `test_api_quota_message_does_not_override_rate_limit`
     (429 → `Rate_limited`, 402 → `Hard_quota`)가 바뀌지 않고 통과해야 한다.

관련 PR·이슈:

- #38437, #38454 는 exact 표에 칸을 더하는 방식으로 들어갔다. 2단계가 그 칸을 이 판정으로 옮긴다.
- #38449 는 `Refusal_unread` 한 칸으로 들어간다.

## 5. 하지 않는 것

- 재시도 지연, 쿼터 창, 후보 순서 선호는 다루지 않는다 (RFC-0440, RFC-0458).
- 새 Gate 를 만들지 않는다. 판정은 관찰이고, 넘길지는 지금처럼 각 걸음이 정한다.
- 응답 문장에서 이유를 읽지 않는다. 이유는 응답의 상태 코드와 문서화된 코드 칸에서만 읽는다.
- 공식 클라이언트의 provider 오류를 이 판정에 넣지 않는다. 그 계열에도 어긋난 칸이 있다
  (`MissingApiKey` 는 멈추고 `AuthError` 는 넘긴다). #38776 에서 다룬다.
