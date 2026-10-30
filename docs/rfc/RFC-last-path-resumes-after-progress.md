---
rfc: "last-path-resumes-after-progress"
title: "마지막 경로가 잠깐 실패해도, 도구를 실행한 채팅 작업은 같은 경로에서 이어서 돈다"
status: Draft
created: 2026-09-17
updated: 2026-09-18
author: claude
supersedes: []
superseded_by: null
related: ["provider-path-rest", "0458"]
---

# RFC: 마지막 경로의 일시 실패 뒤, 진전을 남긴 채팅 작업은 이어서 돈다 (last-path-resumes-after-progress)

## 0. 요약

런타임 후보가 하나뿐인 keeper 는 429·5xx·연결 끊김 한 번에 채팅 작업을 잃는다.
후보가 둘 이상이면 같은 실패에도 작업이 체크포인트에서 다음 후보로 이어진다.
차이는 **다음 후보가 있느냐** 하나뿐이다.

이 RFC 는 채팅 작업(`masc_keeper_msg` 가 만드는 direct operation)에 한해, 마지막 후보도
같은 경로에서 이어 가게 한다. 조건은 셋이다.

- 실패가 시간이 지나면 풀리는 종류다 (3.3).
- 실패한 시도가 도구를 실행해 결과를 체크포인트에 남겼다. 즉 진전이 있었다 (3.2).
- 앞선 후보의 context 초과가 이 턴의 실패를 대표하지 않는다 (3.1).

이어가기는 같은 작업이 최신 체크포인트에서 시작한다. 공급자가 풀리는 시각을 말해 경로에 쉼이
기록됐으면 그 시각에, 아니면 곧바로다. 새 쉼은 만들지 않는다(RFC-0458 §3.4).
횟수를 세는 장치는 두지 않는다. 이어갈 때마다 새로 실행한 도구 결과가 필요하므로, 이어가기
횟수는 작업이 실제로 실행한 도구 묶음의 수를 넘지 못한다.

heartbeat lane 은 바꾸지 않는다 (3.5).

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
| 채팅 작업 미루기 | `lib/keeper/keeper_turn.ml:1004` (hint 가 있을 때) | hint 가 없어 `:1040` 의 `dispatch_failed ~class_:Runtime_failure` |
| 작업 상태 | `lib/server/server_routes_http_keeper_stream.ml:1606` | `Turn_failed` → `Keeper_chat_operation.Turn_exception` |

429(`Rate_limited`), 5xx(`Server_error`), 소켓 끊김(`Network_transient`),
유휴 timeout(`Provider_timeout`) 모두 이 경로로 간다. 같은 후보를 다시 부르는 경로가 있긴 하다.
carried range 축출(`keeper_turn_driver_try_provider.ml:1710`–`1729`)과 MaxTokens 뒤
no-thinking 이어가기(`:1987`–`1999`)다. 하지만 둘 다 이 실패들을 다루지 않는다.

후보가 둘이면 결과가 다르다. `on_retry_deferred` 가 다음 후보를 hint 로 넘긴다.
`Keeper_direct_runtime_continuation.defer`(`keeper_direct_runtime_continuation.ml:124`)가
작업을 `Queued` 로 되돌린다. 재개할 때는 `load`(`:53`–`55`)가 최신 체크포인트를 읽어,
같은 작업 id 가 거기서 다음 후보로 이어진다. 이 동작은 테스트가 고정한다:
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

> 채팅 작업의 마지막 후보 시도가 3.3 의 이유로 실패했고, 그 시도가 도구 결과를 체크포인트에
> 새로 남겼으면, 같은 작업을 같은 경로에서 최신 체크포인트부터 잇는다. 그 경로에 공급자가 말한
> 쉼이 기록돼 있으면 그 쉼이 끝난 뒤다.

`keeper_turn_driver.ml:842` 의 `else if is_last` 가지에서 아래를 모두 만족하면 hint 를 넘긴다.

- 후보 순회를 부른 쪽이 체크포인트에서 이어 가는 lane 이다 (3.5).
- `observed_overflow` 가 `None` 이다. 앞선 후보가 context 를 넘겼으면 순회는 그 오류로 끝나고
  (`:848`–`850`), 그 복구는 context 쪽 일이다. 같은 경로로 미루면 그 복구를 건너뛴다.
