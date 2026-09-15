---
rfc: "0452"
title: "소비는 lane 이 아니라 다룬 주체가 한다 — 채팅 턴도 자기가 처리한 자극을 ack 한다"
status: Rejected
created: 2026-09-14
revised: 2026-09-15
author: claude
related: ["0373", "0377", "0303"]
---

# RFC-0452 — 소비는 lane 이 아니라 다룬 주체가 한다 (Rejected)

- Status: **Rejected (2026-09-15).** 이 문서의 핵심 접근 — 채팅 턴이 **채널-단위 전달 증거**로 자극을 ack 한다 — 은 구현 매핑에서 **unsound** 로 판명됐다(§3). 채널로 답이 나갔다는 증거는 *어느 자극을* 처리했는지 귀속시키지 못하므로, 그대로 배선하면 이 문서가 없애려던 바로 그 silent loss 를 만든다. 원래 문제 서술(§1)과 분석은 후속 작업의 근거로 남긴다. sound 한 해결 후보는 §3.5.
- 선행: RFC-0377(대화 배치 자극 intake, Accepted) 은 "한 턴이 준비된 모든 자극을 본다" 를 열었다. RFC-0373(턴 lane admission) 은 자율/채팅/유지보수 세 lane 이 실행 슬롯 하나를 공유함을 적었다. 이 문서는 그 둘이 닫지 않은 한 줄을 열려 했다: **자극을 소비(ack)하는 주체가 자율 lane 하나로 고정돼 있다.**

## 0. 결정 요약 (개정: 접근 기각)

원래 결정은 "채팅 턴도 자기가 처리한 자극을 ack 한다, 판정은 그 대화 route 로 답이 나갔다는 `Continuation_route_addressed` 증거" 였다. 구현을 매핑하며 이 증거가 **어느 자극을 처리했는지 증명하지 못한다**는 것을 확인했다(§3.1–3.2). 그래서 채택하지 않는다.

