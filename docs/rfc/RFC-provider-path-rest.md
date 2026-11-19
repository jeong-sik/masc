---
rfc: "provider-path-rest"
title: "사용량 제한은 그 경로만 쉬게 하고, Keeper 는 다음에 보낼 경로의 쉼만 기다린다"
status: Draft
created: 2026-09-15
updated: 2026-11-15
author: claude
supersedes: []
superseded_by: null
related: ["0433", "0370", "exact-lane-waits-for-a-stated-reset", "a-restarted-server-keeps-the-resets-providers-stated"]
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

### 대기의 의존성이 바뀐 경우 (2026-09-26)

대기는 실패한 dispatch의 배정·후보 순서·binding에 속한다. heartbeat는 턴 진입 전에
이 값을 한 Runtime snapshot에서 읽는다. 기존 sleep 경계에서 현재 snapshot과
비교해 배정 변경, 같은 이름의 lane 편집, credential binding 교체를 발견하면
대기를 끝내고 현재 배정으로 다시 판단한다. 이전 dispatch의 deferred suffix도
메모리와 durable 저장소에서 해제한다. 관련 없는 설정 변경은 대기를 깨지 않는다.

대기를 결정할 때 관측된 경로의 rest가 다른 실행의 성공으로 풀린 경우에도 재평가한다.
이 근거는 dispatch 결정에 함께 실어, 결정과 sleep 준비 사이에 일어난 회복도 읽는다.
저장된 rest가 없이 실패 응답만으로 정한 대기는 그 응답의 기한을 유지한다.
Board·schedule 알림과 cadence 변경은 동일 provider 대기를 조기에 끝내지 않는다.
stop은 어느 대기든 종료한다. 대기를 깨우는 동작은 Queue source를 ACK하지 않는다.

직접 채팅도 턴 진입 때 읽은 dispatch snapshot을 저장된 재시도의 관측 근거로 사용한다.
Owner는 정확히 그 재시도가 여전히 Queued일 때만 후보와 `not_before`를 함께 갱신한다.
새 배정도 쉬고 있다면 새 경로의 release 시각을 저장한다. 기존 시각만 해제해서
쉬는 경로를 조기에 부르지 않는다. 체크포인트·입력·완료된 효과·gate 의무는 유지한다.
이 관측 근거는 프로세스 안에만 존재한다. 재시작으로 근거가 사라져도 성공으로
해석하지 않고, 저장된 `not_before`를 유지한다.

Owner의 cooling 관측은 기존 sleep 경계를 사용한다. 상태가 그대로이면 전체 readiness
조회나 변경 알림을 발생시키지 않는다. 재시도 변경 또는 기한 도달 때만 drain을 깨운다.

### 쉼이 풀리면 순서도 풀린다 (2026-11-06)

시각을 말하지 않은 쉼도 3.3 표의 시각에 순서에서 풀린다. 전에는 그 경로가 성공할
때까지 뒤로 밀렸다. GLM 이 16분 뒤 돌아왔는데 Keeper 둘이 며칠을 기다리기로 한 일이
이 규칙에서 나왔다. 까닭과 치르는 값은 3.3 끝의 개정 절에 있다.

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
| suffix 없음, 여러 후보, route 가 `Rate_limited`·`Hard_quota` | 새 walk의 머리가 쉬지 않음 | 일반 실패 cadence를 유지한다. 마지막 후보의 quota로 다른 후보까지 쉬지 않는다 |
| suffix 없음, 여러 후보, route 가 `Rate_limited`·`Hard_quota` | 새 walk의 머리가 쉼 | 새 walk의 관측된 release 시각까지 기다린다 |
| suffix 없음, 단일·미해결 배정, route 가 `Rate_limited`·`Hard_quota` | 실패한 경로가 쉼 | 실패 응답과 관측된 경로의 release 중 늦은 시각까지 기다린다 |
| suffix 없음, route 가 그 밖 | 새 walk의 머리가 쉬지 않음 | 지금처럼 cadence |
| suffix 없음, route 가 그 밖 | 새 walk의 머리가 쉼 | 새 walk의 관측된 release 시각까지 기다린다. 실패 응답의 대기는 더하지 않는다 |

suffix가 없으면 이 턴의 후보 순회가 끝났다는 뜻이다. 모든 후보가 같은 이유나
같은 기한으로 쉬는 것은 아니다. 마지막 Claude 후보가 quota reset을 알려 줬더라도
앞선 HTTP·Codex 후보가 일시적인 연결 오류로 실패했다면 그 reset을 레인 전체의
대기시간으로 적용하지 않는다. 새 walk의 머리가 사용 가능하면 일반 실패 cadence로
돌아간다. 즉시 같은 입력을 반복하는 deferred continuation을 만들지는 않는다.
단일 후보와 해소할 수 없는 배정은 실패 응답 자체의 대기 근거를 유지한다.