- **마지막 후보 자신의 오류**로 계산한 route 가 3.3 대상이다.
- 그 시도에서 3.2 의 진전이 관측됐다.

```ocaml
on_retry_deferred
  { assignment_id = runtime_id
  ; failed_runtime_id = attempt_runtime_id
  ; next_runtime_id = attempt_runtime_id   (* 같은 경로 *)
  ; later_runtime_ids = []
  ; failure = error                        (* 마지막 후보 자신의 오류 *)
  }
```

hint 의 모양은 바꾸지 않는다. `next_runtime_id = failed_runtime_id` 인 hint 가 새로 생길 뿐이다.
이런 hint 를 거부하거나 합치는 곳은 없다. 작업에 재시도를 기록하는 `runtime_retry`
(`lib/keeper_chat_operations/keeper_semantic_execution.ml:44`)는 빈 id 만 막는다.

### 3.2 진전과 끝나는 이유

**진전의 정의**: 실패한 시도에서 `After_tool_results_appended` 나 `After_context_injection`
체크포인트가 저장됐다. 둘 다 도구를 실행한 뒤에만 나온다
(`packages/agent_core/lib/pipeline/pipeline.ml:470`, `:511`–`515`).

`After_assistant_collected` 는 진전으로 세지 않는다.
- 이 체크포인트는 keeper 의 accept 판단보다 먼저 저장된다(`pipeline.ml:321`–`326`).
- accept 가 거부한 응답도 이 체크포인트에 남는다. MaxTokens 뒤 no-thinking 이어가기
  (`keeper_turn_driver_try_provider.ml:1987`–`1999`)는 잘라낸 체크포인트를 저장하지 않는다.
  그래서 거부된 응답이 든 체크포인트가 최신으로 남는다.
- 이걸 진전으로 세면 이런 반복이 생긴다: 응답이 거부된다 → 이어가기 호출이 429 를 받는다 →
  거부된 응답이 든 체크포인트에서 재개한다 → 다시 MaxTokens → … 끝이 없다.

지금의 `checkpoint_stage_observed` 는 모든 stage 에서 켜지므로 이 목적에 쓰지 않는다.
체크포인트 sink wrapper(`keeper_turn_driver_try_provider.ml:984`–`985`)가 stage 를 빠짐없이
match 해, 도구를 실행한 stage 일 때만 새 관측값을 켠다. 이 관측값은 dispatch 마다 새로 만든다.
`checkpoint_stage` 에 constructor 가 새로 생기면 컴파일러가 판단을 요구한다.

**끝나는 이유**:

1. 채팅 작업은 재개할 때 최신 체크포인트에서 이어 간다(`keeper_direct_runtime_continuation.ml:53`–`55`).
   이미 실행한 도구는 다시 실행하지 않는다.
2. 그러니 이어가기 k 번에는, 서로 다른 시도 k 개가 각각 그 전 재개 지점 뒤에 도구를 실행해야
   한다. 이어가기 횟수는 작업이 실제로 실행한 도구 묶음의 수를 넘지 못한다.
3. 체크포인트에서 복원하는 것만으로는 이 stage 가 새로 저장되지 않는다.
   - `load` 는 keeper 쪽 저장만 한다(`:84`).
   - `Pipeline_terminal_resume.replay` 는 재개할 때 `After_tool_results_appended` 를 저장할 수
     있지만, masc 에서는 불리지 않는다. `with_resume_once` 는 `execution_store` 가 있을 때만
     묶이고(`packages/agent_core/lib/agent/agent_execution_runner.ml:381`), `lib/` 에는
     `execution_store` 를 넘기는 곳이 없다. 이 경로를 연결하는 변경은 이 논증을 다시 봐야 한다.
     그 경우에도 replay 가 기록하는 것은 앞 시도에서 실행하고 저장하지 못한 도구 결과라,
     실행 한 번에 한 번뿐이다.
4. 매번 실패하는 경로에서는 첫 이어가기가 도구를 실행하기 전에 실패한다. 그 실패는 hint 를
   만들지 않고, 작업은 지금처럼 `Failed` 로 끝난다.

