---
rfc: "last-path-resumes-after-progress"
title: "마지막 경로가 잠깐 실패해도, 진전을 남긴 작업은 그 경로가 쉰 뒤 이어서 돈다"
status: Draft
created: 2026-09-17
updated: 2026-09-17
author: claude
supersedes: []
superseded_by: null
related: ["provider-path-rest"]
---

# RFC: 마지막 경로의 일시 실패 뒤, 진전을 남긴 작업은 이어서 돈다 (last-path-resumes-after-progress)

## 0. 요약

런타임 후보가 하나뿐인 keeper 는 429·5xx·연결 끊김 한 번에 작업을 잃는다.
후보가 둘 이상이면 같은 실패에도 작업이 체크포인트에서 다음 후보로 이어진다.
차이는 **다음 후보가 있느냐** 하나뿐이다.

이 RFC 는 마지막 후보에도 이어가기를 허용한다. 조건은 둘이다.

- 실패가 시간이 지나면 풀리는 종류다 (3.3).
- 실패한 시도가 체크포인트를 새로 남겼다. 즉 진전이 있었다.

이어가기는 실패한 경로가 쉬고 난 뒤 같은 작업, 같은 경로에서 시작한다.
횟수를 세는 장치는 두지 않는다. 이어갈 때마다 새 체크포인트가 필요하므로, 이어가기 횟수는
작업이 실제로 해낸 일의 양을 넘지 못한다 (3.2).

## 1. 지금 동작

### 1.1 실측 (2026-09-17)

Terminal-Bench 4.0.0 스모크 `terminal-bench/html-js-filter` 에서 keeper 하나를 돌렸다.
조건은 이렇다.
- 모델: `openrouter/deepseek/deepseek-v4.1-flash`
- 런타임: `[runtime] default` 하나

