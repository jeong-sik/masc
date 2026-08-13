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
판단한다. 그 판단은 발화 도구 호출로 표현된다 — `keeper_board_post`,
`connector_post`.

턴의 최종 텍스트는 목적지를 갖지 않는다. 그것은 turn record 와 raw trace 에 남는
사고 기록이며, 어떤 채널로도 자동 발송되지 않는다.

`Keeper_continuation_delivery_intent` 와 그 배달 경로를 삭제한다. 이 모듈은 최종
텍스트를 "턴을 유발한 source" 로 되돌려 보내는데, 그 목적지 결정이 Keeper 를
거치지 않는다.

## 2. 증거

측정일 2026-08-13. §2.1 과 §2.4 는 keeper `sangsu` (13:28–17:35, 4시간 07분, 모델
`ollama_cloud.deepseek-v4-flash`), §2.2 는 obligation 을 가진 keeper 전수다.

### 2.1 배달 실측

`<base-path>/.masc/keepers/sangsu/continuation_delivery_obligations_v1/` 의
obligation 19건 전수:

| 항목 | 값 |
|---|---|
| obligation 총계 | 19 |
| 사고 기록이 배달된 건 | 19 (100%) |
| `state=delivered` + `connector_message_id` | 17 |
| Keeper 가 목적지를 판단한 건 | 0 |

배달된 내용은 전부 "이 replay 는 이미 처리한 X 의 중복 결과다", "새 근거 없으니
무응답으로 끝낸다" 형태다.

사용자에게 실제로 유용했던 답변(patchroom 페스티벌 상세 정보)은 이 목록에 **없다**.
그것은 Keeper 가 `connector_post` 도구로 목적지를 정해 보냈다
(`appr_a2071663`, `appr_63ede856`).

즉 Keeper 는 이미 두 가지를 구분해서 하고 있었다 — **말할 때는 도구를 썼고, 생각할
때는 텍스트로 썼다.** 배달 경로가 그 구분을 무시하고 사고 기록만 골라 발송했다.

### 2.2 단일 keeper 현상이 아니다

obligation 을 가진 keeper 전수 (42건):

| keeper | obligation | `connector_message_id` 보유 | 커넥터 |
|---|---|---|---|
| sangsu | 19 | 17 | discord |
| kidsnote | 10 | 2 | slack |
| rtprobe | 8 | 0 | dashboard |
| analyst | 3 | 0 | dashboard |
| rondo | 2 | 0 | dashboard |

42건 중 38건의 본문을 확인했고 전부 사고 기록이었다. 목적지를 판단해 작성한 발화는
한 건도 없다. 커넥터 종류와 무관하게 같은 형태가 나온다.

- kidsnote: `"이미 처리한 Vincent의 Slack 메시지입니다. 새 요청 없음. 게시 없이
  종료합니다."`
- rondo: `"Memory write confirmed. 상태 불변 — 말할 것 없음."`
- analyst: `"중복 wake(appr_10736fa7 …)는 이미 읽어 evidence 에 반영 완료"`

"게시 없이 종료합니다" 와 "말할 것 없음" 이 게시 대상이 됐다. Keeper 가 내린 결론과
배달 경로가 실행한 동작이 정반대다.

### 2.3 목적지 판단 부재의 결과

사용자가 discord 에서 "미안해 그만 좀 조용하거라" 라고 요청했다. Keeper 는
`"조용히 하라는 요청이니, 추가 반응 없이 무응답으로 끝낸다."` 를 생성했고, 이 문장이
obligation `kdelivery-34d18e16…` 으로 같은 채널에 발송됐다
(`connector_message_id = 1537387311699075102`). Keeper 는 침묵을 결정했는데 배달
경로가 그 결정을 채널에 실어 보냈다.

### 2.4 반복 실측

`run_finished` 200턴 중 183턴(비어 있지 않은 184턴의 99%)이 같은 결론을 재진술했다.
그중 140턴은 `새 근거 없으니 무응답으로 끝낸다.` 한 문장이 전부다.

Keeper 의 기억은 작동하고 있다 — 매 턴 "이미 처리했다" 를 정확히 식별한다. 실패한
것은 그 앎이 **말하지 않을 근거**가 아니라 **말할 내용**이 된 지점이다.

## 3. 왜 사고 기록이 발화가 되는가

`Keeper_turn_outcome.of_result_surface` (`lib/keeper/keeper_turn_outcome.ml:55-57`):

```ocaml
| Runtime_agent.Completed ->
    if String.trim response_text = "" then No_visible_reply else Visible_reply
```

빈 문자열 비교가 목적지 판단을 대신한다. 텍스트가 비어 있지 않다는 사실 하나로
`Visible_reply` 가 되고, `keeper_agent_result.ml:115` 가 그 값을 보고 obligation 을
만든다.

목적지는 Keeper 가 아는 사실이다. 문자열 길이는 그 사실을 알지 못한다.

## 4. 설계

### 4.1 삭제

- `lib/keeper_runtime/keeper_continuation_delivery_intent.ml{,i}`
- `lib/keeper/keeper_agent_result.ml` 의 `continuation_delivery_intent_for_result`
  와 그 호출 경로
- obligation 저장 디렉터리와 그 reader/writer
- 위 경로에만 존재하던 테스트

RFC-0358 이 이미 turn record 와 raw trace 를 read-only dashboard projection 으로
소유한다. 사고 기록의 보존과 관측은 그쪽이 담당하므로 배달 경로가 없어져도 잃는
관측성은 없다.

### 4.2 turn outcome

`of_result_surface` 의 `response_text` 인자를 제거한다. `Completed` 는
`No_visible_reply` 다. 발화는 도구가 소유하므로 최종 텍스트에서 발화 여부를 읽지
않는다.

`Direct` 턴(dashboard chat, 사용자가 직접 물은 턴)의 응답 경로는 이 RFC 범위 밖이며
변경하지 않는다.

## 5. 비목표

- 반복 억제 장치. 문구 탐지, 유사도 비교, 발화 rate cap, noop 백오프 강화. 턴이
  계속 도는 것은 이 제품의 성공 조건이지 억제 대상이 아니다.
- 침묵 강제. Keeper 가 말할지 말지는 Keeper 가 정한다.
- 새 게이트나 제약 추가. 이 RFC 는 목적지 판단권을 Keeper 에게 돌려줄 뿐이다.
- `Direct` 턴 응답 계약 변경.

## 6. 검증 계약

기능 단위로 검증한다.

- Keeper 가 `connector_post` 로 discord 에 답하면 그 내용이 해당 채널에 도달한다.
- Keeper 가 `keeper_board_post` 로 board 에 올리면 board 에만 나타난다.
- Keeper 가 발화 도구를 쓰지 않고 턴을 끝내면 어떤 채널에도 메시지가 나타나지
  않으며, 그 턴의 사고 기록은 dashboard turn record 에서 읽을 수 있다.
- HITL 승인이 해소된 뒤 이어지는 턴에서 Keeper 가 발화 도구를 쓰지 않으면 원래
  채널에 아무것도 발송되지 않는다.
- §2.1 의 19건을 재생하면 0건이 발송된다.

검증은 실제 discord 채널과 dashboard 에서 수행하고 로그와 스크린샷을 증거로 남긴다.