횟수·예산을 세는 상태는 추가하지 않는다. 새 저장 상태도 없다.

### 3.3 대상이 되는 실패

`Keeper_runtime_failure_route.route` 를 읽는다. `retry_class` 만으로는 부족하다.
판단에 공급자가 밝힌 대기 시간과 `Empty_completion.stop_reason` 이 필요하기 때문이다.

| route | 대상 | 이유 |
|---|---|---|
| `Retry_after_observed { Rate_limited; retry_after }` | 예 | 공급자가 시간이 지나면 푸는 제한. 주간 한도를 429 로 보내는 공급자도 있다(`provider-path-rest` §4). 그 경우 진전 없이 한 번 더 실패하고 끝난다 |
| `Retry_after_observed { Capacity_backpressure; _ }` | 예 | 공급자나 masc 슬롯의 일시 과부하 |
| `Retry_after_observed { Server_error; _ }` | 예 | 5xx, 공급자 일시 장애 |
| `Retry_after_observed { Empty_completion { stop_reason }; _ }`에서 `EndTurn`, `MaxTokens`, `StopSequence` | 예 | 저장된 도구 결과를 버리지 않고 체크포인트에서 한 번 재개한다. 다시 빈 응답이 오면 새 도구 결과가 없으므로 다음 재개는 성립하지 않는다 |
| `Retry_after_observed { Empty_completion { stop_reason }; _ }`에서 `Refusal`, `ContentFilter`, `RepetitionTruncation`, `StopToolUse`, `PauseTurn`, `Compaction`, `ContextWindowExceeded`, `UnmatchedToolCalls`, `Unknown _` | 아니오 | 앞의 세 사유는 같은 입력에서 같은 결과가 난다. 나머지는 provider 응답을 이어 보내거나 context·tool protocol을 별도로 복구해야 하며, 빈 응답 오류에는 그 복구에 필요한 내용이 없다 |
| `Retry_after_observed { Network_transient; _ }` | 예 | 전송 계층 끊김 |
| `Retry_after_observed { Provider_timeout; _ }` | 예 | 마감 초과 |
| `Retry_after_observed { Hard_quota; retry_after = Some _ }` | 예 | 공급자가 리셋 시각을 말했다. `path_rest_sec` 과 `note_quota` 도 이 시각을 쓴다 |
| `Retry_after_observed { Hard_quota; retry_after = None }` | 아니오 | 리셋을 모른다. 결제 전에는 풀리지 않을 수 있다 |
| `Rotate_now _` | 아니오 | 자격 증명·모델 없음·반복 생성은 이 경로의 속성이라 기다려도 같다 |
| `Exhausted_visible_alive _` | 아니오 | 요청 자체의 문제, context 초과, 설정 불일치, 통합 결함 |

판정 함수는 `Keeper_runtime_failure_route` 에 둔다.
`route_resumes_on_same_path : route -> bool` 이고, route 와 `retry_class` 를
빠짐없이 match 한다. 대기 시간은 판정에 쓰지 않는다(3.4).

### 3.4 쉬는 시간

같은 경로로 잇는 작업에 새 쉼을 만들지 않는다. RFC-0458 §3.4 의 운영자 결정(2026-09-17)이
"숫자로 된 쉼을 새로 만들지 않는다" 이고, 5xx·끊김·timeout 은 쉼이 아니라 실패 증거만 남긴다.

기다림은 이미 있는 갈래가 정한다. 채팅 lane 의 `retry_not_before`
(`keeper_direct_runtime_continuation.ml:107`)가 읽는 `next_dispatch_after_failure`
(`lib/keeper/keeper_turn_driver.ml:394`)는 hint 가 있으면 route 와 상관없이
`deferred_lane_rest ~now hint` 를 따른다(`:408`–`420`). 같은 경로 hint 에서 그 답은 이렇다.

- 실패한 경로에 쉼이 기록돼 있다: 429 의 rate limit 증거나 quota 창(`path_rest`, `:259`).
  → `Wait_until { release_at = 그 시각; wait = Path_release }`
- 기록이 없다: 5xx·끊김·timeout, 그리고 쉼을 남기지 않은 실패.
  → `Dispatch_now`
- `Capacity_backpressure` 는 hint 와 상관없이 MASC 자신의 쉼을 기다린다(`:401`–`407`).

