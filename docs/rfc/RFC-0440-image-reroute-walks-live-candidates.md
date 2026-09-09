---
rfc: "0440"
title: 이미지 턴의 reroute 는 살아 있는 후보를 걷는다 — lane 과 media_failover 를 한 집합으로, 402·429 후보는 이번 걸음에서 뒤로
status: Draft
created: 2026-09-09
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0414", "keeper-vision-delegation-tool", "0265"]
---

## 0. 한 줄 요약

이미지가 실린 턴은 지금 "lane 안에서 이미지를 받는 첫 후보" 하나를 고르고, 그 후보가 죽어 있어도 다음 턴에 또 고른다. 후보 집합을 lane 과 `media_failover` 의 합집합으로 만들고, 402·429·quota 로 끝난 후보는 같은 걸음에서 뒤로 보내며, 살아 있는 후보가 없으면 이미지를 떨구지 않고 위임(`keeper_analyze_image` 경로)으로 내려간다.

## 1. 측정 (2026-09-09, `<base-path>/.masc`)

채팅 요청 12건 전부를 `keeper_chat_events/*/tui-*.jsonl` 로 재었다.

| 키퍼 | 결과 |
|---|---|
| msx-retro-mania (glm-coding.glm-5.3 lane, MSX 화면 이미지 동반) | 5건 중 4건 `Payment required: Insufficient Balance`, 1건 rate limit. 첫 provider 응답까지 3~6초 만에 죽음 |
| goo-yang-bong, rondo (텍스트) | 정상. 첫 글자까지 23~73초, 도구 17회 턴은 3분 이상 |

같은 날 시스템 로그:

- deepseek 402 `Insufficient Balance` 141회(00:24Z 시작), deepseek 성공 턴 0회.
- ollama_cloud 429 240회(주간 한도).
- msx-retro-mania 한 요청(03:07:13Z)의 시도 순서: `deepseek.deepseek-v4-flash-vision-exp` 402 → `openai-responses.gpt-5.6-luna` `insufficient_quota` → 다시 `deepseek-v4-flash-vision-exp` 402 → 종료. 8순위 `glm-coding.glm-4.6v` 와 이미지를 받는 `claude_code.*` 는 한 번도 시도되지 않았다.

## 2. 지금 구조 — 세 가지 사실

1. **reroute 후보는 lane 후보뿐이다.** `keeper_turn_driver.ml` 의 `lane_modality_reroute_decision ~first_candidate ~remaining_runtimes` 는 그 키퍼 lane 의 나머지 후보만 넘긴다. `runtime_agent.ml:782` 주석은 "media_failover order, then declaration order" 라고 적었지만 드라이버는 그렇게 부르지 않는다. runtime.toml 의 glm-5.3 lane 주석(2026-09-06)이 이 사실을 알고 vision 모델을 lane 2순위에 끼워 넣었다.
2. **선택은 순수하고 liveness 를 모른다.** `Runtime_agent.decide_modality_reroute` 는 `List.find_opt` 로 "이미지를 받는다고 선언한 첫 후보" 를 고른다. 주석 그대로 "no provider liveness (deferred to RFC-0260)". 직전 턴의 402 는 다음 턴의 선택에 아무 영향이 없다.
3. **도구 경로는 다르게 걷는다.** `keeper_vision_tool.vision_runtime_candidates` 는 `media_failover` 를 먼저, 나머지 런타임을 뒤에 세우고 `Runtime_attempt_fsm.should_try_next` 로 후보를 넘어간다. 그리고 `Keeper_vision_ingest.delegates_media` 는 lane 에 이미지를 받는 후보가 하나라도 있으면 위임하지 않는다 — 그 후보가 죽어 있어도.

세 사실이 합쳐지면: lane 에 죽은 vision 후보 하나가 있는 키퍼는 위임도 못 받고(3), 그 후보만 고르고(1·2), 실패하면 lane 의 텍스트 failover(luna)로 튀었다가 같은 후보로 돌아온다.

## 3. 판단

