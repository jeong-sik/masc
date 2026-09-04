---
rfc: "event-queue-admit-all-ready"
title: "이벤트 큐 — 준비된 자극은 한 턴이 전부 본다, 턴 실패는 자극을 버리지 않는다"
status: Draft
created: 2026-08-22
updated: 2026-08-22
author: claude
supersedes: []
superseded_by: null
related: ["0377"]
---

# RFC: 이벤트 큐 — 준비된 자극은 한 턴이 전부 본다, 턴 실패는 자극을 버리지 않는다 (event-queue-admit-all-ready)

## 0. 요약

Keeper 턴은 지금 Event Layer 자극을 **사이클당 1건**만 받는다 (`keeper_heartbeat_stimulus_intake.mli` 머리 주석,
RFC-0020 §3 Rule 4). RFC-0377 이 `Connector_attention` 한 종류만 "같은 대화는 함께" 로 풀었다. 이 RFC 는 그 규칙을
모든 자극 종류로 넓힌다: **claim 시각에 준비된 pending 자극 전부가 그 턴에 들어간다.** 개수·바이트·시간 창 같은
숫자 장치는 두지 않는다.

둘째, 턴이 실패하면 지금은 그 턴에 들어간 자극을 **영구 폐기**한다 (`Batch_quarantine` → `Turn_attempt_terminal`).
라이브 처분 4,205건 중 379건(9.0%)이 이 경로로 사라졌고, 원인은 전부 provider/설정/컨텍스트 쪽이지 자극 내용이
아니다. 전부 admit 하는 세계에서 이 규칙은 실패 한 번에 수십 건을 지운다. 그래서 **턴 실패는 큐에 아무 것도 하지
않는다**로 바꾼다. 자극은 "어떤 턴이 그것을 보고 끝났다" 는 사실로만 큐를 떠난다.

셋째, 같은 `schedule_id` 의 `Schedule_due` occurrence 여러 건은 턴 컨텍스트에서 **하나의 행**으로 투영한다
(파생 상태, 쓰기 시점 dedup 없음).

## 1. 관측 (라이브 `<base-path>`, 2026-08-22)

### 1.1 사이클당 1건은 유입을 못 따라간다

#29448(ack 된 사이클 뒤 수면 생략 + urgency 정렬) 배포(`9daf0c871b`, 06:09Z) 뒤 55분:

| 지표 | 배포 전 18.9h 평균 | 배포 후 55분 |
|---|---|---|
| taskmaster 소비 | 4.1/h | 13.3/h (12건, ack 9) |
| 소비 간격 p50 | 302s (cadence 수면) | 18s |
| taskmaster 도착 (`Board attention owner lane signaled`) | — | 12건 ≈ 13/h |
| taskmaster 잔량 | 52 → 68 | **71** |

수면 생략은 설계대로 동작하고(간격이 cadence 가 아니라 턴 길이), 잔량이 안 주는 이유는 도착이 같은 속도이기
때문이다. 소비가 턴당 1건이면 잔량은 유입/드레인의 평형값에 멈춘다. 잔량 71 의 구성: `board_attention` 53,
`schedule_due` 18(전부 한 `schedule_id` 의 occurrence), `task_cancelled` 1, `board_signal` 1. 가장 오래된 항목은
19.8h 전에 도착했다 (p50 5.3h).

### 1.2 턴 실패가 자극을 지운다 — 9.0%

전 keeper `event-queue-v15.json` 의 `projected_dispositions` 4,205건 중 `detail` 이 있는 `ack_source_terminal`
(= `Turn_attempt_terminal`, 턴 실패로 terminal 처리) 379건(9.0%). 사유 분류:

| 사유 (`detail` 접두) | 건수 | 자극 종류 상위 |
|---|---:|---|
| `provider_attempt_effect_fenced` | 138 | schedule_due 47, board_attention 43, completion_authority_rejected 31 |
| `Invalid config 'model_input_projection'` | 76 | board_attention 52, schedule_due 10 |
| 컨텍스트 초과 (`model_context_window_exceeded`, `Prompt exceeds max length`, codex out of room) | 50 | schedule_due 26, board_signal 11, board_attention 10 |
| codex `usage limit` | 29 | board_attention 18, schedule_due 9 |
| `terminal_effect_failed` | 23 | completion_authority_rejected 11 |
| 기타 | 63 | schedule_due 43 |

keeper 별: analyst 121, sangsu 92, taskmaster 83, code-reviewer 41, rondo 38. 379건 중 자극 내용이 원인인 것은
0건이다 — 모두 runtime/provider/설정/컨텍스트 크기의 문제다. `completion_authority_rejected` 42건은 "검증자가
너의 완료를 거부했다" 는 사실이 keeper 에게 한 번도 전달되지 않고 사라진 경우다.

### 1.3 한 자극이 컨텍스트에서 차지하는 크기

taskmaster 오늘 요청 913행(`wire-capture/2026-08/22*.jsonl`)의 `extra_system_context` 섹션별 p50:

