---
rfc: "conversation-holds-the-turn-slot"
title: "대화는 턴 슬롯을 보유한다"
status: Draft
created: 2026-09-01
updated: 2026-09-01
author: vincent
related: ["0373", "0303", "0385", "0377", "0315", "0366"]
---

# RFC: 대화는 턴 슬롯을 보유한다

## 0. Summary

진행 중인 운영자 대화가 턴 슬롯을 W 동안 보유한다(conversation hold). 이 창 안에서
Autonomous 레인의 admission은 typed 사유로 미뤄진다. 미뤄진 것은 skip이 아니라 부채다.
연속 D회 누적되면 다음 `Child_finished` 경계에서 자율 레인에 슬롯 1개가 보장 지급되고
부채는 리셋된다(bounded deferral debt).

채팅의 자율 턴 선점은 이미 존재하는 협력적 yield(`chat_yield_request`)를 그대로 쓴다.
본 RFC는 yield의 경계 지연만을 다룬다. 하드 interrupt는 수동 전용으로 유지한다.

단일-기록자 턴 슬롯 불변식(`keeper_owner.mli` 162,813 전이 / 0 위반, #28441)은 변경하지
않는다. 바뀌는 것은 배제가 아니라 **순서**다.

## 1. Problem

하나의 슬롯 비대칭이 양쪽에서 결함으로 나타난다. 슬롯이 해제될 때 채팅이 무조건 먼저
(`start_child_if_needed` → `notify_turn_slot_released` 순서, `lib/keeper/keeper_owner.ml:1125-1126`)
그리고 자율 턴은 대화의 숨(사용자가 읽고 타이핑하는 간격)을 가져갈 수 있다.

### 결함 (a): 대화 흐름이 끊긴다

자율 턴이 대화 세션 창 안에서 시작된다. 운영자는 keeper의 응답을 읽는 사이에
자율 활동을 보게 된다.

실측(2026-08-30..09-01 로그, 채팅 op 전체 582건):

| 지표 | 값 |
|---|---|
| 대화 세션(채팅 op를 간격 600초로 묶음) | 309개 |
| 세션 창(첫 제출 −60s ~ 마지막 완료 +180s) 안의 `scheduled_autonomous` 턴 시작 | 22회 |
| 끼어든 세션 | 14/309 (4.5%) |
| 같은 세션의 메시지 사이에 낀 경우(break-in-middle) | 5회 |

절대 빈도는 낮지만 방향이 문제다. RFC-0373의 후속 수정(`on_turn_slot_released`)은
채팅 턴이 끝나는 순간 자율 사이클을 즉시 깨우므로, 슬롯 경합이 일어난 대화에서는
응답 직후 자율 턴이 시작되는 것이 보장된다.

### 결함 (b): 메시지가 자율 턴 뒤에 대기한다

자율 턴이 돌고 있을 때 도착한 채팅 메시지는 협력적 yield 경계까지 기다린다.
yield는 agent-core iteration(공급자 왕복 + 도구 배치) 단위로만 난다.

실측(채팅 op 전체 582건, 대기 = started_at − created_at):

| 지표 | 값 |
|---|---|
| 전체 대기 | p50 = 0.0s, p95 = 249.4s, max = 8,518.6s |
| 10초 초과 / 60초 초과 | 138건 / 69건 |
| 이 중 자율 턴 yield 서명과 일치(자율 턴이 보유자) | 21건, 대기 중앙값 27.5s, max 118.6s |
| 이 중 이전 채팅 op 미완료에 따른 FIFO 대기 | 30건 (RFC-0377 영역) |
| 나머지 | 87건 (부팅 단계, 재시도 backoff 등 다른 admission 요인) |

yield 서명이 있는 21건의 대기가 본 RFC의 직접 대상이다. 중앙값 27.5초, 최대 118.6초는
사용자가 체감하는 응답 지연의 실측 크기다.

### 반대편 결함: 채팅이 자율을 굶긴다 (RFC-0373)

RFC-0373의 측정(2026-08-12): 자율 deferral 50건 중 50건이 chat_operation 홀더가 원인,
최장 16.3분 홀드로 5사이클 연속 손실, sangsu 손실률 18.6%.

본 RFC 작성 시점의 갱신 측정(2026-08-30..09-01, 3일):
"Keeper Owner deferred autonomous work" 303건, 홀더 레인 **303/303 = chat_operation**.
홀더 발화면 분할(홀더 op의 source와 조인, 278건 조인 성공): dashboard 196건(사람),
agent 82건(에이전트 `keeper_msg`). 사람 대화가 주된 홀더다.

이 갱신은 두 가지를 말한다. 첫째, 0373의 굶주림이 여전히 진행 중이다. 둘째, 홀더가
사람·에이전트 섞여 있으므로 홀드 정책은 발화면을 가리지 않아야 측정과 맞는다(§4.1).

## 2. Invariant

RFC-0373은 "admission 정책을 쓰기 전에 invariant를 먼저 문서로 남겨라"고 요구했다.
그 invariant는 이미 문서로 존재한다 — #28441이 `lib/keeper/keeper_owner.mli:48-68`에
남겼다. 슬롯은 단일-기록자 불변식을 지킨다. 턴 두 개가 한 keeper에서 병행되면 조용한
오염이 아니라 `Turn_phase_transition_violation`이 발생한다. 실측 2026-08-10..12:
162,813 전이, 위반 0. 그 주석은 순서 정책을 "RFC-0373이 있는 자리"로 넘겼고, 본 RFC가
그 순서 계약을 쓴다.

해제된 슬롯의 제공 순서:

1. 부채 지급(debt ≥ D)이면 자율 레인에 1개
2. 대기 중 chat op
3. 자율 레인(자기 cadence 또는 wake)

이 순서를 `keeper_owner.mli`에 서술하고 테스트가 고정한다. 레인 분리(0373 방향 3)는
불변식 때문에 여전히 범위 밖이다.

## 3. Current structure

- 레인은 3종(`keeper_owner.ml:38`: `Autonomous | Chat_operation | Maintenance`).
  admission은 `Run_if_idle`(`keeper_owner.ml:1051-1099`): 슬롯 점유 시 요청은
  `Autonomous_busy`를 받고, 진 요청이 Autonomous일 때만 `autonomous_lost_slot := true`
  (`:1063-1065`). 채팅 op는 SQL FIFO로 내구 대기한다(`lib/keeper/keeper_chat_operation_store.ml:747-780`).
- `Child_finished`(`keeper_owner.ml:1100-1127`)에서 채팅 drain이
  `notify_turn_slot_released`(`:321-334`)보다 먼저다. notify의 발화 조건 3개(턴 종료 +
  슬롯 미선점 + 자율 레인이 마지막 통지 이후 거부됨)는 모두 필요하다. 세 번째를 빼면
  턴 시작이 114.9/h → 1523.5/h로 폭증했다(`keeper_owner.mli:175-201`).
  결선은 `lib/server/server_runtime_bootstrap.ml:1069-1097`.
- **admission은 observation보다 먼저다.** `run_keepalive_unified_turn`에서
  `Run_if_idle`(`lib/keeper/keeper_heartbeat_loop.ml:565`)이 관측(`:697`)과 결정(`:702`)보다
  먼저고, 셋 다 획득한 슬롯 안에서 일어난다. Busy 패자는 아무것도 관측하지 못한다.
  decision-audit(`:814-829`)와 skip counter(`:742`)도 슬롯 안에서만 나온다.
  그래서 홀드 판정의 입력은 owner가 직접 아는 값이어야 한다. 관측 경로는
  `Keeper_chat_store`를 의도적으로 읽지 않는다(`lib/keeper/keeper_world_observation.ml:1495-1503`).
- **채팅의 자율 턴 선점은 이미 존재한다.** `chat_yield_request`
  (`lib/keeper/keeper_unified_turn.ml:152-186`, 조건 `queued_count > 0`)을 에이전트
  실행 루프가 탐사하고(`lib/keeper/keeper_agent_run.ml:1034-1045`),
  `Yielded_to_operation_queued`로 매핑된다. yield는 checkpoint를 저장하는 깨끗한
  종료다("checkpoint saved — will resume next cycle",
  `lib/keeper/keeper_unified_turn_success.ml:450-458`). §1(b)의 실측 21건이 이 경계의
  지연이다.
- 하드 interrupt는 수동 전용이다: owner측 `Interrupt_running_operation`
  (`keeper_owner.ml:833-853`), registry측 `interrupt_current_turn_exact`
  (`lib/keeper/keeper_registry_setup.ml:1331-1379`), HTTP `POST /api/v1/keepers/turn/interrupt`,
  TUI Esc. 자율 턴이 인터럽트되면 `Skip_interrupted_turn`
  (`keeper_heartbeat_loop.ml:1083-1087`)으로 끝난다.
- `proactive_rt.last_ts`는 **시도(attempt)를 기록한다**, 성공이 아니라
  (`lib/keeper/keeper_unified_metrics_failure.ml:70-84`). 일시 오류가 last_ts를 묵히면
  cooldown_elapsed=false가 영구화되어 자율 턴이 돌아오지 않던 좀비 상태(#5594)의 원인이었다.
  본 RFC는 이 시도 의미를 보존한다.
- 스케줄 하트비트의 admission은 오늘 무조건이다
  (`lib/keeper/keeper_world_observation.ml:1641-1687`, 주석 "fixed local thresholds never
  suppress a Keeper cycle"). skip 사유는 닫힌 3종(paused / proactive disabled / reactive
  disabled). cadence 기본 300초(`lib/config/env_config_keeper.ml:464-472`).

## 4. Design

### 4.1 정책 상태 머신

Owner가 유지하는 상태는 세 개다. 전부 owner가 직접 관찰하는 값이고 관측 경로를
거치지 않는다.

- `last_chat_activity_at` — chat `Submit_operation`과 chat 레인 `Child_finished`에서 갱신
- `conversation_debt` — §4.2 M3의 단위로 누적
- `debt_payment_due` — debt ≥ D인 동안 참

상태 전이(요약):

| 현재 상태 | 사건 | 결과 |
|---|---|---|
| (어디서든) | chat op 제출 | 슬롯이 비어 있으면 즉시 chat 실행. 자율 턴이 돌면 §4.2 M2 |
| 대화 보유 중 (now − last_chat_activity_at < W) | Autonomous `Run_if_idle` | typed 사유로 defer, debt +1 |
| 대화 보유 중 | `Child_finished`, debt < D | 슬롯을 대기 chat op에(오늘과 동일). notify는 억제 |
| 대화 보유 중 | `Child_finished`, debt ≥ D | **지급**: 자율 레인에 슬롯 1개, no-re-yield 규칙 적용, debt 리셋 |
| 대화 아님 | `Child_finished` | 오늘의 3조건 계약 그대로 |
| W 경과 | 다음 cadence poll | 자율 admission 정상. 즉시 wake하지 않는다(§4.3) |

### 4.2 네 가지 메커니즘

**M1 — Conversation hold (W).** 대화 보유 중 Autonomous 레인의 `Run_if_idle`은
새 typed 사유를 반환하고 실행하지 않는다(M4). `notify_turn_slot_released`는 억제한다
(§4.3의 네 번째 조건). 홀드는 chat 레인 자체의 admission, Maintenance 레인,
event-queue 자극 처리를 건드리지 않는다. Gate/HITL 결의는 자율 레인을 깨우지만
홀드를 연장하지 않는다.

홀드는 발화면을 가리지 않는다(사람 TUI·커넥터·에이전트 `keeper_msg` 균일 적용).
근거: §1의 갱신 측정에서 홀더가 dashboard 196 / agent 82로 섞여 있고, 에이전트
`keeper_msg`도 자율 사이클을 같은 방식으로 밀어낸다. `Surface_ref.t`
(`lib/keeper/surface_ref.ml:6-30`)가 닫힌 합타입으로 발화면을 이미 들고 있으므로,
측정이 사람/에이전트 분리 정책을 정당화하면 후속 RFC가 범위를 좁힐 수 있다.

**M2 — 경계 있는 양방향 선점 (거의 기존 그대로).** 채팅이 자율 턴 중에 도착하면
자율 턴은 다음 iteration 경계에서 yield한다(checkpoint 저장, 오늘의 동작). 본 RFC의
변경분은 하나다: §1(b)의 실측(중앙값 27.5s, max 118.6s)이 문제라면, yield 탐사를
지속화된 post-tool 경계로 내린다. 선행 사례가 있다 — 승인된 Gate 결의는 이미
"persisted post-tool boundary"에서 자율 턴을 선점한다
(`lib/keeper/keeper_unified_turn.ml:280-283`, #28809). 하드 registry interrupt는
수동 전용으로 유지한다. checkpoint를 버리는 도구가 아니라 checkpoint를 저장하는
경로가 맞다.

부분 부작용은 롤백하지 않는다. 연속 턴이 "Your Recent Actions"로 이미 이룬 일을
본다(RFC-event-queue-admit-all-ready 원칙 계승). 자극은 완료 시에만 ack되므로
yield/interrupt가 큐를 건드리지 않는다. `last_ts`는 시도마다 갱신된다(#5594 보존).

**M3 — Bounded deferral debt (D).** 부채의 단위:

- 홀드로 미뤄진 자율 사이클 1회 = 1
- 홀더가 chat인 `Turn_busy` 패배 1회 = 1 (§1 갱신 측정의 303건이 이 경우)
- 채팅으로의 yield 전위 1회 = 1 (연속 턴이 밀려난 것)
- 수동 interrupt = 0 (운영자가 명시적으로 선택했다)

부채는 어떤 자율 admission이든(자연스러운 admission 또는 지급) 리셋된다.
시간 감쇠 없음, 침묵 시 리셋 없음 — 밀린 사이클은 턴이 돌 때까지 빚으로 남는다.

debt ≥ D이면 다음 `Child_finished`에서 지급한다. notify가 홀드를 뚫고 발화하고,
그 경계에서 `start_child_if_needed`를 한 번 건너뛴다. **지급은 채팅 큐가 비어 있기를
요구하지 않는다.** 빈 큐만 허용하면 숨을 쉬지 않는 대화에서 부채를 갚을 수 없는데,
그것이 sangsu 최악 사례 그 자체다.

**no-re-yield 규칙**: 지급된 자율 턴은 지급 시점에 이미 큐에 있던 op에는 yield하지
않는다. 그렇지 않으면 지급 턴이 자기가 밀어낸 op에게 곧바로 슬롯을 돌려주고 지급이
무의미해진다. owner projection에 `newest_queued_created_at`을 더하고, yield 탐사는
그 값이 지급 시각보다 큰 경우에만 발동한다. 지급 이후의 신규 제출은 정상적으로
선점한다. 밀려난 FIFO 맨 앞 op는 지급 턴 종료 후 실행된다.

고지하는 비용: 큐 맨 앞 chat op 1건이 자율 턴 1회 분량을 기다릴 수 있다. D회당 최대
1회다. 연속 대화 중 자율 사이클 상실률의 정직한 상한은 D/(D+1)이다 — 0이 아니라는
뜻이다. 오늘의 상한이 100%인 것과 비교된다.

**M4 — Typed defer 축.** 미룸은 `skip_reason`이 아니다. `skip_reason`은 획득한 슬롯
안에서 계산되는 세계 관측 기반 판정이고(3종 유지), 미룸은 슬롯 밖의 owner-local
admission 중재다. "이 사이클은 빚이다"를 표현하는 skip 변형은 없다.

대신 `Keeper_owner.autonomous_block`(`keeper_owner.ml:48-50`, `Turn_busy`가 이미
사는 곳)에 변형을 추가한다:

```ocaml
type autonomous_block =
  | Turn_busy of turn_in_flight option
  | Conversation_hold of { last_chat_activity_age_sec : float; debt : int }
  | Shutdown_requested of Keeper_shutdown_types.Operation_id.t
```

가시성(§6): defer 경로가 decision-audit 행과 counter를 남긴다. 오늘의 열린 문자열
`"keeper_owner_" ^ kind`(`keeper_heartbeat_loop.ml:1416-1425`)를 typed 라벨로 대체한다.

### 4.3 상호작용 매트릭스

| 질문 | 판정 |
|---|---|
| 홀드 중 slot-release wake? | `notify_turn_slot_released`에 네 번째 조건 "홀드 비활성 또는 debt ≥ D"를 추가한다. 폭풍 재유도: notify는 여전히 `autonomous_lost_slot`(in-flight 패배로만 설정)과 미선점 슬롯을 요구한다. 대화 중 — 큐가 찬 채팅 종료는 미선점 조건이 이미 억제, 빈 큐 종료는 홀드가 억제, 지급 wake는 cadence/D로 유계(300s cadence에서 ≤ 12/D 회/시간). 대화 밖은 불변. "턴이 끝났다"만으로 wake를 만드는 경로가 없으므로 1523.5/h 메커니즘은 재발할 수 없다 |
| 홀드 만료 시 즉시 wake? | 하지 않는다. 다음 cadence poll이 회수한다(대화 종료 후 최대 W + 300s). 만료 직후 급한 일이 없고 부채가 보장한다 |
| yield된 턴의 `last_ts` | 시도 의미 유지(#5594). 갱신된다. `idle_seconds`는 admission gate가 아니므로 "방금 돌았다" 해가 없다 |
| 부분 부작용 / 자극 | 롤백 없음, continuation이 관찰. 자극은 완료 시에만 ack — yield가 큐를 건드리지 않음 |
| debt 지급 시 채팅이 대기 중이면? | §4.2 M3. 빈 큐 불요, no-re-yield 규칙, FIFO 보존, 비용 고지 |
| Maintenance 레인 | 무변경. 0373 측정과 본 갱신 측정(303건) 모두에서 홀더 0건 |
| observe-condition wake(RFC-observe-by-waking-not-polling) | 어떤 자극이 자율 레인을 깨웠는지 무관하게 홀드가 균일 적용된다 |

## 5. Settings

`lib/config/keeper_runtime_setting_registry.ml`에 선언한다
(census 스크립트 `scripts/check-keeper-runtime-setting-registry.sh`가 env↔registry
일치를 강제한다).

| TOML 키 | env | 기본 | 범위 | reload | category |
|---|---|---|---|---|---|
| `turn.conversation_hold_silence_sec` | `MASC_KEEPER_TURN_CONVERSATION_HOLD_SILENCE_SEC` | 180 | int ≥ 0 (0 = 홀드 비활성) | Hot | turn |
| `turn.conversation_defer_debt_limit` | `MASC_KEEPER_TURN_CONVERSATION_DEFER_DEBT_LIMIT` | 4 | int ≥ 1 | Hot | turn |

W = 180은 cadence 300보다 **작게** 잡았다. 끼어들기 위험은 W가 아니라 cadence poll의
착지 시각이 지배한다. W ≥ cadence이면 운영자가 실제로 자리를 떠난 뒤의 첫 poll까지
미뤄지는데 그때는 대화가 이미 끝났으니 순수 손해다. W < cadence에서 정상적인 대화
정지(3분 이상)는 다음 cadence poll이 자연스럽게 통과한다.

D = 4는 최악 연속 상실을 4사이클(약 20분)로 묶고, 연속 대화에서 지급 인터리브가
약 20분당 1회다. 대화 중 상실률 상한 D/(D+1) = 80% — 0이 아니라고 RFC가 명시한다.

**폐기 선례와의 구별.** `MASC_KEEPER_AUTONOMOUS_FAIRNESS_COOLDOWN_SEC`
(`keeper_runtime_setting_registry.ml:170-181`)은 Retired다. 사유: "No runtime reader
consumed this overlay; retaining it fabricated operator control". 그것은 자율 실행을
억제하는 cooldown이었다. 본 RFC의 W/D는 반대 방향이다 — chat 우선의 유계화와
자율 실행의 하한 보장이고, 두 설정 모두 첫 PR부터 실제 reader를 가진다.

## 6. Telemetry

- **decision-audit defer 행**: `Keeper_decision_audit.make`에 선택 필드 `~admission`을
  더하고, defer 경로(`keeper_heartbeat_loop.ml:1416-1425`)에서 append한다.
  슬롯 안 행은 모양을 유지한다. 오늘 Busy 패자는 audit에 아무것도 남기지 않는다.
- **counter**: `masc_keeper_proactive_skip_total{keeper,reason}`에 typed 라벨
  `conversation_hold`, `turn_busy_chat_operation`을 추가한다. 이 경로의 열린 문자열을
  대체한다. 라벨 pin 테스트를 확장한다.
- **owner projection**: `hold_active`, `last_chat_activity_age_sec`, `conversation_debt`,
  `newest_queued_created_at`. composite JSON으로 노출된다. dashboard TS는 open-set이라
  변경이 필요 없다.
- **지급 로그**: "defer debt paid: N cycles owed, autonomous granted ahead of queued chat
  op" 한 줄. 지급이 밀어낸 op의 대기 시간은 §1(b)와 같은 쿼리로 사후 측정한다.

## 7. 선행 RFC와의 관계

- **RFC-0303 (수정 조항)**. "예정 heartbeat는 그 자체가 wake 신호"는 유지한다. wake는
  계속 발생한다. 본 RFC가 추가하는 것은 대화 진행 중 Autonomous 레인의 슬롯 획득이
  typed·가시·부채 유계로 미뤄질 수 있다는 것이다. 0303이 기각한 것(no-progress 판정,
  wake tombstone, 자동 정지)과 다르다. 부채는 진행 판정이 아니라 빚진 슬롯의 장부고,
  아무것도 억제하지 않고 지급만 보장한다.
- **RFC-0385 §8 (범위 선언)**. 이 홀드는 "말할 수 있는가"(내용)가 아니라 "언제 슬롯이
  제공되는가"(중재)다. 반복 억제 아님, rate cap 아님(턴 수 상한 없음), noop backoff
  아님, 침묵 강제 아님, wake 빈도 변경 아님(wake는 그대로, D는 자율에 대한 하한 보장).
- **RFC-0377 (구별)**. 0377은 인바운드 채팅의 배치 경계를 정하며 debounce를 거부했다
  ("claim 시각에 pending 전부"). 본 RFC의 W는 어떤 채팅 턴도 지연시키지 않는다. 유일한
  예외는 지급 경계 1회이고 유계·고지된다.
- **RFC-0373 (계승과 마무리)**. 0373이 열어둔 정책을 닫는다. 0373이 기각한 방향(chat
  레인에 cap/timeout/cooldown)은 계승해 기각 유지 — 16.3분 채팅 턴은 정당했다.
  유계화하는 것은 chat이 아니라 지연이다. 0373의 검증 막대(bounded admissions)를
  §8이 이어받는다.
- **RFC-0315**: defer 사유는 typed 축에 올린다. **RFC-event-queue-admit-all-ready**:
  선점/yield가 자극을 버리지 않음을 전제로 계승. **RFC-0366**: 운영자 발화 경로와
  무관. **RFC-observe-by-waking-not-polling**: observe-condition wake에도 홀드 균일 적용.

## 8. Verification (fail-first)

현재 트리에서 전부 실패해야 한다.

1. 자율 턴 진행 중(느린 도구 1개 시나리오) chat op 제출 → bounded 시간(1 iteration)
   내 `started_at`. 현재는 긴 도구 배치 뒤로 밀린다.
2. chat 활동 후 W 이내, 빈 슬롯에 `run_autonomous_if_idle` → `Conversation_hold`
   반환. 현재는 실행된다.
3. defer 경로가 decision-audit 행 + counter 라벨을 남긴다. 현재 둘 다 없다.
4. D회 누적 → `Child_finished`에서 다음 cadence poll 이전 자율 wake·admission.
   현재는 채팅이 무조건 먼저다.
5. 큐에 chat op가 있어도 지급 + no-re-yield(지급 시각 이전 큐 op로는 yield하지
   않고, 신규 제출은 선점, 종료 후 FIFO 보존). 현재 탐사는 큐 존재 자체에 발동한다.
6. 홀드 중 `Turn_slot_released` wake 부재(callback 카운터로) + 홀드 밖에서는 기존
   3조건 계약 회귀(`keeper_owner.mli` 서술과 함께 pin).
7. `.mli` 순서 계약 고정: §2의 제공 순서와 홀드 계약을 `keeper_owner.mli`에 서술하고
   테스트가 고정한다. skip 라벨 pin 테스트 확장.

## 9. Non-goals

- Maintenance 레인 변경(양쪽 측정에서 홀더 0건)
- 레인 분리 / 병렬 턴(단일-기록자 불변식 유지)
- 채팅 턴 길이 제한(0373 기각 방향)
- intake batching(0377)
- 내용 기반 억제, noop 판정(0385 §8)
- wake 빈도 변경
- FIFO 대기(이전 채팅 op 뒤에 서는 30건) — 0377의 영역

## 10. References

코드:

- `lib/keeper/keeper_owner.ml` — `Run_if_idle`(:1051-1099), `Child_finished`(:1100-1127),
  `notify_turn_slot_released`(:321-334), `autonomous_lost_slot`(:1063-1065),
  `Interrupt_running_operation`(:833-853), `autonomous_block`(:48-50)
- `lib/keeper/keeper_owner.mli` — 단일-기록자 불변식(:48-68), wake 3조건 계약(:175-201)
- `lib/keeper/keeper_heartbeat_loop.ml` — admission 선행 구조(:565, :697, :702),
  슬롯 안 audit/counter(:742, :814-829), defer 경로(:1416-1425)
- `lib/keeper/keeper_unified_turn.ml` — `chat_yield_request`(:152-186),
  post-tool 경계 선행(:280-283)
- `lib/keeper/keeper_unified_turn_success.ml` — yield 처리(:450-458)
- `lib/keeper/keeper_agent_run.ml` — yield 탐사(:1034-1045)
- `lib/keeper/keeper_unified_metrics_failure.ml` — last_ts 시도 의미(:70-84)
- `lib/keeper/keeper_registry_setup.ml` — `interrupt_current_turn_exact`(:1331-1379)
- `lib/keeper/keeper_chat_operation_store.ml` — FIFO claim(:747-780)
- `lib/keeper/keeper_world_observation.ml` — `scheduled_autonomous_decision`(:1641-1687),
  관측 경로의 chat store 스킵(:1495-1503)
- `lib/server/server_runtime_bootstrap.ml` — wake 결선(:1069-1097)
- `lib/keeper/surface_ref.ml` — 발화면 닫힌 합타입(:6-30)
- `lib/config/keeper_runtime_setting_registry.ml` — 폐기 fairness 선례(:170-181)
- `lib/config/env_config_keeper.ml` — cadence 기본(:464-472)

RFC: 0373, 0303, 0385, 0377, 0315, 0366, event-queue-admit-all-ready,
observe-by-waking-not-polling.

측정 재현: 스크립트는 라이브 base path(`~/me/.masc`)의
`keepers/*/chat-operations.sqlite3`(operations 표)와 `logs/system_log_YYYY-MM-DD.jsonl`
("keepalive turn scheduled" / "Keeper Owner deferred autonomous work" /
"yielded autonomous Owner child" 라인)에서 위 수치를 재계산한다.