도구를 48번 호출하고 9분 42초가 지났을 때, OpenRouter 가 스트림 중간에
`finish_reason: "error"` 를 보냈다. 작업은 `Failed {Turn_exception}` 으로 끝났다.
masc 는 이 값을 공급자 오류가 아니라 모르는 stop reason 으로 읽었다(#36920).
그 해석은 #36922 가 고친다.

하지만 #36922 가 들어가도 결과는 같다. 아래 1.2 가 이유다.

### 1.2 후보 하나일 때의 경로 (main `97b455767a`)

| 단계 | 위치 | 후보 하나일 때 |
|---|---|---|
| 같은 턴에서 다음 후보로 | `lib/keeper/keeper_turn_driver.ml:466` `lane_should_retry` | `is_last` 면 곧바로 `false` |
| 다음 턴으로 남은 후보 넘기기 | `keeper_turn_driver.ml:842`–`871` | `rest` 가 비어 `on_retry_deferred` 를 부르지 않는다 |
| 채팅 작업 미루기 | `lib/keeper/keeper_turn.ml:1004` | hint 가 없어 `dispatch_failed ~class_:Runtime_failure` |
| 작업 상태 | `lib/server/server_routes_http_keeper_stream.ml:1606` | `Turn_failed` → `Keeper_chat_operation.Turn_exception` |

429(`Rate_limited`), 5xx(`Server_error`), 소켓 끊김(`Network_transient`),
유휴 timeout(`Provider_timeout`) 모두 이 경로로 간다.
같은 후보를 다시 부르는 경로는 어느 실패 종류에도 없다.

후보가 둘이면 결과가 다르다. `on_retry_deferred` 가 다음 후보를 hint 로 넘긴다.
`Keeper_direct_runtime_continuation.defer`(`keeper_direct_runtime_continuation.ml:124`)가
작업을 `Queued` 로 되돌리고, 같은 작업 id 가 체크포인트에서 다음 후보로 이어진다.
이 동작은 테스트가 고정한다:
`test/keeper_chat_operations/test_keeper_direct_runtime_continuation.ml`,
`test/test_keeper_direct_runtime_resume.ml`.

## 2. 왜 지금 설계가 이 경우를 뺐나

RFC `provider-path-rest` §5 는 suffix 가 없는 실패를 일부러 뺐다.

> suffix 가 없으면 cadence 를 유지한다. 그때 곧바로 다시 돌리면 방금 실패한 경로에
> 같은 입력을 되풀이한다. 끝을 만드는 장치가 없다.

같은 RFC §4 의 3번은 이어가기가 끝나는 이유를 "suffix 길이가 줄어든다" 로 들었다.
같은 경로로 이어가면 suffix 가 줄지 않으므로 그 논증이 성립하지 않는다.

이 RFC 는 끝을 만드는 다른 근거를 댄다. 횟수를 세는 게이트는 쓰지 않는다.

## 3. 바꾸는 것

### 3.1 규칙

> 마지막 후보의 시도가 시간이 지나면 풀리는 이유로 실패했고, 그 시도가 체크포인트를
> 새로 남겼으면, 같은 작업을 같은 경로에서 그 경로의 쉼이 끝난 뒤 체크포인트부터 잇는다.

`keeper_turn_driver.ml:842` 의 `else if is_last` 가지에서, 조건을 만족하면 hint 를 넘긴다.

```ocaml
on_retry_deferred
  { assignment_id = runtime_id
  ; failed_runtime_id = attempt_runtime_id
  ; next_runtime_id = attempt_runtime_id   (* 같은 경로 *)
  ; later_runtime_ids = []
  ; failure = error
  }
```

그 뒤는 지금 있는 장치가 그대로 받는다.

- 채팅 lane: `Keeper_turn` 이 hint 를 보고 `Keeper_direct_runtime_continuation.defer` 로
  작업을 미룬다. 작업은 `Queued` 로 남는다.
- heartbeat lane: `next_dispatch_after_failure` 가 hint 를 읽는다.

hint 의 모양은 바꾸지 않는다. `next_runtime_id = failed_runtime_id` 인 hint 가 새로 생길 뿐이다.

### 3.2 끝나는 이유

1. 이어가기 조건인 "진전" 은 실패한 시도의 `checkpoint_stage_observed` 다.
2. 이 값은 턴을 보낼 때마다 `false` 로 새로 만든다(`keeper_turn_driver.ml:1338`).
   켜는 곳은 체크포인트 sink 하나다(`keeper_turn_driver_try_provider.ml:295`, `:985`).
3. agent_core 는 끝난 일 뒤에만 체크포인트를 남긴다.
   - `After_assistant_collected`: 모델 응답을 다 받은 뒤 (`packages/agent_core/lib/pipeline/pipeline.ml:321`)
   - `After_tool_results_appended`: 도구 결과를 붙인 뒤 (`pipeline.ml:470`). 재개할 때
     `Pipeline_terminal_resume.replay` 도 이미 실행된 도구의 결과를 기록하며 이 체크포인트를 남긴다.
   - `After_context_injection`: 도구 결과 뒤 컨텍스트를 주입한 다음 (`pipeline.ml:512`)
   - `After_rejected_response_dropped`: 받은 응답을 accept 가 거부한 뒤. 이 경우의 실패는
     3.3 의 대상이 아니다.
   체크포인트에서 복원하는 것만으로는 체크포인트가 새로 생기지 않는다.
4. 그래서 이어가기 k 번에는, 서로 다른 시도 k 개가 각각 끝난 모델 응답이나 도구 결과를
   하나 이상 남겨야 한다. 이어가기 횟수는 그 작업이 실제로 받은 모델 응답과 실행한 도구
   묶음의 수를 넘지 못한다.
5. 매번 실패하는 경로에서는 첫 이어가기가 진전 없이 실패한다. 그 실패는 hint 를 만들지
   않고, 작업은 지금처럼 `Failed` 로 끝난다.

횟수·예산을 세는 상태는 추가하지 않는다. 새 저장 상태도 없다.

### 3.3 대상이 되는 실패

`Keeper_runtime_failure_route` 의 분류를 그대로 쓴다. 같은 경로에서 시간이 지나면 풀리는
종류만 대상이다.

| route | 대상 | 이유 |
|---|---|---|
| `Retry_after_observed Rate_limited` | 예 | 분 단위로 풀리는 제한 |
| `Retry_after_observed Capacity_backpressure` | 예 | 공급자나 masc 슬롯의 일시 과부하 |
| `Retry_after_observed Server_error` | 예 | 5xx, 공급자 일시 장애 |
| `Retry_after_observed Network_transient` | 예 | 전송 계층 끊김 |
| `Retry_after_observed Provider_timeout` | 예 | 마감 초과 |
| `Retry_after_observed Hard_quota` | 아니오 | 계정 잔액·한도 소진. 결제나 리셋 전에는 같은 경로에서 풀리지 않는다 |
| `Rotate_now _` | 아니오 | 자격 증명·모델 없음·반복 생성은 이 경로의 속성이라 기다려도 같다 |
| `Exhausted_visible_alive _` | 아니오 | 요청 자체의 문제, context 초과, 설정 불일치, 통합 결함 |

판정 함수는 `Keeper_runtime_failure_route` 에 두고 `retry_class` 전체를 빠짐없이 match 한다.
`retry_class` 에 새 constructor 가 생기면 컴파일러가 이 판단을 요구한다.

### 3.4 쉬는 시간

같은 경로로 잇는 대기는 그 실패의 `path_rest_sec`
(`lib/keeper_runtime/keeper_runtime_failure_route.ml:327`)을 쓴다.

- 공급자가 시간을 말했으면 그 값(최소 1초)
- 말하지 않았으면 `rate_limit_backoff_floor_sec` (60초)
- 모두 `rate_limit_backoff_cap_sec` (900초)로 자른다

`next_dispatch_after_failure`(`keeper_turn_driver.ml:342`)에 경우 하나를 더한다.
`next_runtime_id = failed_runtime_id` 인 hint 이면, 실패한 경로가 풀리는 시각과
`deferred_lane_rest` 가 계산한 시각 중 늦은 쪽까지 `Wait_until { wait = Path_release }` 한다.
지금 표에서는 5xx·끊김·timeout 에 경로별 쉼 저장소가 없다. 그래서 이 경우를 따로 두지 않으면
`Dispatch_now` 로 곧바로 다시 부른다.

이렇게 하면 `provider-path-rest` 의 성질 P, "쉬기 시작한 경로에 풀리기 전에 다시 보내지
않는다" 가 같은 경로로 잇는 경우에도 유지된다.

### 3.5 구현 범위

- `lib/keeper_runtime/keeper_runtime_failure_route.{ml,mli}`:
  `retry_class_resumes_on_same_path : retry_class -> bool` (3.3 표, 빠짐없는 match).
- `lib/keeper/keeper_turn_driver.{ml,mli}`
  - 후보 순회(`attempt_runtime_candidates`)가 실패한 시도의 진전 여부를 받는다.
    지금 `allow_retry` 가 `same_run_retry_allowed` 로 같은 사실을 읽고 있으니, 그 원천
    `checkpoint_stage_observed` 를 이름 붙은 인자로 넘긴다.
  - `else if is_last` 가지에서 3.1 의 hint 를 넘긴다.
  - `next_dispatch_after_failure` 에 3.4 의 경우를 더한다.
- `lib/keeper/keeper_direct_runtime_continuation.ml`: `retry_not_before` 가 이미
  `next_dispatch_after_failure` 를 읽는다. 바꿀 것이 없는지 테스트로 확인한다.
- 테스트: 7절.

## 4. Phase 2: 중간에 끊긴 생성의 분류

1.1 의 실제 실패는 오류 객체가 없는 `finish_reason: "error"` 였다. #36922 뒤에는 이 실패가
`ProviderReportedError` 가 되고, route 는 `Exhausted_visible_alive Provider_integration` 이다.
3.3 에 따르면 대상이 아니다. 끝 표시 없이 닫힌 SSE(`Provider_wire_error Incomplete_stream`)도
같은 route 로 간다.

그러니 Phase 1 만으로는 1.1 에서 본 바로 그 실패가 여전히 작업을 끝낸다. 대상이 되는 건 공급자가
상태를 밝힌 스트림 중간 오류(429·5xx), 소켓 끊김, timeout 이다.

Phase 2 는 "공급자가 요청을 받은 뒤 생성을 끊었다" 는 사실에 타입을 준다.

- 후보 이름: `Http_client.Provider_interrupted`
- 대상 1: 상태 없이 `finish_reason: "error"` 로 끝난 choice. OpenRouter 는 이 값을 "공급자가 실패했다"
  로 정규화한다(openrouter.ai/docs/api-reference/overview).
- 대상 2: 끝 표시 없이 닫힌 스트림
- route 는 `Retry_after_observed Network_transient` 로 보낸다.

따로 설계하는 이유는 두 가지다.

- `Provider_reported_error` 의 문서는 "AGENT_CORE 는 여기서 재시도 의미를 추론하지 않는다"
  이다. 이 원칙을 어느 사실에 대해 바꾸는지 한 번에 하나씩 정해야 한다.
- 끝 표시 없는 스트림에는 공급자나 프록시의 크기 제한처럼 매번 같은 자리에서 끊기는 경우가
  섞일 수 있다. 3.2 의 진전 조건이 무한 반복은 막지만, 그런 끊김이 얼마나 있는지는 재 보지 않았다.

## 5. `provider-path-rest` 와의 관계

- 3.1 표에 한 줄을 더한다: "suffix 가 없고 마지막 시도가 진전을 남겼고 route 가 3.3 대상이면,
  실패한 경로가 풀릴 때 같은 경로로 잇는다."
- §4 의 끝나는 이유 3번 옆에, 같은 경로로 잇는 경우는 진전 조건이 끝을 만든다고 적는다.
- 성질 P 는 3.4 로 유지된다.

## 6. 고르지 않은 대안

- **최대 재시도 횟수**: 누적 횟수를 세는 게이트다. `provider-path-rest` 도 constitution 도
  피하는 모양이다. 숫자를 정할 근거도 없다.
- **쉼 없이 곧바로 재시도**: 성질 P 를 깬다. 공급자가 내려간 동안 같은 호출을 되풀이한다.
- **벤치 설정에서 같은 모델을 런타임 id 여러 개로 복제**: 제품 동작을 바꾸지 않고 기존
  failover 를 속여 쓰는 설정이다. 후보 수보다 한 번 적게만 견디고, 실제 사용자는 이 설정을
  쓰지 않는다.
- **벤치 어댑터가 실패한 작업에 "계속" 메시지를 다시 보내기**: 태스크 조건을 바꾼다.
  harbor 기본 에이전트와 비교할 수 없게 된다.

## 7. 검증

- 판정 함수: `retry_class` 전체에 대한 표 테스트.
- 후보 순회
  - 마지막 후보 + 대상 route + 진전 있음 → 같은 경로 hint
  - 진전 없음 → hint 없음
  - 대상이 아닌 route → hint 없음
  - 후보가 둘 이상일 때의 기존 hint 는 그대로
- `next_dispatch_after_failure`
  - 같은 경로 hint + 5xx → 60초 `Wait_until Path_release`
  - 429 + 힌트 5초 → 5초
  - 경로 저장소의 쉼이 더 길면 그 시각
- 채팅 작업 (기존 재개 테스트 옆)
  - 마지막 후보가 진전 뒤 502 → 작업 `Queued`, 같은 id 로 같은 경로에서 재개해 완료
  - 재개한 시도가 진전 없이 다시 502 → `Failed`
- 벤치 실측: 같은 DeepSeek 스모크를 다시 돌린다. 스트림 중간 5xx 뒤 에피소드가 이어지는지,
  `keepers_stopped`·`interrupted` 와 함께 기록한다. 1.1 의 상태 없는 끊김은 Phase 2 전까지
  그대로 실패한다.

## 8. 확인 못 한 것

- OpenRouter 연결 끊김이 실제로 어느 모양(소켓 오류, 끝 표시 없는 SSE, 오류 finish)으로
  오는지 비율을 모른다. 1.1 은 한 건이다.
- 재개할 때마다 체크포인트를 다시 읽고 컨텍스트를 다시 보내는 비용(토큰·지연)을 재지 않았다.
- `After_rejected_response_dropped` 이후 같은 시도에서 3.3 대상 실패가 나는 순서가 가능한지
  확인하지 않았다. 가능하면 거부된 응답도 진전으로 센다.