턴의 route 는 턴이 끝난 이유다. 시도가 provider 에게 들은 말과 다를 수 있다.
Muse 처럼 효과를 볼 수 없는 lane 은 시도를 fence 로 감싸서, 구독 한도 소진으로 거절된 턴도
`Exhausted_visible_alive` 로 끝난다. 그 시도는 이미 경로에 reset 시각까지의 쉼을 적었다.
그래서 route 가 그 밖이어도 새 walk 의 머리가 쉬면 기다린다. 2026-11-05 09:51Z~16:52Z 에
경로가 하나인 Keeper 하나가 11-09 00:00Z 까지 쉬는 경로로 거절된 턴 457번을 보냈다.
턴마다 실패한 턴이 남긴 자극이 다음 턴을 곧바로 깨웠다.

heartbeat 와 채팅 lane 은 이 표 하나(`Keeper_turn_driver.next_dispatch_after_failure`)를
같이 읽는다. 같은 실패에 두 lane 이 다르게 답하지 않는다.

### 3.2 상태 모양

새로 저장하는 상태는 없다. 경로별 사실은 기존 두 저장소가 가진다. 아래는 그 사실에서
사이클마다 다시 계산하는 파생값이다.

```ocaml
(* 한 경로의 지금 상태 — Keeper_turn_driver *)
type release_basis = Stated_by_provider | Bounded_by_masc

type path_rest =
  | Path_serving
  | Path_resting of { release_at : float; release_basis : release_basis }

(* 실패한 사이클 뒤 다음 사이클 — Keeper_heartbeat_loop *)
type wait_basis = Failure_response | Observed_path_rest

type after_failure =
  | Continue_on_deferred_lane of { next_runtime_id : string }
  | Wait_for_path_release of
      { release_at : float
      ; waiting_on : string  (* 풀리기를 기다리는 runtime 또는 assignment id *)
      ; basis : wait_basis
      }

(* 두 lane 이 같이 읽는 결정 — Keeper_turn_driver *)
type next_dispatch =
  | Dispatch_now of { runtime_id : string }
  | Wait_until of
      { release_at : float; waiting_on : string; basis : wait_basis }
```

`keepalive_turn_outcome.provider_backoff : provider_backoff option` 을
`after_failure : after_failure option` 으로 바꾼다. `None` 은 cadence 다.

### 3.3 한 경로가 언제 풀리나

| 증거 | 풀리는 시각 | 시각을 정한 쪽 |
|---|---|---|
| 429, provider 가 시간을 말함 (`retry_after = Some h`) | `noted_at + max h 1초` | provider |
| 429, 시간을 말하지 않음 | `noted_at + rate_limit_backoff_floor_sec` (60초) | masc |
| 402·HardQuota, 리셋 시각을 말함 (`Until t`) | `t` | provider |
| 402·HardQuota, 말하지 않음 (`Observed`) | `noted_at + rate_limit_backoff_cap_sec` (900초) | masc |

`Until t` 에는 사용량 조회(usage read)가 찾은 리셋 시각도 들어간다. 그 시각도 provider 의
답이다.

