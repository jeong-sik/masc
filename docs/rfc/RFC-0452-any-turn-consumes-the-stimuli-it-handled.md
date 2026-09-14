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

이 RFC 의 결정: **소비자는 lane 이 아니라 "그 자극을 실제로 다뤘다고 선언한 턴" 이다.** 어느 lane 이든 턴이 자기 컨텍스트에 admit 된 자극 중 **명시적으로 다뤘다고 선언한 것만** ack 한다. 선언은 typed 도구로, admit 된 집합에 대해서만 유효하다 — 못 본 자극은 ack 할 수 없다.

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

소비자는 lane 의 이름이 아니라 **그 자극을 실제로 다룬 주체** 다. 채팅 턴이 자극을 다뤘으면 채팅 턴이 소비자다. 빠진 것은 "채팅은 소비 금지" 가 아니라 **"내가 이 자극을 다뤘다" 를 선언할 수단** 이다. 그 선언이 있으면 1.3 의 안전은 그대로 유지된다: 선언 안 한 자극은 절대 ack 되지 않으므로, "몇 시야" 턴은 리포트 자극을 건드리지 않는다.

## 3. 설계

### 3.1 admit 된 자극 집합을 턴이 들고 있다

이미 있다. `pending_selections`(RFC-0377) 가 이 턴에 admit 된 자극이고 librarian 이 컨텍스트에 넣는다. 이 집합의 자극 id 들이 이 턴이 ack **할 수 있는** 유일한 대상이다.

### 3.2 명시적 선언 도구 (typed)

모델이 턴 중에 부르는 도구를 추가한다(이름 잠정 `masc_stimulus_handled`). 입력은 자극 id 목록이고, **admit 된 집합에 대해서만 유효** 하다. admit 되지 않은 id 는 거부한다(Result 의 Error). 이로써 "못 본 자극을 ack" 하는 상태가 **표현 불가능** 해진다 — API 가 admit 집합의 부분집합만 받는다.

도구는 자극을 즉시 소비하지 않는다. "이 턴이 이것을 다뤘다" 는 선언을 턴-로컬로 모을 뿐이다. 실제 durable ack 는 턴 종료 경계에서 한 번에 일어난다(3.3).

### 3.3 턴 종료 시, 선언된 것만 ack (모든 lane)

턴이 끝날 때(채팅이든 자율이든) ack 대상 = (admit 된 자극) ∩ (선언된 자극). 그것만 `ack_pending_result`. 선언 안 된 admit 자극은 pending 으로 남아 다음 턴을 기다린다.

lane 별 **기본값** 은 다르되 규칙은 하나다:

| lane | 선언 없는 admit 자극의 처리 | 근거 |
|---|---|---|
| 자율(keepalive) | 기본 ack (현행 batch 유지) | 자율 턴의 목적이 "큐의 일을 처리" 다. 처리가 곧 존재 이유. |
| 채팅 | 기본 미ack | 채팅 턴의 목적이 "운영자에게 답" 이다. 자극 처리는 부수적일 수 있다. |

즉 자율은 opt-out(선언으로 특정 자극을 "안 했다" 표시), 채팅은 opt-in(선언으로 "했다" 표시). 두 기본값의 차이는 lane 이 아니라 **각 lane 의 목적** 에서 나온다. 규칙 자체("선언이 소비를 정한다")는 하나다.

> 비목표: 이 문서는 자율 lane 을 opt-in 으로 바꾸지 않는다. 현행 batch-ack 는 그대로 두고, 채팅에 선언-ack 를 추가한다. 자율까지 선언-ack 로 통일하는 것은 선언이 신뢰 가능해진 뒤의 별도 결정으로 남긴다.

### 3.4 B1(발행 자기 클럭, #36213)과의 관계

- B1 은 **발행** 을 제한한다: delivery=none interval 은 schedule_instance 당 미소비 occurrence 최대 1개.
- 이 RFC(B2)는 **소비** 를 넓힌다: 어느 lane 이든 다룬 자극을 ack.
- 독립·상보. B1 만: 최대 1 pending, 자율 턴이 소비. B2 만: 발행은 여전히 쌓이지만 아무 턴이나 소비. 둘 다: 1 pending 을 다룬 주체가 소비. 권장: B1 먼저(작고 출혈 차단), B2 는 모델 소비 모델의 근본.

## 4. 경계 (constitution)

- **Gate 아님.** 선언은 처리의 evidence 이지 스케줄링을 강제하는 Gate 가 아니다. 선언이 없어도 턴은 정상 동작한다(자극이 pending 으로 남을 뿐).
- **텍스트 추론 금지.** 모델의 답변 문장을 스캔해 "했다" 를 추정하지 않는다. 명시적 typed 도구 호출만. semantic string matching 은 이 프로젝트에서 금지다.
- **새 durable 상태 최소.** 소비는 기존 `ack_pending_result` + reaction ledger 를 그대로 쓴다. 추가되는 것은 턴-로컬 선언 집합(휘발)과 도구 하나뿐. 새 상태·필드·Gate 를 durable truth 에 넣지 않는다.
- **admit 경계 재사용.** ack 가능 집합은 RFC-0377 의 pending_selections 그대로. 별도 권한 축을 만들지 않는다.

## 5. 검증

테스트(결정론):

1. 채팅 턴이 admit 된 schedule X 를 `masc_stimulus_handled` 로 선언 → 턴 종료 후 X 는 ack, 같은 턴에 admit 된 Y 는 pending 유지.
2. 채팅 턴이 아무것도 선언 안 함 → 어떤 자극도 ack 안 됨("몇 시야" 안전 케이스).
3. 채팅 턴이 admit 되지 않은 자극 id 를 선언 → 도구가 Error, 어떤 ack 도 없음.
4. 자율 턴은 현행 batch-ack 그대로(회귀 없음).

불변식(TLA+ bug model 로도 표현 가능, software-development.md 참조):

> **어떤 자극도, 그 자극을 ack 한 턴의 admit 집합에 없었다면 ack 되지 않는다.**

이 불변식은 3.2 의 타입(도구가 admit 집합의 부분집합만 받음)으로 by-construction 성립한다. `NextBuggy = Next \/ AckUnadmitted` 가 이 불변식을 위반해야 spec 이 유효하다.

## 6. 관련

- RFC-0377 대화 배치 자극 intake — admit 집합의 출처.
- RFC-0373 턴 lane admission — 슬롯 하나를 세 lane 이 공유, 채팅이 자율을 굶기는 starvation 측정.
- RFC-0303 stimulus-gated keeper wake — 자극이 wake 를 여는 규칙.
- #36213 발행 자기 클럭(B1) — 이 RFC 의 상보 축.
- #36203 / #36195 — 자율 lane 소비가 멈추는 다른 원인(펜스). 이 RFC 는 소비자를 늘려 단일 소비자 의존 자체를 줄인다.