그래서 이 갈래는 바꾸지 않는다. 대기 시간의 상한도 판정에 넣지 않는다. 공급자가 말한 시각이
`path_rest_sec` 의 상한(`rate_limit_backoff_cap_sec`)에 잘려 그 전에 재개하면, 재개한 시도는
도구를 실행하기 전에 실패하고 3.2 에 따라 작업이 끝난다. 호출 한 번이 그 비용이다.

**성질 P 와의 관계**: `provider-path-rest` 의 P 는 "쉬기 시작한 경로에 풀리기 전에 다시 보내지
않는다" 다. 5xx·끊김·timeout 에는 RFC-0458 뒤로 쉼이 없으니 곧바로 보내도 P 를 깨지 않는다.
429·quota 의 쉼은 공유 저장소에 있고, 이 작업도 그 시각을 기다린다.

### 3.5 heartbeat lane 은 바꾸지 않는다

후보 순회는 채팅 lane(`Keeper_turn`)과 heartbeat lane(`Keeper_unified_turn_execution`)이 같이
쓴다. 같은 경로 hint 는 채팅 lane 에서만 만든다.

- 채팅 작업은 재개할 때 최신 체크포인트에서 이어 간다. 3.2 의 진전이 쌓인다.
- heartbeat 에서 실패한 사이클은 자극을 남긴다(`Batch_no_action`, `keeper_heartbeat_loop.ml:443`–`449`).
  다음 사이클은 새 턴이다. 새 턴은 첫 도구 실행으로 진전을 다시 얻는다. 그래서 진전 조건이
  반복을 끝내지 못한다.
- 게다가 지금 heartbeat 는 suffix 없는 5xx·끊김·timeout 에 cadence 를 wake 가 끊을 수 있게
  잔다(`keeper_turn_driver.ml:382`–`388`, `keeper_heartbeat_loop.ml:1526`–`1530`). 같은 경로 hint 가
  들어가면 이 cadence 대신 3.4 의 hint 갈래를 따르고, 그 답은 `Dispatch_now` 라서 남은 자극을
  쉬지 않고 다시 돌린다.

부르는 쪽이 순회에 이어가기 방식을 알린다.

```ocaml
type failure_continuation =
  | Resume_operation_checkpoint  (* Keeper_turn: 같은 작업을 최신 체크포인트에서 *)
  | Restart_cycle                (* Keeper_unified_turn_execution: 다음 사이클이 새 턴 *)
```

`Restart_cycle` 이면 같은 경로 hint 를 만들지 않는다. `provider-path-rest` §3.1 의 "두 lane 은 같은
표를 읽는다" 는 suffix 가 있는 경우에 계속 성립한다. 같은 경로 hint 는 채팅 lane 에만 생긴다.

### 3.6 적용 범위

- Agent_core 런타임만 해당한다. 공식 클라이언트 런타임(Codex, Claude Code, Antigravity)의 시도는
  체크포인트 관측값을 넘기지 않는다(`keeper_turn_driver.ml:2224` 은 Agent_core 분기뿐이다).
- 후보가 둘 이상인 lane 에서 마지막 후보까지 와서 실패하면, 재개는 `[마지막 후보]` 로 고정된다.
  앞에서 rate limit 으로 밀린 머리 후보가 그새 풀렸어도 다시 부르지 않는다. 마지막 후보가 진전
  없이 또 실패하면 작업이 끝난다. 이 경우를 머리부터 다시 걷게 할지는 범위 밖이다.

### 3.7 구현 범위

- `lib/keeper_runtime/keeper_runtime_failure_route.{ml,mli}`: `route_resumes_on_same_path` (3.3).
- `lib/keeper/keeper_turn_driver_try_provider.ml`: 도구를 실행한 stage 의 관측값 (3.2).
- `lib/keeper/keeper_turn_driver.{ml,mli}`
  - `attempt_runtime_candidates` 가 `failure_continuation` 과 진전 관측값을 받는다.
  - `else if is_last` 가지에서 3.1 의 hint 를 넘긴다.
  - `.mli` 문서의 "remaining candidates" 설명을 고친다.