| 섹션 | p50 | max |
|---|---:|---:|
| `### Board Activity (N)` (자극 1건) | 526 B | 728 B |
| `### Scheduled Wake (N)` | 946 B | 946 B |
| `### Your Recent Actions (10 turns)` | 39,721 B | 65,434 B |
| `### Fleet Messages (10)` | 21,469 B | 24,756 B |

board 자극 53건을 전부 실어도 약 27 KB — 같은 턴의 "최근 행동" 섹션 하나(40 KB)보다 작다. 컨텍스트 예산은 자극
개수가 아니라 도구 결과·행동 기록이 정한다(#29463).

### 1.4 코드

| 지점 | 지금 |
|---|---|
| `keeper_heartbeat_stimulus_intake.ml` `intake_selection` | primary 1건 + (`Connector_attention` 일 때만) 같은 대화 companions |
| `keeper_heartbeat_loop.ml` `batch_disposition_of_cycle_outcome` | `Completed` → 전부 ack, `Failed` → `Quarantine_source`/`Defer_to_queue_tail`/no-action, `Checkpointed` → no-action |
| `failed_source_disposition` | `Provider_attempt_effect_fenced`/`Tool_correction_lost` 는 무조건, 그 밖의 `Exhausted_visible_alive` 는 deferred lane 이 없을 때 `Quarantine_source` — terminal_class 14종 중 자극에 귀속되는 것은 없음. `Retry_after_observed`/`Rotate_now` 는 꼬리 이동 |
| `Keeper_registry_event_queue.defer_pending_result` | 실패한 자극을 꼬리로 이동 (`transient_turn_failure`) |
| `Keeper_event_queue_state.Turn_attempt_terminal` | 실패 receipt 종류 |

Checkpointed 사이클은 ack 없이 같은 head 를 다시 읽는다 (128 사이클 중 36건). 이건 결함이 아니라 "완료 전엔 ack
없음" 의 결과이고 이 RFC 에서도 유지한다.

## 2. 설계

### 2.1 admission — claim 시각의 준비된 pending 전부

`heartbeat_event_intake` 는 urgency → 도착순으로 정렬된 pending(#29448) 을 head 부터 **끝까지** 읽어 준비된
것을 전부 이 턴에 admit 한다. 종류별 예외는 지금 있는 것만 유지한다:

| 종류 | 규칙 |
|---|---|
| `Hitl_resolved` | 지금처럼 승인 id 가 pending map 을 떠난 뒤에만 준비됨; 준비 안 된 항목은 건너뛴다 |
| `Connector_attention` | RFC-0377 §3 유지 — 턴당 대화 하나. 정렬상 첫 `Connector_attention` 의 대화만 admit, 다른 대화는 잔류 |
| 그 외 (`Board_signal`, `Board_attention`, `Bootstrap`, `Fusion_completed`, `Schedule_due`, `Completion_authority_rejected`, `Task_cancelled`, `Workspace_message`) | 준비된 것 전부 |

- Board 읽기가 일시 실패한 항목(`Stimulus_retry_later`)은 지금처럼 그 항목만 이번 사이클에서 빼고 나머지는
  admit 한다. 첫 실패 항목이 `event_queue_intake_error` 에 남는 것도 그대로.
- 배치 크기·바이트·대기 창·"너무 오래된 것 버리기" 는 두지 않는다. 배치 크기는 유입/드레인 속도의 사실이지 제어
  대상이 아니다 (RFC-0377 §3 과 같은 입장).
- 턴 컨텍스트 투영 순서는 큐 순서(urgency → 도착)와 같다.

### 2.2 disposition — 턴 결과는 턴의 속성, 큐는 사실만 든다

`batch_disposition` 은 두 값만 남는다:

| 턴 결과 | 큐 |
|---|---|
| `Completed` | admit 된 전부 ack (`Turn_completed` receipt) |
| `Failed`, `Checkpointed`, `Input_required`, `Cancelled`, `Skipped`, 없음 | 아무 것도 하지 않음 — 자극은 pending 에 남고 다음 사이클이 다시 admit |

삭제: `Batch_quarantine`, `Batch_defer`, `Quarantine_source`, `Defer_to_queue_tail`, `terminalize_failed_selection`,
`defer_selection_to_queue_tail`, `Keeper_registry_event_queue.defer_pending_result` /
`terminalize_pending_turn_attempt_result`, receipt 종류 `Turn_attempt_terminal` 과 그 직렬화. `failed_source_disposition`
은 `Pause_keeper_for_integrity`(keeper 상태, 큐와 무관) 판정만 남기고 이름을 그에 맞게 바꾼다. 실패의 사실은 지금처럼
턴 기록(turn record)과 로그가 든다 — 큐 receipt 에 중복 저장하지 않는다.

왜 "꼬리로 이동" 도 지우나: 전부 admit 하면 꼬리가 의미를 잃는다. 실패한 자극을 뒤로 미루는 것은 "실패했다" 는 과거
증거로 다음 순서를 정하는 일이고, 이 저장소 원칙(과거 evidence 를 scheduling gate 로 쓰지 않는다)에 어긋난다.

`provider_attempt_effect_fenced` 의 재실행 우려(부분 실행된 외부 효과가 다시 실행될 수 있음)는 큐가 아니라 keeper 가
다룬다: 다음 턴의 `### Your Recent Actions` 에 실패한 턴의 행동이 그대로 보이고, 무엇을 다시 할지는 keeper 판단이다.
큐가 자극을 숨겨서 막는 방식은 "거부된 완료" 42건처럼 keeper 가 알아야 할 사실까지 함께 숨긴다.

결정론적으로 매 사이클 실패하는 경우(설정 오류, 컨텍스트 초과)는 cadence 속도로 같은 실패가 반복되며 로그·metric
에 그대로 보인다. 지금도 그 keeper 는 다른 이유로 깨어나 같은 실패를 반복하므로 새 비용이 아니다. 고치는 자리는
설정/컨텍스트이지 큐가 아니다.

### 2.3 `Schedule_due` 투영 — 같은 schedule 은 한 행

`Keeper_world_observation` 에서 같은 `schedule_id` 의 admit 된 occurrence 들을 하나의 `Scheduled Wake` 행으로
접는다: 메시지, 첫/마지막 due 시각, occurrence 수. 큐에는 손대지 않고(쓰기 시점 dedup 없음) ack 은 전부 함께 된다.
taskmaster 의 18건은 한 턴에서 한 행이 되고 한 번에 사라진다. 멈춘 keeper 가 며칠 동안 쌓은 occurrence 가 풀 LLM
턴을 18번 소비하는 일이 없어진다.

### 2.4 손대지 않는 것

- Checkpoint 재개 시 intake 는 다시 돈다(새로 도착한 것도 포함). 완료 전 ack 없음은 그대로.
- `Connector_attention` 의 대화 단위 규칙(RFC-0377), ack 뒤 `Attention_resolved`/`Attention_ignored` 표시.
- `Keeper_event_queue.drain_board_all` (런타임 호출자 0) — 이 RFC 구현에서 삭제한다. RFC-0377 §2 가 "board 는 이미
  배치" 라고 적은 것은 이 함수를 가리키는데 실제로는 쓰이지 않았다.

## 3. 의미 — ack 은 "봤다" 이지 "처리했다" 가 아니다

전부 admit 하면 keeper 가 53건 중 3건만 행동하고 턴을 끝낼 수 있다. 나머지 50건은 ack 되어 큐를 떠난다. 이것은
의도된 동작이다: 큐는 깨움과 주의의 장치이지 작업 목록이 아니다. 게시글·판정·작업은 각자의 store 에 그대로
있고 keeper 는 도구로 언제든 다시 찾는다. "처리 안 된 것을 다시 넣기" 는 "처리됐는가" 를 기계가 판정하는 gate 를
요구하므로 하지 않는다.

## 4. 검증

1. Feature test (`test_keeper_connector_attention_batch.ml` 를 일반 자극으로 확장): board_attention 5 + 같은 `schedule_id` 의 schedule_due 3 +
   대화 A connector 2 + 대화 B connector 1 → intake 1회 → admit 10건(A 2건 포함, B 잔류), 관찰 행은 board 5 +
   schedule 1(occurrence 3) + connector 2.
2. disposition test (`batch_disposition_of_cycle_outcome` 직접 호출, 같은 파일): `Failed`(각 terminal_class 대표값) →
   큐 변화 0, pending 그대로; `Completed` → 전부 `Turn_completed`.
3. 일시 Board 읽기 실패 (`test_keeper_board_unavailable.ml` 확장): 5건 중 2번째만 `Io_error` → 4건 admit, 1건 잔류, `event_queue_intake_error` 에 그 1건.
4. 라이브 재측정(PR 본문에 before/after): taskmaster pending 71 → 첫 완료 턴 뒤 잔량; 24h acks/h 대 도착/h;
   `Turn_attempt_terminal` 건수는 0(종류 삭제); 같은 `schedule_id` 로 한 턴에 ack 된 occurrence 수.
5. 컨텍스트: admit 전부를 실은 턴의 `extra_system_context_bytes` 분포를 wire-capture 로 기록(§1.3 기준선과 비교).

## 5. 하지 않을 것

- 배치 상한, 바이트 상한, 오래된 자극 자동 폐기, 도착 창(debounce).
- 쓰기 시점 occurrence dedup (enqueue 가 기존 pending 을 보고 거르는 것).
- "처리됨" 판정과 재큐잉.
- 실패 횟수에 따른 자극 격리·지수 백오프.

## 6. 관계

- RFC-0020 §3 Rule 4 ("턴당 최대 1건") 는 이 RFC 로 대체된다. `keeper_heartbeat_stimulus_intake.mli` 머리 주석이 그
  규칙의 정본이므로 함께 고친다.
- RFC-0377 은 이 RFC 의 특수 사례가 된다 (대화 단위 규칙은 유지).
- #29448 (수면 생략·urgency 정렬) 위에 선다. #29462 가 이 RFC 의 추적 이슈. 대시보드 `작업 대기열` 의 HEAD 표기
  역전(`keeper-lane-strip.ts`)은 #29473 에서 다룬다.
