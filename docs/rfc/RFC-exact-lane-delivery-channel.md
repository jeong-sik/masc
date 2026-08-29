---
rfc: "exact-lane-delivery-channel"
title: "exact 레인이 답을 받는 통로를 고른다 — 본문 JSON 이 후보를 절반 떨어뜨린다"
status: Draft
created: 2026-08-30
updated: 2026-08-30
author: claude
supersedes: []
superseded_by: null
related: ["cli-runtimes-as-lane-slots", "prompts-and-tool-definitions-outside-ocaml"]
---

# RFC: exact 레인 전달 통로 (exact-lane-delivery-channel)

## 요약

exact 레인 넷 중 셋은 모델의 **응답 본문**에서 JSON 을 읽고, 하나(`verifier_exact`)는 **도구 호출**에서 읽는다. 같은 모델이 같은 프롬프트로 두 통로에서 정반대 결과를 낸다. 본문 통로는 살아 있는 후보의 절반을 떨어뜨리고, 떨어지는 이유는 능력이 아니라 마크다운 펜스다.

이 문서는 그 실측을 기록하고, 통로를 바꾸려면 무엇을 건드려야 하는지와 그 대가를 적는다. 결론을 강제하지 않는다 — `Agent_core.Exact_output` 이 도구를 **의도적으로** 배제한다고 선언해 두었으므로, 그 선언을 뒤집는 일은 근거와 합의가 먼저다.

## 측정

2026-08-30, ollama.com 경유. 각 레인의 실제 프롬프트와 실제 스키마를 태웠고 시도는 각 5 회다.

| 후보 | librarian(본문) | hitl(본문) | verifier(도구) |
|---|---|---|---|
| qwen3-5-cloud | 5/5 | 5/5 | 5/5 |
| deepseek-0731 | 5/5 | 5/5 | 5/5 |
| minimax-m3 | **0/5** | 2/5 | 5/5 |
| gemma4-31b | **0/5** | **0/5** | 5/5 |
| kimi-k3 | 4/5 | 5/5 | 5/5 |

**도구 열은 전부 5/5 다.** 본문 열에서만 후보가 죽고, 실패는 한 종류다 — 답을 ```json 펜스로 감싼다. exact-output 경로에는 펜스 제거가 없고(있는 쪽은 `fusion_judge_parse.ml:177` 뿐이다) 그래서 `Invalid_json_output` 이 된다.

같은 과제를 통로만 바꿔서 다시 쟀다. 프롬프트도 스키마도 그대로다.

| 모델 | 본문 JSON | 도구 호출 |
|---|---|---|
| minimax-m3 | 0/5 | **5/5** (29.3s) |
| gemma4:31b | 0/5 | **5/5** (5.5s) |
| qwen3.5:397b | 5/5 | 5/5 (48.0s) |
| deepseek-0731 | 5/5 | 5/5 (8.1s) |

펜스는 모델이 **본문에 쓸 때만** 생긴다. 도구 호출의 인자는 provider 가 별도 필드로 직렬화하므로 마크다운이 낄 자리가 없다.

### 이것이 지금 무엇을 뜻하나

`librarian_exact` 의 HTTP 후보가 사실상 둘(qwen, deepseek)인 이유는 살아 있는 모델이 둘뿐이어서가 아니라 통로 때문이다. 도구 호출이면 넷이고, 그중 가장 빠른 gemma 가 5.5s 로 현재 1 번보다 4 배 빠르다.

2026-08-11 에 "gemma4 를 네 exact 레인 전부에서 제거했다 — 출력을 ```json 펜스로 감싸 Invalid_json_output 이 된다" 는 기록이 있다. 그 판단은 본문 통로에서 옳았고 지금도 옳다. 통로가 바뀌면 전제가 바뀐다.

## 제약

`packages/agent_core/lib/llm_provider/exact_output.mli` 는 이렇게 선언한다.

> Provider config, wire response formats, schema envelopes, capability overrides, **tools**, reasoning controls, token measurement, and retry/fallback are deliberately absent from this interface.

`minimum_guarantee` 도 `Json_syntax` 와 `Provider_schema` 둘뿐이다. 도구 통로는 이 인터페이스에 없다.

`verifier_exact` 가 도구 호출을 쓰는 것은 이 모듈을 통해서가 아니다. `Task.Anti_rationalization` 이 `report_review_verdict` 스키마를 직접 넘기는 별도 경로다. 즉 masc 에는 이미 두 경로가 있고, 넷 중 하나만 다른 쪽에 서 있다.

