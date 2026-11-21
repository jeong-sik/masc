---
rfc: "keeper-reaction-and-queue"
title: "Keeper 는 무엇에 깨고 언제 받는가 — 반응·실림과 틱 경계"
status: Draft
created: 2026-11-22
updated: 2026-11-22
author: vincent
related: ["a-keeper-takes-every-waiting-message-in-one-turn", "official-client-start-seed-window", "keeper-context-window-in-tokens"]
---

# RFC: Keeper 는 무엇에 깨고 언제 받는가 — 반응·실림과 틱 경계

- 상태: Draft. §1 은 운영자 결정과 정할 것, §2~§3 은 실측과 지금 코드, §4 는 제안, §5·§6 은 불변식과 Librarian 제약, §8 은 켜기 전 판정 기준이다.
- 코드 기준: origin/main `3e2f6b7bb03c`. 실측: 2026-11-21 11:00~24:00 KST 운영(`~/me`).
- 이 RFC 는 `RFC-a-keeper-takes-every-waiting-message-in-one-turn.md`(이하 묶음 RFC)의 §1-3 일부와 §6 한 줄을 대체한다(§1.1).

## 0. 요약

- **[사실]** 13시간 동안 Keeper 17개가 턴 3,419번을 열었다. 큐 입력이 들어올 때마다 턴이 하나씩 열린다.
- **[사실]** 같은 구간 Claude Code 요청의 문맥 토큰은 20.7억이다. 예약 43%, Board 31%, heartbeat 밖(Keeper 사이 채팅) 15%, 주기 9% 다.
- **[사실]** 큐에 넣는 일은 모두 Keeper 를 깨운다. urgency 는 순서만 정하고 깨우기를 늦추지 않는다(§3.1).
- **[제안]** 깨우는 규칙만 바꾼다. 받는 규칙은 그대로다.
  - 무엇에 깨는가: 입력 종류마다 만드는 쪽이 `React | Carry` 를 정한다(§4.2). 입력의 뜻으로 가른다.
  - 언제 깨는가: 사람 입력은 바로 깨운다. Keeper 가 만든 React 입력은 그 Keeper 의 틱 경계에서 깨운다(§4.3).
  - 무엇을 받는가: 어느 까닭으로 열린 턴이든 기다리던 입력을 모두 가져간다(묶음 RFC §1-2).
- **[제안]** 버리거나 중복을 지우는 입력은 없다. 모든 입력이 턴에 닿는다.

## 1. 운영자 결정과 정할 것

### 1.1 결정 (2026-11-22)

1. 묶음 RFC §1-3 의 「debounce, 라운드 상한도 두지 않는다」 중 **깨우는 시점**은 이 RFC 가 대체한다. Keeper 가 만든 입력은 틱 경계에서 깨운다.
   - 까닭: 그 결정 아래에서 claim 때 묶음은 채팅 549건 중 28번만 일어났다(§2.4). Keeper 가 한가할 때 입력이 오면 바로 혼자 돈다.
   - 묶음 RFC §6 의 「debounce」 줄도 같은 범위에서 대체한다.
2. 묶음 RFC 의 나머지 결정은 그대로다.
   - §1-1 큐는 업무 종류를 모른다.
   - §1-2 메시지는 한 번에 쭉 들어간다.
   - §1-3 의 휴리스틱 금지와 묶음 개수 상한 금지.
   - §1-4 멈추지 않는다.
   - §1-5 턴은 typed 끝에서 닫힌다.

### 1.2 정할 것

1. **Carry 로 둘 입력 종류.** 후보는 §4.1 표에 적었다.
2. **틱 길이.** 제안은 300초다. 선언된 설정(§4.3)으로 두고 코드 리터럴로 두지 않는다.
3. **틱을 건너뛸 입력.** 보낸 사람으로 가른다. 제안은 사람이 보낸 입력(운영자 채팅, HITL 답, Ask 답)이다.
4. **켜는 순서.** 제안은 §8 이다.

## 2. 무슨 일이 있었나

### 2.1 턴은 입력 수만큼 열린다

2026-11-21 11:00~24:00 KST, 모든 Keeper 의 `turns.jsonl` `opened` 줄 3,419개를 실어 온 큐 입력 종류로 셌다. 턴 하나가 여러 종류를 실으면 각 종류에 한 번씩 센다.

