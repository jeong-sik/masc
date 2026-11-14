---
rfc: "one-slot-fault-judgment-for-every-walk"
title: "다음 후보로 넘길지는 한 곳에서 정한다 — exact 걸음과 Keeper 걸음이 같은 오류에 같은 답을 한다"
status: Draft
created: 2026-09-24
updated: 2026-11-14
author: claude
related: ["librarian-lifecycle", "0440", "0454", "0492", "typed-terminal-reason", "exact-lane-walks-one-slot-list"]
---

# 다음 후보로 넘길지는 한 곳에서 정한다

- Status: **Draft (2026-09-24).** §3 의 결정 넷은 운영자가 2026-09-24 에 정했다.
- 한 줄: "이 실패는 이 후보(바인딩)의 사정이라, 다음 후보가 같은 입력을 받아도 되는가"를
  exact 걸음과 Keeper 걸음이 따로 답한다. 같은 오류에 둘의 답이 다른 자리가 여섯이다.
  agent_core 에 판정 하나를 두고 두 걸음이 그것을 읽는다.
- 기준: main `39a4173e41`. 계기: #38472.
- 2026-11-14 추가: §1.4·§2.3·§3.5·§4 의 5단계. 기준 main `be09733135`. 계기: #38403.
  §3.5 는 운영자 결정 전이다.

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

### 1.4 연결을 열지 못한 실패 (2026-11-14)

