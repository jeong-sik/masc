---
rfc: "event-queue-admit-all-ready"
title: "이벤트 큐 — 준비된 자극은 어드미션 경계 안에서 본다, 턴 실패는 자극을 버리지 않는다"
status: Draft
created: 2026-08-22
updated: 2026-09-25
author: claude
supersedes: []
superseded_by: null
related: ["0377"]
---

# RFC: 이벤트 큐 — 준비된 자극은 어드미션 경계 안에서 본다, 턴 실패는 자극을 버리지 않는다 (event-queue-admit-all-ready)

## 0. 요약

Keeper 턴은 지금 Event Layer 자극을 **사이클당 1건**만 받는다 (`keeper_heartbeat_stimulus_intake.mli` 머리 주석,
RFC-0020 §3 Rule 4). RFC-0377 이 `Connector_attention` 한 종류만 "같은 대화는 함께" 로 풀었다. 이 RFC 는 그 규칙을
모든 자극 종류로 넓힌다: **claim 시각에 준비된 pending 자극을 턴에 넣는다.** 개수·시간 창은 두지 않는다.
2026-09-24 변경(§7)은 렌더된 관찰의 바이트를 admission 시점에 제한한다. 맞지 않는 한 행은 운영자에게
드러나는 차단 상태로 보존하고 다른 준비된 자극이 진행되게 한다.

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

### 2.1 admission — claim 시각의 준비된 pending 을 바이트 경계 안에서