| 입력 종류 | 그 종류를 실은 턴 | 그 종류만 실은 턴 |
|---|---|---|
| Board 신호(`board`) | 851 | 614 |
| 예약(`schedule`) | 850 | 765 |
| 판정으로 들어온 Board 글(`board_attention`) | 515 | 427 |
| 도구 결과(`tool_result`) | 380 | 366 |
| 위임 결과(`delegate`) | 346 | 158 |
| 완료 승인(`completion_approved`) | 59 | 19 |
| Ask 답(`ask`) | 22 | 12 |
| 작업 공간 메시지(`workspace_message`) | 20 | 2 |
| 완료 거절(`completion_rejected`) | 19 | 7 |
| 작업 취소(`task_cancelled`) | 1 | 1 |

- 큐 입력 없이 열린 턴은 753번이다. 주기 턴 234번과 Keeper 사이 채팅 작업(구간 안에 548건 생성)이다.
- 대부분의 턴은 입력 한 종류만 싣는다. 입력 하나가 턴 하나를 연다.

### 2.2 토큰은 어디서 나오나

Claude Code 요청을 그 요청이 속한 턴의 출처로 나눴다. 요청 하나의 문맥은 input + cache_read + cache_creation 토큰이다. 출처는 그 턴 직전 15초 안의 `keepalive turn scheduled` 로그 사유다. 그런 줄이 없으면 heartbeat 밖이다.

| 출처 | 턴 | Claude Code 요청 | 문맥 토큰 | 몫 |
|---|---|---|---|---|
| 예약 | 302 | 1,866 | 8.96억 | 43% |
| Board | 318 | 1,248 | 6.39억 | 31% |
| heartbeat 밖 | 136 | 643 | 3.18억 | 15% |
| 주기 | 125 | 361 | 1.87억 | 9% |
| 그 밖의 반응 | 23 | 59 | 0.32억 | 2% |

Claude Code 세션을 가진 Keeper 만 들어간다. 다른 runtime 의 토큰은 세지 않았다.

### 2.3 틱으로 다시 세면

같은 턴을 「Keeper 마다 틱 하나에 턴 하나」로 다시 셌다. Keeper 와 틱 번호의 쌍 수를 센 것이다. 묶인 턴이 길어질 수 있으니 토큰이 같은 비율로 줄지는 않는다.

| 틱 | 남는 턴 |
|---|---|
| 60초 | 2,872 (84%) |
| 300초 | 1,392 (41%) |
| 600초 | 924 (27%) |
| 1,800초 | 399 (12%) |

### 2.4 claim 때 묶음은 드물다

같은 구간 채팅 작업 549건 가운데 다른 작업과 한 실행으로 묶인 것은 28번이다(2건 20번, 3건 7번, 7건 1번). 지금 `Keeper_chat_operation_batch.select` 는 출처·답할 곳·지시가 같은 연속 구간만 묶는다(묶음 RFC §2.2).

### 2.5 캐시는 1시간 안팎 유지된다

같은 transcript 안에서 앞 요청과의 간격으로 Claude Code 요청을 나눴다(02:00~15:30Z).

| 앞 요청과의 간격 | 요청 | cache_read | cache_creation |
|---|---|---|---|
| 0~60초 | 3,698 | 99% | 1% |
| 60~300초 | 373 | 98% | 2% |
| 330~600초 | 34 | 95% | 5% |
| 600~1,800초 | 52 | 93% | 7% |
| 1,800~3,600초 | 27 | 93% | 7% |
| 3,600초 넘음 | 1 | 0% | 100% |

30분 이하 틱은 Claude Code 캐시를 놓치지 않는다. 30분 넘는 간격의 표본이 작아 신뢰도는 Medium 이다. 다른 runtime 의 캐시는 재지 않았다.

## 3. 지금 코드

### 3.1 넣으면 깬다

- `Keeper_event_queue` 머리 주석: enqueue 는 Event Layer 동작이고, dedup·urgency 는 enqueue 를 늦추지 않는다. Keeper 마다의 wakeup atomic 이 heartbeat sleep 을 끊는다.
- `Keeper_keepalive_signal.wakeup_keeper ?stimulus` 는 입력을 먼저 durable 하게 적고 깨운다.
- `specs/keeper-state-machine/KeeperEventQueue.tla` 의 SafetyInvariant 가 이 계약을 모델링한다.
- urgency(`Immediate | Normal | Low`)는 큐 안 순서만 정한다.

### 3.2 깨운 뒤