## 선택지

### A. exact-output 에 도구 통로를 추가한다

`minimum_guarantee` 에 세 번째 값을 두고, 레인이 스키마를 도구 인자로 실어 보낸다.

- 얻는 것: 세 레인이 한 번에 후보를 넓힌다. 통로가 하나로 모인다.
- 치르는 것: mli 가 명시한 경계를 뒤집는다. tools 가 들어오면 tool_choice, 병렬 도구 호출 금지, 도구 결과 루프 같은 것들이 따라 들어올 압력이 생긴다. 그 경계는 이유가 있어서 그어졌을 것이고, 이 RFC 는 그 이유를 아직 모른다 — **작성 전에 원저자 근거를 찾아야 한다.**

### B. 레인을 anti_rationalization 쪽 경로로 옮긴다

`verifier_exact` 가 이미 서 있는 자리로 librarian 과 hitl 을 옮긴다.

- 얻는 것: 새 인터페이스를 만들지 않는다. 이미 도는 경로다.
- 치르는 것: exact-output 이 주는 것들(frozen lane, 전이 규칙, 측정 receipt, catalog 승인)을 잃는다. 이 레인들이 그걸 쓰고 있으므로 사실상 재구현이다.

### C. 통로는 그대로 두고 후보를 본문 통로에서만 고른다 (현행)

- 얻는 것: 아무것도 안 바꾼다.
- 치르는 것: 후보가 절반이다. 오늘처럼 두 후보가 동시에 막히면 레인이 선다. 그리고 그 사실이 "모델이 부족하다" 로 잘못 읽힌다.

## CLI 꼬리와의 충돌

`cli_slots` 는 도구 통로가 없다. `keeper_lane_cli_oneshot.mli` 는 프롬프트에 스키마를 싣고 fence 제거 없이 엄격 파싱하며, HTTP 의 `Json_syntax_only` 계약을 **의도적으로 그대로 맞췄다** 고 적혀 있다.

A 나 B 를 하면 두 통로가 갈라진다. HTTP 는 도구 인자, CLI 는 본문 JSON 이 된다.

다만 실측상 그 갈라짐은 견딜 만하다. 2026-08-30 `masc-lane-cli-probe` 로 선언된 CLI 런타임 10 개를 레인당 2 회씩 걸었더니, 여섯이 본문 JSON 스키마를 지켰다(gemini 두 행, opus 두 행, codex-spark, sonnet-5 는 hitl 에서 1/2). 나머지 넷은 파싱이 아니라 실행이 실패했다 — codex 두 행은 구독 한도 소진, antigravity 두 행은 agent 종료.

즉 CLI 쪽은 본문 통로로도 잘 돈다. 갈라짐의 비용은 "두 통로를 각각 설명해야 한다" 이지 "한쪽이 안 돈다" 가 아니다.

## 결정하지 않은 것

- A 의 경계를 뒤집을 근거. mli 의 저 문장이 언제 왜 쓰였는지 확인 전이다.
- hitl 프롬프트 쪽 별건. `judge.effect.md` 는 "JSON 으로만 답하라" 를 마지막 줄에 추상적으로 두고, `librarian.md` 는 첫 줄에 구체적으로 둔다. 같은 조건에서 지시를 앞으로 옮기니 qwen 4/5→5/5, minimax 3/5→4/5 였다. 표본이 작아 단정하지 않았고, 통로를 바꾸면 이 문제 자체가 사라진다.
- 비용. exact 레인 호출은 비용 원장에 기록되지 않는다(2026-08-30 확인: glm 비용 행 3,185 건이 전부 `keeper_turn_id` 를 가진 키퍼 턴이다). 통로를 바꾸면 후보가 바뀌고 후보마다 가격 선언이 다르므로, 레인 호출을 원장에 넣는 것이 이 결정보다 앞설 수도 있다.

## 재현

```
# 후보 × 레인 채널 매트릭스 (HTTP)
python3 lane_matrix.py 5

# CLI 슬롯 (레인이 실제로 쓰는 경로)
masc-lane-cli-probe --lane librarian --runtime claude_code.claude-opus-5 --trials 2
```

`masc-lane-cli-probe` 는 `Keeper_lane_cli_oneshot.run` 을 직접 부른다. 호출을 재구현하지 않으므로 나온 값이 레인이 실제로 받는 값이다.
