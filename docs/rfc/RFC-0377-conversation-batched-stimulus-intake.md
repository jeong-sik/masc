---
rfc: "0377"
status: Draft
---

# RFC-0377 — 같은 대화의 밀린 메시지는 한 턴이 함께 본다 (Conversation-Batched Stimulus Intake)

- Status: Draft
- Depends on: RFC-0376 (출력 목적지는 Keeper 가 판단한다)
- Scope: ambient lane (`Connector_attention` stimulus intake). Mention(triggered) lane 은 비범위.

## 1. 문제 (실측)

sangsu 라이브 데이터 (2026-08-08 ~ 08-13, `keepers/sangsu/` 기준):

- 배달된 continuation obligation 48건 전수가 **서로 다른 단일 inbound message 에 1:1 바인딩**. 연속 turn id 28308→28336 이 snowflake 오름차순 inbound 를 하나씩 소비 — 관찰된 "위에서부터 하나씩 답장"의 구조적 원인.
- inbound 메시지 발생 → 답장 배달 지연이 438s → 4,461s 로 단조 증가 (48건 중앙값 1,533s). 단건 드레인이 라이브 채널 유입 속도를 따라가지 못하는 시그니처.
- 사용자 체감: 밀린 대화 5개에 5턴에 걸쳐 순서대로 5개의 답장이 도착. 앞선 답장이 만들어지는 동안 대화 맥락은 이미 흘러가 있음.

## 2. 원인 (코드)

한 턴은 구조적으로 stimulus 하나만 본다:

| 지점 | 동작 |
|---|---|
| `lib/server/server_discord_in_process_gateway.ml` (`handle_ambient`) | inbound 메시지 1건 = `Connector_attention { event_id; channel(reply_to_message_id 포함) }` 1건 enqueue |
| `lib/keeper/keeper_heartbeat_stimulus_intake.ml` (`consume_single_heartbeat_stimulus`) | RFC-0020 §3 Rule 4: 턴당 Event Layer stimulus **최대 1건** admit |
| `lib/keeper_runtime/keeper_event_queue.ml` (`is_board_signal`) | board signal 은 `drain_board_all` 로 배치 드레인이 **이미 존재**하나 `Connector_attention` 은 제외 |

즉 board 자극에는 이미 "쌓인 것을 한 턴이 함께 본다"는 선례가 있고, connector 자극만 단건 규칙에 남아 있다.

## 3. 설계

**Claim 시점 대화 단위 드레인.** intake 가 `Connector_attention` 을 선택하면, 같은 conversation
(동일 connector channel 좌표)의 pending `Connector_attention` 전부를 그 턴에 함께 admit 한다.

- 배치의 경계는 **claim 시각에 pending 인 것 전부**다. debounce window, 최대 개수, 대기 타이머 등
  숫자 기반 장치는 두지 않는다 (배치 크기는 유입/드레인 속도의 사실적 결과이지 제어 대상이 아니다).
- 턴 컨텍스트에는 배치 전 건이 도착 순서대로 투영된다. Keeper 는 전체를 보고 하나의 응답으로 묶을지,
  개별로 응답할지, 무응답으로 넘길지 **스스로 판단**한다 (RFC-0376: 발화는 `connector_post` 도구로만).
  reply 대상 message 선택도 Keeper 판단이다 — intake 는 사실 투영만 하고 행동을 강제하지 않는다.
- 다른 conversation 의 stimulus 는 배치에 포함하지 않는다 (턴당 대화 하나 유지).
- ack 은 RFC-0376 과 동일하게 **턴 완료 = 배치 전 건 ack**. 턴 실패 시 전 건이 기존 실패 경로대로 큐에 남는다.
- 참조 선례: 이 harness 자체 — Claude Code 는 턴 진행 중 도착한 사용자 메시지를 다음 턴 컨텍스트에
  묶어서 투영하고, 응답 방식은 모델이 판단한다.

## 4. 비범위

- Mention(triggered) lane 의 `Chat_operation_store.claim_next` (`LIMIT 1`) 배칭. mention 1건당 답장
  1건은 그 자체로 결함이 아니다. 라이브 증거가 생기면 별도 RFC.
- Cross-conversation 배칭, board/schedule/fusion 등 다른 stimulus 종류 (board 는 이미 자체 드레인 보유).
- 응답 텍스트의 자동 병합·요약 — 응답 형태는 전적으로 Keeper 판단.

## 5. 검증

1. Feature test: 채널 A 에 5건 + 채널 B 에 2건 enqueue → intake 1회 → 턴 컨텍스트에 A 의 5건 전부
   (도착순), B 의 2건은 큐 잔류 → 턴 완료 시 A 5건 전부 ack, B 2건 잔류.
2. 턴 실패 경로: 배치 admit 후 턴 실패 → 5건 전부 큐 잔류 (부분 ack 없음).
3. 라이브 재측정: sangsu 백로그 시나리오에서 inbound→응답 지연 중앙값과 턴당 소비 stimulus 수를
   before/after 로 기록해 PR 에 첨부.
