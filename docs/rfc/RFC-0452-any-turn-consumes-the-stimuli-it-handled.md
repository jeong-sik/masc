---
rfc: "0452"
title: "소비는 lane 이 아니라 다룬 주체가 한다 — 채팅 턴도 자기가 처리한 자극을 ack 한다"
status: Draft
created: 2026-09-14
author: claude
related: ["0373", "0377", "0303"]
---

# RFC-0452 — 소비는 lane 이 아니라 다룬 주체가 한다

- Status: Draft
- 선행: RFC-0377(대화 배치 자극 intake, Accepted) 은 "한 턴이 준비된 모든 자극을 본다" 를 열었다. RFC-0373(턴 lane admission) 은 자율/채팅/유지보수 세 lane 이 실행 슬롯 하나를 공유함을 적었다. 이 문서는 그 둘이 닫지 않은 한 줄을 연다: **자극을 소비(ack)하는 주체가 자율 lane 하나로 고정돼 있다.**

## 0. 결정 요약

지금 자극(schedule_due·board·connector·workspace_message·hitl…)을 durable 하게 소비(ack)하는 경로는 자율 keepalive 턴 하나뿐이다. 채팅 턴은 운영자에게 답만 하고 자극을 ack 하지 않는다.

그런데 채팅 턴도 자극을 **읽는다** — librarian 이 pending 자극을 컨텍스트에 넣기 때문이다. 즉 모델은 "예약: 삼국지 이어가기 ×N" 을 보고 그 대화에서 실제로 다루는데, 시스템은 그걸 처리한 것으로 세지 않는다. 그 결과 채팅이 계속되면(또는 자율 lane 이 굶거나 펜스되면) 자극이 영원히 안 빠지고 event queue 에 단조 축적된다. msx-retro-mania 는 2026-09-14 에 30개까지 쌓였다.

이 RFC 의 결정: **소비자는 lane 이 아니라 자극이 요구한 효과를 실제로 남긴 턴이다.** 어느 lane 이든, admit 된 자극 중 그 자극이 요구한 durable 효과(답이 그 대화 route 로 전달됨·gate grant 소비·task 정산 등)를 남긴 것을 ack 한다. 효과가 없는 하트비트 wake(`result_delivery=None`)는 잃을 것이 없으니 턴의 관여로 소비하고, 개수는 #36213 이 묶는다. **어느 쪽도 모델의 자기 신고를 신뢰하지 않는다 — 소비는 증거로 판정한다.**

## 1. 문제

### 1.1 소비 경로가 자율 lane 하나뿐이다

`stimuli_acked` 로 자극을 durable 하게 ack 하는 코드는 `lib/keeper/keeper_heartbeat_loop.ml` 에만 있다. 채팅 턴 경로(`Submit_operation`/`Submit_interactive_operation` → operation runner → `keeper_agent_run`)에는 자극 ack 가 없다.

### 1.2 그런데 채팅 턴은 자극을 본다

`lib/keeper/keeper_librarian_context_io.ml:22-40`:

```ocaml
let events = match Keeper_registry_event_queue.pending_selections_result ~base_path keeper_name with
  | Ok selections -> List.map Context.source_of_event selections
  | ... in
...
(References.empty, []) (events @ chats)
```

librarian 은 event queue 의 pending 자극과 chat pending 을 **둘 다** 컨텍스트에 넣는다. 그래서 채팅 턴의 모델은 pending schedule_due 를 읽고, 운영자가 "삼국지 이어가자" 라고 하면 그 자극이 요구하는 일을 그 턴에서 그대로 한다. 하지만 ack 경로가 없어 자극은 pending 그대로 남는다.

### 1.3 lane 분리의 원래 근거는 성립하지만 반쪽이다

소비를 자율 lane 으로 제한한 이유는 하나다: **"ack = 처리했다" 인데, 잘못 ack 하면 일이 사라진다.** 운영자가 "지금 몇 시야" 라고 물은 턴이 "일일 리포트 올려" 자극을 조용히 ack 하면, 리포트는 영영 안 올라간다. 그래서 채팅은 답만, 자극 소비는 "큐의 일을 하는" 자율 턴만.

