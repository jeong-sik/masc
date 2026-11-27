---
rfc: "ask-answer-is-queued-before-it-is-recorded"
title: "질문 답은 큐에 먼저 넣고, 같은 잠금 안에서 기록한다"
status: Draft
created: 2026-11-27
updated: 2026-11-27
author: claude
supersedes: []
superseded_by: null
related: ["#55173", "#55146", "#55156", "#42955", "#50873"]
---

# 질문 답은 큐에 먼저 넣고, 같은 잠금 안에서 기록한다

- 코드 기준: main `9cdbaa9ddf3ff`.
- **정한 것**: 답을 기록하는 순서(D1), 열린 질문을 가리키는 포인터를 처리하는 법(D2), 지우는 것(D3), 종료 중에 온 답(D4).
- **바뀌는 동작**: Keeper 의 종료 작업이 intake 를 쥐고 있는 동안 온 답은 거절된다. 질문은 열린 채로 남는다(D4).

## 0. 요약

운영자가 Keeper 의 질문에 답하면 서버는 답을 질문 로그에 먼저 쓴다. 그다음 Keeper 큐에 "답이 왔다" 포인터를 넣는다. 둘 사이에 실패하면 답은 있는데 큐에는 없다. 이 틈을 메우려고 1분마다 도는 답변 복구가 있다. 복구는 질문 로그에 있는 모든 답을 반응 원장에서 다시 확인한다.

이 복구가 두 문제를 만든다.

