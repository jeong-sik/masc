---
rfc: "keeper-reaction-and-queue"
title: "Keeper 는 무엇에 깨고 언제 깨는가 — 바로·틱·실림"
status: Draft
created: 2026-11-22
updated: 2026-11-22
author: vincent
related: ["a-keeper-takes-every-waiting-message-in-one-turn", "official-client-start-seed-window", "keeper-context-window-in-tokens"]
---

# RFC: Keeper 는 무엇에 깨고 언제 깨는가 — 바로·틱·실림

- 상태: Draft. §1 은 운영자 결정과 정할 것, §2~§3 은 실측과 지금 코드, §4 는 제안, §5·§6 은 불변식과 Librarian 제약, §8 은 켜는 순서와 판정 기준이다.
- 코드 기준: origin/main `3e2f6b7bb03c`. 실측: 2026-11-21 11:00~24:00 KST 운영(`~/me`).
- 이 RFC 는 `RFC-a-keeper-takes-every-waiting-message-in-one-turn.md`(이하 묶음 RFC)의 §1-3 일부와 §6 한 줄을 대체한다(§1.1).

## 0. 요약

- **[사실]** 13시간 동안 Keeper 17개가 턴 3,419번을 열었다. 큐 입력이 들어올 때마다 턴이 하나씩 열린다.
- **[사실]** 같은 구간 Claude Code 요청의 문맥 토큰은 20.7억이다. 예약 43%, Board 31%, heartbeat 밖(Keeper 사이 채팅) 15%, 주기 9% 다.
- **[사실]** 큐에 넣는 일은 하나만 빼고 모두 Keeper 를 깨운다. urgency 는 순서만 정하고 깨우기를 늦추지 않는다. 예외는 Board 읽기가 잠깐 실패할 때 남기는 `Board_routing_pending` 행이다(§3.1).
- **[제안]** 깨우는 규칙만 바꾼다. 받는 규칙은 그대로다.
  - 입력을 만드는 쪽이 깨우기를 셋 중 하나로 고른다. 바로(`Now`), 틱 경계에서(`At_tick`), 깨우지 않고 다음 턴에 실림(`Carry`)이다(§4.2).
  - 고르는 근거는 입력 종류와 보낸 사람 종류다. 둘 다 타입으로 읽는다. 업무 종류로 가르지 않는다.
  - 틱 경계는 Keeper 마다 고정 시차를 둔 격자다(§4.3).
  - 어느 까닭으로 열린 턴이든 기다리던 입력을 모두 가져간다(묶음 RFC §1-2).
  - 반응이 없으면 스스로 깨는 간격을 30분 → 1시간 → 2시간으로 늘린다. 반응이 오면 30분으로 돌아간다. Keeper 마다 따로 정할 수 있다(§4.4).
- **[제안]** 버리거나 중복을 지우는 입력은 없다. 모든 입력이 턴에 닿는다.

## 1. 운영자 결정과 정할 것

### 1.1 결정 (2026-11-22)

1. 묶음 RFC §1-3 의 「debounce, 라운드 상한도 두지 않는다」 중 **깨우는 시점**은 이 RFC 가 대체한다. 다른 Keeper 가 만든 입력은 틱 경계에서 깨운다.
   - 까닭: 그 결정 아래에서 claim 때 묶음은 채팅 548건 중 28번만 일어났다(§2.4). Keeper 가 한가할 때 입력이 오면 바로 혼자 돈다.
   - 묶음 RFC §6 의 「debounce」 줄도 같은 범위에서 대체한다.
2. 깨우지 않고 실을(`Carry`) 입력은 셋이다.
   - 관심 판정으로 들어온 Board 글(`Board_attention`)
   - Board 반응·투표(`Reaction_changed`, `Vote_cast`)
   - 승인된 완료(`Task_outcome`). 거절은 `Completion_authority_rejected` 로 따로 온다.
3. 바로(`Now`) 깨울 입력은 셋이다.
   - 사람이 보낸 입력
   - 외부 연결에서 온 알림(`Connector_attention`)
   - Keeper 가 스스로 시작한 일의 결과: 도구 결과, 백그라운드 작업, 조합 실행, fusion 심의
4. 입력을 모으는 틱의 값은 300초다. 선언된 설정으로 둔다(§4.3).
5. 반응이 없을 때 스스로 깨는 간격은 두 배씩 늘린다(§4.4).
   - 30분에서 시작해 1시간, 2시간으로 늘리고 2시간에서 멈춘다. 반응이 오면 30분으로 돌아간다.
   - 시작값과 상한은 Keeper 마다 따로 정할 수 있다. 정하지 않은 Keeper 는 전체 기본값을 쓴다.
   - 까닭: 5분 틱은 처리할 입력이 없으면 턴을 열지 않는다. 반응이 없을 때 Keeper 를 깨우는 것은 이 간격 하나다.
6. 묶음 RFC 의 나머지 결정은 그대로다.
   - §1-1 큐는 업무 종류를 모른다.
   - §1-2 메시지는 한 번에 쭉 들어간다.
   - §1-3 의 휴리스틱 금지와 묶음 개수 상한 금지.
   - §1-4 멈추지 않는다.
   - §1-5 턴은 typed 끝에서 닫힌다.

### 1.2 정할 것

1. **켜는 순서.** 제안은 §8 이다.

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

- 큐 입력 없이 열린 턴은 753번이다.
  - 주기 턴 234번
  - 구간 안에서 시작한 채팅 실행 499번. 시작한 작업 539건에서 묶여서 줄어든 40건을 뺀 값이다.
  - 아직 나누지 못한 20번
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

