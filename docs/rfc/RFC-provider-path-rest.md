---
rfc: "provider-path-rest"
title: "사용량 제한은 그 경로만 쉬게 하고, Keeper 는 다음에 보낼 경로의 쉼만 기다린다"
status: Draft
created: 2026-09-15
updated: 2026-09-15
author: claude
supersedes: []
superseded_by: null
related: ["0433", "0370"]
---

# RFC: 사용량 제한은 그 경로만 쉬게 한다 (provider-path-rest)

## 0. 요약

지금은 한 경로(runtime 후보)가 rate limit 이나 quota 소진으로 실패하면 Keeper 전체가
600초를 쉰다. 그동안 예약 wake 가 와도 턴이 뜨지 않는다. 그런데 턴 드라이버는 그 순간
이미 쉬지 않는 다른 경로를 다음 턴용으로 골라 두었다. heartbeat 가 그 선택을 읽지 않는다.

이 RFC 는 **누가 쉬는가**를 바로잡는다. 백오프를 없애거나 줄이는 일이 아니다.

- 쉼은 제한을 받은 경로의 것이다. 그 사실은 이미 경로별 저장소 두 곳에 기록된다.
- Keeper 는 **다음에 보낼 경로**가 쉬는 동안만 기다린다. 다음 경로가 쉬지 않으면
  기다리지 않고 남은 입력을 그 경로로 잇는다.