- `lib/keeper/keeper_turn.ml`: `Resume_operation_checkpoint` 를 넘긴다.
- `lib/keeper/keeper_unified_turn_execution.ml`: `Restart_cycle` 을 넘긴다.
  - "deferred frozen runtime lane suffix" 로그에 `same_path` 필드를 더한다. `provider-path-rest`
    §8 의 실측은 "다른 경로가 있었는데 기다린 건수" 를 세므로, 같은 경로 hint 를 구분해야 한다.
- 테스트: 5절.

## 4. Phase 2: 중간에 끊긴 생성의 분류

1.1 의 실제 실패는 오류 객체가 없는 `finish_reason: "error"` 였다. #36922 뒤에는 이 실패가
`ProviderReportedError` 가 되고, route 는 `Exhausted_visible_alive Provider_integration` 이다.
3.3 에 따르면 대상이 아니다. 끝 표시 없이 닫힌 SSE(`Provider_wire_error Incomplete_stream`,
`complete_stream_error.ml:196`–`201`)도 같은 route 로 간다.

그러니 Phase 1 만으로는 1.1 에서 본 바로 그 실패가 여전히 작업을 끝낸다. Phase 1 로 이어지는 건
공급자가 429·5xx 를 밝힌 스트림 중간 오류, 소켓 끊김, timeout 이다.

Phase 2 는 "공급자가 요청을 받은 뒤 생성을 끊었다" 는 사실에 타입을 준다.

- 후보 이름: `Http_client.Provider_interrupted`
- 대상 1: 상태 없이 `finish_reason: "error"` 로 끝난 choice. OpenRouter 는 이 값을 "공급자가 실패했다"
  로 정규화한다(openrouter.ai/docs/api-reference/overview). errors 문서가 드는 스트림 중간 오류의
  원인에는 연결 끊김, timeout, 출력 중 토큰 한도, 출력 콘텐츠 필터, 과부하가 섞여 있다. 그래서
  상태도 `metadata.error_type` 도 없는 이 값은 "시간이 지나면 풀린다" 고 단정할 수 없다.
- 대상 2: 끝 표시 없이 닫힌 스트림
- route 는 `Retry_after_observed Network_transient` 로 보내는 안을 검토한다.

따로 설계하는 이유는 세 가지다.

- `Provider_reported_error` 의 문서는 "AGENT_CORE 는 여기서 재시도 의미를 추론하지 않는다"
  이다. 이 원칙을 어느 사실에 대해 바꾸는지 한 번에 하나씩 정해야 한다.
- 위 원인 가운데 토큰 한도와 콘텐츠 필터는 기다려도 같다. 3.2 의 진전 조건 때문에 한 번 더
  실패하고 끝나지만, 그 비용을 받아들일지는 따로 정한다.
- 끝 표시 없는 스트림에는 공급자나 프록시의 크기 제한처럼 매번 같은 자리에서 끊기는 경우가
  섞일 수 있다. 얼마나 있는지는 재 보지 않았다.

## 5. `provider-path-rest` 와의 관계

- §3.1 표에 한 줄을 더한다: "채팅 lane, suffix 없음, 마지막 시도가 도구를 실행한 뒤 3.3 대상
  route 로 실패 → 실패한 경로가 풀릴 때 같은 경로로 잇는다."
- §4.2 의 전제 "suffix 에는 실패한 경로가 들어 있지 않다" 는 같은 경로 hint 에서 성립하지 않는다.
  그래도 P 는 지켜진다. 이 hint 의 기다림은 경로에 기록된 쉼이 정한다(3.4).
- §4.3 의 끝나는 이유 옆에, 같은 경로로 잇는 경우는 3.2 의 진전 조건이 끝을 만든다고 적는다.

RFC-0458 과의 관계: §3.4 의 실패 증거는 걷는 순서만 바꾼다. 후보가 하나면 순서가 바뀌어도 같은
후보다. 이 RFC 는 그 실패로 작업을 잃지 않게 할 뿐, 쉼이나 순서 규칙을 더하지 않는다.

## 6. 고르지 않은 대안

- **최대 재시도 횟수**: 누적 횟수를 세는 게이트다. `provider-path-rest` 도 constitution 도
  피하는 모양이다. 숫자를 정할 근거도 없다.
