---
rfc: "0488"
title: "GLM 의 이전 reasoning 은 모델 행이 지우라고 선언할 때만 지운다"
status: Draft
created: 2026-11-05
updated: 2026-11-05
author: claude
supersedes: []
superseded_by: null
related: ["0363", "0382"]
---

# RFC-0488 — GLM 의 이전 reasoning 은 선언할 때만 지운다

## 0. 요약

GLM Keeper 의 run 첫 요청은 입력의 56.5% 를 캐시에서 못 읽는다. 같은 run 의 뒤 요청은 1.4% 만 못 읽는다(§1.2). 첫 요청이 놓치는 이유의 20.6% 는 MASC 가 직전 턴 assistant 메시지의 reasoning 을 지우고 보내기 때문이다. 이미 보낸 메시지가 다음 요청에서 바뀌면 그 뒤 기록 전체를 provider 가 다시 계산한다.

지우는 이유는 둘이다.

1. 보존 여부를 적는 필드가 둘이다. `Provider_config.preserve_thinking` 과 `Provider_config.clear_thinking` 이 같은 결정을 반대 방향으로 적는다. 둘이 어긋나면 `clear_thinking` 이 이긴다.
2. 둘 다 비어 있으면 MASC 가 "지운다"를 고른다(`Provider_config.clear_thinking_value` 의 `None -> true`). z.ai 는 Coding Plan endpoint 에서 보존을 기본값으로 둔다(§2). MASC 가 provider 의 기본값과 반대 값을 만들어 보낸다.

이 RFC 는 세 가지를 정한다.

1. `clear_thinking` 필드를 지운다. 보존 여부는 `preserve_thinking` 하나가 정한다(§3.1).
2. 모델 행이 보존 여부를 선언하지 않으면, GLM 요청에 `clear_thinking` 멤버를 싣지 않고 이미 보낸 reasoning 을 그대로 보낸다. endpoint 의 기본값이 적용된다(§3.2).
3. 기본 설정(`config/runtime.toml`)의 GLM 행은 `preserve-thinking = true` 를 선언한다(§3.3).

## 1. 지금 동작

### 1.1 코드 (main `f39e0939c22`)

| 사실 | 위치 |
|---|---|
| `clear_thinking` 이 있으면 그 값, 없으면 `not preserve_thinking`, 둘 다 없으면 `true` | `packages/agent_core/lib/llm_provider/provider_config.ml` `clear_thinking_value` |
| GLM wire(`Thinking_object_clear_thinking`)는 위 값을 `thinking.clear_thinking` 으로 보낸다 | 같은 파일 `clear_thinking_object_request_field`, `backend_openai_request.ml` |
| 위 값이 `true` 면 replay 정책이 `Tool_call_assistant_messages_latest_user_turn` 이다. 완료된 user 턴의 reasoning 은 요청에서 빠진다 | `reasoning_dialect.ml` `apply_clear_thinking_replay_gate` |
| `clear_thinking` 을 `Some` 으로 정하는 production 코드는 두 곳이다. 둘 다 같은 자리에서 `preserve_thinking = Some false` 도 정한다 | `lib/keeper/keeper_structured_output_schema.ml` `for_deterministic_subcall`, `lib/keeper/keeper_vision_tool.ml` |
| 기본 설정의 GLM 행은 `preserve-thinking = false` 다 | `config/runtime.toml` `[models.glm-5-3]` 외 9행 |

### 1.2 측정 (2026-11-05 00:00:01Z~10:41:57Z)

비용 원장 `<base-path>/.masc/costs/2026-11/05.jsonl` 의 `usage_scope = per_request` 행만 센다. run 은 `(runtime_id, routing_run_id)` 다. 미적중은 `cache_miss_input_tokens / input_tokens` 다.

| | run | 첫 요청 미적중 | 뒤 요청 미적중 | 첫 요청이 차지한 미적중 토큰 |
|---|---|---|---|---|
| `glm-coding.*` | 269 | 56.5% | 1.4% | 82.9% |

턴 사이에 처음 바뀐 자리는 `<base-path>/.masc/keepers/<name>/provider-inputs/2026-11/05.jsonl` 로 판정한다. 이 파일은 턴마다 마지막 요청 1건을 적고, System·도구 정의·메시지마다 sha256 을 남긴다. 연속한 두 턴의 마지막 요청에서 처음 다른 것을 찾고, 뒤 턴의 첫 요청 미적중 토큰을 그 원인에 더한다. GLM·opencode Keeper 의 짝을 셌다(짝을 못 찾은 65쌍 제외).