- 급한 축적(msx 의 delivery=none 하트비트, 2026-09-14 30개)은 B1(#36213, PR #36249 병합)이 이미 schedule_instance 당 1개로 묶었다.
- routable 자극(hitl/ask/fusion/schedule)이 쌓이는 건 채팅이 슬롯을 오래 쥐어 자율 lane 이 consume 를 못 하는 starvation(§1.3, RFC-0373) 때문이다. 이걸 채팅의 채널-단위 guess-ack 로 덮으면 요구된 전달이 사라진다(silent loss).
- sound 한 해결 후보는 §3.5. 무엇이 맞는지는 "routable 자극이 실제로 starvation 으로 쌓이는가" 를 측정한 뒤 정한다.

## 1. 문제

### 1.1 소비 경로가 자율 lane 하나뿐이다

`stimuli_acked` 로 자극을 durable 하게 ack 하는 코드는 `lib/keeper/keeper_heartbeat_loop.ml` 에만 있다. 채팅 턴 경로(`Submit_operation`/`Submit_interactive_operation` → operation runner → `keeper_agent_run`)에는 자극 ack 가 없다.

### 1.2 그런데 채팅 턴은 자극을 본다

`lib/keeper/keeper_librarian_context_io.ml` 의 librarian 은 event queue 의 pending 자극과 chat pending 을 **둘 다** 컨텍스트에 넣는다. 그래서 채팅 턴의 모델은 pending schedule_due 를 읽고, 운영자가 "삼국지 이어가자" 라고 하면 그 자극이 요구하는 일을 그 턴에서 그대로 한다. 하지만 ack 경로가 없어 자극은 pending 그대로 남는다.

주의 두 가지:

- librarian 은 이 자극을 **읽기만** 한다. 같은 파일 주석: read-only SQLite 스냅샷이라 *"cannot chase a growing/reordered cursor, claim a row, or wait for the Owner mailbox."* 컨텍스트에 넣을 뿐 claim/ack 하지 않는다.
- 초안이 예시 맨 앞에 세웠던 `Connector_attention` 페이로드는 현재 **dormant** 다. 타입 주석: *"an ambient connector message... Dormant — no producer emits it yet."* 지금 실제로 event queue 에 쌓이는 건 board/schedule/workspace/hitl 류다.

### 1.3 lane 분리의 원래 근거는 성립하지만 반쪽이다

소비를 자율 lane 으로 제한한 이유는 하나다: **"ack = 처리했다" 인데, 잘못 ack 하면 일이 사라진다.** 운영자가 "지금 몇 시야" 라고 물은 턴이 "일일 리포트 올려" 자극을 조용히 ack 하면, 리포트는 영영 안 올라간다. 그래서 채팅은 답만, 자극 소비는 "큐의 일을 하는" 자율 턴만.

근거 자체는 옳다. 하지만 이 규칙은 **소비의 안전** 을 지키려고 **소비의 가능성** 을 lane 에 묶었다. 채팅이 실제로 자극을 다뤄도 소비가 안 된다. 채팅이 오래 이어지면 자율 턴이 슬롯을 못 잡아(RFC-0373 의 starvation) 자극이 무한정 안 빠진다. 안전 규칙이 정체를 낳는다. — **이 §1.3 이 이 문서가 열려던 실제 문제이고, 아래 §3 은 이 문서의 답이 왜 틀렸는지다.**

## 2. 통찰 (개정)

소비자는 lane 의 이름이 아니라 그 자극이 요구한 효과를 실제로 남긴 주체다 — 여기까지는 옳다. 하지만 이 통찰이 배선으로 이어지려면 **"실제로 남겼다" 를 그 자극에 귀속시켜 증명** 할 수 있어야 한다. 채팅 턴에서는 그 증명이 안 된다(§3.1). 자극을 소비할 자격이 있는 주체는 **그 자극에 의해 깬(admit 된) 턴** 이고, 그건 오늘 자율 턴이며 이미 완료 시 ack 한다(§3.3). 채팅 턴은 operator 메시지로 깨고 자극은 ambient 컨텍스트일 뿐이라, 채널-단위 증거로는 "이 자극을 처리했다" 를 주장할 수 없다.

## 3. 왜 채널-단위 접근이 unsound 한가

### 3.1 채팅 턴의 전달 증거는 채널 좌표뿐이다

`result.terminal_effect_receipt` 의 유일한 전달 증거는 `Surface_post_completed target` 이고, `target`(`Keeper_surface_post.delivery_target`)은 채널/스레드 좌표(`Delivered_to_discord {channel_id}` / `Delivered_to_slack {channel_id; thread_ts}`)만 담는다. `Keeper_surface_post.matches_continuation_route` 도 그 좌표가 대화 채널과 같은지만 본다. **어느 자극에 대한 답인지는 어디에도 없다.**

### 3.2 그래서 채널 매치 ack 는 over-attribution 이다

채널 C 로 답이 나갔다는 사실은 "C 로 라우팅된 pending 자극을 처리했다" 를 증명하지 않는다. 운영자가 C 에서 "몇 시야" 를 묻고 keeper 가 C 로 시간을 답하면, C 로 라우팅된 pending 자극("fusion 결과를 C 로 전달")까지 ack 된다 — fusion 결과는 한 번도 안 나갔는데. 자극은 사라지고 요구된 전달은 영영 안 일어난다. **이것이 이 문서가 없애려던 바로 그 silent loss 다.** pending 자극이 하나든 여럿이든 성립한다. bare post 하나가 무조건 만족시키는 유일한 자극 타입(ambient attention: "C 에 무슨 일이 있었다, 주목")은 현재 dormant 다(§1.2).

### 3.3 자율 ack 는 왜 sound 한가 (대조)

자율 턴은 자극에 의해 깨고, 그 admit 집합을 완료 시 ack 한다. 근거는 "이 턴이 이 자극들을 보고 행동을 골랐다"(admit = 이 턴의 존재 이유)이지 "각 자극을 개별로 전달했다" 가 아니다 — #34655 가 후자를 뗀 이유가 이것이다. 채팅 턴엔 그 admit 관계가 없다(operator-woken). 그래서 자율의 sound 함을 채팅이 그대로 빌릴 수 없다.

### 3.4 (이전 §3.3) 자율 ack 강화도 별개로 unsound

이전 초안의 §3.3(자율 ack 를 증거 기반으로 좁힘)은 #34655/#32277/#34662 를 되살린다. route-match 를 ack 에 걸면 "읽고 답 안 함" 이 wake 사유가 되어 재승격 폭풍이 된다(같은 디스코드 17행, 2026-09-08 3,711 소비 라인, 30분에 36턴, #34655; board 포스트 297회 재생, #32277). 답장 필수/ambient 를 durable·비-semantic 으로 구분할 신호가 없어(§4) 경계 안에서 불가.

### 3.5 sound 한 해결 후보 (별도 작업)

1. **stimulus-level 전달 증거.** surface post 가 "이 자극(occurrence/continuation id)을 처리했다" 를 durable 하게 참조하면, 채팅이든 자율이든 그 자극만 정확히 ack 할 수 있다. terminal_effect_receipt / 도구 배선 확장이 필요 — 별도 RFC.
2. **자율 consume starvation 을 직접 해소.** 이미 sound 한 consumer(자율)가 채팅 중에도 주기적으로 슬롯을 얻어 admit 배치를 consume 하게 한다. RFC-0373 스케줄 공정성 영역. guess-ack 없이 근본을 고친다.

## 4. 경계 (constitution — sound 후속이 지킬 것)

이 경계들은 §3 의 unsound 판정 근거이기도 하다.

- **Gate 아님.** 소비는 처리의 evidence 이지 스케줄링을 강제하는 Gate 가 아니다.
- **모델 자기 신고 금지. semantic matching 금지.** 소비를 모델의 말("했다")에 걸지 않는다. 답변 문장을 스캔해 "했다" 를 추정하지도 않는다. durable 효과에만 건다.
- **귀속되는 증거만.** 자극을 ack 하는 증거는 **그 자극에 귀속** 되어야 한다. 채널-단위 좌표는 귀속을 만족하지 못한다(§3.1). stimulus-level 증거(§3.5.1)나 자극-woken 턴의 admit 관계(§3.3)만 만족한다.
- **새 durable 상태 최소.** 필요한 곳에서만. admit 경계는 RFC-0377 의 pending_selections 그대로.
- **무거운 검증은 별도.** task/goal 형 자극의 "목표 달성 여부" 는 RFC-0444 의 goal verifier 경로.

## 5. 검증

이 문서는 채택되지 않으므로 구현 테스트는 없다. sound 후보(§3.5)를 진행할 때 만족해야 할 불변식:

> **어떤 자극도, 그 자극에 귀속되는 전달의 durable 증거 없이는 ack 되지 않는다.** 그리고 **어떤 턴도 자기 admit 집합 밖의 자극은 ack 하지 않는다.**

채널-단위 증거는 앞 절(귀속)을 만족하지 못한다(§3.1). stimulus-level 증거(§3.5.1) 또는 자극-woken admit 관계(§3.3)만 만족한다.

## 6. 관련

- RFC-0377 대화 배치 자극 intake — admit 집합의 출처.
- RFC-0373 턴 lane admission — 슬롯 하나를 세 lane 이 공유, 채팅이 자율을 굶기는 starvation(§3.5.2 의 무대).
- RFC-0303 stimulus-gated keeper wake — 자극이 wake 를 여는 규칙.
- #36213 발행 자기 클럭(B1, PR #36249 병합) — msx delivery=none 축적을 이미 1개로 묶은 축.
- #34655 / #32277 / #34662 — 자율 완료-시-ack 를 route-match 에서 뗀 이유(재승격 폭풍). §3.4 의 근거.
- 후속(별도 RFC 후보): §3.5 의 (1) stimulus-level 전달 증거, (2) 자율 consume starvation 직접 해소.