제공자가 말한 유효한 Retry-After와 quota reset은 그대로 보존한다(#39190).
`rate_limit_backoff_cap_sec`는 시각을 말하지 않은 경우의 fallback에만 적용한다.
cadence는 어디에도 들어가지 않는다. Retry-After가 후속 요청 전 대기를 나타낸다는
[RFC 9110 §10.2.3](https://www.rfc-editor.org/rfc/rfc9110.html#section-10.2.3)을 따른다.

429 와 402 를 다르게 두는 근거는 이미 타입에 있다. `retry_class` 문서가 `Rate_limited` 를
"soft 429 throttle", `Hard_quota` 를 "account-level quota/balance exhaustion" 으로
구분한다. 분 단위로 풀리는 제한과 결제해야 풀리는 소진을 같은 길이로 쉬게 할 이유가 없다.

`Observed` 는 끝나는 시각 `rests_until` 을 들고 있다. `Runtime_quota_window` 가 관찰을
적는 순간에 cap 을 더한 값이다. 호출처는 그대로다. 같은 scope 가 다시 거절하면 다시 적은
순간부터 센다. 사용량 읽기가 "리셋 없음" 을 적은 관찰은 예외다. 그 관찰이 쉬는 동안 뒤에
온 거절은 그것을 바꾸지 않는다. 그 거절이 물을 것에 읽기가 이미 답했기 때문이다.

단일·미해결 배정의 실패 응답은 저장소에 관측이 없어도 자기 경로의 휴식 근거다.
여러 후보의 배정에서는 마지막 실패 응답 하나를 다른 후보의 휴식으로 확대하지 않는다.

**풀리는 시각에 걷는 순서도 풀린다.** 다음 턴은 `resumed_runtime_lane` 순서로 걷는다.
남긴 suffix 뒤에 lane 의 나머지 후보가 오고, 방금 실패한 후보는 그 뒤에 온다.
순서(`Runtime_candidate_standing.order`)는 위 표의 시각까지만 쉬는 경로를 뒤로 민다.
그 시각이 지나면 그 증거는 순서를 바꾸지 않는다. 그 경로에 실패 증거(RFC-0458 §3.4)가
있으면 그 규칙대로 놓이고, 없으면 선언한 자리로 돌아간다.

그래서 suffix 가 쉬면 대기 시각은 **걷는 순서에서 가장 먼저 풀리는 경로**가 정한다.

- 첫 경로가 쉬지 않으면 곧바로 잇는다.
- 첫 경로가 쉬면 걷는 순서의 경로 가운데 가장 이른 풀림까지 기다린다. 그때 그 경로가
  앞으로 온다.

suffix 가 없으면 같은 규칙을 assignment 의 새 walk 순서(선언 순서 → quota·backpressure
강등)에 적용한다. 단일·미해결 배정만 실패 응답의 쉼과 비교해 늦은 쪽을 쓴다.

`Path_resting.release_basis` 는 풀리는 시각을 정한 쪽이다. 증거가 여럿이면 가장 늦은
시각을 정한 쪽을 적는다. 완료 검증(`Verification_retry.provider_rest`)이 이 값을 읽는다.
provider 가 정한 시각이면 그 뒤에 다시 검토한다. masc 가 정한 시각이면 시간만으로는 같은
거절을 다시 만날 수 있어서 생산자가 움직여야 한다고 본다.

#### 2026-11-06 개정: "성공할 때까지" 를 지운다

전에는 시각을 말하지 않은 증거가 풀린 뒤에도 순서가 그 경로를 성공할 때까지 뒤로
밀었다. 대기 계산은 그 경로의 풀림으로 대기를 줄이지 않았다.

**무슨 일이 있었나.** 2026-11-06 06:04Z, GLM 이 1308(5시간 사용량 소진)을 HTTP 429 로
보냈다. 시간을 말하지 않은 rate limit 으로 읽혔다. 그 429 증거가 GLM 을 성공할 때까지
뒤로 묶었다. 그래서 대기는 GLM 이 풀리는 시각을 쓰지 않고 며칠 쉬는 머리를 따랐다.
wkbl-front 는 323,727초, masc-productor-owner 는 237,327초를 기다리기로 했다.
GLM 은 06:20:44Z 에 돌아왔다.

1308 을 hard quota 로 읽게 고쳐도 같은 일이 남는다. 앞서 시각을 말하지 않은 429(1302
같은 throttle)가 같은 경로에 있으면, 뒤에 사용량 조회가 리셋 시각을 찾아도 그 증거가
순서를 묶는다.

**그 규칙이 왜 있었나.**

- RFC-0433 §3.1: 끝나는 때를 말하지 않은 소진은 "시계가 아니라 다음 성공이 지운다".
  RFC-0370 이 거부한 지어낸 기간(15분 쿨다운 같은 것)을 만들지 않으려는 결정이었다.
- #34059 설계 메모: 힌트가 없으면 만료 시각을 지어내지 않는다.
- RFC-0458 §3.4 운영자 결정(2026-09-17): 타임아웃·5xx 를 429 와 같은 칸에 두면서 숫자로
  된 쉼을 새로 만들지 않기로 했다. 그 실패 증거는 쉼이 아니라서 이 개정이 바꾸지 않는다.

**왜 지워도 되나.**

- 새 시각을 만들지 않는다. floor(60초)와 cap(900초)은 이 RFC 가 이미 대기 길이로 쓰는
  운영자 선언 값이다. RFC-0458 §2.4 도 쉼의 길이는 "provider 가 말한 시각이나 운영자가
  선언한 floor·cap" 이어야 한다고 적었다.
- 대기는 그 시각에 이미 끝났다. 순서만 남아 있었다. 같은 증거로 대기와 순서가 다른
  시각에 풀리니, 대기 계산이 순서를 따로 따라가야 했다. 그 어긋남이 이번 대기를 만들었다.
- "성공할 때까지" 는 과거 증거를 순서의 Gate 로 만든다. 429 를 한 번 맞은 머리는
  sibling 이 답하는 동안 불리지 않는다. 그러면 사실상 영원히 뒤에 남고, masc 가 사용자가
  선언한 순서를 덮는다. RFC-0458 §3.4(#38174)가 실패 증거에서 고친 것과 같은 모양이다.

**치르는 값.** 계속 거절하면서 시각을 말하지 않는 경로는 floor(429, 60초)나 cap(quota
관찰, 900초)이 지날 때마다 다시 머리에 온다. 그때 걷는 Keeper 가 요청을 한 번 보낸다.
다시 거절되면 증거가 새로 적히고, 후보 관측은 Keeper 사이에 공유되므로 모든 Keeper 의
순서가 다시 그 경로를 뒤로 민다.

§4 의 P 는 그대로다. 대기는 전보다 일찍 끝날 수 있다. quota 관찰은 판단한 때가 아니라
적은 때부터 cap 을 세고, 대기는 걷는 순서에서 가장 먼저 풀리는 경로의 시각에 끝난다.
그때 다음 턴은 풀린 그 경로부터 걷고, 아직 쉬는 경로는 순서 뒤에 남는다. wake 는 여전히
잠을 끊지 못한다.

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
  같은 binding의 새로운 거부가 기존 대기 중 reset을 연장해도, 이 RFC의 대기 무효화는
  이미 정한 deadline을 연장하지 않는다. 명시적 reset과 시각 없는 fallback을 구분한
  dispatch admission에서 해결해야 하며, heartbeat와 직접 채팅 모두에 남아 있다.

Phase 2 는 walk 가 쉬는 후보를 건너뛰고, 모두 쉬면 호출 없이 "모든 경로가 쉼" 을 typed
terminal 로 끝내게 한다. RFC-0433 의 "새 fail-closed 경로를 만들지 않는다" 와 부딪히므로
따로 설계한다.

> 2026-11-10: exact lane 부분은 RFC-exact-lane-waits-for-a-stated-reset 이 정한다. provider 가
> 말한 시각 전에는 그 slot 을 부르지 않고, 모두 기다리면 호출 없이 typed 결과로 끝낸다.
> 시각 없는 쉼은 순서만 바꾼다. Keeper turn walk 부분은 이 절에 남는다.
>
> 2026-11-15: Keeper turn walk 의 말한 시각 부분은 6.1 이 정한다. 시각 없는 쉼은 그대로 순서만 바꾼다.

### 6.1 Keeper walk 도 provider 가 말한 시각 전에는 부르지 않는다 (2026-11-15)

#### 계기

2026-11-15 07:36Z 에 같은 claude_code 계정으로 Keeper 셋이 20초 사이에 차례로 거절당했다.

- 07:36:57 `kidsnote-slack-reader` 가 거절당했다. 계정의 7일 한도가 찼다. provider 는 풀리는 시각을 말했고, masc 는 그 시각을 한도 표(`Runtime_quota_window`)에 적었다.
- `masc-productor-owner` 는 07:36:54 에 시도를 시작했고 07:37:00 에 요청을 보냈다. 07:37:04 에 거절당했다.
- `wkbl-data` 는 07:37:12 에 턴을 시작했다. 07:37:17 에 거절당했다.

뒤의 두 호출은 보내기 전에 결과가 정해져 있었다. 표에 그 계정의 풀리는 시각이 이미 있었다.

#### 왜 부르나

- Keeper 는 자기 턴이 실패한 뒤에만 그 시각을 기다린다. heartbeat 는 실패하거나 쉰 턴 뒤에만 대기를 정한다(`Keeper_heartbeat_loop.after_failure_of_cycle_outcome`). 턴이 쉼(`Turn_rested`)으로 끝나는 것도 그 턴의 호출이 거절된 뒤다(`Keeper_turn_driver.provider_rest_of_failure`).
- 턴 안의 walk 는 표를 순서로만 읽는다(`Runtime_candidate_standing.order`). 쉬는 후보를 뒤로 밀 뿐이고, 앞에 부를 후보가 없으면 쉬는 후보를 부른다.
- 그래서 다른 Keeper 의 거절이 적은 시각은 이 Keeper 의 첫 호출을 막지 못한다. 첫 호출이 실패한 뒤의 대기만 그 시각에 맞춘다.
- exact lane 은 같은 표를 읽고 그 시각 전에는 부르지 않는다(RFC-exact-lane-waits-for-a-stated-reset R1). 판정 함수 `Runtime_candidate_standing.stated_until` 이 이미 있다.

#### 잰 것

스크립트로 서버 로그를 읽었다. 기간은 2026-11-10 00:00Z 부터 11-15 10:00Z 까지이고, 그동안 서버가 29번 시작했다. 같은 provider 행에 같거나 늦은 시각이 보내기 전에 적혀 있었는지 본다.

| heartbeat 턴의 한도 거절(풀리는 시각까지 기다린 것) | 보낸 때 기준 | 시도 시작 기준 |
|---|---:|---:|
| 전체 | 155 | 155 |
| 같은 프로세스의 다른 Keeper 가 먼저 적었다 | 41 | 33 |
| 자기 앞선 거절만 적었다 | 1 | 1 |
| 앞선 프로세스만 적었다(재시작이 잊었다) | 69 | 77 |
| 처음 들은 시각 | 39 | 39 |
| 보낸 때를 모른다(Agent Core HTTP) | 5 | 5 |

- 「보낸 때」는 공식 client 의 `turn composition:` 줄이다. 그 줄을 쓰지 않는 runtime 은 시도 시작이다. 「시도 시작」은 후보 시도 안에서 찍히는 `agent started` 줄이다.
- 41건은 Keeper 17명이 냈다. provider 는 claude_code 39건, muse_serve 2건이다. 앞선 거절과 이 호출 사이는 중앙값 39초, 가장 길게 26분이다.
- K1 은 후보를 부르기 직전, 시도를 시작하기 전에 표를 읽는다. 그래서 막는 몫은 「시도 시작 기준」 33건에 가깝다. 나머지 8건은 시도를 시작한 뒤 보내기 전에 다른 Keeper 가 시각을 적은 경우다. 계기의 `masc-productor-owner` 가 여기에 든다. 아래 「받아들이는 틈」에 적는다.
- 이 숫자는 아래 한계다.
  - 「먼저 적은 때」는 먼저 거절된 Keeper 의 대기 줄 시각이다. 표에 실제로 적히는 때는 거절 때라서 그보다 앞이다. 거절 줄(`turn terminal`) 시각으로 다시 세면 41건이 43건, 33건이 34건이 된다.
  - 표는 scope 로 묶는데 스크립트는 provider 행으로 묶는다. 두 행이 scope 를 나눠 쓰면 따로 센다.
  - 채팅 턴, 다음 후보로 넘어가 성공한 턴의 거절, lane 실행은 세지 못했다. 그 로그 줄은 provider 행을 적지 않는다.
  - 같은 기간 agent-core 기록(`agent_failed`, `provider_error_hard_quota`)은 506번이고, 그중 451번이 시각을 말했다.
- 69건은 이 절이 줄이지 않는다. 재시작 뒤 첫 거절은 RFC-a-restarted-server-keeps-the-resets-providers-stated 가 다룬다. 그 RFC §6 의 첫 결정에 이 숫자를 보탠다.

#### 규칙

- **K1.** Keeper walk 는 후보를 부르기 직전에 `Runtime_candidate_standing.stated_until` 을 읽는다. 값이 있으면 그 후보를 부르지 않는다. exact lane 과 같은 함수이고 같은 표다. 읽는 자리는 `attempt_runtime_candidates` 에서 후보마다 한 번이다. walk 를 시작할 때 한 번만 읽지 않는다. 같은 walk 의 앞 후보가 거절되면서 뒤 후보의 scope 에 시각을 적을 수 있다.
- **K2.** 건너뛴 후보는 「불러서 자기 계정 사정으로 거절된 후보」와 같게 다룬다. 호출만 없다(exact lane R5). walk 는 다음 후보로 간다. 실패 시도 표시(`note_failed_attempt`)는 남기지 않는다. 한도 거절도 지금 그 표시를 남기지 않는다.
- **K3.** walk 의 모든 후보를 건너뛰면 호출 없이 끝난다.
  - 결과는 typed 오류 하나다. 가장 이른 풀리는 시각과 그 시각의 후보를 싣는다. walk 는 이 오류를 lane 오류(`lane_terminal`)로 내고, 오류의 후보는 그 후보다.
  - 이 턴은 실패가 아니라 쉼(`Turn_rested`)으로 끝난다. `provider_rest_of_failure` 는 오류에 실린 시각과 후보로 쉼을 만든다. 이 함수는 오류를 직접 받지 않고 실패 경로(`~route`)만 받는다. 그래서 `Keeper_runtime_failure_route` 에 더하는 K3 갈래가 풀리는 시각(`release_at`)과 그 후보(`waiting_on`)를 싣는다. 채팅의 `retry_not_before` 도 같은 경로(`route_of_error`)에서 읽는다. assignment 의 새 walk 를 다시 읽지 않는다. 턴의 walk 가 assignment 의 walk 보다 좁을 수 있기 때문이다(미디어로 거른 walk, 이어가는 suffix). 머리를 다시 읽으면 넓은 walk 의 머리가 쉬지 않는다는 이유로 쉼이 사라지고, 같은 좁은 walk 가 다시 돈다.
  - heartbeat 의 대기는 그 시각이 지나거나 dispatch snapshot 이 바뀔 때(배정, lane, binding 편집) 끝난다. walk 머리가 쉬지 않는다는 이유로는 끝나지 않는다. 대기 근거(`wait_basis`)에 이 경우의 갈래를 하나 더한다. 호출이 없었으므로 `Failure_response` 가 아니다.
  - 불러서 Retry-After 와 함께 429 를 받은 턴은 지금처럼 실패로 끝나고, heartbeat 가 3.1 표로 기다린다. 호출이 없는 K3 만 쉼이다. 두 경우 모두 다음 호출은 그 시각 뒤다.
  - 쉰 턴은 지금처럼 자극을 소비하지 않는다.
- **K4.** masc 가 정한 쉼은 지금처럼 순서만 바꾼다. 시각 없는 고갈(`Observed_until`)과 Retry-After 없는 rate limit 이 여기에 든다(RFC-0433). `stated_until` 은 이 둘에 값을 주지 않는다.
- **K5.** 다음 후보로 넘어가는 실패 뒤에 남은 후보가 모두 기다리면, 실패한 후보가 마지막 후보처럼 끝난다.
  - 걸리는 갈래는 다시 시도가 허락되고 오류도 다시 시도할 수 있는 갈래(`retry_admitted && error_is_retryable`)뿐이다. 실패를 기록한 뒤에 `rest` 를 K1 으로 읽어 판정한다.
  - 끝나는 모양은 지금의 마지막 후보와 같다. lane 을 대표하는 overflow 가 이기고, 같은 경로 이어가기(`defer_to_the_failed_path`)를 보고, 그 실패로 끝난다.
  - 지금 이 갈래는 `rest` 를 끝까지 걷는다. K1 이 남은 후보를 모두 건너뛰면 walk 가 `[]` 에 닿아 「exhausted all candidates」 문자열 오류로 끝난다. K5 는 그 끝을 막는다.
  - `is_last`(`rest = []`)의 뜻은 바꾸지 않는다. 지금 갈래 순서는 다시 시도, `is_last`, suffix 넘기기다. `is_last` 를 넓히면 suffix 넘기기보다 먼저 걸린다.
  - 다시 시도가 허락되지 않은 실패는 K5 에 걸리지 않는다. checkpoint 단계에 닿으면 `same_run_retry_allowed` 가 false 다. 이 실패는 지금처럼 suffix 갈래로 가서, 아직 부르지 않은 후보에게 입력을 넘긴다(`on_deferred`). 넘겨받은 후보가 기다리고 있어도 넘긴다. 얼마나 기다릴지는 3.1 표와 `deferred_lane_rest` 가 정한다. 채팅 작업은 `retry_not_before` 로 suffix 머리의 시각까지 미뤄지고, 저장한 진행을 잃지 않는다.

새 저장 상태는 없다. 표는 프로세스 메모리에 있고 재시작하면 잊는다(exact lane 3.5). 지우는 규칙도 그대로다. 시각이 지나면 읽을 때 지운다. 성공은 말한 리셋을 지우지 않는다(`Runtime_quota_window.note_succeeded`). K1 은 `attempt_runtime_candidates` 를 지나는 walk 모두에 걸린다. heartbeat 턴, 채팅 턴, `One_shot_walk` 가 같다.

scope 는 계정이 아니다. credential 참조, client home, 또는 provider 행이다(`Runtime_quota_window.scope_of_credential`, `scope_of_claude_code_home`). 두 runtime 행이 credential 하나를 나눠 쓰면 함께 기다린다. 같은 계정이라도 scope 가 다르면 따로 판정되고, 각 scope 가 한 번씩 거절된다. 지금과 같다.

#### 상황별 동작

| 상황 | 지금 | 바뀐 뒤 |
|---|---|---|
| tick N 에 Keeper A 가 거절됨, tick N+1..N+M 에 B·C 가 같은 scope 의 후보를 가진 채 턴 시작 | 순서가 그 후보를 뒤로 민다. 앞 후보가 모두 실패하거나 그 후보뿐이면 B·C 가 한 번씩 거절된 뒤 기다린다 | 그 후보를 부르지 않는다. 앞 후보가 모두 실패했으면 그 실패로 끝난다(K5). 그 후보뿐이면 호출 없이 그 시각까지 쉰다(K3) |
| 쉬는 동안 wake 가 옴 | 첫 거절 전에는 턴이 떠서 부른다 | K3 로 쉰 턴 뒤의 대기는 wake 가 끊지 못한다(4절 P) |
| 풀리는 시각이 지남 | 부른다 | 부른다 |
| 위임: B 가 새 채팅 작업을 받았고 B 의 후보가 모두 기다림 | 부르고 거절된다. 작업은 실패로 끝난다. 도구 결과를 저장한 뒤의 같은 경로 이어가기만 `retry_not_before` 로 미룬다 | 부르지 않는다. 작업은 K3 오류로 끝난다. 이어가는 작업은 지금처럼 suffix 머리가 쉬면 그 시각까지 미룬다(3.4) |
| checkpoint 단계에 닿은 뒤 실패, 아직 부르지 않은 뒤 후보가 모두 기다림 | suffix 로 넘긴다. heartbeat 는 3.1 표로 suffix 머리의 시각까지 기다리고, 채팅 작업은 `retry_not_before` 로 미뤄진다 | 같다. K5 는 이 갈래에 걸리지 않는다 |
| context window 초과로 다음 후보로 넘어갔는데 다음 후보가 기다림 | 그 후보를 부르고 거절된다 | 건너뛴다. 남은 후보가 없으면 초과 오류로 끝난다(K5) |
| 공식 CLI(home h) → API(credential k) → 공식 CLI(home h), 첫 CLI 가 시각과 함께 거절되고 API 가 다시 시도할 수 있는 오류로 실패 | 세 번째 후보를 불러 또 거절된다 | 세 번째 호출만 없어진다. walk 는 API 의 실패로 끝난다(K5) |

새 채팅 작업을 그 시각까지 Queued 로 미루는 일은 이 절에 넣지 않는다. 미루려면 이어갈 체크포인트가 있어야 하는데, 호출 전의 새 작업에는 없다.

#### 받아들이는 틈

- **시도 시작과 보내기 사이.** K1 은 시도를 시작하기 전에 읽는다. 공식 client 는 그 뒤 prompt 를 짓고 프로세스를 띄운 다음 보낸다. 그 사이 다른 Keeper 가 같은 scope 에 시각을 적으면 이번 호출은 나간다. 잰 기간에 8건이었다. 거절 줄 시각으로 세면 9건이다. 호출 하나마다 한 번이고 반복되지 않는다. 다음 턴은 K1 이 걸러 낸다. exact lane 의 「HTTP 의 틈」(exact lane 3.5)과 같은 종류다. 막으려면 client 가 보내기 직전에 다시 읽고 typed 결과로 돌아와야 한다. runtime 마다 보내는 자리가 달라서 이 절에 넣지 않는다.
- **이미 떠 있는 호출.** 적히기 전에 보낸 호출은 그대로 거절된다.

#### 하지 않는 것

- 시각 없는 쉼을 배제로 바꾸지 않는다(K4).
- 표를 저장하지 않는다.
- 운영자가 한도를 일찍 올렸을 때 푸는 장치를 만들지 않는다. exact lane 3.5 와 같다.
- 새 Gate, 새 저장 상태, 새 설정 값을 더하지 않는다.

RFC-0433 과는 exact lane RFC 2절과 같은 이유로 부딪히지 않는다. RFC-0433 의 안전선은 시각 없는 표시가 배제로 바뀌는 것을 막는다. K1 은 provider 가 말한 시각만 읽고, 그 쉼은 그 시각에 끝난다.

#### 고치는 문장 (구현과 같이)

구현 PR 이 같이 고친다. 이 RFC 만으로는 동작이 바뀌지 않으므로 지금은 고치지 않는다.

- RFC-0433 8절 앞의 2026-11-11 메모. 지금은 exact lane 만 적는다. Keeper walk 도 같은 범위라고 적는다.
- RFC-a-restarted-server-keeps-the-resets-providers-stated 1.2 「Keeper walk 에서 이 표는 순서 선호다. 미뤄진 후보도 남은 후보가 없으면 부른다」와 3절 「Keeper 를 막기 … 순서 선호다」. 말한 시각은 Keeper walk 도 지킨다고 적는다. 3절 「재시작과 무관한 반복 거절 … 따로 조사할 일이다」에는 이 절의 측정을 잇는다.
- `runtime_quota_window.mli` 모듈 설명 「For a Keeper walk it is an ordering preference, not an admission gate」. 시각 없는 쉼에만 맞는 말로 좁힌다.
- RFC-exact-lane-waits-for-a-stated-reset 1.3 과 4절의 「Keeper turn walk」 줄.

#### 구현 순서

1. `Runtime_candidate_standing.stated_until` 을 `.mli` 로 내보낸다. 지금은 `order_exact` 만 부른다.
2. `attempt_runtime_candidates` 에 K1·K2·K5 를 넣고, K3 의 typed 오류를 `Keeper_internal_error` 에 더한다.
3. `Keeper_runtime_failure_route` 에 `release_at` 과 `waiting_on` 을 싣는 K3 갈래를, `Keeper_turn_driver.wait_basis` 에 K3 대기의 갈래를 더한다. `provider_rest_of_failure`, `next_dispatch_after_failure`, heartbeat 의 대기 끊기(`provider_wait_interrupt`)의 match 를 컴파일러가 멈춘 곳마다 이름으로 채운다.
4. 위 「고치는 문장」.

#### 검증

- `attempt_runtime_candidates`:
  - 머리 후보에 말한 시각이 있으면 `run_attempt` 가 그 후보로 불리지 않고 다음 후보로 불린다.
  - 모든 후보가 기다리면 `run_attempt` 가 한 번도 불리지 않는다. K3 오류가 가장 이른 시각과 그 후보를 싣는다.
  - 앞 후보의 거절이 같은 scope 에 시각을 적으면, 같은 walk 의 뒤 후보를 부르지 않는다.
  - 다음 후보로 넘어가는 실패 뒤 남은 후보가 모두 기다리면 그 실패로 끝난다. overflow 가 있으면 overflow 로 끝난다(K5).
  - checkpoint 단계에 닿은 실패 뒤 아직 부르지 않은 후보가 모두 기다리면, 지금처럼 `on_deferred` 가 그 후보들로 불린다. K5 가 걸리지 않는다.
  - 시각 없는 고갈과 Retry-After 없는 429 는 지금처럼 부른다(K4).
- `provider_rest_of_failure`: K3 오류는 오류에 실린 시각의 쉼이다. assignment 의 walk 머리가 쉬지 않아도 쉼이다. 그 대기는 wake 로도, 머리가 쉬지 않는다는 이유로도 끊기지 않고, dispatch snapshot 이 바뀌면 끊긴다(#34653 회귀 시험 유지).
- 채팅: 새 작업은 K3 오류로 끝난다. 이어가는 작업의 `retry_not_before` 는 그 시각이다.
- `One_shot_walk`: K3 오류를 받은 호출처가 그것을 후보의 실패로 읽는지 시험으로 정한다. 건너뛴 후보에는 `on_attempt_error` 가 불리지 않는다.
- 배포 뒤 실측: 이 절의 스크립트를 다시 돌린다. 「시도 시작 기준」의 다른 Keeper 몫이 0 인지 본다. 「보낸 때 기준」에 남는 것이 받아들이는 틈뿐인지 본다.

#### 확인 못 한 것

- 채팅 턴과 다음 후보로 넘어간 거절이 scope 별로 몇 번인지. 로그가 provider 행을 적지 않는다.
- `known_from_itself` 1건이 어느 길로 나갔는지. 자기 대기 중에 같은 행을 다시 불렀다. wake 로 뜬 턴인지 채팅 턴인지 보지 않았다.
- Agent Core HTTP 실행 5건의 보낸 때. 시작 줄이 Keeper 이름을 적지 않는다.

## 7. 고르지 않은 대안

- **cap·floor 숫자만 줄이기**: 누가 쉬는가를 그대로 두고 증상만 누른다. 거부한다.
- **Phase 2 를 먼저**: 시각 없는 쉼까지 walk 에서 빼는 admission 은 RFC-0433 을 뒤집는다. 말한 시각만 빼는 일은 6.1 이 다룬다. 드라이버가 이미
  고른 경로를 heartbeat 가 읽게 하는 것만으로 측정한 13건 중 6건이 풀린다.
- **cadence 유지**: 힌트가 있어도 cadence 로 올리는 것은 provider 가 말한 사실을 버리는 일이다.

## 8. 검증

- 결정 함수 테스트: 첫 경로가 쉬지 않는 suffix → 이어가기, 모두 쉬는 suffix → 순서가
  풀리는 가장 이른 시각, 시각을 말하지 않은 429 로 쉬는 뒤 경로도 floor 에 대기를 줄임,
  quota 리셋 시각, 시각 없는 429 뒤 사용량 조회가 찾은 리셋까지만 기다림(2026-11-06),
  suffix 없는 여러 후보의 rate limit → 새 walk 머리가 사용 가능하면 cadence, 쉬면 그 release까지; 단일 경로 힌트 5초 →
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