| 처음 바뀐 자리 | 쌍 | 첫 요청 미적중 토큰 몫 | 그 첫 요청들의 미적중률 |
|---|---|---|---|
| System | 53 | 25.8% | 87.5% |
| 앞은 그대로, 뒤에 덧붙이기만 | 182 | 24.8% | 18.8% |
| 도구 정의 | 77 | 24.2% | 65.0% |
| 직전 턴 assistant 의 reasoning 제거 | 94 | 20.6% | 41.3% |
| user·문맥 메시지 수정 | 14 | 3.8% | 45.8% |
| 맨 앞 메시지 | 14 | 0.8% | 53.7% |

`provider-inputs` 는 턴의 마지막 요청만 남기므로, 첫 요청의 차이를 마지막 요청으로 대신 본다. 이 표의 원인 배정은 그 범위의 추정이다.

## 2. z.ai 문서 (2026-11-05 확인)

- https://docs.z.ai/api-reference/llm/chat-completion `ChatThinking.clear_thinking`: "Default value is True. Controls whether to clear `reasoning_content` from previous conversation turns." `true` 면 "the system ignores/removes `reasoning_content` from prior turns, and only keeps non-reasoning context (e.g., user/assistant visible text, tool calls, and tool results)." 이 멤버는 지금 턴에서 생각할지는 바꾸지 않는다.
- https://docs.z.ai/guides/capabilities/thinking-mode Preserved Thinking: "This capability is enabled by default on the Coding Plan endpoint and disabled by default on the standard API endpoint." 켜면 "you must return the complete, unmodified reasoning_content back to the API." 이전 reasoning 을 남기면 "increases cache hit rates—saving tokens in real tasks." 블록은 "Do not reorder or edit these blocks; otherwise, performance may degrade and cache hit rates may be affected."

두 문서의 기본값은 endpoint 마다 다르다. MASC 가 멤버를 보내지 않으면 그 endpoint 의 기본값이 적용된다. 표준 endpoint 는 서버가 이전 reasoning 을 지운다. MASC 가 reasoning 을 보내도 결과는 같다.

## 3. 결정

### 3.1 보존 여부는 `preserve_thinking` 하나다

`Provider_config.t` 와 `Provider_config.make` 에서 `clear_thinking` 을 지운다. 이 필드를 읽던 곳은 모두 `preserve_thinking` 을 읽는다.

| 지금 | 바뀐 뒤 |
|---|---|
| `clear_thinking_value ~clear_thinking ~preserve_thinking` | 지운다 |
| `preserved_thinking_active ~enable_thinking ~clear_thinking ~preserve_thinking` | 지운다. replay 판정은 §3.2 의 표 하나다 |
| `clear_thinking_object_request_field ... ~clear_thinking ~preserve_thinking` | `~preserve_thinking` 만 받는다 |
| `Cache` 요청 키의 `clear_thinking` | 지운다. 같은 결정이 `preserve_thinking` 으로 이미 키에 있다 |
| `exact_output_plan` 의 `Option.is_some config.clear_thinking` | 지운다. 바로 위 줄이 `preserve_thinking` 을 본다 |
| 대시보드 runtime 선언의 `clear_thinking` | 지운다 |
| 구조화 출력·vision subcall 의 `clear_thinking = Some true` | 지운다. 같은 자리의 `preserve_thinking = Some false` 가 같은 요청을 만든다 |

### 3.2 선언이 없으면 지우지 않는다

GLM wire(`Thinking_object_clear_thinking`) 하나에만 적용한다. 다른 preserve wire 는 replay 정책을 catalog 행의 capability 가 정하고, 클라이언트가 만든 기본값이 없다.

| `supports_reasoning` | `enable_thinking` | `preserve_thinking` | `thinking.clear_thinking` | replay 정책 |
|---|---|---|---|---|
| false | 아무 값 | 아무 값 | `Some p` 면 `not p`, `None` 이면 싣지 않음 | `No_replay` |
| true | `Some false` | 아무 값 | 위와 같음 | `No_replay` |
| true | `None`·`Some true` | `Some true` | `false` | `All_assistant_messages` |
| true | `None`·`Some true` | `None` | 싣지 않음 | `All_assistant_messages` |
| true | `None`·`Some true` | `Some false` | `true` | `Tool_call_assistant_messages_latest_user_turn` |