- heartbeat loop 의 sleep 은 기본이 `Interrupt_on_wakeup` 이다. 깨우기가 오면 바로 사이클을 돈다.
- `Serve_wakeup_after_duration` 은 이미 있다. 깨우기를 기간 끝에 한 번 처리한다. 지금은 provider 쉼에만 쓴다(#34653).
- 사이클은 준비된 큐 입력을 받아 한 턴에 싣는다. 결과 전달이 있는 예약은 같은 답할 곳끼리만 한 턴을 나눈다.
- 채팅 작업은 다른 줄이다. Owner 가 `Chat_operation_store.claim_next ~batch:Keeper_chat_operation_batch.select` 로 집는다.

### 3.3 주기

- 운영의 주기는 `keeper.keepalive_interval_sec = 1800` 이다(`runtime_params.json`).
- #54338 뒤로는 끝까지 돈 예약 턴도 주기 경계를 채운다.

## 4. 제안

### 4.1 입력 종류 표

만드는 쪽과 지금 urgency 는 코드에서 읽었다. 제안 열의 「결정」은 §1.2-1 에서 운영자가 정한다.

| payload | 만드는 쪽 | 지금 urgency | 제안 |
|---|---|---|---|
| `Board_signal` | Board 쓰기 → `Board_wake` | 주소·전체 알림 Immediate, 그 밖 Normal | React, 틱 |
| `Board_routing_pending` | Board 부모 읽기 실패 | 확인 필요 | React, 틱 |
| `Board_attention` | 관심 판정(`keeper_board_attention_candidate`) | Normal | Carry 후보(결정) |
| `Bootstrap` | `keeper_supervisor_launch` | Normal | React |
| `Tool_result_ready` | `keeper_client_tool_outbox_wake` | Immediate | React, 틱 여부 결정 |
| `Fusion_completed` | `fusion_sink` | Immediate | React, 틱 |
| `Schedule_due` | `server_schedule_consumers` | 예약 body 가 정함 | React(예약이 시각을 정함) |
| `Connector_attention` | `server_connector_attention_delivery` | Low | React, 틱 |
| `Hitl_resolved` | 승인 큐 | Immediate | React, 틱 건너뜀(사람) |
| `Ask_answered` | `keeper_ask_answer_wake` | Normal | React, 틱 건너뜀(사람) |
| `Completion_authority_rejected` | `completion_authority_wakeup` | Immediate | React, 틱 |
| `Task_cancelled` | `keeper_task_cancellation_wake` | Normal | React, 틱 |
| `Workspace_message` | `server_bootstrap_loops` | Immediate | React, 틱 |
| `Delegate_completed` | `keeper_delegate_completion_wake` | Immediate | React, 틱 |
| `Composition_completed` | `keeper_composition_completion_wake` | Immediate | React, 틱 |
| `Owned_job_completed` | `keeper_owned_job_completion_wake` | Immediate | React, 틱 |
| `Task_outcome` | `keeper_task_outcome_wake` | Immediate | Carry 후보(결정) |
| Board 반응·투표 | `Board_signal` 안의 kind | 위와 같음 | Carry 후보(결정) |
| 채팅 작업(Keeper 가 보냄) | `masc_keeper_delegate` 등 | 별도 줄 | 틱 |
| 채팅 작업(사람이 보냄) | 대시보드·TUI·Slack | 별도 줄 | 틱 건너뜀 |
| 주기 | heartbeat loop | — | 틱 격자 위 |

- 이 표는 손으로 적었다. 구현 PR 은 이 표를 payload 의 `match` 로 바꾼다. 새 payload 가 생기면 컴파일러가 빈 칸을 알린다.

### 4.2 React | Carry — 무엇에 깨는가

- 입력을 만드는 쪽이 `React` 와 `Carry` 중 하나를 고른다. payload 마다 `match` 로 빠짐없이 적는다.
- `React`: 지금처럼 적고 깨운다.
- `Carry`: 적기만 하고 깨우지 않는다. 다음 사이클이 받아 그 턴에 같이 싣는다.
- Carry 입력은 다음에 열리는 턴에 실린다. 어느 까닭으로 열린 턴이든 된다.
- 기다리는 시간의 상한은 주기 하나와 턴 하나다. 돌고 있는 Keeper 의 루프는 한 주기 안에 깨어 큐를 읽는다. 큐에 행이 있으면 그 행이 반응형 트리거가 되어 턴을 연다. 이 상한은 §5 의 불변식으로 확인한다.
- 입력의 뜻을 타입으로 가르는 일이라 시간 장치가 아니다.

### 4.3 틱 경계 — 언제 받는가

**정의.**
- Keeper k 의 틱 경계는 `n × T + offset(k)` 다. T 는 틱 길이다.
- `offset(k)` 는 Keeper 이름에서 정해지는 고정값이다(0 ≤ offset < T). 모든 Keeper 가 같은 초에 함께 출발하지 않게 한다.
- 경계는 마지막 턴 시각에서 재지 않는다. 그래서 cooldown 이 아니다.

**깨우는 규칙.**
- Keeper 가 만든 React 입력이 들어오면 적기만 한다. 깨우기는 그 Keeper 의 다음 경계에 한 번 보낸다.
- 경계에 기다리던 입력이 있으면 턴을 연다. 한 턴에 묶을 수 없는 입력(답할 곳이 다른 예약 등)이 남으면 이어서 다음 턴을 연다. 다음 경계를 기다리지 않는다.
- 그래서 턴 수에 상한을 두지 않는다. 깨우는 시각만 경계로 모은다.

**받는 규칙(그대로).**
- 어느 까닭으로 열린 턴이든, 그때 기다리던 입력을 모두 가져간다. 사람이 연 턴, 주기 턴, 예약 턴도 같다.
- 그래서 경계 전에 Keeper 입력이 와 있으면, 사람 입력이 연 턴에 같이 실릴 수 있다. 도착 시각으로 거르지 않는다.

**대상.**
- Keeper 가 만든 React 입력이다. 사람이 보낸 입력은 보낸 사람으로 가르고 틱을 건너뛴다. 업무 종류로 가르지 않는다(묶음 RFC §1-1).
- 예약은 예약이 정한 시각에 깬다. 예약이 이미 시각을 정한 일이기 때문이다.

**설정.**
- `keeper.turn_tick_sec` 를 `Runtime_params` 로 등록한다. 값은 `Off | Every of seconds` 처럼 타입으로 둔다. 0 같은 특별한 값으로 끄지 않는다.
- 기본값은 `Off` 다. 켜는 것은 §8 의 순서를 따른다.

**구현 지점(스케치).**
- 깨우는 쪽: `wakeup_keeper` 가 입력의 보낸 사람을 보고, Keeper 가 보낸 React 입력이면 wakeup atomic 대신 「다음 경계에 깨움」을 건다.
- heartbeat loop: sleep 길이를 「주기 경계」와 「걸린 틱 경계」 중 이른 쪽으로 잡는다. 사람 입력의 깨우기는 지금처럼 sleep 을 끊는다(`Interrupt_on_wakeup`).
- 턴이 끝난 뒤 남은 입력이 이미 받은 묶음에서 나온 것이면 바로 다음 턴을 연다(`next_cycle_starts_now`, 지금과 같음). 턴 도중 새로 온 Keeper 입력은 다음 경계를 기다린다.
- 채팅 줄: Keeper 가 보낸 작업은 경계에서만 claim 을 시작한다. 사람이 보낸 작업은 지금처럼 바로 claim 한다. claim 하면 기다리던 작업을 봉투째 함께 집는다(선행 조건).

**선행 조건.**
- 보낸 사람이 다른 채팅을 봉투째 한 턴에 넣는 일(묶음 RFC §4.2·§4.3)이 먼저다.
- 지금 `select` 는 같은 출처의 연속 구간만 묶는다. 틱만 넣으면 보낸 사람 수만큼 경계마다 턴이 이어진다. 턴 수는 줄지 않고 지연만 는다.

### 4.4 주기와 하나로

- 주기 턴도 틱 격자 위에서 연다. 주기 경계가 되면 그 뒤 첫 틱 경계에서 연다.
- #54338 의 규칙(끝까지 돈 예약 턴이 주기 경계를 채움)은 그대로다.
- 그러면 Keeper 마다 시계가 틱 하나로 모인다. 예약만 자기 시각을 따로 가진다.

### 4.5 결정론과 비결정론의 경계

- masc 가 정한다(결정론):
  - 입력 종류마다 React 인지 Carry 인지(타입)
  - 틱 경계(설정과 Keeper 이름)
  - 경계에서 무엇을 받는지(도착 시각)
- Keeper 가 정한다(비결정론): 받은 묶음에서 무엇이 낡았는지, 무엇부터 할지, 답을 어떻게 쓸지.
- 새 durable 상태는 없다. 경계는 시계와 설정에서 계산한다. 지난 턴의 기록을 scheduling 근거로 쓰지 않는다.

## 5. 불변식과 TLA+

(masc-d3 이 쓴다.) 새 spec `specs/keeper-state-machine/KeeperReactionQueue.tla` 와 cfg 들이다. 구현 1단계에서 `KeeperEventQueue.tla` 를 이것으로 바꾼다.
- 사람 입력이 기다리면 깨우기 신호가 있거나 턴이 돌고 있다.
- 경계에서 받은 입력이 남으면 깨우기 신호가 있거나 턴이 돌고 있다.
- Carry 의 나이는 주기 하나와 턴 하나를 넘지 않는다.
- 공정성 아래에서 모든 입력은 결국 턴에 실린다.
- buggy cfg 는 하나씩 반드시 위반한다: 사람 입력이 경계를 기다림, 틱마다 턴 하나, 같은 출처만 묶는 select, 주기 사이클이 Carry 를 두고 Skip.

## 6. Librarian 제약

(masc-d3 이 쓴다.) 봉투가 커지면 턴 첫 요청이 max-context 를 더 자주 넘는다. 그때 `past_max_context` 가 시작점을 옮긴다. 컷 설치와 `librarian_memory` lane 켜기 뒤에 켠다. `RFC-official-client-start-seed-window.md` 와 같은 순서다.

## 7. 무엇이 나빠지나

- Keeper 사이 응답이 최대 틱 하나만큼 늦다. 위임 → 결과 → 다음 일처럼 이어지는 사슬은 한 단계마다 틱 하나까지 늦어진다(300초 틱이면 단계마다 최대 5분).
- 턴 하나가 받는 입력이 많아져 턴이 길어진다. 첫 요청이 커진다(§6).
- 틱보다 긴 턴을 도는 Keeper 는 효과가 작다. 턴이 끝나면 이미 지난 경계의 입력을 바로 받는다.
- 예약 간격이 틱보다 짧아도 예약은 제 시각에 깬다. 예약을 틱으로 늦추지 않는다.

## 8. 켜는 순서와 판정 기준

**순서.**
1. 입력 종류 표를 `match` 로 바꾸고 React | Carry 를 넣는다. 기본은 모두 React 다(동작 변화 없음). 이 단계에서 `KeeperEventQueue.tla` 를 `KeeperReactionQueue.tla` 로 바꾼다(hard cut, §5).
2. 묶음 RFC §4.2·§4.3(봉투 묶음)을 구현한다.
3. Librarian 컷을 설치하고 `librarian_memory` lane 을 켠다.
4. 운영자가 고른 Carry 종류를 켠다.
5. `keeper.turn_tick_sec` 를 켠다.

**판정.** 켜기 전과 켠 뒤를 같은 길이 구간으로 잰다.
- Keeper 마다 연 턴 수, 입력 종류별 턴 수(§2.1 의 셈)
- 출처별 문맥 토큰(§2.2 의 셈)
- cache_read 몫(§2.5 의 셈)
- 입력 종류별 도착 → 턴 시작 지연. 반응 원장(`Keeper_reaction_ledger`)의 stimulus → `Turn_started` 로 잰다. 켜기 전 값부터 먼저 잰다.
- 새 세션 첫 요청이 자기 창을 넘은 비율, W2 경보 수
- 첫 턴 실패 수

사람이 보낸 입력의 지연이 늘거나, 첫 턴 실패나 W2 경보가 늘면 끈다.

## 9. 열린 질문

1. `Tool_result_ready` 는 Keeper 자기 일의 이어짐이다. 틱을 기다리게 할지 정해야 한다. 기다리면 자기 일이 틱만큼 늦고, 건너뛰면 380번(§2.1)이 그대로 남는다.
2. 다른 runtime(Codex, Agent Core, HTTP provider)의 캐시 유지 시간은 재지 않았다.
3. `offset(k)` 를 이름에서 정하면, Keeper 이름을 바꿀 때 경계가 옮겨진다. 문제가 되는지 본다.
4. 여러 계정 배포(`is_multi_account`)에서 틱을 어디서 세는지 정해야 한다.

## 10. 하지 않는 것

- 입력을 버리거나 중복을 지우는 일
- 턴 수나 묶음 크기의 상한
- 마지막 턴에서 재는 cooldown
- 업무 종류(리뷰, 배포 등)로 가르는 일
- 도는 턴을 끊는 일
- Keeper 지시나 프롬프트에 「덜 깨라」를 적는 일