2026-11-14 15:57~18:16 KST 에 호스트가 잠들었다 깨기를 되풀이했다 (#38403).
그동안 GLM API 후보의 턴이 `failed to resolve hostname` 으로 실패했다.
이 문장은 이름 찾기 결과가 비었을 때 `resolve_origin` 만 만든다 (`http_client.ml:892`).
이름을 못 찾았으니 연결을 열지 않았고, 요청은 나가지 않았다.
그런데 lane 증거에는 `api_candidate_fault: unknown_after_dispatch` 로 남았다. "보냈고 결과를 모른다"는 뜻이다.

연결을 열지 못한 실패는 연결을 여는 함수에서만 생긴다. 그런 함수는 두 쌍이다.

- `http_client.ml` 의 `resolve_origin`(`:882`)과 `make_connection`(`:1000`).
- exact 측정 전송 `exact_output_measurement_transport.ml` 의 `resolve_origin`(`:133`)과 `make_connection`(`:189`).
- `resolve_origin` 은 이름을 찾고 TLS 설정을 준비한다. 실패를 `Error` 로 돌려준다.
- `make_connection` 은 TCP 로 잇고 TLS 를 감싼다. TCP 실패는 `Error` 로 돌려준다.
  TLS handshake 예외(`Tls_alert`·`Tls_failure`·`End_of_file`)는 다시 던진다
  (`http_client.ml:1004~1021`, 측정 전송 `:190~207`). 그 예외는 밖에서 `classify_network_exn` 을 거쳐 `NetworkError` 가 된다.
- 이름 찾기·TCP·TLS 모두 요청을 쓰기 전에 끝난다.
- one-shot 클라이언트는 TCP 와 TLS 를 Cohttp 의 `post` 안에서 연다 (`connect` closure, `http_client.ml:946`).
  이름 찾기만 그 전에 한다.
- `post_sync_once` 는 연결이 열린 뒤에야 `Dispatch_started` 로 넘어간다 (`http_client.ml:1647`).
  스트림 길도 연결이 열린 뒤에 `dispatch_entered` 를 부른다 (`:2004`).

그런데 그 실패가 다른 네트워크 오류와 같은 값이 된다.

- 연결 함수는 실패를 `NetworkError { message; kind }` 로 만든다 (`http_client.ml:1017~1021`).
  보낸 뒤 연결이 끊긴 실패도 같은 생성자다.
- `Retry.NetworkError` 와 provider 오류의 `NetworkError` (`error.ml:387`) 도 그 값을 그대로 옮긴다.
- 그래서 `candidate_fault.ml:52` 는 모든 네트워크 오류를 `Unknown_after_dispatch` 로 둔다.
  그 주석은 "§2.1 표에 network 줄이 없다"고 적는다.

`kind` 로는 가를 수 없다.

- `Timeout`·`Tls_error` 는 연결 전에도 뒤에도 난다.
- `ENETUNREACH`·`EHOSTUNREACH` 는 `Dns_failure` 로 읽힌다 (`http_client.ml:348`). 열린 소켓에서도 날 수 있다.

attempt 의 `dispatch: dispatched` 는 틀리지 않았다.

- `keeper_attempt_dispatch.mli` 의 `Dispatched` 는 "후보의 provider 나 클라이언트를 불렀다"는 뜻이다.
- 연결 실패는 부른 클라이언트의 답이다. 틀린 것은 요청 하나의 판정이다.

`Request_wire` 로도 가를 수 없다.

- RFC-0492 §3.3 의 `Request_wire.delivery` 는 열린 연결의 쓰기가 peer close 로 실패했고 응답 바이트가 없었는지 본다.
  그때만 `Not_delivered` 다. 그 요청을 다시 보내도 된다는 근거다 (`http_client.ml:1028`).
- 연결이 열리기 전의 실패는 쓰기를 시작하지 않았다. 그래서 `Possibly_delivered` 로 남는다.

## 2. 제안

### 2.1 판정 하나

agent_core 에 닫힌 판정 하나를 둔다. 오류가 **누구의 사정**인지만 답한다. 넘길지는 걸음이 정한다.

```ocaml
(* packages/agent_core/lib/llm_provider/candidate_fault.mli *)

(** 이 후보(provider·모델·자격 증명·계정의 묶음)에만 있는 사정 *)
type binding_fact =
  | Credential      (** 401 *)
  | Account_access  (** 403. #38975 에서 Credential 과 나눴다 *)
  | Account         (** 402. 계정이 결제하지 못한다. 같은 quota scope 의 후보가 함께 본다 *)
  | Model_absent    (** 404 *)
  | Rate_limit      (** 429. 이 후보에게 늦추라는 답이다. 무엇이 바닥났는지는 말하지 않는다 *)
  | Capacity        (** 529, provider capacity pool *)
  | Server          (** 5xx *)
  | Window          (** context overflow, 창에서 멈춘 빈 답 *)
  | Body_limit      (** 413. 이 바인딩이 받는 요청 본문 크기 한도 *)
  | Admission       (** 보내기 전에 이 바인딩의 단계가 받지 않음:
                        선언된 입력 용량 초과, 입력을 잴 수 없음, 준비된 요청 거절 *)
  | Deadline        (** 헤더·전체 기한 초과. 연결이 열렸는지는 싣지 않는다 (§5) *)
  | Output_dialect  (** 답을 내용 칸이 아닌 곳에 둠 *)
  | Refusal_unread  (** 상태는 왔는데 거절 본문이 기한 안에 안 옴 *)

type t =
  | Binding of binding_fact
      (** 이 바인딩의 사정이다. 다음 후보가 같은 입력을 받아도 된다 *)
  | Unattributed
      (** 거절은 왔지만, 누구의 사정인지 응답이 기계가 읽는 모양으로 말하지 않는다 *)
  | Unknown_after_dispatch
      (** 보냈고 결과를 모른다. 다시 보내도 되는지는 걸음의 효과 규칙이 정한다 *)
  | Local_admission
      (** MASC 의 허가 대기열이나 로컬 용량에서 기다리다 기한이 지났다
          (Queue·Capacity_backpressure 단계의 Timeout). 아무것도 보내지 않아
          이 바인딩에 대해 말하는 것이 없다 *)
  | Not_sent
      (** 이 바인딩의 host 로 연결을 열지 못해, 이 요청은 나가지 않았다 (§2.3).
          누구의 사정인지는 모른다. host 이름이 이 바인딩의 것일 수도, 모든 후보가 쓰는 망일 수도 있다 *)

val of_api_error : Retry.api_error -> t
```

`of_api_error` 는 `InvalidRequest` 를 이유마다 나눈다.

- `Request_body_refused_by_provider` → `Binding Body_limit`
- `Refusal_body_not_received` → `Binding Refusal_unread`
- `Attempt_rejected`·`Json_parse_error` → `Binding Admission`. `InputCapacity` 도 `Binding Admission` 이다.
- `Unknown_invalid_request` → `Unattributed`

지금 어떤 응답도 "입력 탓"을 증명하지 않는다. 그런 응답이 생기면 그때 판정을 더한다.

판정이 읽는 오류는 `Retry.api_error` 하나다. 연결을 열지 못한 실패는 §2.3 대로 그 안의 생성자 하나가 된다.
처음 적은 `type dispatch` 와 `of_transport_error` 는 구현되지 않았다 (#38913 은 `of_api_error` 만 넣었다). §2.3 이 그 자리를 대신한다.
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
| `Unknown_after_dispatch` | 넘김 | `allow_retry` (checkpoint·effect 규칙). 지금 규칙 그대로다 |
| `Not_sent` | 넘김 (자기 receipt 의 `No_generation_dispatch`) | 넘김. 다시 보내도 되는지는 지금처럼 `allow_retry` 가 effect fence 로 정한다 |

두 걸음의 차이는 "보냈는데 결과를 모름"을 어떻게 다루는지 하나만 남는다. 이건 오류 분류가 아니라 걸음의 효과 규칙이다.
exact 걸음은 판정을 가리지 않고 모두 넘기므로 이 판정을 읽지 않는다. exact 요청에는 도구가 없어서 결과를 모르는 요청을 넘겨도 효과가 겹치지 않는다 (`RFC-exact-lane-walks-one-slot-list.md` §3.3, Q1). Keeper 턴은 도구를 쓰므로 `allow_retry` 가 정한다.
넘기기 전에 같은 후보에서 하는 일(같은 후보 재시도, 범위를 줄여 다시 보내기)도 바꾸지 않는다.

`Keeper_runtime_failure_route` 의 rotate·retry 분류도 `binding_fact` 에서 나오게 해서, 손으로 맞추는 곳을 없앤다.

### 2.3 연결을 열지 못한 실패는 따로 생성자를 갖는다 (2026-11-14 제안)

이 사실은 단계 칸으로 싣지 않는다. 오류 생성자 하나로 둔다.

- 이 실패는 §1.4 의 연결 함수에서만 생긴다. 만드는 곳이 정해져 있어서 생성자 하나로 충분하다.
- 단계 칸을 더하면 연결과 무관하게 오류를 만드는 자리마다 단계를 지어 넣어야 한다.
  `keeper_runtime_attempt.ml` 의 `ProviderUnavailable`·빈 답 변환, `error_domain.ml:142` 가 그렇다.
  그 자리들은 지금처럼 `NetworkError` 를 만든다. 판정도 지금처럼 `Unknown_after_dispatch` 다.
- 보냈는지를 말하는 타입은 이미 여럿이다: `one_dispatch_phase`, `post_sync_once_error`,
  `Count_tokens_sync` 의 측정 단계, `Exact_output_measurement_transport.dispatch_intent`,
  `Exact_output.generation_dispatch_fact`, `Runtime_attempt_dispatch.t`,
  `Anti_rationalization.failure_certainty`, `Request_observation`. 하나를 더하지 않는다.

1. **만드는 곳.**
   - `Http_client.http_error` 에 `Connect_failed of { message; kind }` 를 더한다.
   - §1.4 의 연결 함수 두 쌍은 실패를 이 생성자로 돌려준다. 다른 자리는 이 생성자를 만들지 않는다.
   - 두 `make_connection` 은 TCP 연결과 TLS 감싸기를 도는 동안 난 예외를 잡는다.
     `classify_network_exn` 이 `NetworkError` 로 읽는 예외는 같은 `kind` 의 `Connect_failed` 로 돌려준다.
     `Eio.Time.Timeout` 은 기한이라 지금처럼 밖으로 보낸다 (§5). 취소 같은 예약 예외도 다시 던진다.
   - `classify_network_exn` 은 바꾸지 않는다. 예외만 보고는 연결 전인지 모른다.
   - one-shot 클라이언트(`make_client`)는 TCP 연결을 Cohttp 의 `post` 안에서 연다 (`http_client.ml:947`).
     그 연결 실패는 지금처럼 `NetworkError` 다. 이름 찾기는 `post` 전에 하므로 `Connect_failed` 가 된다.
2. **놓일 수 없는 짝.**
   - `Connect_failed` 는 `Before_dispatch_error` 안에만 온다. 연결 함수는 `phase := Dispatch_started` 보다 먼저 끝난다.
   - `post_sync_once` 의 `fail` 은 `Dispatch_started_error`·`Response_received_error` 안의 `Connect_failed` 를
     `:1551` 의 어긋난 receipt 처럼 거절한다.
   - exact 측정 전송도 자기 단계 값과 같은 규칙을 쓴다 (`:281`).
   - 이 짝은 타입이 아니라 실행 중 거절로 막는다. 생성자를 만드는 곳이 연결 함수뿐이라 성립한다.
   - exact 의 dispatch 사실은 감싸는 값에서 나온다 (`exact_output_execution.ml:103~107`).
     그래서 `Completion_failed { Connect_failed; Generation_dispatch_started }` 도 같은 거절로 막힌다.
3. **옮기는 곳.**
   - `Retry.api_error` 에 `Connect_failed of { message; kind }` 를 더한다.
     provider 오류 `Llm_provider.Error.provider_error` 에는 `Connect_failed of { provider; kind; detail }` 를 더한다.
     `NetworkError` 가 세 계열에 다 있는 것과 같은 모양이다. 기한 단계 칸은 없다.
   - `core_error_of_http_error`·`of_http_error`·`of_retry_api_error`·`error_domain` 왕복·
     `keeper_runtime_attempt.ml` 의 HTTP 오류 재구성이 이 생성자를 그대로 옮긴다.
     어느 변환도 `NetworkError` 로 접지 않는다.
   - `error_domain` 의 `` `Network_error of string `` (`:11`)은 `kind` 와 계열을 잃는다. 돌아올 때 `kind = Unknown` 이 된다 (`:195`).
     `Connect_failed` 는 provider·`kind`·detail 을 싣는 변형을 따로 둔다.
   - `attribution_of_http_error` (`provider_failure_attribution.ml:255`)는 `Connect_failed` 에도 `NetworkError` 와 같은 `kind` 규칙을 쓴다.
   - `Keeper_request_failure` 의 저장 원인에 `Provider_connect_failed` 를 더한다 (`keeper_request_failure.ml:100`).
     `Provider_network` 로 접지 않는다. 생성자를 더할 뿐이라 옛 기록은 새 decoder 로 그대로 읽힌다.
     새 이름(`provider_connect_failed`, walk 증거의 `not_sent`)이 든 기록은 옛 decoder 가 읽지 못한다.
     1.0 전이라 hard cut 으로 둔다.
   - `Retry.is_retryable`·`Llm_provider.Error.is_retryable`(`error.ml:402`)·`Error_domain.is_retryable`(`:295`)은
     `NetworkError` 의 `kind` 규칙을 함수 하나로 뽑아 같이 부른다. `Tls_error`·`Local_resource_exhaustion` 은 계속 재시도하지 않는다.
   - `Runtime_attempt_fsm.should_try_next` 는 `Connect_failed` 를 `NetworkError` 와 같은 갈래에 둔다.
     Keeper lane 이 넘기는 동작은 바뀌지 않는다.
4. **판정.**
   - `of_api_error` 는 `Retry.Connect_failed _` 를 `Not_sent` 로 둔다. `Retry.NetworkError _` 는 지금처럼 `Unknown_after_dispatch` 다.
   - Keeper predicate 의 `Candidate_fault.t` match (`keeper_turn_driver_try_runtime.ml:68`·`:118`·`:149`)는
     `Not_sent` 를 `Unknown_after_dispatch` 와 같은 `false` 갈래에 둔다. 넘김은 위의 FSM 이 정한다.
   - walk 증거 `fault_to_json` (`keeper_runtime_walk_evidence.ml:67`)은 `not_sent` 로 적는다.
   - exact 의 `provider_refusal_of_api_error` (`exact_output.ml:843`)는 `Connect_failed` 에 자기 거절 이름을 따로 준다.
     저장되는 `network_error` 이름(`:126`)에 접지 않는다.
     `execution_cause_is_binding_rest` (`:1105`)는 `NetworkError` 와 같은 갈래에 둔다.
   - `Anti_rationalization.failure_certainty` 는 attempt 단위다.
     `Dispatched` attempt 의 `Connect_failed` 는 지금처럼 `Outcome_unknown` 이다. 앞선 요청이 나갔을 수 있다.
5. **route.**
   - route 의 retry class 에 새 생성자 `Connection_not_opened` 를 더한다. 기록이 "보냈다 잃음"과 "보내지 않음"을 나눈다.
   - `route_of_api_error` 는 `Not_sent` 를 `observe_retry Connection_not_opened` 로 둔다. `Network_transient` 처럼 `observe_retry` 갈래다.
   - 그 class 를 읽는 match (`keeper_runtime_failure_route.ml:507`·`:602`·`:731`)는 `Network_transient` 와 같은 갈래에 둔다.
     이름은 `connection_not_opened` 다 (`:529` 옆).
   - `route_of_provider_error` 의 provider `Connect_failed` 도 같은 class 로 간다 (`keeper_runtime_failure_route.ml:374`).
   - slot 상태가 그 class 를 어떻게 읽을지는 #38403 이 정한다.

생성자를 더하면 `http_error`·`api_error`·`provider_error` 를 읽는 match 가 모두 컴파일에서 멈춘다.
그 자리마다 판단을 적는다. `_` 로 넘기지 않는다.

exact 걸음의 동작은 바뀌지 않는다. 이 실패는 지금처럼 `Before_dispatch_error` 안에 오고, 자기 receipt 는 `No_generation_dispatch` 다.

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
5. **(제안, 결정 전) 연결을 열지 못한 실패는 `Not_sent` 다.**
   `Local_admission` 에 접지 않는다. 그건 MASC 자신의 대기열이라 어느 바인딩의 이야기도 아니다.
   `Not_sent` 는 이 바인딩의 host 이름이 틀렸을 수도 있다. route 가 두 class 를 따로 적어야 운영자가 가른다.
   Keeper 걸음의 넘김은 바뀌지 않는다. 바뀌는 것은 요청 하나의 판정, route class, 증거 이름이다.

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

1·3·4단계는 main 에 들어갔다 (`candidate_fault.ml`, `keeper_turn_driver_try_runtime.ml`, `keeper_runtime_failure_route.ml`).
2단계는 RFC-exact-lane-walks-one-slot-list §3.3 이 대신했다. exact 걸음은 이 판정을 읽지 않고
`flow_execution_terminal_kind` (`exact_output.ml:1044`)로 넘긴다. §1.1 의 줄 번호는 `39a4173e41` 기준이다.

2026-11-14 추가 (§2.3).

5. §2.3 전부를 한 PR 로 낸다. 생성자·판정·route class·증거 이름·저장 원인을 나누면 그 사이에 접는 변환이 생긴다.
   - 표 테스트: 연결 함수 두 쌍의 실패마다 `Connect_failed`, 연결이 열린 뒤의 실패마다 `NetworkError` 가 나온다.
     TLS handshake 실패와 handshake 도중의 `End_of_file` 줄을 넣는다.
   - `post_sync_once` 가 `Dispatch_started_error` 안의 `Connect_failed` 를 거절한다.
   - `of_api_error` 표 테스트는 `_` 없이 `Connect_failed` 의 기대값을 적는다.

## 5. 하지 않는 것

- 재시도 지연, 쿼터 창, 후보 순서 선호는 다루지 않는다 (RFC-0440, RFC-0458).
- 새 Gate 를 만들지 않는다. 판정은 관찰이고, 넘길지는 지금처럼 각 걸음이 정한다.
- 응답 문장에서 이유를 읽지 않는다. 이유는 응답의 상태 코드와 문서화된 코드 칸에서만 읽는다.
- 공식 클라이언트의 provider 오류를 이 판정에 넣지 않는다. 그 계열에도 어긋난 칸이 있다
  (`MissingApiKey` 는 멈추고 `AuthError` 는 넘긴다). #38776 에서 다룬다.
- 연결 전인지를 `kind`·오류 문장·errno 로 짐작하지 않는다. 오류를 만든 함수만 본다.
- 기한 초과에는 연결 여부를 싣지 않는다. 기한 값은 어느 기한이 끝났는지를 말한다 (`retry.ml:118`).
  연결 전에 끝난 기한도 지금처럼 자기 phase 로 끝나고, 판정도 그대로다.
  - one-shot `post_sync` 의 기한은 본문 읽기까지 감싼다 (`http_client.ml:1490`). 그 클라이언트는 `open_connection` 을 부르지 않는다.
    기한 쪽에서 연결 여부를 가리면 보낸 요청을 "안 보냄"으로 적는 길이 생긴다.
  - 기한에 연결 여부를 싣으려면 따로 제안한다.
- attempt 의 dispatch 사실(`Runtime_attempt_dispatch`)은 바꾸지 않는다. 그 값은 후보의 클라이언트를 불렀는지를 말한다.
- 호스트가 잠들었는지, 모든 후보가 같이 실패했는지를 세어 판정하지 않는다. 그건 #38403 의 일이다.
- `Not_sent` 에 쉬는 시간이나 재시도 지연을 붙이지 않는다.
- 열린 연결에서 쓰기가 peer close 로 실패한 요청(`Request_wire.Not_delivered`)은 다루지 않는다.
  그 요청은 서버에 온전히 닿지 않았다 (`request_wire.mli`). 그 사실은 RFC-0492 §3.3 이 다시 보내기 근거로 쓴다.
  이 판정으로 넓히려면 따로 제안한다.
