---
rfc: "0376"
title: "출력 목적지는 Keeper 가 판단한다"
status: Draft
created: 2026-08-13
related: ["0315", "0358"]
---

# RFC-0376 — 출력 목적지는 Keeper 가 판단한다

## 1. 결정

Keeper 는 자기 출력을 board 에 놓을지, discord 채널에 놓을지, dashboard 에 놓을지
판단한다. 그 판단은 발화 도구 호출로 표현된다.

자율턴의 최종 텍스트는 목적지를 갖지 않는다. turn record 와 raw trace 에 남는 사고
기록이며 어떤 채널로도 자동 발송되지 않는다.

`Keeper_continuation_delivery_intent` 와 그 배달 경로를 삭제한다. 이 경로는 최종
텍스트를 "턴을 유발한 source" 로 되돌려 보내며, 그 목적지 결정이 Keeper 를 거치지
않는다.

Direct 턴(dashboard chat)의 응답 계약은 바꾸지 않는다. §4.3 이 그 보존 수단을
명시한다.

## 2. 증거

### 2.0 측정 조건

`<base-path>/.masc/keepers/<name>/raw-traces/` 는 최근 200개만 유지하는 롤링
윈도우다 (RFC-0358 §3). 아래 턴 수치는 2026-08-13 17:35 시점 스냅샷이며 재측정하면
윈도우가 이동해 다른 값이 나온다. obligation 디렉터리는 롤링이 아니지만 라이브
데이터이므로 측정 이후 증가할 수 있다.

측정 대상 200턴의 모델 분포는 단일하지 않다.

| 모델 | 턴 |
|---|---|
| `glm-coding.glm-5-turbo` | 120 |
| `ollama_cloud.deepseek-v4-flash` | 75 |
| `ollama-cloud-deepseek-v4-flash-0731` | 5 |

같은 형태가 세 모델에 걸쳐 나온다. 이 문서가 다루는 것은 모델 특성이 아니라 시스템
계약이다.

### 2.1 배달 실측

keeper `sangsu` 의 obligation 19건 전수:

| 항목 | 값 |
|---|---|
| obligation 총계 | 19 |
| 사고 기록이 배달된 건 | 19 |
| `state=delivered` + non-null `connector_message_id` | 17 |
| Keeper 가 목적지를 판단한 건 | 0 |

사용자에게 실제로 유용했던 답변(patchroom 페스티벌 상세 정보)은 이 목록에 없다.
Keeper 가 `connector_post` 도구로 목적지를 정해 보냈다. obligation 중 patchroom 을
언급하는 12건은 전부 "이미 답변을 보냈다" 는 메타 코멘트다.

즉 Keeper 는 이미 구분하고 있었다 — **말할 때는 도구를 썼고, 생각할 때는 텍스트로
썼다.**

### 2.2 단일 keeper 현상이 아니다

obligation 을 가진 keeper 전수 (측정 시점 42건):

| keeper | obligation | non-null `connector_message_id` | 커넥터 |
|---|---|---|---|
| sangsu | 19 | 17 | discord |
| kidsnote | 10 | 2 | slack |
| rtprobe | 8 | 0 | dashboard |
| analyst | 3 | 0 | dashboard |
| rondo | 2 | 0 | dashboard |

본문을 확인한 38건이 전부 사고 기록이다. 커넥터 종류와 무관하다.

- kidsnote: `"이미 처리한 Vincent의 Slack 메시지입니다. 새 요청 없음. 게시 없이
  종료합니다."`
- rondo: `"Memory write confirmed. 상태 불변 — 말할 것 없음."`

"게시 없이 종료합니다" 와 "말할 것 없음" 이 게시됐다.

source family 분포는 `hitl_resolution` 과 `connector_attention` 뿐이다.
`fusion_completion` 과 `schedule_occurrence` 는 0건 — §4.2 가 이 공백을 다룬다.

### 2.3 목적지 판단 부재의 결과

사용자가 discord 에서 "미안해 그만 좀 조용하거라" 라고 요청했다. Keeper 는
`"조용히 하라는 요청이니, 추가 반응 없이 무응답으로 끝낸다."` 를 생성했고, 이 문장이
obligation `kdelivery-34d18e16…` 으로 같은 채널에 발송됐다
(`connector_message_id = 1537387311699075102`). Keeper 가 내린 결론과 배달 경로가
실행한 동작이 정반대다.

### 2.4 반복

