---
rfc: "0376"
title: "자율턴의 최종 텍스트는 외부 발화가 아니다"
status: Draft
created: 2026-08-13
related: ["0232", "0315", "0358"]
---

# RFC-0376 — 자율턴의 최종 텍스트는 외부 발화가 아니다

## 1. 결정

자율턴(scheduled autonomous, HITL replay, connector attention wake)의 최종 텍스트는
keeper 의 사고 기록이며, 그 자체로 외부 채널 발화가 되지 않는다.

외부 발화는 keeper 가 발화 도구(`connector_post`, `keeper_board_post`)를 호출한
결과로만 채널에 도달한다. 턴이 텍스트로 끝났다는 사실은 발화 의도의 근거가 아니다.

이에 따라 다음 세 판정이 텍스트 유무에서 분리된다.

| 판정 | 현재 근거 | 변경 후 근거 |
|---|---|---|
| `Keeper_turn_outcome` | `response_text <> ""` | 자율턴은 `No_visible_reply`. 발화 도구 호출이 `Visible_reply` 를 만든다 |
| continuation delivery obligation 생성 | `Visible_reply` | 발화 도구가 생산한 payload |
| `is_noop_cycle` | `(not has_text) && tools_used = []` | substantive tool 부재. 텍스트는 보지 않는다 |

## 2. 증거

keeper `sangsu`, 2026-08-13 13:28–17:35 (4시간 07분), 모델
`ollama_cloud.deepseek-v4-flash`.

### 2.1 반복 실측

- `run_finished` 200턴 중 183턴(비어 있지 않은 184턴의 99%)이
  `무응답으로 끝낸다` 를 포함한다.
- 그중 140턴은 `새 근거 없으니 무응답으로 끝낸다.` 한 문장이 전부다.
- 텍스트 없이 끝난 턴은 16건이며, 모두 도구를 호출한 턴이다.

### 2.2 배달 실측

`~/.masc/keepers/sangsu/continuation_delivery_obligations_v1/` 의 obligation 19건
전수:

- 19건 전부가 사고 독백이다. "이 replay 는 이미 처리한 X 의 중복 결과다",
  "새 근거 없으니 무응답으로 끝낸다" 형태.
- 17건이 `state.kind = delivered` 이며 `connector_message_id` 를 가진다.
  즉 discord 채널로 실제 발송됐다.
- 사용자에게 유용했던 실제 답변(patchroom 페스티벌 상세 정보)은 이 목록에 **없다**.
  그것은 `connector_post` 도구 승인(`appr_a2071663`, `appr_63ede856`)을 거쳐
  별도 경로로 나갔다.

이 경로의 순기능 사례는 0건이고 독백 배달은 17건이다.

가장 직접적인 사례: 사용자가 "미안해 그만 좀 조용하거라" 라고 요청하자, keeper 는
`"조용히 하라는 요청이니, 추가 반응 없이 무응답으로 끝낸다."` 를 생성했고 이 문장이
obligation `kdelivery-34d18e16…` 으로 discord 에 발송됐다
(`connector_message_id = 1537387311699075102`). 침묵 선언이 발화가 됐다.

### 2.3 백오프 무력화 실측

`keeper_composite_observer.mli:302-306` 은 `consecutive_noop_count ≥ 2` 에서 noop
백오프를 4x 로 제한한다고 규정한다. `is_noop_cycle` 이 텍스트 유무로 판정하므로
독백 한 줄이 매 턴 카운터를 0으로 되돌린다.

`sangsu.json` 실측: `noop_turn_count = 0`, `total_turns = 28269`. 이 keeper 의
전 생애에서 백오프가 한 번도 발동하지 않았다.

## 3. 왜 이 구조가 됐는가

이 절은 되돌리기의 근거를 남기기 위한 기록이다.

1. 과거 프롬프트에는 `SPEECH_ACT: stay_silent` 선언이 있었다. 구조적 작업이 없는
   자율턴은 이 선언으로 침묵을 표명했다. 현재 트리에는 이 증거가 남아 있지 않다 —
   `config/prompts/keeper.core_behavior.md` 와
   `test/test_keeper_no_signal_silence.ml` 둘 다 삭제됐다. 근거는 커밋
   `5c619375f2` 의 diff 에서 제거된 주석 라인이며, 그 주석이
   `config/prompts/keeper.core_behavior.md:4` 를 인용하고 있었다.