- 후보 집합은 한 곳이 답한다. "키퍼 K 의 이미지 후보" 는 lane 의 이미지 후보 → `media_failover` → 나머지 선언 런타임 중 이미지를 받는 것(선언 순서)을 이어 붙이고 중복을 뺀 목록이다. 지금 `keeper_vision_tool` 이 쓰는 꼬리(선언 순서)를 그대로 포함하므로 도구 경로가 잃는 후보는 없고, reroute 는 lane 밖 후보를 얻는다. 두 경로가 같은 함수를 부른다.
- reroute 는 걸음이다. 후보가 402·429·`insufficient_quota` 같은 `should_try_next` 오류로 끝나면 같은 걸음에서 다음 이미지 후보로 간다. 같은 턴에서 같은 후보를 다시 방문하지 않는다. lane 의 텍스트 failover 는 이미지를 받지 못하는 후보라 이 걸음에 끼지 않는다.
- 바닥은 위임이다. 살아 있는 이미지 후보가 없으면 `No_capable_runtime` 으로 이미지를 떨구는 대신 `Keeper_vision_ingest` 의 eager read 로 내려간다. 읽기 결과가 텍스트로 들어가므로 키퍼의 lane 은 그대로다.
- `delegates_media` 는 "이미지를 받는 후보가 있나" 가 아니라 "살아 있는 이미지 후보가 있나" 를 본다. 이번 턴의 걸음 결과가 그 답이다.
- 새 상수·임계값·카운터는 없다. 후보 집합과 걸음 규칙만 바뀐다.

## 4. 하지 않는 것

- provider 잔고 감시·알림. 잔고가 비었다는 사실은 402 로 이미 온다.
- lane 의 텍스트 failover 순서. 이 RFC 는 이미지 턴만 다룬다.
- `multimodal_policy` 축의 부활. RFC-keeper-vision-delegation-tool §2.4 가 2026-08-25 에 접은 이유 그대로.
- `media_failover` 이름 변경. 문서에서 "이미지 후보 순서" 로 부르고 키는 둔다.

## 5. 오늘의 임시 조치 (WORKAROUND)

`<base-path>/.masc/config/runtime.toml` 에서 `media_failover` 머리를 `claude_code.claude-haiku-4-5`, `glm-coding.glm-4.6v` 로 올리고, glm-5.3 lane 에 `claude_code.claude-haiku-4-5` 를 deepseek 앞에 넣었다. 첫 번째만 고르는 구조를 그대로 둔 채 첫 번째를 살아 있는 것으로 바꾼 것이라 워크어라운드다. §7 PR-A 가 들어가면 lane 에 끼운 haiku 는 뺀다.

## 6. 검증

- 재생: 오늘의 msx-retro-mania 요청 5건을 같은 입력으로 다시 보내 5건 모두 이미지 후보 중 살아 있는 것에서 답이 오는지.
- 단위(`test_keeper_turn_driver_*`, `test_runtime_agent`): 가짜 provider 가 첫 이미지 후보에 402 를 주면 두 번째 이미지 후보가 dispatch 되고, 같은 턴에서 첫 후보를 다시 부르지 않는다. 이미지 후보가 전부 402 면 위임 경로가 호출되고 이미지가 떨어지지 않는다. lane 의 텍스트 후보는 이미지 걸음에 나타나지 않는다.
- 운영 지표(주 단위, `tool_calls` 와 `keeper_chat_events`): "402 다음 턴에 같은 후보 재선택" 0건, 이미지 동반 요청의 `event_error` 비율.

## 7. 구현 순서 (Stacked PR)

1. PR-A: 이미지 후보 집합 함수 하나 + reroute 와 vision tool 이 그것을 쓰게. 테스트: 두 경로가 같은 목록을 본다.
2. PR-B: reroute 걸음 — `should_try_next` 오류에서 다음 이미지 후보로, 같은 턴 재방문 없음.
3. PR-C: 바닥을 위임으로. `delegates_media` 가 걸음 결과를 본다.

각 PR 은 §6 의 해당 단위 테스트를 함께 낸다.

## 8. 워크어라운드 자기 점검

카운터·문자열 분류기·cap 이 아니다. 후보 집합의 정의와 걸음 규칙을 바꾼다. §5 의 설정 변경만 워크어라운드이고 제거 시점을 적었다.