이 셈은 모든 입력을 틱에 맞춘 하한이다. 바로 깨우는 입력(§1.1-3)은 틱을 기다리지 않으니, 실제로 남는 턴은 이보다 많다.

### 2.4 claim 때 묶음은 드물다

같은 구간에 만든 채팅 작업 548건 가운데 다른 작업과 한 실행으로 묶인 것은 28번이다(2건 20번, 3건 7번, 7건 1번). 지금 `Keeper_chat_operation_batch.select` 는 출처·답할 곳·지시가 같은 연속 구간만 묶는다(묶음 RFC §2.2).

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

### 2.6 쉬는 동안 간격을 늘리면

같은 구간을 다시 돌렸다. 주기 턴이 한 번이라도 있던 Keeper 15개만 센다.

- 규칙: 턴이 끝나면 다음에 저절로 열리는 턴은 t초 뒤다. 입력으로 열린 턴 뒤에는 t 가 시작값으로 돌아간다. 저절로 열린 턴 뒤에는 t 가 2배가 되고, 상한을 넘지 않는다.
- 입력으로 열린 턴은 실제 시각 그대로 둔다. 저절로 열린 턴이 뒤의 입력을 바꿨을 수 있지만 반영하지 않았다.

| 규칙 | 저절로 열린 턴 |
|---|---|
| 지금: 1,800초마다, 입력 턴과 상관없음 (실측) | 234 |
| 300초에서 시작, 상한 1,800초 | 751 |
| 300초에서 시작, 상한 7,200초 | 731 |
| 600초에서 시작, 상한 7,200초 | 295 |
| 1,800초, 늘리지 않음 (마지막 턴에서 잼) | 86 |
| 1,800초에서 시작, 상한 3,600초 | 60 |
| 1,800초에서 시작, 상한 7,200초 | 56 |

