# Provider usage 의미론 감사 — input_tokens의 캐시 포함 여부 (RFC-0382 G6)

- 확인일: 2026-08-17 (공식 문서 fetch 기준)
- 질문: 각 provider wire의 prompt/input 토큰 카운트가 캐시 성분(read/write)을 **포함**하는가 **배제**하는가, 그리고 agent_core `Types.api_usage`가 그 차이를 흡수하는가.
- 결론: 배제형 wire는 Anthropic Messages 형식 하나. canonical 계약을 "inclusive prompt total"로 명문화하고(`types.mli`), Anthropic parse 경계에서 정규화한다(`Backend_anthropic.usage_of_wire_counts`).

## Provider별 wire 의미론

| Provider (wire) | prompt 카운트 필드 | 캐시 필드 | 의미론 | 근거 |
|---|---|---|---|---|
| Anthropic Messages | `usage.input_tokens` | `cache_creation_input_tokens`, `cache_read_input_tokens` | **배제형** — "Number of input tokens which were not read from or used to create a cache"; `total_input_tokens = cache_read + cache_creation + input_tokens` | platform.claude.com/docs prompt-caching, 2026-08-17 확인 |
| OpenAI Chat/Responses | `usage.prompt_tokens` (`input_tokens`) | `prompt_tokens_details.cached_tokens` | **포함형** — "reused 1,920 **of its** 2,006 prompt tokens" (cached ⊂ prompt) | developers.openai.com prompt-caching, 2026-08-17 확인 |
| Gemini generateContent | `usageMetadata.promptTokenCount` | `cachedContentTokenCount` | **포함형** — "this is still the total effective prompt size meaning this includes the number of tokens in the cached content" | ai.google.dev/api/generate-content, 2026-08-17 확인 |
| GLM (OpenAI-compat) | `usage.prompt_tokens` | `prompt_tokens_details.cached_tokens` | **포함형** — RFC-0382 §3.2 정정 기록(라이브 데이터로 확정: input에 cache read 기포함) | RFC-0382 §3.2, 2026-08-16 |
| ollama / ollama_cloud | `prompt_eval_count` | (없음) | 캐시 미보고 — backend가 캐시 필드 0 고정. 로컬 KV 재사용 시 `prompt_eval_count`는 처리분만 세는 것으로 알려져 있으나 캐시 필드가 없어 구분 불가 (G2 계열 한계) | backend_ollama.ml:366-367 |
| llama-server (OpenAI-compat) | `usage.prompt_tokens` | usage에는 없음 (`timings.cache_n` 별도) | **포함형** (prompt 전체) — 캐시 관측은 timings 축(G5/PR-2) | RFC-0382 §3.1 |
| Kimi (Anthropic-compat) | Anthropic 형식 동일 | 동일 | Anthropic 형식으로 파싱되므로 정규화가 동일 적용. Kimi 자체 문서로는 **확인 필요** — compat 표면이 의미론까지 미러링한다고 가정 | backend_anthropic 경유 (count-tokens 주석) |

## agent_core 코드 판정 (수정 전 → 후)

| 사이트 | 수정 전 | 수정 후 |
|---|---|---|
| `backend_anthropic.ml` parse_response | wire 값 그대로 복사 (**배제형 유입**) | `usage_of_wire_counts`로 inclusive 정규화 |
| `streaming.ml` message_start | 동일 유입 | 동일 정규화 (output은 delta 소유라 0 유지) |
| `streaming.ml` message_delta | input 0 고정, cache는 그대로 | 변경 없음 + 계약 주석 (아래 잔여 결함 참조) |
| `backend_openai_parse.ml` / `_responses.ml` | prompt_tokens verbatim | 변경 불요 (wire가 이미 포함형) |
| `backend_gemini.ml` | promptTokenCount verbatim | 변경 불요 (동일) |
| `cache.ml` (저장 코덱) | schema "1" — 정규화 전 값 잔존 가능 | schema "2"로 하드컷 (구 항목은 버전 가드가 은퇴) |
| `pricing.ml` estimate_cost | `regular = input − creation − read` — 포함형 가정이라 Anthropic 유입 시 이중 차감(`max 0`이 침묵 클램프) | 가정이 참이 되어 산식 그대로 정당화 |

## 영향 (수정 전 결함의 실현 조건)

Anthropic 형식 + 캐시 활성(system/tools cache_control) 조합에서:

1. **비용 과소**: regular input이 `max 0 (exclusive − creation − read)`로 클램프 — 캐시가 클수록 정규 입력 과금이 0으로 소멸.
2. **점유율 과소**: `keeper_context_observation_projection`의 ratio 분자(RFC-0233 "provider-reported prompt total")가 배제형 값 — 캐시된 프리픽스가 클수록 창 점유가 실제보다 작게 보고.

## 잔여 결함 (이 PR 범위 밖, #28903으로 추적)

- **누적 delta를 add로 접음**: 공식 계약 "The token counts shown in the usage field of the message_delta event are *cumulative*" vs `complete_stream_state.add_usage`(가산). wire가 최종 delta에 cache 필드를 반복하면 cache 이중 계산, server-tool 스트림의 input 갱신은 파서의 0 고정으로 폐기됨.
- **`emit_synthetic_events` + fold 조합 위험**: 같은 usage를 MessageStart/MessageDelta 양쪽에 실어, fold 소비자가 생기면 input/cache 2배. 현재 프로덕션 호출자 0 (테스트 전용)이라 라이브 영향 없음.