- 다음에 보낼 경로가 쉬면, 다음 턴이 쉬지 않는 경로로 시작할 수 있는 가장 이른 시각까지
  기다린다. 그동안 wake 는 잠을 끊지 못한다(#34653 보장 유지).
- 쉬는 길이는 cadence 에서 뗀다.

## 1. 지금 동작 (2026-09-15 실측, #36583)

### 1.1 wake 가 턴이 되기까지

keeper 13명, 약 02:00Z~08:50Z, `schedule_due` 62건. wake 도착은 event queue
disposition 의 `source_arrived_at`, 소비한 턴은 `raw-traces` 의 `run_started` 로 쟀다.

| wake 와 소비 턴 사이에 있던 일 | 건수 | 중앙값 | 최대 |
|---|---|---|---|
| 아무 일 없음 | 17 | 74초 | 854초 |
| 앞 턴이 도는 중 | 16 | 182초 | 1,886초 |
| rate limit 실패 (서버 멈춤 없음) | 11 | 928초 | 2,936초 |
| 서버 멈춤 | 15 | 2,094초 | 6,018초 |

rate limit 이 끼면 11건 모두 392초를 넘었다. 같은 서버 세대 안에서 rate limit 으로 끝난
턴 뒤 다음 턴까지 39건의 중앙값은 683초였다. 성공한 턴 뒤는 390건 중앙값 80초였다.

### 1.2 쉬는 동안 다른 경로가 있었나

서버 로그 두 개(`masc-server-restart-20260915-context.log`, `masc-server-56516.log`)에서
`rate-limited failure route; backing off next cycle by 600s` 13건을 바로 앞의
`keeper cycle FAILED` 줄과 짝지었다.

| 실패 줄의 `deferred_next_runtime` | 건수 | 내용 |
|---|---|---|
| 다른 경로 (`ollama_cloud.ollama-cloud-deepseek-v4-1-flash`) | 6 | glm-coding 이 durable progress 뒤 429. 드라이버가 deepseek 를 다음 경로로 넘겼는데 Keeper 가 600초 쉼 |
| `none` | 7 | 이 턴에서 lane 후보를 모두 시도함. deepseek 는 timeout·반복 생성, kimi 는 주간 한도(AuthError), 마지막 glm 이 429 |

analyst 15:29:15 KST 로그가 한 턴에 모든 사실을 보여 준다.

```
same-run runtime retry deferred after durable run progress (checkpoint_observed=true)
deferred frozen runtime lane suffix after checkpoint failed_runtime=glm-coding.glm-5.3-flash next_runtime=ollama_cloud.ollama-cloud-deepseek-v4-1-flash remaining=2 reason=rate_limit
keeper cycle FAILED runtime=glm-coding.glm-5.3-flash ... deferred_next_runtime=ollama_cloud.ollama-cloud-deepseek-v4-1-flash
rate-limited failure route; backing off next cycle by 600s (cadence 600s, cap 900s); stimuli queued meanwhile are served when it ends
```

다음 턴은 14분 뒤 deepseek 로 떴고 성공했다.

## 2. 기존 장치가 왜 못 했나

새 장치를 만들기 전에 이미 있는 것을 따라갔다. 좌표는 main `265dd506c1` 기준이다.

1. **같은 턴 안의 교체는 된다.** `lane_should_retry`(`lib/keeper/keeper_turn_driver.ml:247`)는
   429 를 `Runtime_attempt_fsm.should_try_next`(`lib/runtime/runtime_attempt_fsm.ml:21`)로 넘겨
   다음 후보로 간다.
2. **durable progress 뒤에는 다음 턴으로 넘긴다.** 같은 턴 재시도가 막히면 남은 후보를
   `on_retry_deferred`(`keeper_turn_driver.ml:667`)가 `deferred_runtime_lane` 으로 넘긴다.
   다음 턴은 `quota_ordered_deferred_runtime_lane`(`:170`)로 쉬는 경로를 뒤로 민다.
3. **경로별 쉼 증거도 이미 있다.** 429 는 `Runtime_lane_preference.note_rate_limit`
   (후보 행 단위, `keeper_turn_driver.ml:547`), 402·HardQuota 는 `Runtime_quota_window`
   (자격 증명 단위)에 남는다. 둘 다 keeper 사이에 공유된다.
4. **heartbeat 가 이 선택을 안 읽는다.** `failure_route_rate_limited_backoff_hint`
   (`lib/keeper/keeper_heartbeat_loop.ml:212`)는 `failure.route` 만 보고
   `failure.deferred_runtime_lane` 은 보지 않는다. rate limit 이면 무조건 Keeper 전체를
   `Serve_wakeup_after_duration` 으로 재운다(`:1524`). **배선 문제다.**
5. **쉬는 길이가 cadence 에 묶여 있다.** `retry_backoff_sec`
   (`lib/keeper_runtime/keeper_runtime_failure_route.ml:307`)는 힌트가 없으면
   `max cadence floor`, 힌트가 있어도 `max hint cadence` 다. provider 가 5초라고 해도
   cadence 600초를 잔다. `.mli` 는 "힌트가 없으면 floor" 라고 적고 있어 코드와 다르다.
6. **실패한 턴 뒤에는 cadence 를 다 잔다.** `last_wake_source`(`:1579`)는 자극을 ack 한
   사이클만 곧바로 다음 사이클로 보낸다. 실패한 턴은 ack 하지 않고, wake 신호는 그 턴을
   띄울 때 이미 썼다. 그래서 드라이버가 다음 경로를 넘겨 둔 non-rest 실패
   (lane-smith 05:12Z `Generation_repeated` → 다음 경로 glm)도 605초를 기다렸다.

## 3. 바꾸는 것 (Phase 1)

### 3.1 규칙

> Keeper 는 **다음에 보낼 경로**가 쉬는 동안만 기다린다.

실패한 사이클 뒤 다음 사이클은 아래 표로 정한다.

| 실패가 넘긴 것 | 다음 경로 상태 | 다음 사이클 |
|---|---|---|
| deferred suffix 있음 | 걷는 순서의 첫 경로가 쉬지 않음 | 기다리지 않는다. 남은 입력이 있으면 곧바로 그 suffix 로 턴을 잇는다 |
| deferred suffix 있음 | 첫 경로가 쉼 | 다음 턴의 첫 경로가 쉬지 않게 되는 가장 이른 시각까지 기다린다 (3.3 끝) |
| suffix 없음, route 가 `Rate_limited`·`Hard_quota` | 실패한 경로가 쉼 | 실패한 경로가 풀리는 시각과, assignment 를 새로 걸을 때 첫 경로가 쉬지 않게 되는 시각 중 늦은 쪽까지 기다린다 |
| 그 밖 | — | 지금처럼 cadence |

suffix 가 없다는 것은 이 입력에 쓸 수 있는 경로를 이 턴이 이미 다 썼다는 뜻이다
(마지막 후보였거나, 반복 생성으로 거부된 모델만 남았다). 그래서 이 경우는 실패한
경로의 쉼을 기다린다. 같은 입력을 방금 실패한 경로들에 곧바로 다시 보내지 않는다.
대기가 끝나면 다음 턴은 assignment 를 머리부터 새로 걷는다. 그 머리가 아직 쉬면 대기를
그 머리가 풀릴 때까지 늘린다. 예: lane [A; B] 에서 A 가 600초 힌트로 쉬고 B 가 힌트 없는
429 로 끝나면, B 의 60초 뒤 새 walk 는 여전히 A 부터 부르므로 A 가 풀릴 때까지 기다린다.

heartbeat 와 채팅 lane 은 이 표 하나(`Keeper_turn_driver.next_dispatch_after_failure`)를
같이 읽는다. 같은 실패에 두 lane 이 다르게 답하지 않는다.

### 3.2 상태 모양

새로 저장하는 상태는 없다. 경로별 사실은 기존 두 저장소가 가진다. 아래는 그 사실에서
사이클마다 다시 계산하는 파생값이다.

```ocaml
(* 한 경로의 지금 상태 — Keeper_turn_driver *)
type path_rest =
  | Path_serving
  | Path_resting of { release_at : float }

(* 실패한 사이클 뒤 다음 사이클 — Keeper_heartbeat_loop *)
type after_failure =
  | Continue_on_deferred_lane of { next_runtime_id : string }
  | Wait_for_path_release of
      { release_at : float
      ; waiting_on : string  (* 풀리기를 기다리는 runtime 또는 assignment id *)
      }

(* 두 lane 이 같이 읽는 결정 — Keeper_turn_driver *)
type next_dispatch =
  | Dispatch_now of { runtime_id : string }
  | Wait_until of { release_at : float; waiting_on : string }
```

`keepalive_turn_outcome.provider_backoff : provider_backoff option` 을
`after_failure : after_failure option` 으로 바꾼다. `None` 은 cadence 다.

### 3.3 한 경로가 언제 풀리나

| 증거 | 풀리는 시각 |
|---|---|
| 429, provider 가 시간을 말함 (`retry_after = Some h`) | `noted_at + max h 1초` |
| 429, 시간을 말하지 않음 | `noted_at + rate_limit_backoff_floor_sec` (60초) |
| 402·HardQuota, 리셋 시각을 말함 (`Until t`) | `t` |
| 402·HardQuota, 말하지 않음 (`Observed`) | 판단한 시각 + `rate_limit_backoff_cap_sec` (900초) |

모든 값은 `rate_limit_backoff_cap_sec` 로 자른다. cadence 는 어디에도 들어가지 않는다.

429 와 402 를 다르게 두는 근거는 이미 타입에 있다. `retry_class` 문서가 `Rate_limited` 를
"soft 429 throttle", `Hard_quota` 를 "account-level quota/balance exhaustion" 으로
구분한다. 분 단위로 풀리는 제한과 결제해야 풀리는 소진을 같은 길이로 쉬게 할 이유가 없다.

`Observed` 는 기록 시각을 갖지 않으므로 판단한 시각부터 센다. 기록 시각을 더하면
`note_observed_exhausted` 호출처 13곳이 바뀌어 이번 범위에서 뺐다.

실패한 턴이 방금 받은 route 는 저장소보다 새 사실이다. suffix 가 없을 때는 route 의
`retry_class` 와 힌트로 같은 표를 적용한다.

풀리는 시각과 걷는 순서는 같이 움직이지 않을 수 있다. 다음 턴은
`quota_ordered_deferred_runtime_lane` 순서로 걷고, 그 순서는 쉬는 증거가 있는 경로를
뒤로 민다. provider 가 말한 시각은 그 시각에 증거가 지워져 순서도 같이 풀린다. 말하지 않은
증거는 성공이 올 때까지 뒤로 밀린 채다. cap 에 잘린 시각도 cap 이 먼저 와서 순서보다 먼저
풀린다.

그래서 suffix 가 쉬면 대기 시각은 **걷는 순서의 첫 경로**가 정한다.

- 첫 경로가 쉬지 않으면 곧바로 잇는다.
- 첫 경로가 쉬면 그 경로가 풀리는 시각까지 기다린다. 뒤의 경로가 더 일찍 풀리고 그 시각에
  순서도 풀린다면(말한 시각, cap 안) 그 시각까지만 기다린다. 그때 그 경로가 앞으로 온다.
- 뒤의 경로가 일찍 풀려도 순서가 안 풀리면 대기를 줄이지 않는다. 줄이면 다음 턴이 아직
  쉬는 첫 경로를 부른다.

suffix 가 없으면 같은 규칙을 assignment 의 새 walk 순서(선언 순서 → quota·backpressure
강등)에 적용하고, 실패한 경로의 쉼과 비교해 늦은 쪽을 쓴다.

### 3.4 chat lane

`Keeper_direct_runtime_continuation.retry_not_before` 는 3.1 의 같은 결정을 읽는다.
suffix 의 walk 머리가 쉬지 않으면 곧바로 claim 할 수 있고, 머리가 쉬면 그 시각까지
미룬다. 지금은 실패한 경로의 쉼을 기다린다.

### 3.5 구현 범위

- `lib/keeper_runtime/keeper_runtime_failure_route.{ml,mli}`: `retry_backoff_sec` 를
  `path_rest_sec ~cap_sec ~retry_class ~retry_after_hint` 로 바꾼다. cadence 인자는 없앤다.
- `lib/keeper/keeper_turn_driver.{ml,mli}`: 3.3 표를 계산하는 `path_rest`, walk 머리 판단
  (`deferred_lane_rest`, `assignment_walk_rest`), 두 lane 이 같이 읽는
  `next_dispatch_after_failure`.
- `lib/keeper/keeper_heartbeat_loop.{ml,mli}`: `after_failure` 와 결정 함수, sleep 분기.
  `provider_backoff` 와 `failure_route_rate_limited_backoff_hint` 는 지운다. lib 안에서
  아무도 부르지 않고 테스트만 부르던 `next_keepalive_sleep_duration_sec` 도 지운다.
- `lib/keeper/keeper_direct_runtime_continuation.ml`: `retry_not_before` 가 3.4 를 따른다.
- 테스트: 8절.

## 4. #34653 보장은 그대로인가

#34653 이 막은 것: 소진된 경로를 wake 가 거듭 깨워 같은 호출을 되풀이하는 것
(2026-09-09, 41분에 실패 턴 183회, 중앙값 30초 간격).

지키는 성질을 **P** 로 부른다.

> 실패로 쉬기 시작한 경로에, 그 경로가 풀리기 전에 wake 때문에 다시 보내지 않는다.

1. **다음 경로가 쉬면 wake 가 잠을 못 끊는다.** `Wait_for_path_release` 는 rate limit·
   quota 에서 `Serve_wakeup_after_duration` 을 그대로 쓴다.
2. **이어가는 턴은 쉬는 경로에서 시작하지 않는다.** `Continue_on_deferred_lane` 은 걷는
   순서의 첫 경로가 쉬지 않을 때만 나온다. suffix 에는 실패한 경로가 들어 있지 않다.
   대기가 끝나는 시각에도 첫 경로는 쉬지 않는다(3.3 끝).
3. **이어가기는 끝이 있다.** 이어간 턴이 또 실패하면 드라이버는 그 경로를 뺀 더 짧은
   suffix 를 넘기거나 suffix 를 넘기지 않는다. 한 입력에 이어가기는 lane 후보 수를 넘지
   못한다. 누적 횟수를 세는 게이트는 없다. suffix 의 길이가 줄어드는 것이 끝을 만든다.

바뀌는 것도 있다. provider 가 시간을 말하지 않은 429 가 **유일한 경로**에서 나면 지금은
cadence(라이브 600초)를 자고, 바뀐 뒤에는 60초를 잔다. 그런 Keeper 는 그 경로를 약
10배 자주 두드린다. #34653 의 30초 중앙값보다는 두 배 이상 느리고, wake 는 여전히 잠을
끊지 못한다. 주간 한도처럼 오래가는 소진이 402·HardQuota 로 오면 900초를 잔다.
provider 가 주간 한도를 429 로 보내면(#34653 의 ollama cloud 108건) 60초 간격이 된다.
이 비용을 받아들일지가 이 RFC 에서 리뷰어가 정할 한 가지다.

## 5. 세 번째 문제를 범위에 넣나

#36583 의 세 번째 항목(실패한 턴이 못 먹은 자극이 남았는데 cadence 를 다 기다림)은
**deferred suffix 가 있을 때만** 넣는다.

- 넣는 이유: suffix 가 있으면 다음 턴은 같은 턴의 재실행이 아니라 다른 경로로의 이어가기다.
  "진전 없는 턴을 곧바로 다시 돌리지 않는다" 는 cadence 의 이유가 해당하지 않는다.
  3.1 의 첫 줄이 rest 실패와 non-rest 실패를 가리지 않고 이 경우를 덮는다.
- 빼는 부분: suffix 가 없으면 cadence 를 유지한다. 그때 곧바로 다시 돌리면 방금 실패한
  경로에 같은 입력을 되풀이한다. 끝을 만드는 장치가 없다.

## 6. Phase 2 (이번 범위 밖)

Phase 1 뒤에도 P 가 안 닿는 곳이 셋 있다. 모두 지금도 있는 동작이다.

- lane walk 는 쉬는 후보를 **뒤로 밀 뿐 부른다**(RFC-0433 의 ordering-only 결정).
  이어간 턴의 첫 경로가 실패하면 walk 가 쉬는 후보까지 갈 수 있다.
- Keeper 가 쉬지 않을 때 wake 로 시작한 턴도 첫 경로가 쉬면 그 경로를 부른다.
- 대기가 끝난 순간과 턴이 실제로 뜨는 순간 사이에 다른 keeper 가 같은 후보에 새 쉼을 적으면
  (후보 관측은 프로세스 전역이다), 다음 턴은 다시 판단하지 않고 그 후보를 부른다. 남은 입력
  없이 `Continue_on_deferred_lane` 이 나와 cadence 를 잔 뒤도 같다.

Phase 2 는 walk 가 쉬는 후보를 건너뛰고, 모두 쉬면 호출 없이 "모든 경로가 쉼" 을 typed
terminal 로 끝내게 한다. RFC-0433 의 "새 fail-closed 경로를 만들지 않는다" 와 부딪히므로
따로 설계한다.

## 7. 고르지 않은 대안

- **cap·floor 숫자만 줄이기**: 누가 쉬는가를 그대로 두고 증상만 누른다. 거부한다.
- **Phase 2 를 먼저**: walk 에 admission 을 넣는 일은 RFC-0433 을 뒤집는다. 드라이버가 이미
  고른 경로를 heartbeat 가 읽게 하는 것만으로 측정한 13건 중 6건이 풀린다.
- **cadence 유지**: 힌트가 있어도 cadence 로 올리는 것은 provider 가 말한 사실을 버리는 일이다.

## 8. 검증

- 결정 함수 테스트: 첫 경로가 쉬지 않는 suffix → 이어가기, 모두 쉬는 suffix → 순서가
  풀리는 가장 이른 시각, 순서가 안 풀리는 뒤 경로는 대기를 줄이지 않음, quota 리셋 시각,
  suffix 없는 rate limit → 실패 경로의 쉼, 새 walk 머리가 쉬면 그 머리까지, 힌트 5초 →
  5초(cadence 무관), 그 밖 → cadence.
- 채팅 lane: 쉬지 않는 머리 → 곧바로 claim, 쉬는 머리 → 풀릴 때까지.
- #34653 회귀: 유일한 경로가 쉬는 동안 결정은 `Serve_wakeup_after_duration` 대기이고,
  `interruptible_sleep` 은 그 대기 중 wakeup 을 끝까지 미룬다(기존 테스트 유지).
- 배포 뒤 실측: `rate-limited failure route` 대신 새 로그 줄의 `waiting_on` 과
  다음 턴의 runtime 을 짝지어, 다른 경로가 있었는데 기다린 건수가 0 인지 본다.

## 9. 확인 못 한 것

- 오늘 13건의 429 가 `Retry-After` 를 가졌는지 모른다. 로그에 힌트가 안 찍힌다.
  새 로그 줄에 풀리는 시각을 찍는다.
- 측정한 11건 중 suffix 가 있던 건수는 서버 로그가 없는 세대(PID 57313)에서 셀 수 없었다.
- 한 자격 증명을 나눠 쓰는 두 행은 429 를 따로 기록한다(RFC-0433). 이어간 경로가 같은
  계정이면 한 번 더 429 를 받고 suffix 가 줄어든다.