근거 자체는 옳다. 하지만 이 규칙은 **소비의 안전** 을 지키려고 **소비의 가능성** 을 lane 에 묶었다. 채팅이 실제로 자극을 다뤄도 소비가 안 된다. 채팅이 오래 이어지면 자율 턴이 슬롯을 못 잡아(RFC-0373 의 starvation) 자극이 무한정 안 빠진다. 안전 규칙이 정체를 낳는다.

## 2. 통찰

소비자는 lane 의 이름이 아니라 **그 자극이 요구한 효과를 실제로 남긴 주체** 다. 채팅 턴이 그 대화로 답을 보냈으면 채팅 턴이 소비자다. 빠진 것은 "채팅은 소비 금지" 가 아니라 **처리의 증거를 소비로 연결하는 배선** 이다. 그리고 그 증거는 이미 durable 하게 남는다(§3.2). 모델이 "했다" 고 말하는지는 보지 않는다 — 효과가 남았는지를 본다. 그래서 1.3 의 안전이 유지될 뿐 아니라 강해진다: 효과 없이 "했다" 는 말만으로는 자극이 사라지지 않는다.

## 3. 설계

### 3.1 admit 된 자극 집합을 턴이 들고 있다

이미 있다. `pending_selections`(RFC-0377) 가 이 턴에 admit 된 자극이고 librarian 이 컨텍스트에 넣는다. 이 집합이 이 턴이 소비 **할 수 있는** 유일한 대상이다 — admit 안 된 자극은 어떤 경로로도 ack 되지 않는다.

### 3.2 소비는 선언이 아니라 durable 효과로 판정한다

소비의 근거는 모델이 "했다" 고 말한 것이 **아니라**, 그 자극이 요구한 효과가 durable 하게 남았는지다. 자극은 이미 타입으로 두 부류다(`result_delivery : Keeper_continuation_channel.t option`, 그리고 `continuation_route` disposition).

**(a) deliverable 있는 자극** — connector_attention(디스코드/슬랙), board mention, workspace_message, hitl_resolved, delegate_completed, task_outcome, `result_delivery` 가 routable 인 schedule. 처리하면 durable 효과가 남는다:
- 답장류 → 그 대화 route 로 답이 실제로 나갔다는 `continuation_route` disposition / delivery obligation 충족. 시스템은 "이 턴이 conversation X 로 답했다" 를 이미 안다(`keeper_unified_turn.ml` 의 continuation_route).
- hitl → gate grant 소비. task/delegate → task 정산.

이 부류의 ack 는 **그 효과 증거로만** 판정한다. 효과가 없으면 모델이 무슨 말을 했든 자극은 pending 으로 남는다.

**(b) deliverable 없는 하트비트** — `result_delivery = None` 인 interval schedule("이어서 플레이" 류). 설계상 결과물을 추적하지 않는다("그냥 깨워라"). 검증할 효과가 없으니 잃을 것도 없다. 이 부류는 **턴이 이 wake 를 admit 하고 실행했다** 로 소비하고, 재증식은 #36213(자기 클럭)이 schedule_instance 당 1개로 막는다.

"실제 확인" 은 (a) 에서 효과 증거로, (b) 에서는 확인할 효과가 애초에 없음으로 각각 정당하다. 모델의 자기 신고를 신뢰하는 경로는 어디에도 없다.

### 3.3 lane 구분 없이 같은 증거 규칙

턴이 끝날 때(채팅이든 자율이든) ack 대상 = admit 된 자극 중 §3.2 의 증거를 남긴 것. lane 별 예외 없음. 자율 턴도 admit 된 배치를 통째로 ack 하지 않는다 — 효과를 남긴 것만.

이것은 현행 자율 batch-ack 의 의도된 변경이다:

- 오늘 자율 턴은 admit 된 배치를 완료만 하면 효과와 무관하게 통째로 done 처리한다 — **효과 없이 사라지는 silent loss**(안 했는데 done). 증거 기반은 그걸 닫는다.
- delivery=none 하트비트는 (b) 규칙(관여)으로 소비되므로, 자율 턴의 흔한 케이스는 회귀가 없다.
- deliverable 있는 자극을 처리하고도 효과가 안 남는 경우(전달 실패 등)는 pending 으로 남아 재시도된다. 이는 손실이 아니라 재처리(at-least-once)이며 기존 delivery obligation 경계와 같은 성질이다.