- **모든 체크포인트를 진전으로 세기**: 3.2 의 거부된 응답 반복을 막지 못한다.
- **heartbeat lane 에도 적용**: 3.5 의 이유로 끝이 없다.
- **5xx·끊김·timeout 에 경로 쉼(예: 60초 최소값) 두기**: RFC-0458 §3.4 의 운영자 결정과 어긋난다.
  곧바로 재개해서 생기는 비용, 곧 짧은 장애 중 재개한 시도가 도구 실행 전에 실패해 작업이 끝나는
  경우는 7 의 벤치 실측으로 잰다. 문제라고 나오면 RFC-0458 §5 처럼 증거와 함께 쉼을 더한다.
- **벤치 설정에서 같은 모델을 런타임 id 여러 개로 복제**: 제품 동작을 바꾸지 않고 기존
  failover 를 속여 쓰는 설정이다. 후보 수보다 한 번 적게만 견디고, 실제 사용자는 이 설정을
  쓰지 않는다.
- **벤치 어댑터가 실패한 작업에 "계속" 메시지를 다시 보내기**: 태스크 조건을 바꾼다.
  harbor 기본 에이전트와 비교할 수 없게 된다.

## 7. 검증

- `route_resumes_on_same_path`: route 전체에 대한 표 테스트. 리셋 시각이 있는/없는 `Hard_quota` 를
  포함한다.
- 진전 관측: stage 마다 관측값이 켜지는지. `After_assistant_collected` 만 저장된 시도는 꺼져 있다.
- 후보 순회
  - `Resume_operation_checkpoint` + 마지막 후보 + 대상 route + 도구 실행 → 같은 경로 hint
  - 도구 실행 없음, 응답만 수집 → hint 없음
  - `Restart_cycle` → hint 없음
  - `observed_overflow` 가 있으면 → hint 없음
  - 대상 아닌 route → hint 없음
  - 후보가 둘 이상일 때의 기존 hint 는 그대로
  - 기존 `test_single_candidate_checkpoint_failure_has_no_hint`
    (`test/test_keeper_turn_driver_failover.ml:3721`)는 `allow_retry=false` 인 네트워크 오류에서
    hint 가 없다고 고정한다. `Restart_cycle` 경우로 남기고, `Resume_operation_checkpoint` 경우를
    새로 둔다.
- `next_dispatch_after_failure` (코드는 그대로, 같은 경로 hint 에서의 답을 고정)
  - 같은 경로 hint + 5xx → `Dispatch_now`
  - 같은 경로 hint + 그 경로에 기록된 429 쉼 → 그 시각까지 `Wait_until Path_release`
- 채팅 작업 (기존 재개 테스트 옆)
  - 마지막 후보가 도구 실행 뒤 502 → 작업 `Queued`, 같은 id 로 같은 경로에서 재개해 완료
  - 재개한 시도가 도구 실행 전에 다시 502 → `Failed`
  - 응답이 거부된 뒤 no-thinking 이어가기가 429 → `Failed` (hint 없음)
- 벤치 실측: 같은 DeepSeek 스모크를 다시 돌려, 스트림 중간 5xx 뒤 에피소드가 이어지는지 기록한다.
  곧바로 재개한 시도가 도구 실행 전에 다시 실패해 끝난 작업 수도 센다(6 의 비용).
  1.1 의 상태 없는 끊김은 Phase 2 전까지 그대로 실패한다.

## 8. 확인 못 한 것

- OpenRouter 연결 끊김이 실제로 어느 모양(소켓 오류, 끝 표시 없는 SSE, 오류 finish)으로
  오는지 비율을 모른다. 1.1 은 한 건이다.
- 재개할 때마다 체크포인트를 다시 읽고 컨텍스트를 다시 보내는 비용(토큰·지연)을 재지 않았다.
- 짧은 장애가 얼마나 이어지는지, 곧바로 재개한 시도가 그 안에 걸리는 비율을 모른다.
- heartbeat 의 새 사이클이 실패한 턴의 도구 결과를 history 에 얼마나 담는지(3.5 의 "새 턴" 이 일을
  처음부터 다시 하는지)는 코드로 끝까지 따라가지 않았다. 3.5 의 결정은 wake 대기 방식이 바뀌는
  문제만으로도 성립한다.