측정 시점 200턴 중 비어 있지 않은 턴의 약 99% 가 같은 결론을 재진술했고, 그중 약
70% 는 `새 근거 없으니 무응답으로 끝낸다.` 한 문장이 전부였다. §2.0 의 롤링 윈도우
때문에 정확한 절대값은 재현되지 않는다.

Keeper 의 기억은 작동한다 — 매 턴 "이미 처리했다" 를 정확히 식별한다. 실패한 것은 그
앎이 **말하지 않을 근거**가 아니라 **말할 내용**이 된 지점이다.

## 3. 계약이 이미 인정하는 것

`lib/keeper/keeper_unified_turn.ml:1160-1174` 는 Keeper 의 목적지 판단을 이미 1급으로
다룬다.

```ocaml
| Some origin, None, External_effect_completed, Completed,
  Some (Surface_post_completed target)
  when Keeper_surface_post.matches_continuation_route target origin.channel ->
    Continuation_delivery_settled_by_terminal_surface_post
| Some _, None, _, Completed, _ ->
    Continuation_delivery_quarantined
      { detail = "routable continuation completed without a visible delivery intent" }
```

첫 arm 은 Keeper 가 발화 도구로 origin 채널에 게시했으면 그것으로 배달이 종결됐다고
판정한다. 채널 일치까지 `matches_continuation_route` 로 확인한다.

즉 **"발화 도구 호출 = 목적지 판단"** 은 새로 만들 계약이 아니라 이미 있는 계약이다.
obligation 경로는 그 위에 덧붙은 두 번째 경로이며, 최종 텍스트를 근거로 삼는다.

`Keeper_turn_outcome.of_result_surface` (`lib/keeper/keeper_turn_outcome.ml:55-57`):

```ocaml
| Runtime_agent.Completed ->
    if String.trim response_text = "" then No_visible_reply else Visible_reply
```

빈 문자열 비교가 두 번째 경로의 판정자다. 목적지는 Keeper 가 아는 사실이고 문자열
길이는 그 사실을 알지 못한다.

## 4. 설계

### 4.1 삭제 대상

모듈과 그 전용 테스트:

- `lib/keeper_runtime/keeper_continuation_delivery_intent.ml{,i}`
- `lib/keeper/keeper_continuation_delivery_store.ml{,i}`
- `lib/keeper/keeper_continuation_delivery_publisher.ml{,i}`
- `lib/keeper/keeper_continuation_delivery_recovery.ml{,i}`
- `test/keeper_continuation_delivery_{intent,store,publisher}/`

참조를 걷어내야 하는 소비자:

- `lib/keeper/keeper_agent_result.ml{,i}` — `run_result` 필드와 빌더
- `lib/keeper/keeper_unified_turn.ml{,i}` — §4.4
- `lib/keeper/keeper_unified_turn_execution.ml`
- `lib/keeper/keeper_heartbeat_loop.ml{,i}` — §4.4
- `lib/keeper/keeper_heartbeat_loop_cycle.ml{,i}`
- `lib/keeper/keeper_execution_outcome.ml{,i}`
- `lib/keeper/keeper_terminal_effect_policy.ml`
- `lib/keeper/keeper_agent_run.ml{,i}`
- `lib/keeper/keeper_agent_run_finalize_response.ml`
- `lib/server/server_bootstrap_loops.ml{,i}`
- `lib/server/server_dashboard_schedule_projection.ml` — §4.5
- `test/test_schedule_consumer_dispatch.ml`,
  `test/test_keeper_terminal_reason_typed.ml`
- `dashboard/src/api/dashboard-tools-prompts.ts`,
  `dashboard/src/components/tools/scheduled-automation-panel.{ts,test.ts}`

후속 절단(별도 PR): `Keeper_chat_delivery_identity.delivery_key` 의
`Continuation` kind. 생산자는 이 RFC 로 사라지지만 기존 chat 행의 decode 어휘로
남아 있어, 행 decode 정책과 기존 데이터 정리를 함께 다뤄야 한다.

### 4.2 실측이 없는 두 source family

`origin_of_payload` 의 4개 family 중 `Schedule_occurrence` 와 `Fusion_completion` 은
obligation 실측이 0건이다. 이 둘에 대해서는 "오늘 이 경로에 얼마나 의존하는가" 를
모른다.

그럼에도 같은 결정에 묶는 근거:

1. 배달 **내용**은 4개 family 모두 턴 최종 텍스트로 동일하다. 목적지가 요청 시점에
   고정된 경우(mli 가 규정하는 "explicit result destination")에도 사고 기록을 보내는
   문제는 같다.
2. §3 의 `Settled_by_terminal_surface_post` arm 이 네 family 모두에 적용되므로, Keeper
   가 발화 도구로 지정 채널에 보내는 경로는 삭제 후에도 살아 있다.

예약·fusion 결과를 지정 목적지로 보내는 요구가 확인되면, 목적지를 Keeper 의 턴
입력으로 전달하고 Keeper 가 발화 도구로 보내는 방식으로 구현한다. 시스템이 최종
텍스트를 대신 보내는 방식으로 되돌리지 않는다.

### 4.3 attention ledger 는 route 사실을 소비한다

`Turn_completed` 는 `continuation_route_disposition` 을 나른다 — 완료된 turn 의
terminal surface post 가 자신을 깨운 채널과 route 일치하면 `addressed`, 아니면
`not_addressed`. unified turn 이 receipt 와 wake payload 채널로 계산하는 typed
사실이며, connector-attention ledger 가 addressed 를 resolved 로, not_addressed 를
ignored 로 마킹한다. 삭제된 completion 타입이 하던 일 중 살아남는 것은 이
사실뿐이다.

`of_result_surface` 는 손대지 않는다. dashboard chat 의 응답 판정은 이 RFC 이전과
동일하다.

### 4.4 stimulus 계약

배달 성공이 아니라 turn 완료가 stimulus 를 acknowledge 한다. disposition
타입(`Acknowledge/Defer/Retain/Quarantine`)과 두 quarantine 지점 — unified turn 의
"visible delivery intent 없음" arm, heartbeat 의 "durable obligation 없음" 분기 —
은 근거가 사라지므로 함께 삭제된다. 말하지 않기로 한 turn 은 정상 완료다. turn
자체가 실패하면 stimulus 는 기존 실패 경로대로 큐에 남는다.

turn 이 도구 셋업에서 받는 reply 채널은 wake payload 가 직접 명명한다
(`Keeper_event_queue.continuation_channel_of_payload`). origin 타입을 경유하던
파생이 사라질 뿐 도구가 보는 값은 같다.

### 4.5 schedule 배달 상태 대시보드 뷰

`masc.dashboard.schedule_result_delivery.v1` 는 obligation state 를 대시보드에
노출한다. §4.1 이 데이터 소스를 없애므로 서버 projection 과 dashboard 컴포넌트
(카드, 타입, 픽스처)를 함께 폐기한다. dispatch receipt 의
`result_delivery_policy` 행은 schedule 도메인이므로 남는다.

근거: `schedule_occurrence` obligation 실측 0건이므로 이 뷰가 현재 표시하는 배달
상태가 없다. 예약 결과 관측이 필요해지면 turn record 기반으로 다시 만든다 — 그때는
Keeper 가 발화 도구로 보낸 사실이 관측 대상이다.

## 5. 비목표

- 반복 억제 장치. 문구 탐지, 유사도 비교, 발화 rate cap, noop 백오프 강화. 턴이
  계속 도는 것은 이 제품의 성공 조건이지 억제 대상이 아니다.
- 침묵 강제. Keeper 가 말할지 말지는 Keeper 가 정한다.
- `Direct` 턴 응답 계약 변경.
- 스케줄러 깨우기 빈도 변경.

## 6. 검증 계약

기능 단위로 검증한다.

- 사용자가 dashboard chat 에서 물으면 Keeper 의 답변이 그대로 표시된다 (§4.3 회귀
  방지).
- Keeper 가 `connector_post` 로 discord 에 답하면 그 내용이 해당 채널에 도달한다.
- Keeper 가 `keeper_board_post` 로 board 에 올리면 board 에만 나타난다.
- 자율턴이 발화 도구 없이 끝나면 어떤 채널에도 메시지가 나타나지 않고, 그 턴은 실패로
  기록되지 않으며, stimulus 는 acknowledge 된다 (§4.4).
- 턴 자체가 실패하면 stimulus 는 큐에 남는다.
- HITL 승인 해소 후 이어지는 턴에서 Keeper 가 발화 도구를 쓰지 않으면 원래 채널에
  아무것도 발송되지 않는다.

검증은 실제 discord 채널과 dashboard 에서 수행하고 로그와 스크린샷을 증거로 남긴다.