`heartbeat_event_intake` 는 urgency → 도착순으로 정렬된 pending(#29448) 을 head 부터 읽어 준비된
것을 admit 한다. §7 의 바이트 경계와 아래 종류별 예외를 적용한다:

| 종류 | 규칙 |
|---|---|
| `Hitl_resolved` | 지금처럼 승인 id 가 pending map 을 떠난 뒤에만 준비됨; 준비 안 된 항목은 건너뛴다 |
| `Connector_attention` | RFC-0377 §3 유지 — 턴당 대화 하나. 정렬상 첫 `Connector_attention` 의 대화만 admit, 다른 대화는 잔류 |
| 그 외 (`Board_signal`, `Board_attention`, `Bootstrap`, `Fusion_completed`, `Schedule_due`, `Completion_authority_rejected`, `Task_cancelled`, `Workspace_message`) | 준비된 것 전부 |

- Board 읽기가 일시 실패한 항목(`Stimulus_retry_later`)은 지금처럼 그 항목만 이번 사이클에서 빼고 나머지는
  admit 한다. 첫 실패 항목이 `event_queue_intake_error` 에 남는 것도 그대로.
- 배치 건수·대기 창·"너무 오래된 것 버리기" 는 두지 않는다. 배치 건수는 유입/드레인 속도의 사실이지 제어
  대상이 아니다 (RFC-0377 §3 과 같은 입장). §7 의 바이트 경계는 예외다.
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

설정 오류처럼 자극과 무관한 실패는 keeper 운영 상태에서 다룬다. 입력 크기가 확정적으로 맞지 않으면 §7.2 의
admission 차단 또는 keeper 일시 정지로 전환한다. `Batch_no_action` 만 반복하면서 같은 입력을 cadence 마다
제출하지 않는다.

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

- 개수 상한(배치 건수), 오래된 자극 자동 폐기, 도착 창(debounce). 바이트 경계는 §7 이 정하는 방식(어드미션 시점 예산)만 허용한다.
- 쓰기 시점 occurrence dedup (enqueue 가 기존 pending 을 보고 거르는 것).
- "처리됨" 판정과 재큐잉.
- 실패 횟수에 따른 자극 격리·지수 백오프.

## 6. 관계

- RFC-0020 §3 Rule 4 ("턴당 최대 1건") 는 이 RFC 로 대체된다. `keeper_heartbeat_stimulus_intake.mli` 머리 주석이 그
  규칙의 정본이므로 함께 고친다.
- RFC-0377 은 이 RFC 의 특수 사례가 된다 (대화 단위 규칙은 유지).
- #29448 (수면 생략·urgency 정렬) 위에 선다. #29462 가 이 RFC 의 추적 이슈. 대시보드 `작업 대기열` 의 HEAD 표기
  역전(`keeper-lane-strip.ts`)은 #29473 에서 다룬다.

## 7. 변경 (2026-09-24): 턴 어드미션 바이트 예산

### 7.1 배경 — 개수 상한이 우연히 문맥을 지키고 있었다

`MASC_KEEPER_ADMISSION_MAX_EVENTS`(기본 32, 상한 256, 환경변수 레지스트리)는 #29365 의 임시 장치로, 이 RFC §5 가
명시적으로 두지 않기로 한 개수 상한이다. 그런데 조사(2026-09-24)에서 이 값이 **pinned 관찰 섹션의 유일한 바이트
경계**로 밝혀졌다:

- `render_board_observations`(`keeper_unified_prompt.ml`)는 행 수 제한이 없다.
- `keeper_context_layers` 는 Required 섹션을 자르지 않는다 — 주석의 근거 "행 예산이 바이트를 묶는다" 가 어드미션
  개수를 가리키고 있었다.
- 라이브 런타임은 `max-prompt-bytes` 를 선언하지 않아 `assemble` 의 `budget_bytes` 가 `None` 이다. tail window 은
  pinned 문맥을 자르지 못한다.
- 실패한 턴은 batch 를 유지한다(`Batch_no_action`). 문맥을 넘는 백로그는 턴이 계속 실패하며 영원히 루프한다.

실측 백로그 71건은 여유가 있고, 추정 파손점은 1,000–1,400건(미측정)이다. #38176 은 이 상한이 TOML 이 아니라
환경변수로 조절되는 점도 부채로 지적했다.

### 7.2 설계

1. **단위**: 턴에 admit 되는 자극이 실제 턴 문맥에 더하는 UTF-8 바이트. 문맥 조립과 같은 렌더러로 후보를
   투영한 뒤, 섹션 제목·건수·접기(`Schedule_due`)·프레이밍 변화까지 포함한 전체 요청의 길이 차이를 잰다.
   행 길이를 더하는 별도 근사식은 쓰지 않는다.
2. **선언**: 런타임 TOML 키 `admission_budget_bytes`(keeper 공통)는 **필수 양의 정수**다. 누락·0·음수·정수
   범위 밖은 로드 오류다. 측정되지 않은 고정 기본값과 임의의 허용 구간은 두지 않는다. 운영자는 배포 전에
   §7.4 의 실제 고정 문맥과 관찰 행 크기를 재고, 사용하는 레인에서 남는 요청 용량 이하로 값을 선언한다.
   라이브 설정을 먼저 채운 뒤 개수 상한을 제거하는 배포 순서도 구현 PR 에 기록한다.
   `MASC_KEEPER_ADMISSION_MAX_EVENTS`, `KeeperAdmissionBounds`, 설정 레지스트리 항목, 런타임 설정 표시줄은
   삭제된다(#38176 의 선택 상한 절반).
3. **합산 경계**: `D` 는 선언한 자극 바이트 예산이다. 같은 불변 입력 스냅샷에서 자극이 없는 최종 요청을
   `Fᵢ`, admit 후보를 넣어 렌더한 최종 요청과의 바이트 차이를 `Aᵢ` 로 잰다(후보 런타임 `i` 별).
   `Aᵢ ≤ D` 를 지키고, 검증 가능한 **전체 요청** 상한 `Cᵢ` 가 있는 후보는 `Fᵢ + Aᵢ ≤ Cᵢ` 도
   지킨다. 이번 턴에서 선택될 수 있는 모든 후보에 이 조건을 적용한다. #38500 의 브리핑 예산도 그 후보
   집합을 쓰지만, `max-prompt-bytes` 가 Claude Code 의 이력 씨앗만 제한하는 경우에는 그 값을 전체 요청
   상한인 양 재사용하지 않는다. `Cᵢ` 를 확인할 수 없는 후보에서는 `D` 만 성장 경계이며 provider
   문맥 적합성 보장은 하지 않는다.
4. **시행 지점**: `consume_batch` 의 순차 admit 루프에서 각 후보를 같은 렌더러로 다시 투영한다. 어떤 후보에서든
   `Aᵢ > D` 또는 알려진 `Fᵢ + Aᵢ > Cᵢ` 이면 그 자리에서 중단하고 잔여 selection 을 pending 에 둔다.
   단, 현재 admitted 가 비었는데 이 selection **혼자도** 전체 예산에 못 맞으면 5번으로 간다. 이미 admit 한 행은
   자르지 않는다.
5. **한 selection 이 맞지 않을 때**: 예산을 무시하고 첫 행을 admit 하지 않는다. source id, 렌더 바이트,
   적용된 `D`·해당 후보의 `Cᵢ`, 이유를 가진 durable `Admission_blocked` 상태로 해당 selection 을 보존한다. 이 상태는
   ready 조회에서 제외하므로 다음 ready selection 이 진행한다. ack·terminal 처분은 하지 않는다. 운영자가
   예산/원본을 고친 뒤 명시적으로 재평가를 요청해야 ready 로 돌아간다. 표시·로그에 차단 이유와 복구 동작을
   노출한다. 자극 없는 `Fᵢ` 자체가 `Cᵢ` 를 넘으면 특정 selection 을 탓하지 않고 keeper 를 입력 부적합으로
   일시 정지하며 pending 을 그대로 둔다.
6. **알려지지 않은 상한의 실패**: `Cᵢ` 가 없어 provider 가 typed 입력 크기 거절을 돌려주면, 효과 실행 전임이
   증명된 경우에도 같은 batch 를 그대로 자동 재제출하지 않는다. keeper 를 입력 부적합으로 일시 정지하고
   실패한 전체 요청 크기와 batch id 를 남긴다. 원인을 한 행으로 특정할 수 없으므로 source 를 자동 격리하지
   않는다. 효과 여부를 증명할 수 없는 실패는 기존 안전 판정을 따른다. 운영자가 원인을 고치고 재개하면
   pending 을 다시 평가한다.
7. **가시성**: 예산 때문에 중단하면 withheld 건수와 바이트를 INFO 로 남긴다. 한 행 차단과 keeper 정지는
   각각 durable 이유를 표시한다. 계측이 차단 자체를 자동 해제하지 않는다.
8. **connector_attention**: recorded items 조회는 실제 admit 된 event id 로만 한다(현행
   `Seq.take max_events` 대체). 앞의 selection 이 차단된 경우도 건너뛴 정확한 id 집합을 사용한다.
9. **경계는 바이트 하나뿐**: 32, 256, clamp 같은 개수 장치는 유지하지 않는다.

### 7.3 이 변경 안에서 하지 않을 것

- 렌더된 문맥을 자르는 사후 예산(`assemble` trim). Required 는 자를 수 없고, 문맥이 이미 커진 뒤라 늦다.
- `max-prompt-bytes` 에서 선언 예산 `D` 를 파생하는 것. 그 키를 선언하지 않은 라이브에서 경계가 사라진다.
   §7.2-3 의 실제 **전체 요청** 상한이 있는 후보에만 추가 적합성 검사를 한다.
- ready 백로그의 우선순위 재정렬·재처리. 명시적으로 차단된 selection 만 ready 조회에서 빠진다.

### 7.4 검증

1. 여러 selection 의 합이 예산을 넘을 때 그 자리에서 중단, 잔여 pending 유지, INFO 1건. 전체 렌더 결과의
   섹션 제목·건수 변화와 schedule 접기까지 계산한다.
2. 단일 초대형 selection 은 `Admission_blocked` 로 남고 다음 ready selection 이 진행한다. 명시적 재평가 전에는
   다음 tick 에도 admit 되지 않는다. 자극 없는 `Fᵢ > Cᵢ` 는 keeper 정지이지 source 차단이 아니다.
3. 전체 요청 상한이 있는 레인에서 `Aᵢ ≤ D` 여도 `Fᵢ + Aᵢ > Cᵢ` 면 admit 을 막는다. 상한 미선언 레인의 typed
   입력 크기 거절은 같은 batch 를 재시도하지 않고 정지하며, 효과 여부가 불명확하면 자동 처분하지 않는다.
4. connector items 조회가 실제 admit 된 id 만 본다(차단된 선두 selection 포함).
5. `admission_budget_bytes` 누락·0·음수·정수 범위 밖 값의 로드 오류(설정 suite).
6. 환경변수·레지스트리 항목 삭제의 회귀(`test_env_config_keeper_admission_bounds` 재작성, 설정 레지스트리
   스냅샷). 기존 4 suite(`test_keeper_board_unavailable`, `test_keeper_connector_attention_batch`,
   `test_keeper_board_turn_ack`, `test_env_config_keeper_admission_bounds`)를 새 계약으로 다시 쓴다.
7. 라이브 재측정(구현 PR 본문): 레인별 자극 없는 최종 요청 `F`, 전체 요청 상한 `C` 의 근거, 관찰 행 바이트
   분포, 선언값 `D` 의 선택 근거, 턴별 admit 바이트, withheld·차단 빈도, 백로그 변화. `C` 없는 레인의
   provider 거절도 기록한다. 계측 전에는 특정 기본값이 안전하다고 주장하지 않는다.

### 7.5 관계

- §5 첫 줄을 이 절이 대체한다. `keeper_heartbeat_stimulus_intake.mli` 머리 주석에 어드미션 예산 한 줄이 함께
  간다.
- #38176 의 선택 상한 절반을 닫는다(간격 하한 60초 절반은 이 RFC 밖).
- #29365 가 방어하던 "도착률이 백로그로 자라는" 문제를 같은 자리에서 계속 막는다.
