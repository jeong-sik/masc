---
rfc: "0425"
title: "질문은 자기가 어떻게 답해질 수 있는지를 말한다 — masc_ask 의 세 필드를 한 갈래로"
status: Draft
created: 2026-09-06
updated: 2026-09-06
author: vincent
supersedes: null
superseded_by: null
related: []
---

# 질문은 자기가 어떻게 답해질 수 있는지를 말한다

## 측정

2026-09 `~/me/.masc/tool_calls` 원장, `masc_ask` 131콜.

```
성공 47 · 실패 84

masc_ask 를 쓴 턴 66
  깨끗함                32
  실패 후 성공           9
  실패하고 끝내 못 보냄   25   ← 블로킹 질문이 운영자에게 도달하지 않았다
```

못 보낸 25턴의 56콜을 사유로 가르면:

| 수 | 사유 | 층 |
|---:|---|---|
| 27 | `header is required` | 질문 객체 안의 필드 누락 |
| 11 | `unsupported field(s): header` | 같은 필드를 배열 밖에 놓음 |
| 9 | `questions` 배열 자체 없음 | 최상위 |
| 5 | `question_id is required` | 질문 객체 안 |
| 3 | `question offers no choices and refuses free text` | **필드 조합 위반** |
| 1 | `question_id` 를 최상위에 | 최상위 |

앞의 다섯은 중첩을 못 잡은 것이고, 예시 부재가 원인이었다 (#33408 에서 description 에 실제 호출을 넣었다).

이 RFC 가 다루는 것은 **여섯 번째 줄**이다. 조합 위반은 예시로 닫히지 않는다.

## 문제

한 질문이 답해질 수 있는 방법은 세 필드에 흩어져 있다.

```
mode       : "single" | "multi"     (필수)
free_text  : bool                   (기본 false)
choices    : array                  (선택)
```

세 필드가 서로를 제약한다. `choices` 가 없으면 `free_text` 가 참이어야 한다 — 아니면 아무도 답할 수 없는 질문이 되므로 런타임이 거절한다. 그 규칙은 스키마 어디에도 없고 거절 메시지에만 있다.

그리고 `mode` 는 `choices` 가 있을 때만 뜻이 있다. 자유 서술만 받는 질문에 `mode: "multi"` 는 아무 의미가 없는데 스키마는 그것을 필수로 요구한다. 즉 **뜻 없는 값을 반드시 채워야 한다.**

세 축의 조합은 8가지고 그중 유효한 것은 5가지다. 나머지 3가지는 표현 가능하지만 거절된다. 이것이 Alexis King 이 말하는 validate 쪽이다 — 잘못된 상태를 **만들 수 있게 해두고 나중에 거절한다**.

## 고려한 세 가지

### 1. 아무것도 안 한다

조합 위반은 56콜 중 3콜이다. 중첩 실패는 예시(#33408)가 겨냥하고, 지배적 인자는 런타임이다. 이 선택은 그 둘의 효과를 먼저 재보자는 것이다.

### 2. `mode` 를 조건부로 만든다 — 채택

`mode` 는 `choices` 가 있을 때만 뜻이 있다. 자유 서술만 받는 질문에 `single`/`multi` 는 아무것도 말하지 않는데 스키마는 그것을 필수로 요구한다. **뜻 없는 값을 반드시 채우게 하는 것**이 지금의 결함이다.

`choices` 가 있을 때만 `mode` 를 요구하도록 바꾼다. wire 는 깨지지 않는다 — 지금까지 보내던 호출은 전부 그대로 유효하고, 자유 서술 질문만 필드 하나를 덜 채운다.

남는 것: `choices` 없고 `free_text` 거짓인 질문은 여전히 적을 수 있고 런타임이 거절한다. 그 3콜은 이 안으로 닫히지 않는다.

### 3. 답하는 방법을 닫힌 갈래로 접는다 — 접는다

```json
"answer": {"kind": "pick", "mode": "single", "choices": [...]}
"answer": {"kind": "write", "hint": "..."}
"answer": {"kind": "pick_or_write", "mode": "multi", "choices": [...], "hint": "..."}
```

잘못된 조합이 표현 불가능해진다. Parse, don't validate 로는 이쪽이 옳다.

**그런데 값을 못 한다.** 교차 리뷰(GLM, 2026-09-06)와 자체 검토가 같은 지점에 도달했다:

- 이 변경이 직접 없애는 실패는 56콜 중 **3콜**이다.
- wire 를 깨고 여섯 개 진입점(producer / store / TUI decode / TUI render / dashboard wire / 운영자 답변 경로)을 동시에 옮겨야 하며, 컷 시점의 미해결 pending ask 를 버린다.
- 갈래가 지금 형태보다 모델이 더 잘 맞힌다는 **증거가 없다**. 오히려 중첩이 한 단계 깊어진다 (`questions[].answer.choices[]`). 실패의 다수가 중첩을 못 잡은 것이었으므로 방향이 반대일 수 있다.
- "TUI 분기가 줄어든다" 는 초안의 주장도 측정되지 않았다. `Ask_single`/`Ask_multi` 와 `Ask_choices_only`/`Ask_free_text_allowed` 가 하나로 접히는 것은 사실이나, 그것이 렌더를 더 읽기 쉽게 만드는지는 따로 봐야 한다.

3번은 2번이 남긴 3콜을 닫기 위한 것인데, 그 3콜의 비용이 wire 변경 비용보다 작다. 되살리려면 아래 판정 기준 1을 통과해야 한다.

## 영향 범위 (채택안 기준)

| 층 | 파일 |
|---|---|
| 스키마 | `config/tools/masc_ask.toml` — `mode` 의 `required` 를 조건부로 |
| producer | `lib/mcp_tool_runtime_ask.ml` — `mode` 부재 시 `choices` 유무로 갈라 거절하거나 통과 |

TUI·dashboard·운영자 답변 경로는 건드리지 않는다. `mode` 가 없는 질문은 `choices` 도 없으므로 두 화면 모두 이미 자유 서술 슬롯만 그린다.

## 위험 — 스키마가 지배 인자가 아니다

```
ollama_cloud.gpt-oss-120b        39콜   1 ok    3%
glm-coding.glm-5.3               14콜  11 ok   79%
antigravity.gemini-3-8-flash     23콜   9 ok   39%
codex_subscription.gpt-reserve   12콜   6 ok   50%
ollama_cloud.minimax-m3           5콜   5 ok  100%
```

같은 `rondo` 가 gpt-oss-120b 에서 39콜 1성공, glm-5.3 에서 5콜 3성공이다. 프롬프트도 스키마도 같다. 스키마를 어떻게 다듬든 이 격차는 남는다.

## 판정 기준

1. **3번을 되살리려면**: 두 스키마를 같은 프롬프트로 각각 20회 호출해 성공률을 비교하고, 갈래 쪽이 유의하게 높아야 한다. 측정 없이 진행하지 않는다.
2. gpt-oss-120b 를 `masc_ask` 가 필요한 레인에서 빼면 실패의 몇 %가 사라지는가 — 이것이 먼저다.
3. #33408 의 예시가 머지된 뒤 중첩 실패가 실제로 줄었는가.

2와 3의 결과가 먼저 나와야 이 RFC 의 나머지가 의미를 갖는다.