- 300초에서 시작하면 오히려 늘어난다. 입력 턴마다 300·600·1,200초 뒤에 턴이 열리기 때문이다.
- 줄어드는 몫의 대부분은 「마지막 턴에서 잰다」에서 나온다(234 → 86). 2배로 늘리기는 86 → 56 으로 더 줄인다.
- 할 일이 남은 Keeper 도 입력이 없으면 덜 움직인다. 1,800초에서 시작해 상한 7,200초면 최대 2시간에 한 번이다.
- 주기 경계는 진척 없는 턴을 다시 해 보는 타이머이기도 하다(#54338). 그래서 어느 턴이 시작값으로 되돌리는지는 #54338 처럼 턴 결과로 정해야 한다. 실패한 턴은 되돌리지 않는다.

## 3. 지금 코드

### 3.1 넣으면 깬다

- `Keeper_event_queue` 머리 주석: enqueue 는 Event Layer 동작이고, dedup·urgency 는 enqueue 를 늦추지 않는다. Keeper 마다의 wakeup atomic 이 heartbeat sleep 을 끊는다.
- `Keeper_keepalive_signal.wakeup_keeper ?stimulus` 는 입력을 먼저 durable 하게 적고 깨운다.
- `specs/keeper-state-machine/KeeperEventQueue.tla` 의 SafetyInvariant 가 이 계약을 모델링한다.
- urgency(`Immediate | Normal | Low`)는 큐 안 순서만 정한다.
- 예외가 하나 있다. Board 읽기가 잠깐 실패하면 `retain_unavailable_board_routing`(`keeper_keepalive_signal.ml`)이 `Board_routing_pending` 행을 깨우지 않고 넣는다. 주석은 「This row alone never requests a wake」다. 사이클이 읽을 때 경로를 다시 정한다. `Carry` 의 선례다.

### 3.2 깨운 뒤

- heartbeat loop 의 sleep 은 기본이 `Interrupt_on_wakeup` 이다. 깨우기가 오면 바로 사이클을 돈다.
- `Serve_wakeup_after_duration` 은 이미 있다. 깨우기를 기간 끝에 한 번 처리한다. 지금은 provider 쉼에만 쓴다(#34653).
- 사이클은 준비된 큐 입력을 받아 한 턴에 싣는다. 결과 전달이 있는 예약은 같은 답할 곳끼리만 한 턴을 나눈다.
- 채팅 작업은 다른 줄이다. Owner 가 `Chat_operation_store.claim_next ~batch:Keeper_chat_operation_batch.select` 로 집는다.

### 3.3 주기

- 운영의 주기는 `keeper.keepalive_interval_sec = 1800` 이다(`runtime_params.json`). Keeper toml 에 덮어쓰기는 없다.
- 주기 사이클도 큐를 읽는다. `heartbeat_event_intake` 는 깨운 종류로 막지 않는다.
- 모든 Keeper 가 `reactive = true` 다. 그래서 큐에 행이 있으면 사이클이 턴을 연다. `on_demand` Keeper 도 같다.
- scheduled-autonomous gate 가 꺼진 Keeper 는 큐 행이 없는 주기 사이클을 `Scheduled_autonomous_disabled` 로 Skip 한다(`keeper_world_observation.ml` 의 판정). 그래도 `periodic_cadence_after_cycle` 은 `periodic_due` 면 주기 경계를 쓴다.
- `pending_stimulus_remains`(`next_cycle_starts_now` 가 읽는다)는 `~ready:(fun _ -> true)` 로 모든 행을 센다.
- #54338 뒤로는 끝까지 돈 예약 턴도 주기 경계를 채운다.

### 3.4 보낸 사람은 어디서 아나

- 큐 입력(`stimulus`)은 `post_id`·`urgency`·`arrived_at`·`payload` 넷뿐이다. 보낸 사람 종류가 없다.
- 만드는 쪽은 이미 알거나 같은 방법으로 알 수 있다.
  - 작업 공간 메시지: `workspace_message_speaker` 가 가른다. Keeper 등록부에 같은 이름이 있으면 Keeper, 아니면 외부 작성자다. 주석대로 등록부 일치가 증명이고, 이름의 모양으로 가르지 않는다.
  - 완료 판정: `completion_authority = Human_operator | System_llm_agent` 다.
  - 채팅 작업: 저장소의 `speaker_authority` 가 있다.
  - Board 글·댓글: 작성자는 `Agent_id` 다. 같은 등록부 일치로 가를 수 있다.
  - 작업 취소: `tc_cancelled_by` 는 문자열이다. 같은 등록부 일치가 필요하다.

## 4. 제안

### 4.1 깨우기 표

만드는 쪽과 지금 urgency 는 코드에서 읽었다. 「결정」은 §1.1 의 운영자 결정이다.

| 입력 | 만드는 쪽 | 지금 urgency | 깨우기 |
|---|---|---|---|
| `Board_signal` 글·댓글 | Board 쓰기 → `Board_wake` | `Explicit_mention`·`Broadcast` Immediate, 그 밖 Normal | 사람이 쓰면 `Now`, Keeper 가 쓰면 `At_tick` |
| `Board_signal` 반응·투표 | 같음 | 같음 | `Carry` (결정) |
| `Board_routing_pending` | Board 부모 읽기 실패 | `Targets`·`Broadcast` Immediate, 그 밖 Normal | `Carry` (지금도 깨우지 않음) |
| `Board_attention` | `keeper_board_attention_candidate` | Normal | `Carry` (결정) |
| `Bootstrap` | `keeper_supervisor_launch` | Normal | `Now` |
| `Schedule_due` | `server_schedule_consumers` | 예약 body 가 정함 | `Now` (예약이 시각을 정함) |
| `Connector_attention` | `server_connector_attention_delivery` | Low | `Now` (결정) |
| `Hitl_resolved` | 승인 큐 | Immediate | `Now` (결정) |
| `Ask_answered` | `keeper_ask_answer_wake` | Normal | `Now` (결정) |
| `Tool_result_ready` | `keeper_client_tool_outbox_wake` | Immediate | `Now` (결정) |
| `Owned_job_completed` | `keeper_owned_job_completion_wake` | Immediate | `Now` (결정) |
| `Composition_completed` | `keeper_composition_completion_wake` | Immediate | `Now` (결정) |
| `Fusion_completed` | `fusion_sink` | Immediate | `Now` (결정) |
| `Task_outcome` | `keeper_task_outcome_wake` | Immediate | `Carry` (결정) |
| `Completion_authority_rejected` | `completion_authority_wakeup` | Immediate | `Human_operator` 면 `Now`, `System_llm_agent` 면 `At_tick` |
| `Task_cancelled` | `keeper_task_cancellation_wake` | Normal | 사람이 취소하면 `Now`, Keeper 가 취소하면 `At_tick` |
| `Workspace_message` | `server_bootstrap_loops` | Immediate | 외부 작성자면 `Now`, Keeper 면 `At_tick` |
| `Delegate_completed` | `keeper_delegate_completion_wake` | Immediate | `At_tick` |
| 채팅 작업 | 채팅 저장소 | 별도 줄 | Keeper 가 보내면 `At_tick`, 사람·외부면 `Now` |
| 주기 | heartbeat loop | — | 틱 격자 위(§4.4) |

- 이 표는 손으로 적었다. 구현 PR 은 이 표를 입력 종류와 보낸 사람 종류의 `match` 로 바꾼다. 새 payload 가 생기면 컴파일러가 빈 칸을 알린다.
- `At_tick` 은 다른 Keeper 가 만든 입력에만 붙는다.

### 4.2 바로 | 틱 | 실림 — 만드는 쪽이 고른다

- 입력을 만드는 쪽이 `Now | At_tick | Carry` 중 하나를 고른다. 입력 종류와 보낸 사람 종류를 `match` 로 빠짐없이 적는다.
  - `Now`: 지금처럼 적고 깨운다.
  - `At_tick`: 적고, 그 Keeper 의 다음 틱 경계에 깨운다(§4.3).
  - `Carry`: 적기만 한다. 다음에 열리는 턴에 실린다. 어느 까닭으로 열린 턴이든 된다.
- 보낸 사람 종류는 만드는 쪽에서 타입으로 읽는다(§3.4). 이름의 모양이나 접두어로 가르지 않는다.
- 만드는 쪽이 고른 깨우기 종류를 큐 행에 typed 필드로 적는다. 보낸 사람이 아니라 만드는 쪽의 결정을 적는 것이다.
  - 까닭: 턴을 열지 정하는 판정도 그 행이 깨우기를 올렸는지 알아야 한다. 같은 Board 댓글이라도 사람이 쓰면 `Now`, Keeper 가 쓰면 `At_tick` 이라, payload 만으로는 가를 수 없다.
  - 필드가 없으면 판정이 보낸 사람을 다시 추론해야 한다. 그러면 이름으로 가르는 문자열 분류가 된다. 프로세스 메모리에 두면 재시작과 깨우기 신호가 늦게 남는 경우(§5.1 `LateWake`)에 맞지 않는다.
- 「깨우기를 올렸나」는 한 함수가 계산한다. `Now` 는 늘 참, `At_tick` 은 `arrived_at` 뒤 첫 틱 경계가 지났으면 참, `Carry` 는 늘 거짓이다. 틱이 `Off` 면 `At_tick` 도 늘 참이다.
- 이 함수를 세 곳이 같이 부른다. 세 곳을 손으로 따로 맞추지 않는다.
  - `keeper_cycle_decision` 의 `Board_event_pending`. 지금 `has_pending_board_activity` 는 반응·투표를 포함해 모든 pending 이벤트를 센다.
  - `event_queue_trigger_of_stimulus`. `Task_outcome` 은 trigger 와 observation 주입 두 길로 들어온다.
  - `pending_stimulus_remains`. `peek_when_result` 가 이미 `~ready` 를 받으니, 이 함수를 넘기면 된다.
- `Carry` 행은 주기 경계가 된 사이클에서만 턴을 연다. 그 밖의 사이클에서 `Carry` 행만으로 턴을 열지 않는다(§5.5-3, `TurnHasCause`).
- 주기 경계가 된 사이클은 `Carry` 가 기다리면 gate 와 상관없이 턴을 연다(§5.5-5).
  - 지금은 큐 행이 있으면 판정이 그 행을 반응형 트리거로 세어 턴을 연다. 그래서 지금은 문제가 없다.
  - gate 가 꺼진 Keeper 가 주기 사이클을 Skip 하는 것은 큐 행이 없을 때뿐이다(§3.3).
  - 문제는 `Carry` 를 반응형 트리거에서 빼는 순간(§5.5-3) 생긴다. 그래서 §5.5-5 는 §5.5-3 보다 먼저, 늦어도 같은 PR 에 들어가야 한다.
- 그래서 `Carry` 가 기다리는 시간의 상한은 주기 하나와 턴 하나다(§5.2 `CarryAgeBound`). 쉬는 간격이 늘어나면(§4.4) 주기 하나는 그 Keeper 의 상한(기본 2시간)이다.
- 입력의 뜻과 보낸 사람을 타입으로 가르는 일이라 시간 장치가 아니다.

### 4.3 틱 경계 — 언제 깨는가

**정의.**
- Keeper k 의 틱 경계는 `n × T + offset(k)` 다. T 는 틱 길이다.
- `offset(k)` 는 Keeper 이름에서 정해지는 고정값이다(0 ≤ offset < T). 모든 Keeper 가 같은 초에 함께 출발하지 않게 한다.
- 경계는 마지막 턴 시각에서 재지 않는다. 그래서 cooldown 이 아니다.

**깨우는 규칙.**
- `At_tick` 입력이 들어오면 적기만 한다. 깨우기는 그 Keeper 의 다음 경계에 한 번 보낸다.
- 경계에 기다리던 입력이 있으면 턴을 연다. 한 턴에 묶을 수 없는 입력(답할 곳이 다른 예약 등)이 남으면 이어서 다음 턴을 연다. 다음 경계를 기다리지 않는다.
- 그래서 턴 수에 상한을 두지 않는다. 깨우는 시각만 경계로 모은다.

**받는 규칙(그대로).**
- 어느 까닭으로 열린 턴이든, 그때 기다리던 입력을 모두 가져간다. 사람이 연 턴, 주기 턴, 예약 턴도 같다.
- 그래서 경계 전에 `At_tick` 입력이 와 있으면, `Now` 입력이 연 턴에 같이 실릴 수 있다. 도착 시각으로 거르지 않는다.

**설정.**
- `keeper.turn_tick_sec` 를 `Runtime_params` 로 등록한다. 값은 `Off | Every of seconds` 처럼 타입으로 둔다. 0 같은 특별한 값으로 끄지 않는다.
- 기본값은 `Off` 다. 켤 때 값은 300초다(§1.1-4). 켜는 것은 §8 의 순서를 따른다.

**구현 지점(스케치).**
- 깨우는 쪽: 만드는 쪽이 `wakeup_keeper` 에 깨우기 종류를 넘긴다. `wakeup_keeper` 는 보낸 사람을 추론하지 않는다. `At_tick` 이면 wakeup atomic 대신 「다음 경계에 깨움」을 건다.
- heartbeat loop: sleep 길이를 「주기 경계」와 「걸린 틱 경계」 중 이른 쪽으로 잡는다. `Now` 깨우기는 지금처럼 sleep 을 끊는다(`Interrupt_on_wakeup`).
- 턴이 끝난 뒤 남은 입력이 이미 받은 묶음에서 나온 것이면 바로 다음 턴을 연다(`next_cycle_starts_now`, 지금과 같음). 턴 도중 새로 온 `At_tick` 입력은 다음 경계를 기다린다.
- 채팅 줄: Keeper 가 보낸 작업은 경계에서만 claim 을 시작한다. 사람·외부가 보낸 작업은 지금처럼 바로 claim 한다. claim 하면 기다리던 작업을 봉투째 함께 집는다(선행 조건).

**선행 조건.**
- 보낸 사람이 다른 채팅을 봉투째 한 턴에 넣는 일(묶음 RFC §4.2·§4.3)이 먼저다.
- 지금 `select` 는 같은 출처의 연속 구간만 묶는다. 틱만 넣으면 보낸 사람 수만큼 경계마다 턴이 이어진다. 턴 수는 줄지 않고 지연만 는다.

### 4.4 주기와 하나로

- 주기 턴도 틱 격자 위에서 연다. 주기 경계가 되면 그 뒤 첫 틱 경계에서 연다.
- #54338 의 규칙(끝까지 돈 예약 턴이 주기 경계를 채움)은 그대로다.
- 그러면 Keeper 마다 시계가 틱 하나로 모인다. 예약만 자기 시각을 따로 가진다.

**쉬는 간격.**
- 반응이 없을 때 Keeper 가 스스로 깨는 간격은 시작값에서 두 배씩 늘어 상한에서 멈춘다. 기본은 30분 → 1시간 → 2시간이다(§1.1-5).
- 시작값으로 돌리는 턴: 깨우기를 올린 입력(`Now`·`At_tick`, 예약 포함)으로 열려 끝까지 돌고, 받은 입력을 모두 처리한 턴이다. #54338 의 규칙과 같은 판정이다.
- 깨우기를 올린 행이 큐에 남아 있는 동안은 간격이 시작값이다. 실패하거나 체크포인트에서 멈춘 턴이 남긴 행이 그렇다.
  - 까닭: 주기 경계는 진척 없는 턴을 다시 해 보는 타이머이기도 하다(`due_schedule_service_of_cycle` 주석). 처리되지 않은 반응이 남았다는 것은 반응이 이미 왔다는 뜻이다. 그래서 다시 해 보는 간격은 지금처럼 최대 30분이다.
  - 큐 행은 지금의 상태라 지난 턴의 기록을 scheduling 근거로 쓰는 것이 아니다.
- `Carry` 입력만 실린 턴은 반응이 아니다. 시작값으로 돌리지 않는다.
- 큐에 깨우기를 올린 행이 없을 때, 스스로 깬 턴이 끝나면 간격이 두 배가 된다. 스스로 깬 턴이 실패해도 같다.
- 간격은 Keeper 마다 따로 센다. 한 Keeper 가 바빠도 다른 Keeper 의 간격은 그대로 늘어난다.

**쉬는 간격의 설정.**
- 값은 `{ start; cap }` 한 쌍이다. `start ≤ cap` 이 아니면 설정을 읽을 때 거절한다. 늘리지 않으려면 `start = cap` 으로 둔다.
- 전체 기본값: `Runtime_params` 에 둔다. 지금 `keeper.keepalive_interval_sec` 가 시작값 자리다.
- Keeper 마다 덮어쓰기: Keeper 설정(TOML)에 `activation_mode` 와 같이 둔다. 정하지 않은 Keeper 는 기본값을 쓴다.
  - `masc_keeper_up` 이 revision compare-and-swap 으로 쓴다. 충돌하면 아무것도 바꾸지 않고 실패한다(`keeper_config_revision_conflict`).
  - 돌고 있는 Keeper 에는 hot-reload 가 한 sweep(약 30초) 안에 적용한다. 서버를 다시 시작하지 않아도 된다.
  - 구현은 `rg -n activation_mode lib/` 로 그 값이 지나는 곳(profile 기본값, meta overlay, owner reducer 의 `Update_profile`, `masc_keeper_up` 인자, snapshot)을 따라간다. 루프가 간격을 읽는 곳은 `Keeper_heartbeat_snapshot.keepalive_interval_sec` 를 부르는 두 곳(주기 도래 판단, sleep 길이)이다.
  - 두 곳이 같은 「유효 간격」 함수 하나를 부른다. 한 곳만 바뀌는 일을 막는다.
  - 그 함수는 「깨우기를 올린 행이 남았나」를 §4.2 의 술어로 직접 읽는다. `next_cycle_starts_now` 는 `stimuli_acked` 가 참일 때만 큐를 읽어서, 실패한 턴 뒤에는 답을 주지 않는다.
- 예약이 잦은 Keeper 는 예약 턴이 간격을 계속 시작값으로 돌린다. 그런 Keeper 는 덮어쓰기가 없어도 늘 30분 안에 움직인다.

### 4.5 결정론과 비결정론의 경계

- masc 가 정한다(결정론):
  - 입력 종류와 보낸 사람 종류마다 `Now`·`At_tick`·`Carry`(타입)
  - 틱 경계(설정과 Keeper 이름)
  - 쉬는 간격의 시작값과 상한(전체 기본값과 Keeper 마다의 덮어쓰기)
- Keeper 가 정한다(비결정론): 받은 묶음에서 무엇이 낡았는지, 무엇부터 할지, 답을 어떻게 쓸지.
- 새로 저장하는 것은 둘이고, 성격이 다르다.
  - 큐 행의 깨우기 종류: 입력이 생길 때 만드는 쪽이 정한 사실이다. 쓸 때 정하고, 읽을 때 다시 추론하지 않는다.
  - Keeper 설정의 쉬는 간격 덮어쓰기: 운영자가 선언한 값이다. `activation_mode` 처럼 저장한다.
- 틱 경계는 시계와 설정에서 계산한다. 쉬는 간격이 지금 몇 단계인지는 프로세스 메모리에만 둔다. 재시작하면 시작값부터 다시 센다.

## 5. 불변식과 TLA+

spec 은 `specs/keeper-state-machine/KeeperReactionQueue.tla` 와 cfg 열 개다. 구현 1단계에서 `KeeperEventQueue.tla` 를 이것으로 바꾼다(§8).

### 5.1 모델

- Keeper 하나의 큐다. 입력은 셋이다. 모델의 「사람 입력」은 §4.2 의 `Now`, 「Keeper 입력」은 `At_tick` 이다.
  - 사람 입력: 넣을 때 깨운다.
  - Keeper 입력: 다음 틱 경계에서 깨운다. 그때 기다리던 Keeper 입력을 모두 한 번에 깨운다.
  - Carry: 깨우지 않는다.
- 어느 까닭으로 열린 턴이든 기다리던 입력을 모두 가져간다.
- 시간은 틱 경계로 센다. 주기는 `Period` 경계마다 온다. 턴 하나는 `TurnBound` 경계 안에 끝난다.
- 깨운 Keeper 는 다음 경계 전에 사이클을 연다.
- 주기 경계는 그 경계에서 연 턴이 끝날 때 채운다(`periodic_cadence_after_cycle`).
- 지금 코드는 깨우기 신호를 먼저 소비하고, 큐는 턴이 나중에 가져간다.
  - 그 사이에 온 입력은 이번 턴에 실리지만 깨우기 신호는 남는다. 모델의 `LateWake` 가 이 경우다.
  - 남은 신호가 연 사이클은 턴을 열지 않는다.

### 5.2 지키는 성질

| 이름 | 뜻 |
|---|---|
| `HumanRoutable` | 기다리는 사람 입력에는 깨우기 신호나 도는 턴이 있다 |
| `RaisedRoutable` | 깨우기를 올린 입력에는 깨우기 신호나 도는 턴이 있다 |
| `HumanAgeBound` | 사람 입력은 도는 턴 하나(`TurnBound`)보다 오래 기다리지 않는다 |
| `KeeperAgeBound` | Keeper 입력은 `max(1, TurnBound)` 보다 오래 기다리지 않는다. 입력 수와 보낸 사람 수에 상관없다 |
| `CarryAgeBound` | Carry 는 `Period + TurnBound` 보다 오래 기다리지 않는다 |
| `TurnHasCause` | 턴은 깨우기를 올린 입력이 있거나 주기 경계가 될 때만 열린다 |
| `EveryInputReachesATurn` | 공정성 아래에서 기다리는 입력은 모두 턴에 실린다(활성) |

- 나이 상한 셋은 하나씩 낮추면 정상 모델에서도 깨진다. 상한이 실제로 닿는 값이라는 뜻이다.
- Carry 의 상한이 「주기 하나와 턴 하나」인 까닭: 주기 경계는 그 경계에서 연 턴이 끝날 때 채워진다. 그 턴이 입력을 가져간 직후 온 Carry 는 턴이 끝난 뒤 주기 하나를 더 기다린다.

### 5.3 일부러 심은 버그

cfg 마다 버그 하나를 더한다. 버그 cfg 는 반드시 위반해야 한다.

| cfg | 버그 | 깨지는 성질 |
|---|---|---|
| `-buggy` | 깨우기 신호를 소비하고 사이클을 열지 않는다(옛 spec 의 버그) | `RaisedRoutable` |
| `-human-waits-for-boundary-buggy` | 사람 입력이 깨우지 않고 경계를 기다린다 | `HumanRoutable` |
| `-claim-one-sender-buggy` | 턴이 가장 오래된 입력의 보낸 사람 것만 가져간다 | `KeeperAgeBound` |
| `-one-turn-per-tick-buggy` | 위와 같고, 남은 입력이 다음 경계까지 깨우기를 잃는다 | `RaisedRoutable` |
| `-periodic-skips-carry-buggy` | 주기 사이클이 Carry 를 두고 턴 없이 경계를 쓴다 | `CarryAgeBound` |
| `-turn-for-unraised-input-buggy` | 판정이 깨우기를 올리지 않은 입력에 턴을 연다 | `TurnHasCause` |
| `-fair-periodic-skips-carry-buggy` | 주기 사이클이 매번 Carry 를 두고 Skip 한다 | `EveryInputReachesATurn` |

- `-claim-one-sender-buggy` 는 §4.3 선행 조건의 근거다.
  - 반례: Carry(보낸 사람 1)와 Keeper 입력(보낸 사람 2)이 같이 기다린다.
  - 경계 뒤의 턴이 보낸 사람 1 의 것만 가져간다.
  - 다음 경계에서 Keeper 입력의 나이가 2 가 된다. 보낸 사람이 하나 늘 때마다 턴 하나씩 더 기다린다.
- `-one-turn-per-tick-buggy` 는 「틱 하나에 턴 하나」를 같은 출처만 묶는 select 와 같이 둔 모양이다. 한 턴에 못 실은 입력을 다음 경계까지 아무도 맡지 않는다.

### 5.4 돌린 결과

TLC 1.8.0 으로 2026-11-22 에 돌렸다. 상수는 `MaxStimuli = 3`, `MaxTime = 8`, `Period = 3`, `TurnBound = 1`, `LastArrival = 7`, `Senders = {"s1", "s2"}` 다.

| cfg | 결과 | 상태 수 |
|---|---|---|
| 기본 | 통과 | 28,738 |
| `-long-turn`(`TurnBound = 2`) | 통과 | 51,999 |
| `-fair`(`LastArrival = 3`, 활성) | 통과 | 7,326 |
| 버그 cfg 일곱 | 모두 위반. 안전 여섯은 exit 12, 활성 하나는 exit 13 | |

- 모델의 `Period = 3` 은 틱 3개다. 운영 비율과 다르다. 쉬는 간격의 시작값으로는 1,800초 ÷ 300초 = 6, 상한으로는 7,200초 ÷ 300초 = 24 다. 상한은 `Period`·`TurnBound` 로 적은 식이라, 비율이 달라도 같은 모양이다.
- `-fair` 는 입력이 `LastArrival = 3` 까지만 온다. 가장 긴 기다림(`Period + TurnBound = 4`)이 마지막 경계 전에 끝나게 하려는 것이다.

### 5.5 구현이 지킬 것

모델의 성질은 아래를 지킬 때만 코드에서도 선다.

1. `Now` 입력은 넣을 때 깨운다(`HumanRoutable`).
2. 틱 경계는 그때 기다리던 Keeper 입력을 개수와 상관없이 모두 깨운다. 턴은 기다리던 입력을 보낸 사람과 상관없이 모두 가져간다(`KeeperAgeBound`).
3. 판정은 깨우기를 올린 입력이 있거나 주기·예약 시각이 될 때만 턴을 연다. Carry 행이나 경계 전 Keeper 행만 있으면 턴을 열지 않는다(`TurnHasCause`).
4. `pending_stimulus_remains`(`next_cycle_starts_now` 가 읽는다)는 깨우기를 올린 행만 센다. 아니면 턴 도중 들어온 Carry 가 턴이 끝나자마자 다음 사이클을 연다.
5. 주기 경계가 된 사이클은 Carry 가 기다리면 턴을 연다(`CarryAgeBound`).
   - 지금 판정은 scheduled-autonomous gate 가 꺼진 Keeper 의 주기 사이클을 `Scheduled_autonomous_disabled` 로 Skip 한다.
   - 그래도 `periodic_cadence_after_cycle` 은 주기 경계를 쓴다.
   - 이대로 Carry 를 켜면, 그 Keeper 의 Carry 는 깨우기를 올린 입력이 올 때까지 실리지 않는다. `-periodic-skips-carry` 두 cfg 가 이 모양이다.

### 5.6 모델 밖

- 예약 전달의 답할 곳 갈래(§3.2). 예약은 제 시각에 깨고, 이 RFC 는 예약의 묶음 규칙을 바꾸지 않는다.
- Keeper 여럿과 고정 시차(`offset(k)`). Keeper 하나의 모델에서는 보이지 않는다. 같은 초에 몰리는지는 §8 에서 잰다.
- provider 쉼(`Serve_wakeup_after_duration`). 쉬는 동안은 사람 입력도 쉼이 끝날 때까지 기다린다. 사람 입력의 상한은 쉼이 없을 때의 값이다.
- 실패하거나 체크포인트에서 멈춘 턴. 모델의 `CycleStart` 는 기다리던 입력을 한 번에 가져가 모두 처리한다. 그래서 §5.2 의 나이 상한은 턴이 끝까지 돌 때만 선다. 그런 턴이 남긴 행은 시작값 간격(§4.4)으로 다시 시도한다.
- 실패한 턴을 이어 받는 사이클(`cycle_wake = Deferred_runtime_lane`, 판정의 `deferred_runtime_lane_pending`). 입력도 주기도 아닌 세 번째 원인이다. 구현은 `TurnHasCause` 를 옮길 때 이 사이클을 막지 않는다.

## 6. Librarian 제약

- 봉투가 커지면 턴의 첫 요청이 커진다.
- 다음 턴의 예상 최대치(`Keeper_model_input_ledger.next_turn_peak`)가 runtime 의 입력 한도를 넘으면, `Keeper_turn_driver_try_provider.past_max_context` 가 요청의 시작을 뒤로 옮긴다.
- 옮기는 자리는 그 Keeper 의 기억 쓰는 쪽이 읽은 끝에 달렸다.
  - 읽은 끝(`Covered`)이 창의 시작보다 뒤면 그 끝으로 옮긴다(`Librarian_point_at_max_context`). 요청에서 빠지는 메시지는 이미 Memory 에 있다.
  - 읽은 끝이 없거나 창의 시작보다 앞이면 지금 턴의 시작으로 옮긴다(`Turn_start_at_max_context`). 창의 시작과 턴 시작 사이의 메시지는 요청에도 Memory 에도 없다.
- 지금 운영에는 `librarian_memory` lane 표가 없다. 쓰는 쪽에 읽은 끝이 없으니, 창을 넘는 요청은 턴 시작으로 옮겨진다.
- 그래서 묶음을 키우는 단계(§8 의 5·6)는 Librarian 컷을 설치하고 `librarian_memory` lane 을 켠 뒤(§8 의 4)에 둔다. #54335(`RFC-official-client-start-seed-window.md`)도 같은 까닭으로 컷 설치 뒤에 켠다.
- 켠 뒤에는 W2 경보로 본다.
  - W2 는 요청이 읽은 끝보다 뒤에서 시작해, 요청에도 Memory 에도 없는 메시지가 생긴 Keeper 에 뜬다(`Keeper_request_start.standing` 의 `Behind`, #54344).
  - §8 은 W2 가 늘면 끈다.
- 쓰는 쪽은 maintenance tick(60초)마다 깨어 턴 기록을 따라간다. 턴 수가 줄면 턴 사이에 따라잡을 시간이 는다. 이 효과는 재지 않았다. §8 의 W2 수로 본다.
- 이 RFC 는 턴이 무엇을 받는지 바꾸지 않는다. 그래서 runtime 을 넘는 턴을 이어 붙이는 규칙(`Keeper_turn_bridge`)도 그대로다.

## 7. 무엇이 나빠지나

- 다른 Keeper 가 만든 입력에 대한 응답이 최대 틱 하나만큼 늦다. 위임 → 결과 → 다음 일처럼 이어지는 사슬은 한 단계마다 틱 하나까지 늦어진다(300초 틱이면 단계마다 최대 5분).
- `Carry` 입력(관심 판정 글, 반응·투표, 승인된 완료)은 다른 턴이 열릴 때까지 기다린다. 쉬는 간격이 상한까지 늘어난 Keeper 에서는 최대 2시간이다.
- 할 일이 남은 Keeper 도 반응이 없으면 최대 2시간에 한 번만 스스로 움직인다. 입력 없이 스스로 깬 턴이 실패하면, 다시 해 보는 것도 그 간격 뒤다. 그런 Keeper 는 쉬는 간격을 따로 짧게 둔다.
- 반응이 남은 채 실패한 턴은 지금처럼 최대 30분 안에 다시 해 본다(§4.4).
- 턴 하나가 받는 입력이 많아져 턴이 길어진다. 첫 요청이 커진다(§6).
- 틱보다 긴 턴을 도는 Keeper 는 효과가 작다. 턴이 끝나면 이미 지난 경계의 입력을 바로 받는다.
- 예약 간격이 틱보다 짧아도 예약은 제 시각에 깬다. 예약을 틱으로 늦추지 않는다.

## 8. 켜는 순서와 판정 기준

**순서.**
1. 깨우기 표를 `match` 로 바꾸고 `Now | At_tick | Carry` 를 넣는다. 그 값을 큐 행에 적는다(저장 형식 hard cut, 배포 안내에 Fresh state 항목을 둔다). 기본은 모두 `Now` 다(동작 변화 없음). 같은 단계에서 §5.5 의 다섯 가지를 코드에 넣는다. `pending_stimulus_remains` 는 깨우기를 올린 행만 세고, 주기 경계가 된 사이클은 `Carry` 가 있으면 gate 와 상관없이 턴을 연다. `KeeperEventQueue.tla` 는 `KeeperReactionQueue.tla` 로 바꾼다(hard cut, §5).
2. Board 글·댓글과 작업 취소의 보낸 사람 종류를 만드는 쪽에서 등록부 일치로 읽는다(§3.4).
3. 묶음 RFC §4.2·§4.3(봉투 묶음)을 구현한다.
4. Librarian 컷을 설치하고 `librarian_memory` lane 을 켠다.
5. §1.1-2 의 `Carry` 를 켠다.
6. `keeper.turn_tick_sec` 를 300초로 켠다.
7. 쉬는 간격을 켠다. 전체 기본값은 30분 → 2시간이다. Keeper 마다의 덮어쓰기는 이 단계에서 같이 넣는다.

**판정.** 켜기 전과 켠 뒤를 같은 길이 구간으로 잰다.
- Keeper 마다 연 턴 수, 입력 종류별 턴 수(§2.1 의 셈)
- 출처별 문맥 토큰(§2.2 의 셈)
- cache_read 몫(§2.5 의 셈)
- 입력 종류별 도착 → 턴 시작 지연. 반응 원장(`Keeper_reaction_ledger`)의 stimulus → `Turn_started` 로 잰다. 켜기 전 값부터 먼저 잰다.
- 저절로 열린 턴 수(§2.6 의 셈), Keeper 마다 쉬는 간격이 어디까지 늘었는지
- 새 세션 첫 요청이 자기 창을 넘은 비율, W2 경보 수
- 첫 턴 실패 수

`Now` 입력의 지연이 늘거나, 첫 턴 실패나 W2 경보가 늘면 끈다.

## 9. 열린 질문

1. 다른 runtime(Codex, Agent Core, HTTP provider)의 캐시 유지 시간은 재지 않았다.
2. `offset(k)` 를 이름에서 정하면, Keeper 이름을 바꿀 때 경계가 옮겨진다. 문제가 되는지 본다.
3. 여러 계정 배포(`is_multi_account`)에서 틱을 어디서 세는지 정해야 한다.
4. 큐 입력 없이 열린 턴 20번이 어디서 왔는지 아직 나누지 못했다(§2.1).
5. Board 가 내려간 동안 다시 남긴 routing 행이 사이클을 이어 여는가. 코드를 읽은 답은 「한 번은 더 열 수 있지만 이어 열지는 않는다」다(시험은 돌리지 않았다).
   - `next_cycle_starts_now` 는 `stimuli_acked` 일 때만 큐를 본다.
   - `stimuli_acked` 는 사이클 시작에 거짓이고, 턴이 묶음을 모두 ack 하고 남긴 선택이 없을 때만 참이 된다. 턴이 없던 사이클은 거짓을 돌려준다.
   - §5.5-4 가 들어가면 `Carry` 인 routing 행은 아예 세지 않는다.

## 10. 하지 않는 것

- 입력을 버리거나 중복을 지우는 일
- 턴 수나 묶음 크기의 상한
- 입력의 깨우기를 마지막 턴에서 재서 늦추는 일(cooldown). §4.4 의 쉬는 간격은 반응이 없을 때 스스로 깨는 턴에만 쓴다.
- 업무 종류(리뷰, 배포 등)로 가르는 일
- 이름의 모양이나 접두어로 보낸 사람을 가르는 일
- 도는 턴을 끊는 일
- Keeper 지시나 프롬프트에 「덜 깨라」를 적는 일