1. 반응 원장의 날짜 파일이 지워지면 전달 증명도 사라진다. 그러면 복구가 지난 답을 다시 전달한다(#55173). 원장이 v8 로 바뀐 11-06 에 실제로 일어났다.
2. 재시작 뒤 첫 바퀴가 원장을 전부 읽는다. 그 읽기가 CPU 풀을 막는다(#55146).

이 RFC 는 순서를 뒤집는다. 서버는 Keeper owner 잠금 안에서 포인터를 먼저 durable 하게 넣고, 같은 잠금 안에서 답을 쓴다. 그러면 "답은 있는데 큐에 없는" 상태가 생기지 않는다. 복구 루프와 원장 확인을 지운다. 새 상태나 새 저장소는 만들지 않는다.

## 1. 지금 동작

### 1.1 답변 경로

- `POST /api/v1/keepers/ask-answer` 는 `Keeper_ask_store.answer` 로 `Answered` 줄을 쓴다(`lib/server/server_routes_http_keeper_asks.ml:126`).
- 그다음 `wake_keeper_for_answered_ask` → `Keeper_ask_answer_wake.deliver` 가 큐에 포인터를 넣는다(`server_routes_http_keeper_asks.ml:79`, `lib/keeper/keeper_ask_answer_wake.ml:291-334`).
- 포인터 넣기가 실패하면 HTTP 500 에 `recorded: true` 를 실어 보낸다. 본문은 "delivery to the keeper is pending automatic recovery" 다(`server_routes_http_keeper_asks.ml:59-77`).
- 대시보드는 이 500 을 "기록은 됨" 으로 따로 받는다(`dashboard/src/api/keeper-asks.ts:47-62`).
- 같은 질문에 두 번째 답이 오면 `Already_answered` 를 받고, 그때도 다시 전달을 시도한다(`server_routes_http_keeper_asks.ml:134-136`).

### 1.2 복구 루프

- `Keeper_ask_answer_wake.pulse` 가 유지보수 틱(60초)마다 돈다(`lib/server/server_bootstrap_maintenance.ml:860-862, 891, 911`).
- 답마다 답변 시각부터 오늘까지의 반응 원장에서 전달 증명을 찾는다(`keeper_ask_answer_wake.ml:403-498`). 증명은 `event_queue_ack`, `turn_started`, 취소 줄이다.
- 증명이 없으면 `enqueue_stimulus_once_durable_result` 로 다시 넣는다. 큐 주인도 같은 원장을 owner 잠금 안에서 다시 읽는다(`lib/keeper/keeper_registry_event_queue.ml:516-535`, `lib/keeper_runtime/keeper_event_queue_persistence.ml:1489-1517`).
- #55156 은 한 프로세스 안에서 "이미 전달을 본 답" 을 기억한다. 재시작하면 비어서, 첫 바퀴는 다시 전부 읽는다.

### 1.3 측정

- **재전달**: v8 원장이 시작된 날, 그 전에 답한 질문이 거의 모두 다시 전달됐다.

  | Keeper | 그날 ack | 그 전에 답한 질문 |
  |---|---|---|
  | e-masc-the-leader | 239 (11-06) | 237 |
  | wkbl-web-leader | 74 (11-06) | 72 |
  | goo-yang-bong | 68 (11-09) | 67 |
  | rondo | 61 (11-09) | 55 |

  - 셈은 `keepers/<k>/reaction-ledger/v8/*/*.jsonl` 의 `stimulus_kind = ask_answered` 인 `event_queue_ack` 와 `.masc/keeper_ask/<k>.jsonl` 의 `answered_at` 으로 했다.
  - 다시 전달된 답에는 지난 병합 승인도 있다.
- **보존 기한**: 반응 원장은 운영자 보존 창을 따른다. 기본은 30일이다(`lib/dated_jsonl/dated_jsonl_store.ml:171`, `lib/config/env_config_core.ml:751-756`).
  - 서버 시작 정리가 날짜 파일을 지운다(`lib/server/server_runtime_startup_maintenance.ml:108-125`). 11-27 에 이 정리는 296초, 219초 걸렸다.
  - 12-06 무렵부터 v8 의 첫 파일이 지워진다. 그 뒤 재시작할 때마다 같은 재전달이 일어난다.
- **풀 부하**: 11-27 18:35 에 재시작한 서버를 18:45 부터 30초 쟀다. 풀 빈칸 대기(`Sync.put`)가 52번, 중간값 21.1초였다. 반응 원장 읽기 대기도 31번, 중간값 6.2초였다(#55146).

## 2. 원인

전달 사실의 권위가 잘못된 곳에 있다.

- 큐는 ack 한 포인터를 잊는다. "전달됐나" 는 반응 원장에 맡긴다.
- 복구는 30일 원장에 줄이 없는 것을 "다시 넣어도 된다" 로 읽는다. 이것은 지난 ack 증거로 다음 행동을 정하는 게이트다.
- 그 게이트가 필요한 이유는 하나뿐이다. 답을 먼저 쓰고 큐에 나중에 넣는 순서다. 이 순서에서는 둘 사이의 실패를 나중에 메울 무언가가 있어야 한다.

## 3. 설계

### D1. owner 잠금 안에서: 확인 → 포인터 → 기록

답변 경로는 다음 순서로 한다.

1. Keeper 의 durable intake fence 를 잡는다(`Keeper_registry_event_queue.with_durable_intake`). fence 가 거절하면 아무것도 쓰지 않는다.
2. 큐 owner 잠금(`Owner_lock.with_durable_lock`)을 잡는다.
3. 질문 로그를 읽는다. 질문이 열려 있고 답이 질문을 만족하는지 검증한다. 지금 `Keeper_ask_store.answer` 가 하는 검증 그대로다.
4. 포인터 `keeper-ask:<ask_id>` 를 strict durability 로 넣는다. `arrived_at` 은 이 답의 `answered_at`(`now`)이다. 이미 있으면 그대로 둔다.
5. 같은 잠금 안에서 `Answered` 줄을 쓰고 다시 읽어 확인한다.
6. 잠금을 놓고 live wake hint 를 보낸다.

불변식: **`Answered` 줄은 언제나 그보다 먼저 durable 해진 포인터를 가진다.**

- 질문 로그는 계속 답의 유일한 권위다. 포인터는 지금처럼 ask id 만 싣는다.
- 3 과 5 사이에 다른 답이 끼어들 수 없다. 답을 쓰는 곳은 이 경로 하나뿐이고(`Keeper_ask_store.answer` 의 호출처는 route 하나), 모두 같은 owner 잠금을 거친다.
- 질문 철회(`withdraw`)는 Keeper 의 도구가 부르고(`lib/mcp_tool_runtime_ask.ml:427`) 이 잠금을 잡지 않는다. 철회가 3 과 5 사이에 들어오면 로그의 첫 줄인 철회가 이긴다.
  - 지금은 이때 다시 읽기가 `Answer_recorded_unconfirmed` 를 돌려준다(`keeper_ask_store.ml:308-310`). 다시 읽은 결과가 철회라는 것이 증명됐으므로 `Already_withdrawn` 으로 고친다.
  - 남은 포인터는 D2 가 정리한다.
- 포인터 동일성은 `post_id`·`urgency`·payload 로 정해지고 `arrived_at` 은 보지 않는다(`lib/keeper_runtime/keeper_event_queue.ml:997-1013`). 앞선 시도가 남긴 포인터가 있으면 4 는 `Already_present` 로 끝난다.
- owner 는 이름으로 풀린다(`Owner_lock.resolve`). 꺼진 Keeper 에게도 지금처럼 포인터가 들어간다.
- 질문 로그 읽기는 CPU 풀을 쓰지 않는다(`keeper_ask_store.ml:191-195`). owner 잠금을 쥔 채로 풀 칸을 기다리지 않는다.

구현은 두 부품으로 나눈다.

- 큐 쪽(`keeper_event_queue_persistence`, `keeper_registry_event_queue`): owner 잠금을 잡은 채로 넘겨받은 함수를 부르는 진입점 하나. 그 함수는 "포인터를 strict durability 로 넣는 함수" 를 받는다. 넘겨받은 함수가 끝난 뒤 이 넣기 함수를 부르면 저장하지 않고 오류를 돌려준다. 큐는 질문 로그를 모른다.
- 질문 로그 쪽(`keeper_ask_store`): 지금의 `before_append` 자리(`lib/keeper/keeper_ask_store.ml:293`)를 실패할 수 있는 `admit` 단계로 바꾼다. `admit` 은 검증을 통과한 질문을 받는다. 실패하면 쓰지 않고 `Admission_failed` 를 돌려준다.

### D2. 열린 질문을 가리키는 포인터는 owner 잠금 안에서 다시 보고 정리한다

intake 는 지금 포인터가 가리키는 질문이 열려 있거나 철회됐거나 없으면, 그 포인터를 독으로 보고 ack 한다(`lib/keeper/keeper_heartbeat_stimulus_intake.ml:1120-1129, 1203-1206`).

D1 에서는 포인터가 답보다 먼저 생긴다. 그래서 intake 가 잠금 밖에서 "열림" 을 읽고 ack 하면, 그사이 기록된 답을 잃는다.

- intake 는 이 포인터를 owner 잠금 안에서 질문 로그를 다시 읽은 뒤에만 ack 한다.
- 다시 읽었을 때 `Answered` 면 ack 하지 않는다. 그 새 스냅샷으로 같은 포인터를 이번 intake 에서 다시 관찰한다. 로그는 덧붙이기만 하므로 두 번째 관찰은 답을 본다.
- 여전히 열림·철회·없음이면 지금처럼 ack 한다. 다시 읽기가 실패하면 지금의 읽기 실패처럼 남기고 보고한다.
- 큐 쪽에는 "잠금 안에서 조건을 본 뒤에만 ack" 하는 진입점을 하나 더한다. 조건은 넘겨받은 함수로 받는다. 조건이 "남겨라" 면 저장하지 않는다.

### D3. 지우는 것

- `Keeper_ask_answer_wake` 의 `deliver`, `deliver_row`, `reconcile`, `report`·`failure`·`held_answer` 타입, supervisor(`t`, `create`, `pulse`), #55156 의 기억.
- 유지보수 연결(`server_bootstrap_maintenance.ml:860-862, 891, 911`).
- 두 번째 답이 왔을 때 다시 전달하는 동작(`server_routes_http_keeper_asks.ml:134-136`).
- "기록됐지만 전달 대기" 500 응답과 `delivered` 필드(`server_routes_http_keeper_asks.ml:59-77`).
- 대시보드가 이 500 을 따로 받는 경로(`dashboard/src/api/keeper-asks.ts:47-90`)와 그 결과를 쓰는 곳.
- `Keeper_ask_answer_wake.mli:148` 의 "No timer, history cap, second answer store or outbox." 계약 문장. 지킬 대상이 없어진다.

남기는 것은 `observe_followup` 이다. 이것은 반응 원장을 증거로만 읽는다(`keeper_ask_answer_wake.ml:190-229`).

### D4. 종료 작업이 intake 를 쥐고 있을 때

- 지금: 답을 기록하고, 큐 넣기가 거절되면 복구가 나중에 넣는다(#50873).
- 이 RFC: fence 가 거절하면 답을 기록하지 않는다. HTTP 503 과 `state: "keeper_shutting_down"` 을 돌려준다. 질문은 열린 채로 남는다.
- 이유: "기록했지만 아직 안 넣은 답" 을 기억하려면 그것이 곧 두 번째 저장소다. 질문이 열린 채로 남는 것은 모든 화면이 이미 보여 주는 상태다. 운영자는 Keeper 가 돌아온 뒤 다시 답하면 된다.

### D5. 배포할 때

- 저장 형식은 바뀌지 않는다. 마이그레이션이나 변환기는 없다.
- 배포 순간 큐에 남은 포인터는 평소처럼 소비된다.
- 옛 코드가 기록만 하고 아직 넣지 못한 답이 있을 수 있다. 직전 보고의 `shutdown_reserved`·`owners_absent` 에 있던 답이다. 이 답은 다시 넣지 않는다. 그 질문은 화면에 "답함" 으로 남는다. 운영자에게 알릴 목록은 배포 전 마지막 복구 보고 로그(`ask answer recovery held by shutdown`)에 있다.

## 4. 중단되는 지점

| 어디서 멈췄나 | 남는 상태 | 결과 |
|---|---|---|
| fence 거절 | 없음 | 503, 질문 열림 |
| 3(검증) 실패 | 없음 | 409·400·404, 지금과 같음 |
| 4(포인터) 저장 실패 | 없음 | 500, 질문 열림 |
| 4 뒤, 5 전에 프로세스 종료 | 포인터만 있고 질문은 열림 | intake 가 잠금 안에서 열림을 확인하고 ack(D2). 운영자가 다시 답하면 새 포인터가 들어간다 |
| 5 에서 `Already_withdrawn` | 포인터만 있고 질문은 철회 | D2 가 ack. 응답은 409 |
| 5 에서 저장 실패 | 포인터만 있고 질문은 열림 | D2 가 ack. 응답은 500, 질문 열림 |
| 5 에서 기록 뒤 다시 읽기 실패(`Answer_recorded_unconfirmed`) | 포인터 있음, 답은 기록됐을 수 있음 | 기록됐으면 intake 가 전달한다. 안 됐으면 D2 가 ack. 응답은 지금처럼 `recording_unconfirmed` |
| 6 전에 종료 | 포인터와 답 둘 다 있음 | live hint 만 빠진다. 다음 heartbeat 가 포인터를 읽는다 |

## 5. 고르지 않은 안

- **질문 로그에 "큐에 넣음" 줄을 더 쓴다**(owned job 의 `completion_delivered` 와 같은 모양).
  - 새 상태가 생긴다. 1분 루프와 원장 확인도 "넣은 뒤, 표시 전" 틈을 메우려고 남는다.
  - 옛 답에는 표시가 없다. 표시가 없는 답을 "안 넣음" 으로 보면 11-06 재전달이 배포 때 한 번 더 일어난다. 옛 답에 표시를 한 번에 채우면 그것은 변환기다.
  - 큐가 이미 가진 사실(넣었는지)을 질문 로그가 한 번 더 적는다. 권위가 둘이 된다.
- **반응 원장 보존 기한을 질문 로그에 맞춘다**: 질문 로그는 기한이 없어서 원장 보존이 사실상 꺼진다. 11-06 같은 세대 전환(v7→v8)은 막지 못한다.
- **보존 기한보다 오래된 답은 전달된 것으로 본다**: 시각으로 상태를 정하는 게이트다(constitution "시간이 지났다는 사실은 상태를 죽일 근거가 아니다"). 11-06 에는 며칠 된 증명도 사라졌다.
- **#55156 의 기억만 둔다**: 재시작 때 비어서 재전달과 첫 바퀴 부하를 못 막는다.

## 6. 구현 순서 (native stack)

1. 이 RFC.
2. 큐 진입점 두 개(D1 의 잠금 안 넣기, D2 의 조건부 ack)와 그 시험. 아직 아무도 부르지 않는다.
3. intake 의 잠금 안 재확인(D2). 답변 경로보다 먼저 넣는다.
   - 거꾸로 넣으면 "포인터는 있고 질문은 아직 열림" 인 틈에 intake 가 포인터를 지울 수 있다.
   - 그 ack 는 반응 원장에 남는다. 복구 루프는 그것을 전달 증명으로 읽고 다시 넣지 않는다. 답을 잃는다.
4. `Keeper_ask_store.answer` 의 `admit` 단계, `Keeper_ask_answer_wake.answer`, route(D1·D4), 두 번째 답의 다시 전달 삭제.
   - 이 층까지만 들어가도 복구 루프는 돈다. 새 답에는 포인터가 이미 있어서 복구는 `Already_present` 로 끝난다.
5. 복구 루프(`deliver`·`reconcile`·`pulse`·supervisor)와 유지보수 연결, 그 시험을 지운다(D3).
6. 대시보드: 500 부분 전달 경로와 `delivered` 를 지운다(D3). 503 은 "Keeper 가 종료 중이라 기록하지 않았다" 로 알리고 초안을 남긴다(D4).

## 7. 확인

- 시험(`test.yml` dispatch).
  - 답이 기록되면 포인터가 큐에 있다.
  - 포인터 저장이 실패하면 답이 기록되지 않는다.
  - fence 가 거절하면 503 이고 질문은 열려 있다.
  - 열린 질문의 포인터는 intake 가 ack 한다.
  - 잠금 안 조건이 "남겨라" 면 ack 하지 않고 저장하지 않는다. 이것은 큐 진입점 시험으로 본다. intake 와 답변 경로의 실제 경합은 끼워 넣을 hook 이 없어 시험하지 않는다.
  - 소비된 답에 두 번째 답이 오면 409 이고 새 포인터가 생기지 않는다.
  - followup 이 보는 출처 id 가 큐에 든 포인터의 id 와 같다.
- 배포 뒤 측정.
  - 재시작 직후 10분 동안 `read_delivery_evidence` 호출이 질문 답변 쪽에서 0 이다. 측정은 runtime-events 로 한다.
  - 같은 구간 `Sync.put` 중간값을 #55146 기준(21.1초)과 비교한다.
  - 대시보드에서 답한 질문이 Keeper 다음 턴의 관찰에 한 번만 들어간다.

## 8. 남는 것

- 큐 파일 자체를 잃으면(격리, 세대 전환) 포인터도 사라진다. 다시 넣어 주는 것은 없다. 이것은 모든 자극 종류가 같고, owned job 의 표시도 같은 계약이다. 큐 손실의 복구는 큐가 맡는다.
- connector attention, owned job 완료, delegate 완료는 여전히 once-only 넣기에서 반응 원장을 읽는다. 같은 보존 기한 문제가 있는지는 따로 본다.