### 3.4 B1(발행 자기 클럭, #36213)과의 관계

- B1 은 **발행** 을 제한한다: delivery=none interval 은 schedule_instance 당 미소비 occurrence 최대 1개.
- 이 RFC(B2)는 **소비** 를 넓힌다: 어느 lane 이든 다룬 자극을 ack.
- 독립·상보. B1 만: 최대 1 pending, 자율 턴이 소비. B2 만: 발행은 여전히 쌓이지만 아무 턴이나 소비. 둘 다: 1 pending 을 다룬 주체가 소비. 권장: B1 먼저(작고 출혈 차단), B2 는 모델 소비 모델의 근본.

## 4. 경계 (constitution)

- **Gate 아님.** 소비는 처리의 evidence 이지 스케줄링을 강제하는 Gate 가 아니다.
- **모델 자기 신고 금지.** 소비를 모델의 말("했다")에 걸지 않는다. durable 효과에만 건다. 답변 문장을 스캔해 "했다" 를 추정하는 semantic string matching 도 금지(이 프로젝트 규칙).
- **새 durable 상태 최소.** 소비 판정을 기존 증거에 건다 — `continuation_route` disposition / delivery obligation(deliverable 자극), 기존 engagement 신호(하트비트). ack 는 기존 `ack_pending_result` + reaction ledger 그대로. 새 상태·필드·Gate·선언 도구를 추가하지 않는다.
- **admit 경계 재사용.** 소비 가능 집합은 RFC-0377 의 pending_selections 그대로. 별도 권한 축을 만들지 않는다.
- **무거운 검증은 별도.** task/goal 형 자극의 "목표 달성 여부" 검증이 필요하면 RFC-0444 의 goal verifier 경로를 쓴다. 이 RFC 는 "요구한 전달이 일어났는가" 까지만 본다.

## 5. 검증

테스트(결정론):

1. 채팅 턴에 connector 자극(대화 X)이 admit 되고, 턴이 route X 로 답을 전달 → X ack. 같은 턴에 admit 된 다른 대화 Y 는 pending 유지.
2. 채팅 턴이 대화 X 자극을 admit 했지만 route X 로 답이 안 나감(전달 실패/무시) → X pending 유지. 모델이 답했다고 주장해도 마찬가지("몇 시야" 안전 케이스: 리포트 자극에 아무 전달 없음 → 안 지워짐).
3. delivery=none schedule 이 admit 되고 턴이 실행 → 소비. (#36213 로 pending 은 애초에 1개.)
4. admit 되지 않은 자극 → 어떤 효과가 있어도 ack 대상이 아니다.
5. 자율 턴과 채팅 턴이 같은 증거 규칙(§3.3). delivery=none 자율 케이스는 회귀 없음.

불변식(TLA+ bug model 로도 표현 가능, software-development.md 참조):

> **어떤 deliverable 자극도, 그 자극이 요구한 전달의 durable 증거 없이는 ack 되지 않는다.** 그리고 **어떤 자극도, ack 한 턴의 admit 집합에 없었다면 ack 되지 않는다.**

앞 절은 소비를 증거(continuation_route/delivery obligation)에 거는 것으로, 뒤 절은 소비 API 가 admit 집합의 부분집합만 받는 것으로 by-construction 성립한다. `NextBuggy = Next \/ AckWithoutDelivery \/ AckUnadmitted` 가 이 불변식을 위반해야 spec 이 유효하다.

## 6. 관련

- RFC-0377 대화 배치 자극 intake — admit 집합의 출처.
- RFC-0373 턴 lane admission — 슬롯 하나를 세 lane 이 공유, 채팅이 자율을 굶기는 starvation 측정.
- RFC-0303 stimulus-gated keeper wake — 자극이 wake 를 여는 규칙.
- #36213 발행 자기 클럭(B1) — 이 RFC 의 상보 축.
- #36203 / #36195 — 자율 lane 소비가 멈추는 다른 원인(펜스). 이 RFC 는 소비자를 늘려 단일 소비자 의존 자체를 줄인다.