2. RFC-0276 Phase 2b(#22052)가 social model self-report protocol 을 purge 했다.
   문자열 프로토콜 제거 자체는 정당하다 — `SPEECH_ACT:` 접두는 string-classifier
   안티패턴이다. 그러나 침묵을 표현할 대체 수단이 배선되지 않았다.
3. PR #22340(2026-06-26)이 프롬프트를 뒤집었다. PR body 의 근거는
   `"finalization requires visible text or tool progress"` 였다 — 즉 침묵하면
   `lib/keeper_tooling/response.ml:12` 의
   `"keeper turn completed with no textual reply"` 로 턴이 실패했다. 런타임 제약을
   고치는 대신 프롬프트를 `"give a short no-work report"` 로 바꿨다.
4. 그 프롬프트 문구와 가드 테스트(`test_prompt_no_silent_reply_contract.ml`)는
   이후 정리되어 현재 트리에 없다. 그러나 §1 의 세 판정은 그대로 남았다.

현재 트리에서 반복을 지시하는 프롬프트 문구는 없다. raw-trace 200턴에
`no textual reply` 실패도 0건이다. 남은 것은 "모델이 사고를 텍스트로 쓰면 그것이
외부 발화가 된다"는 계약 공백뿐이다.

## 4. 설계

### 4.1 발화는 도구가 소유한다

`Keeper_continuation_delivery_intent.create` 는 턴 최종 텍스트를 받지 않는다.
obligation 은 발화 도구가 생산한 payload 로만 생성된다. 발화 도구를 호출하지 않은
자율턴은 obligation 을 만들지 않으며, 이는 실패가 아니라 정상 종료다.

`origin_of_payload` 가 부여하는 continuation source 식별과 채널 라우팅은 그대로
유지한다. 바뀌는 것은 배달 내용의 출처뿐이다.

### 4.2 자율턴의 turn outcome

`Keeper_turn_outcome.of_result_surface` 는 `turn_kind` 를 받는다. `Autonomous` 턴의
`Completed` 는 발화 도구 호출 없이는 `No_visible_reply` 다. `Direct` 턴의 판정은
바꾸지 않는다 — 사용자가 직접 물은 턴에서 최종 텍스트가 답변인 계약은 유지된다.

`turn_kind` 는 RFC-0358 이 이미 `Turn_record.t` 의 필수 필드로 소유하고 있으므로
새 상태를 만들지 않는다.

### 4.3 침묵은 실패가 아니다

`Keeper_tooling.Response.normalize_response_text` 의
`| [] -> Error "keeper turn completed with no textual reply"` 를 제거한다.
텍스트도 도구도 없는 자율턴은 정상 종료한다.

`Direct` 턴에서 모델이 아무 산출도 내지 못한 경우는 별개 사실이며, 그 실패는
`Response_shape` 의 `No_usable_progress` 가 이미 typed 로 소유한다. 텍스트 길이가
그 판정을 대신하지 않는다.

### 4.4 noop 판정

`is_noop_cycle` 은 substantive tool 부재만 본다. 텍스트 유무를 보지 않는다.
이로써 `consecutive_noop_count` 가 실제 무작업 사이클을 세고 백오프가 발동한다.

## 5. 비목표

- 문자열 프로토콜(`SPEECH_ACT:` 계열) 복원. §3.2 가 purge 한 안티패턴을 되살리지
  않는다.
- 반복 문구 탐지, 유사도 억제, 발화 rate cap. 증상 억제이며 CLAUDE.md 워크어라운드
  거부 기준에 해당한다.
- 스케줄러 깨우기 빈도 변경. 이 RFC 는 깨어난 턴이 무엇을 밖으로 내보내는지만
  다룬다.
- `Direct` 턴 발화 계약 변경.

## 6. 검증 계약

- 발화 도구를 호출하지 않은 자율턴은 obligation 을 생성하지 않는다.
- 발화 도구를 호출한 자율턴은 그 도구 payload 로 obligation 을 생성하고, 최종
  텍스트는 obligation 에 등장하지 않는다.
- 텍스트도 도구도 없는 자율턴이 `Error` 없이 종료한다.
- 텍스트만 있고 substantive tool 이 없는 자율턴에서 `consecutive_noop_count` 가
  증가한다.
- `Direct` 턴은 최종 텍스트로 계속 응답한다 (회귀 방지).
- §2.2 의 obligation 19건을 재생하면 0건이 생성된다.

## 7. 롤아웃

단일 PR 로 §4.1–4.4 를 함께 반영한다. 넷 중 일부만 반영하면 판정 근거가 갈려
분기가 늘어난다. 4.2 만 적용하면 obligation 은 막히지만 백오프는 여전히 죽어 있고,
4.4 만 적용하면 discord 배달이 계속된다.

되돌리기는 §3 의 4단계 기록을 근거로 판단한다. 침묵을 다시 금지해야 한다면 그 근거는
프롬프트가 아니라 finalization 계약에 남겨야 한다.