replay 정책이 바뀌는 줄은 넷째 줄 하나다. 지금은 그 줄에서 완료된 턴의 reasoning 을 뺀다. `thinking.clear_thinking` 멤버는 `preserve_thinking` 이 `None` 인 모든 줄에서 빠진다. 지금은 `enable_thinking` 이 있거나 행이 reasoning 을 지원하면 `true` 를 보낸다.

`Some false` 는 지금처럼 지운다. 요청 크기를 줄이려는 운영자의 선택이고, 이 RFC 는 그 선택을 막지 않는다.

### 3.3 기본 설정의 GLM 행은 보존을 선언한다

`config/runtime.toml` 의 GLM 행(`glm-5-3`, `glm-5-3-flash` 와 Coding Plan 의 나머지 text 모델 행)은 `preserve-thinking = true` 를 적는다. 선언이 없어도 Coding Plan endpoint 에서는 같은 결과지만, 행을 표준 endpoint 에 묶어도 보존이 유지되도록 적는다.

라이브 설정(`<base-path>/.masc/config/runtime.toml`)은 운영자 파일이다. 이 RFC 의 PR 은 그 파일을 바꾸지 않는다. 지금 라이브의 `[models.glm-5-3]`·`[models."glm-5.3-flash"]` 는 `preserve-thinking = false` 라서, 운영자가 그 줄을 `true` 로 바꾸거나 지워야 §1.2 의 넷째 원인이 사라진다.

## 4. 검토한 대안

- **`preserve_thinking : bool option` 을 이름 있는 합타입으로 바꾼다** (`Preserve_completed_turns | Clear_completed_turns`). 하지 않는다. `bool option` 은 이미 세 상태가 닫힌 합이고, 세 상태를 모든 wire 가 `match` 로 다룬다. 이 필드는 checkpoint(`checkpoint_contract.ml` 의 필수 필드 `preserve_thinking`)와 raw trace 에 저장된다. 이름을 바꾸면 Keeper resume 이 읽는 저장 형식이 함께 바뀌는데, 바뀌는 동작은 없다. 결함은 같은 결정을 적는 두 번째 필드와 클라이언트가 만든 기본값이다. 이 RFC 는 그 둘을 지운다.
- **모든 모델 행에 보존 여부를 필수로 받는다.** 하지 않는다. 선언이 없을 때의 뜻을 "endpoint 기본값"으로 정하면 기본값을 만들 필요가 없다. 필수로 받으면 thinking 이 없는 행까지 줄을 적어야 한다.
- **클라이언트 기본값을 `false`(보존)로 뒤집는다.** 하지 않는다. 표준 endpoint 에서는 문서의 기본값(지움)과 다른 멤버를 보내게 된다. 멤버를 싣지 않으면 두 endpoint 모두 문서대로 동작한다.

## 5. 영향

- 보존을 선언한 GLM 요청은 완료된 턴의 reasoning 만큼 커진다. 그 부분은 직전 요청과 같은 앞부분이라 캐시에서 읽힌다(§2 문서). 비용은 `docs/constitution.xml` `cost_and_observability` 를 따른다.
- 구조화 출력·vision subcall 은 그대로 `clear_thinking: true` 를 보낸다(`preserve_thinking = Some false`). 한 번만 부르는 요청이라 이전 턴이 없다.
- `preserve_thinking` 이 비어 있는 GLM 요청은 `thinking.clear_thinking` 멤버가 빠진다. Coding Plan 은 보존하고 표준 endpoint 는 지운다.

## 6. 검증

- 시험: §3.2 표의 다섯 줄을 요청 본문(`thinking` 객체)과 replay 정책으로 확인한다. 넷째 줄은 직전 턴 assistant 메시지의 `reasoning_content` 가 요청에 그대로 남는지 본다.
- 배포 뒤: §1.2 와 같은 방법으로 GLM run 첫 요청 미적중률과 "reasoning 제거" 원인의 쌍 수를 다시 센다. 라이브 설정이 보존을 선언한 뒤의 시각으로 자른다. reasoning 제거 쌍이 0 이 되는지, run 첫 요청 미적중률이 얼마나 내려가는지 적는다.

## 7. 층

1. 이 문서.
2. `clear_thinking` 필드와 두 resolver 를 지우고 §3.2 표를 구현한다.
3. 기본 설정의 GLM 행에 `preserve-thinking = true` 를 적는다.
