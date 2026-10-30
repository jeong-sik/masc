---
rfc: "rotate-on-persistent-throttle"
status: Draft
---

# RFC — 지속 스로틀에 대한 런타임 회전 (Rotate on persistent throttle)

- Status: Draft
- Created: 2026-10-06
- Scope: `lib/keeper_runtime/keeper_runtime_failure_route.*`,
  `lib/keeper/keeper_turn_driver*.ml`, `lib/runtime/runtime_candidate_backpressure.*`
- Non-scope: cooldown 수치 신설, 크로스-credential 회전, 60s floor 변경

## 1. 동기 (측정)

2026-10-06 fleet 24h 실측 (autonomous_cycle 2372턴):

- error 525턴(22.1%). 그중 429 계열 382턴, 중앙 latency 2.2s fast-fail.
- `ollama_cloud` 고정 3기(indie-geek-blue, sangsu, you-never-change)가
  50~78% 거부율을 매 턴 맞는다. 에러 중앙 간격 64~66s.
- 같은 기간 `claude_code` 계열은 ~870턴에 에러율 ~2%로 한가하다.

즉 한 provider가 반나절씩 거부하는데도 해당 keeper는 매분 같은
provider를 재시도하고, 건강한 형제 런타임은 놀고 있다.

## 2. 현재 설계 (고장이 아님)

- 429는 `Retry_after_observed`로 라우팅된다. `Rotate_now` 대상이 아니다
  (`keeper_runtime_failure_route.mli`: 회전 클래스는 Auth/Model/Wire 등).
- unhinted 429의 path rest는 `rate_limit_backoff_floor_sec = 60.0`
  ("429 is tried once a minute", RFC-provider-path-rest §3.3). 관측된
  64s 간격은 이 설계의 정확한 발현이다.
- 스케줄러는 provider 건강을 admission에 쓰지 않는다
  (`keeper_heartbeat_loop_scheduling.ml`: observations, not authority).
- backpressure/quota-window는 전부 ordering preference이지 gate가 아니다.

설계 가정("429는 일시적, 60초면 풀린다")이 깨진 provider 앞에서
무한 재시도가 된다. 가정 위반을 감지하는 typed 상태가 없다.

## 3. 제안

워크 head가 429 rest 중이고, **선언된 형제 런타임 중 serving인 것이
있으면 그 턴을 형제에게 디스패치**한다. rest 중인 path는 그대로 쉬고
(provider-stated `retry_after`는 그대로 존중), 턴만 회전한다.

- 새 rotate 사유는 typed variant 1개 (이름 미정, e.g.
  `Throttle_avoidance`). 판단 입력은 typed rest 상태뿐:
  head=`Path_resting`, sibling=`Path_serving`.
- 누적 카운터("N회 연속 429")를 쓰지 않는다. 헌법 `budget_gate`
  (누적 숫자로 행동 제한 금지) 위반이므로, 연속 실패 횟수는 관측용으로만
  남긴다.
- 형제 후보가 없거나 전부 resting이면 현행대로 턴 실패 + rest 유지.
  새 fail-closed 경로를 만들지 않는다 (quota-window와 같은 원칙).

## 4. Non-goals / 경계

- 재시도 간격·횟수·상한 숫자 신설 금지. provider가 말하지 않은 시간은
  만들지 않는다 (현행 `usable_retry_after` 규칙 유지).
- credential scope를 넘는 회전 금지. 429는 scope를 특정하지 않으므로
  (`note_rate_limit` 주석) 회전은 동일 lane의 선언된 후보로만.
- 60s floor / 900s cap 변경 없음.

## 5. 측정 (선행 조건 아님, 병행)

- 성공 지표: fleet error 턴/일 감소, 회전 턴 수, provider별 실행 분포.
- 소스: `keeper.practice.v1`(#41292)의 outcome/terminal-code 집계 +
  기존 walk 텔레메트리. 회전 사유 라벨을 텔레메트리에 추가한다.

## 6. 열린 질문

1. 형제 "serving" 판정의 권위: `path_rest` 하나로 충분한가.
2. 회전 vs 대기 우선순위: head rest가 수 초 남았을 때도 회전하는가,
   아니면 provider hint가 있을 때만 회전하는가.
3. 동일 모델 패밀리 우선 같은 capability binding 조건이 필요한가.
