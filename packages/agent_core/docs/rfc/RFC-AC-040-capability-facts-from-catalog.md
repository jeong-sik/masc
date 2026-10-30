# RFC-AC-040: 공급자·모델 사실은 카탈로그에만 적는다

| | |
|---|---|
| Status | Draft |
| Author | vincent (with Claude analysis) |
| Created | 2026-09-18 |
| Target | `agent_core` — `lib/llm_provider/`, `lib/provider_runtime_binding.ml`, `models.toml`; masc — `lib/runtime/runtime_adapter.ml`, `lib/keeper/keeper_effective_tool_surface.ml` |
| Related | RFC-AC-018 §3·Phase 2, RFC-AC-023 §3.2·§3.3, RFC-AC-034 §2 규칙 4, masc RFC-0370 §3.2 |
| 측정 기준 | `origin/main` `e50d28963b` (2026-09-19). 모든 수와 `파일:줄` 은 부록 A 의 명령으로 다시 낼 수 있다 |

## 0. 요약

- `capabilities.ml` 에 공급자 preset 이 13개 있다. 카탈로그 행은 적지 않은 필드를 이 preset 에서 받는다.
- 내장 카탈로그(`packages/agent_core/models.toml`, 214행)에서 이렇게 받는 값 중 `default_capabilities` 와 다른 값이 1,473개다.
- 받은 값 일부는 카탈로그가 적은 값과 어긋난다. 카탈로그 파일만 읽어서는 그 값이 안 보인다.
- 이 RFC 는 공급자·모델 사실을 카탈로그 한 곳에만 둔다. 아무도 적지 않은 사실은 코드 기본값이 아니라 `unknown` 이다. 경로·인증·wire 모양 같은 프로토콜은 코드에 남는다.
- 작업은 일곱 단계로 나눈다. 단계마다 PR 하나다. 옛 형식을 읽는 호환 코드는 만들지 않는다.
- 타입까지 적은 필드는 `supports_parallel_tool_calls` 하나다. 나머지 필드가 언제 `unknown` 이 되는지는 Q2 가 필드마다 정하고, 그때까지 값은 코드에서 온다 (3.c).

## 1. 문제

### 1.1 코드에 사실이 적혀 있다

`capabilities.ml` 은 preset 13개를 정의한다.

| preset | 줄 | 위에 얹는 preset | 직접 적은 필드 |
|---|---|---|---|
| `default_capabilities` | 241 | — | 38 (레코드 전체) |
| `anthropic_capabilities` | 363 | default | 15 |
| `kimi_capabilities` | 398 | default | 17 |
| `openai_compat_chat_capabilities` | 458 | default | 11 |
| `openai_compat_chat_extended_capabilities` | 483 | openai_compat_chat | 4 |
| `openrouter_capabilities` | 507 | openai_compat_chat_extended | 1 |
| `mimo_capabilities` | 540 | openai_compat_chat | 18 |
| `provider_l_capabilities` | 589 | openai_compat_chat_extended | 4 |
| `ollama_capabilities` | 598 | openai_compat_chat_extended | 5 |
| `ollama_cloud_capabilities` | 621 | ollama | 2 |
| `ollama_cloud_v1_capabilities` | 648 | ollama_cloud | 3 |
| `glm_capabilities` | 671 | default | 12 |
| `gemini_capabilities` | 717 | default | 17 |

`default_capabilities` 를 빼면 필드 대입이 109개다. 그중 85개는 `default_capabilities` 와 값이 다르다.
라벨은 `capabilities_for_provider_label` (`capabilities.ml:802`) 이 preset 으로 바꾼다. 카탈로그의 `base` 와 `[[providers]]` 의 `capabilities_base` 가 이 라벨을 쓴다.

`openrouter_capabilities` 를 받는 행은 없다. OpenRouter 13행은 모두 `base = "openai_chat_extended"` 와 자기 `accepted_reasoning_efforts` 를 적는다. 이 preset 은 행이 없는 config(1.6)에서만 쓰인다.

### 1.2 행이 적지 않은 필드는 코드에서 온다

`models.toml` 214행 중 201행이 `base` 를 적는다. 나머지 13행은 공급자의 `capabilities_base` 를 쓴다.
`Capabilities.apply_declarative_capability_overrides` (`capabilities.ml:1028`) 는 행이 적은 필드만 덮어쓰고, 나머지는 preset 값을 그대로 둔다.

행이 적지 않은 (행, 필드) 쌍을 출처별로 세면 다음과 같다. `supported_models`, `serving_constraint` 는 뺐다.

| 출처 | (행, 필드) 쌍 |
|---|---|
| preset 값이 `default_capabilities` 와 다름 | 1,473 |
| preset 이 기본값과 같은 값을 일부러 다시 적음 | 486 |
| `default_capabilities` 에서만 옴 | 4,134 |

214행 모두 `default_capabilities` 와 다른 값을 적어도 하나 preset 에서 받는다.

### 1.3 코드 값과 카탈로그 값이 어긋난다

| preset | 코드 값 | 값을 직접 적은 행 | 코드 값을 받는 행 |
|---|---|---|---|
| `glm_capabilities` | ctx 200,000 (`:673`), out 40,960 (`:679`) | 28행. out 은 128,000×15, 96,000×3, 4,096×3, 32,768×3, 16,384×2, 131,072×2. 40,960 을 적은 행은 없다 | ctx·out 2행 (`zai-image` 의 `glm-image`, `cogview-4-250304`) |
| `anthropic_capabilities` | ctx 200,000 (`:365`), out 8,192 (`:367`) | 10행 모두 ctx 1,000,000. out 은 128,000×6, 384,000×2, 64,000×2 | 0행 |
| `gemini_capabilities` | ctx 1,000,000 (`:719`), out 65,000 (`:720`) | out 은 65,536×2, 64,000×2. 65,000 을 적은 행은 없다 | out 10행 (채팅 6, 이미지·음성 4), ctx 4행 |
| `kimi_capabilities` | out 32,768 (`:405`) | 0행 | 7행 |

값마다 사정이 있다.

- GLM. `capabilities.ml:674-678` 주석은 "glm-5.1 이 `max_tokens <= 40960` 을 강제한다(2026-04-12)" 고 적는다. 같은 저장소의 `glm-5.1` 행은 out 128,000 이다. 두 기록 중 하나는 틀렸다.
- Anthropic. 주석이 스스로 "default; opus/sonnet 4.6 = 1M", "default; higher for newer models" 라고 적는다 (`:366`, `:368`). 이 값을 받는 행은 없다. 행이 없는 경로(1.6)에서만 쓰인다.
- Kimi. 주석(`:402-404`)은 32,768 이 문서에 적힌 *기본* `max_tokens` 라고 한다. 그런데 이 필드는 *상한* 으로 쓰인다 (`backend_openai_request.ml:190-191`). 기본값이 상한 자리에 들어가 있다.

코드 값이 실제 요청을 망친 기록이 있다. 2026-09-07 `keeper_analyze_image` 가 `glm-coding.glm-4.6v` 에서 HTTP 400 code 1210 을 받았다 (`models.toml:3065-3071`, `test/test_model_catalog_default.ml:428-435`, `test/test_output_token_receipt.ml:283-288`).
provider 이름이 붙은 행이 없어서 조회가 공급자 preset 으로 떨어졌다. 요청한 65,536 이 preset 값 40,960 으로 깎였다. 모델의 실제 범위는 `[1,32768]` 이었다.
고친 방법은 같은 행을 provider 이름만 바꿔 두 번 더 적는 것이었다 (`models.toml:3092`, `:3115`).

이때 출력 토큰 영수증은 값의 출처를 `Catalog_model` 이라고 적는다 (`backend_openai_request.ml:231`). `capabilities_for_config_model` 이 행이 없을 때도 `for_provider_label_base` (`capabilities.ml:1432`) 로 preset 을 `Some` 으로 돌려주기 때문이다. 출처 표시는 카탈로그인데 값은 코드에서 왔다.

### 1.4 병렬 도구 호출: 아무도 재지 않은 `false` 가 요청에 실린다

`supports_parallel_tool_calls` 값이 어디서 오는지 214행을 셌다.

| 출처 | 행 |
|---|---|
| `ollama_cloud` preset 의 `true` | 64 |
| GLM 행이 `default_capabilities` 에서 받은 `false` | 30 |
| `openai_chat` preset 의 `true` | 35 |
| `openai_chat_extended` preset 의 `true` | 17 |
| `gemini` 14, `anthropic` 10, `ollama` 8, `kimi` 7, `nvidia` 4 (모두 `true`) | 43 |
| 행이 직접 적음 | 25 (`true` 13, `false` 12) |

GLM 행 중 이 필드를 적은 행은 없다. 그래도 30행 모두 `false` 로 읽힌다.
`effective_disable_parallel_tool_use` (`capabilities.ml:307-313`) 는 도구가 있고 값이 `false` 면 끄기를 요청한다. 그래서 `backend_openai_request.ml:487-495` 는 GLM 요청마다 `parallel_tool_calls:false` 를 보낸다 (`backend_openai_serialize.ml:902-906`).

2026-09-18 실측 기록(`2026-09-18-zai-glm-parallel-tool-calls-evidence-record.md`)이 있다. Z.AI coding 엔드포인트의 `glm-5.3-flash` 는 필드가 있든 없든 4번 모두 도구 호출 2개를 돌려줬다.
요청에는 아무도 재지 않은 주장이 실리고, 엔드포인트는 그 주장을 무시한다.

### 1.5 카탈로그에 적을 수 없는 사실

`models.toml` 키 목록(`model_catalog.ml:308-361`)에 없는 필드가 있다.

- `uncontrolled_reasoning`. 키가 없다. `ollama_cloud_v1_capabilities` (`capabilities.ml:659`) 만 값을 정한다.
- `emits_usage_tokens`. `models.toml` 에도 capability manifest 에도 키가 없다. JSON provider catalog (`provider_catalog.ml:654`) 와 masc `runtime.toml` (`runtime_toml.ml:927`) 에만 있다. 그런데 `Provider_catalog.set_global` 과 `Capability_manifest.set_global` 을 부르는 곳은 이 저장소에서 인라인 테스트(`capabilities.ml:1983`)뿐이다. 그래서 카탈로그 행은 늘 기본값 `true` 를 받는다.
- `supported_models`. `models.toml` 이 읽는다 (`model_catalog.ml:483`). 일반 경로 `overrides_of_catalog_entry` (`capabilities.ml:1298-1335`) 는 이 값을 넘기지 않는다. exact-output 경로(`exact_output_catalog_binding.ml:575`)만 넘긴다.

코드에만 있는 규칙이 다섯 개다.

| # | 규칙 | 위치 | 성격 |
|---|---|---|---|
| R1 | thinking 이 켜지면 required·named `tool_choice` 를 거절한다 | `provider_config.ml:467-479` | `config.kind = Anthropic` 으로 판정한다. DeepSeek Anthropic 호환 행은 같은 사실을 카탈로그 필드로 따로 적었다 (`models.toml:91-92`) |
| R2 | thinking 중에는 temperature·top_p·presence·frequency penalty 를 버린다 | `reasoning_dialect.ml:109-114`, 적용 `:147-150` | 이름은 `deepseek_…` 인데 `thinking_object` 형식을 쓰는 모든 행에 붙는다. 지금은 5행이고 모두 `deepseek` 공급자다 |
| R3 | effort 를 `high`·`max` 로만 보낸다 | `reasoning_dialect.ml:146`, `:305-315` | 같은 5행이 `accepted_reasoning_efforts = ["high", "max"]` 를 이미 적는다 |
| R4 | 요청에 제어가 없으면 thinking 을 켠 것으로 본다 | `reasoning_dialect.ml:143`, `:157`, `:252-256` | wire 형식에서 기본값을 끌어낸다. 1.5 의 `uncontrolled_reasoning` 과 같은 질문에 답한다 |
| R5 | 엔드포인트가 `parallel_tool_calls:false` 를 지킨다고 가정한다 | `backend_openai_serialize.ml:896-906` | 1.4 의 GLM 실측이 이 가정과 어긋난다 |

### 1.6 행이 없을 때 답하는 곳이 11곳이고, 3곳은 답이 다르다

`Provider_config.capabilities_for_config_model` 이 `None` 이면 호출한 쪽이 `kind` 로 preset 을 고른다. 운영 코드(인라인 테스트 제외)에서 11곳이다.

| # | 위치 | Anthropic | Kimi | OpenAI_compat | Ollama | Gemini | Glm |
|---|---|---|---|---|---|---|---|
| 1 | `provider_config.ml:412` `request_capabilities_for_config` | anthropic | kimi | **default** | ollama | gemini | glm |
| 2 | `provider_config.ml:428` `tool_choice_capabilities_for_config` | **default** | **default** | **default** | **default** | **default** | glm |
| 3 | `backend_anthropic.ml:393-403` `build_request_payload` | anthropic | kimi | **default** | **default** | **default** | **default** |
| 4 | `backend_openai_request.ml:168` `capabilities_of_config` | anthropic | kimi | openai_compat_chat | ollama | gemini | glm |
| 5 | `complete_common.ml:17` `base_capabilities_for_kind` | 4와 같음 | | | | | |
| 6 | `provider_runtime_binding.ml:225` `base_capabilities_of_kind` | 4와 같음 | | | | | |
| 7 | `reasoning_dialect.ml:502` (`:515`, `:535`, `:559`) `capabilities_of_kind` | 4와 같음 | | | | | |
| 8 | masc `keeper_effective_tool_surface.ml:388` `capabilities_of_kind` | 4와 같음 | | | | | |
| 9 | `backend_ollama.ml:61` | | | | ollama | | |
| 10 | `backend_gemini.ml:660` | | | | | gemini | |
| 11 | `backend_gemini.ml:731` | | | | | gemini | |

1·2·3번은 나머지와 답이 다르다. 예를 들어 행이 없는 Anthropic config 는 요청을 만들 때(3·4번) `anthropic_capabilities` 를 쓴다. `tool_choice` 검사(2번)는 `default_capabilities` 를 써서 `supports_tool_choice = false` 로 본다. 3번 backend 에 Anthropic·Kimi 말고 다른 kind 가 실제로 들어오는지는 확인하지 않았다.

`kind` 가 아니라 라벨로 기본값을 고르는 곳도 있다.

- `capabilities.ml:1432` `for_provider_label_base` — 공급자가 `[[providers]]` 에 있고 행이 없으면 공급자 preset 을 돌려준다. 1.3 의 1210 사고가 이 경로였다.
- `capabilities.ml:1029-1035` — `base` 가 없으면 `default_capabilities`.
- `exact_output_catalog_binding.ml:420-425` — 같은 규칙을 한 번 더 구현한다.
- `provider_registry.ml:189-205` — 등록된 공급자마다 preset 을 capability 로 붙인다.
- `provider_runtime_binding.ml:101-106` — registry 에 없으면 `default_capabilities`.
- `provider_catalog.ml:524-540` — JSON provider catalog 에 `capabilities_base` 가 없으면 `default_capabilities`.

카탈로그에 없는 모델을 배포가 선언할 때도 kind 로 preset 을 고른다. masc `runtime_adapter.ml:537-577` 은 `runtime.toml` 의 `[models.<id>.capabilities]` 선언을 `capabilities_of_kind wire` (`:545`) 위에 얹는다.
선언이 적을 수 있는 필드는 23개다. 적지 않은 `supports-*` 불리언은 `false` 로 읽히고 (`runtime_toml.ml:859`), `emits-usage-tokens` 만 `true` 다 (`:876`). `thinking-support` 와 `reasoning-streaming-format` 은 적지 않으면 wire preset 값을 받는다.
나머지 15개 필드는 선언할 키가 없어서 wire preset 값을 받는다. `accepted_reasoning_efforts`, `uncontrolled_reasoning`, `reasoning_replay_override`, `preserve_thinking_control_format`, `chat_output_budget_field` 등이다.

RFC-AC-018 §3 과 RFC-AC-023 §3.2 는 이미 "카탈로그에 없으면 typed 오류" 로 정했다. 위 목록은 그 결정이 아직 코드에 닿지 않은 자리다.

### 1.7 같은 행을 읽는 방법이 둘이다

행을 capability 레코드로 바꾸는 함수가 두 개다.

- 일반 경로: `Capabilities.apply_catalog_entry` (`capabilities.ml:1347-1367`) → `apply_declarative_capability_overrides` (`:1028-1226`)
- exact-output 경로: `Exact_output_catalog_binding.capabilities_of_catalog_binding` (`exact_output_catalog_binding.ml:416-577`). exact-output 슬롯을 만드는 `exact_output_resolver.ml:698` 이 부른다.

코드를 읽고 찾은 차이다.

| 항목 | 일반 경로 | exact-output 경로 |
|---|---|---|
| preset 고르기 | provider 이름이 붙은 행이면 `capabilities_base_by_identity_kind` 를 먼저 본다 (`capabilities.ml:1349-1364`) | 행의 `base`, 없으면 공급자 `capabilities_base` (`:420`). wire 별 base 를 보지 않는다 |
| 틀린 effort 문자열 | 경고하고 목록 전체를 preset 값으로 둔다 (`capabilities.ml:918-943`, `:1114-1124`) | 틀린 항목만 조용히 빼고 나머지를 쓴다 (`:444`) |
| 모르는 enum 문자열 | `Diag.warn` 후 preset 값 | 경고 없이 preset 값 |
| `modality_priority` 별칭 | `preserve`, `visual-first` 등도 받는다 (`capabilities.ml:910-916`) | 두 철자만 받는다 (`:409-414`) |
| `supported_models` | 넘기지 않는다 | 넘긴다 (`:575`) |

첫 줄의 차이는 `ollama_cloud` 공급자 행 40개에 걸린다. 이 공급자는 `capabilities_base_by_identity_kind = { openai_compat = "ollama_cloud_v1" }` 를 적는다.
OpenAI 호환 wire 에서 일반 경로는 `ollama_cloud_v1` 을 얹는다. `thinking_control_format`, `uncontrolled_reasoning`, `accepted_reasoning_efforts` 세 필드가 달라진다. 40행 중 `accepted_reasoning_efforts` 를 적은 행은 없다.

두 함수는 이미 한 번 어긋났다. #35254 (2026-09-12) 는 exact-output 경로가 `accepted_reasoning_efforts`, `thinking_control_format` 등을 빠뜨려 요청이 거절된 일을 고쳤다. 고친 방법은 빠진 필드를 두 번째 함수에 211줄로 복사하는 것이었다.

### 1.8 왜 문제인가

- 행이 필드를 빠뜨리면 코드 값이 조용히 들어간다. 카탈로그만 읽는 사람은 그 값을 볼 수 없다.
- 코드 값에는 근거 기록이 없다. 주석 날짜와 행 값이 어긋나도(GLM 40,960 과 128,000) 아무 검사도 잡지 못한다.
- 틀린 값이 요청에 실려도 영수증은 출처를 카탈로그라고 적는다.
- 틀린 값을 고치는 방법이 행 복제나 필드 복사가 됐다 (glm-4.6v 행 2개, #35254). 같은 모양의 수정이 계속 쌓인다.

## 2. 원칙

1. **공급자·모델 사실은 내장 카탈로그(`packages/agent_core/models.toml`) 한 곳에만 적는다.** 배포가 `AGENT_CORE_MODEL_CATALOG` 로 다른 파일을 주면 그 파일이 내장 카탈로그를 통째로 대신한다. 두 파일을 합쳐 읽는 일은 없다. 카탈로그에 없는 모델만 배포 설정이 능력을 적는다 (2.2.1).
2. **아무도 적지 않은 사실은 `unknown` 이다.** 코드 기본값으로 채우지 않는다. 예를 들어 병렬 도구 호출을 모르면 `parallel_tool_calls` 필드를 보내지 않는다. `false` 를 보내지 않는다.
3. **프로토콜은 코드에 남는다.** 요청 경로, 인증 헤더, wire 필드 이름과 모양이 여기에 든다. 가르는 질문은 하나다. "이 wire 를 쓰는 모든 모델에 늘 참인가." 참이면 코드에 둔다. 모델이나 엔드포인트마다 다를 수 있으면 카탈로그에 둔다.
4. **옛 형식을 읽는 코드는 만들지 않는다.** `base`, `capabilities_base` 를 받아 주는 reader·변환기를 두지 않는다.

### 2.1 앞선 결정과의 관계

- **RFC-AC-018 §3·Phase 2** — "lookup 이 `None` 이면 typed `Unknown_model` 오류" 로 정했다. 3.e 가 이 결정을 끝낸다.
- **RFC-AC-023 §3.2** — silent default 를 없애고 `Capability_unknown` 오류를 내기로 정했다 (RESOLVED). **§3.3** — `capabilities_for_provider_label` 을 없애기로 정했다 (RESOLVED). 3.d 가 이 둘을 실행한다.
  다만 §3.3 은 대신 `model_family_default_caps : Model_family.t -> model_caps` 를 코드에 두자고 한다. 이 RFC 는 이것을 받지 않는다. 계열 기본값은 지금의 preset 과 같은 종류다. 행이 필드를 빠뜨리면 계열 값이 조용히 들어간다.
  §2.2 의 `transport_caps`(wire 가 실어 나를 수 있는 것)는 원칙 3과 같은 방향이다.
- **RFC-AC-034 §2 규칙 4** — 모르는 host·provider·model·label 은 Unknown/None/fail-closed 로 둔다. 원칙 2는 이 규칙을 조회 단위에서 필드 단위로 넓힌다.
- **masc RFC-0370 §3.2** — 턴 타임아웃 300.0 을 "선언이 없을 때의 fallback" 으로 남겼다. 이것은 masc 런타임의 운영 상한이지 공급자·모델 사실이 아니다. 이 RFC 범위 밖이고 서로 어긋나지 않는다.

### 2.2 카탈로그와 `runtime.toml` 이 갈라지는 축

원칙 1의 "한 곳" 은 내장 카탈로그다. 그런데 같은 가중치라도 서빙하는 쪽이 다르면 값이 다르다. 그래서 배포가 자기 엔드포인트의 사실을 `runtime.toml` 에 적어야 할 것처럼 보인다. 두 파일이 맡는 것은 이렇다.

- **카탈로그** — 모델의 사실과 엔드포인트의 사실. 행의 키가 (provider, model) 이다.
- **`runtime.toml`** — 이 배포가 그중 어떤 행을 어떤 이름·엔드포인트 주소·자격증명으로 쓰는지.

같은 무게를 두 엔드포인트가 서빙하면 답이 둘이다. DeepSeek 자체 API 는 `tools` 가 실린 요청에 이전 턴 `reasoning_content` 를 전부 되돌려 보내라고 요구하고, 안 보내면 400 을 낸다 (api-docs.deepseek.com/guides/thinking_mode/, 2026-09-18 확인). 같은 모델을 Ollama 가 서빙할 때는 그 요구가 없고, 클라우드 모델 카드는 오히려 반대로 적는다 — 이전 턴 생각은 다음 사용자 턴 앞에 넣지 말라 (ollama.com/library/gemma4:31b-cloud, 2026-09-18 확인).

그래서 재전송 정책은 모델의 성질이 아니라 엔드포인트의 성질이다. 카탈로그 행은 `provider_name` 으로 엔드포인트를 이미 가르고 있다. **행의 키가 (provider, model) 이므로, 축이 갈라진다는 사실 자체가 카탈로그 안에서 표현된다.**

2026-09-18 에 이 구멍이 실측으로 드러났다. Ollama 가 서빙하는 deepseek 행이 DeepSeek 의 규칙을 물려받고 있어서, 라이브 keeper lane 요청 7.83 MB 중 4.7 MB(60%)가 그 엔드포인트가 만들지도 않은 reasoning 이었다. 고친 자리는 카탈로그 행이다 (#36981).

**규칙.** 원칙 3의 "이 wire 를 쓰는 모든 모델에 늘 참인가" 옆에 하나를 더 둔다. **"같은 모델을 다른 곳이 서빙해도 같은 값인가."** 같으면 한 행으로 족하다. 서빙하는 쪽에 따라 달라지면 **엔드포인트마다 행을 나눈다.** 새 키를 만들지 않는다. 카탈로그에 행이 있는 모델의 사실을 `runtime.toml` 에 적을 자리도 열지 않는다.

### 2.2.1 카탈로그에 없는 모델만 배포 설정에 능력을 적는다

배포가 새 엔드포인트를 묶는데 카탈로그에 그 행이 없으면, 카탈로그에 행을 더한다. 배포 설정이 능력을 적는 것은 카탈로그가 행을 가질 수 없는 모델뿐이다.

- **카탈로그에 행이 있는 모델** — `runtime.toml` 은 쓸 행을 고를 뿐, 행이 적은 사실을 다시 적지 않는다.
- **카탈로그에 없는 모델** — `runtime.toml` 의 `[models.<id>.capabilities]` 블록으로 능력을 선언한다. 블록이 없으면 부팅 때 capability 검사가 그 binding 을 거절한다 (`runtime.ml:1039`, `:1148`). 설치 마법사가 만든 엔드포인트가 이 경우다. provider id 가 운영자 답의 해시라서 어떤 카탈로그 행도 그 이름을 가질 수 없다 (`models.toml:21-27`). 로컬 llama-server 를 등록하는 절차는 `docs/LLAMA-SERVER-RUNBOOK.md` 3절이다.

사실이 두 벌이면 어긋나고, 어긋나면 한쪽이 조용히 이긴다. 2026-09-18 장애 세 건이 모두 이 모양이었다 — 창이 두 벌(작은 쪽이 이김), 요청 상한이 세 벌, 슬롯 선언이 두 벌(#37004). 상세는 #37008.

배포 선언은 아직 원칙 2와 맞지 않는다.

- 카탈로그에 없는 모델은 적지 않은 불리언이 `false` 로 읽히고, 선언할 키가 없는 15개 필드가 wire preset 값을 받는다 (1.6). 3.c·3.d·3.e 와 Q5 가 이 자리를 다룬다.
- 카탈로그에 행이 있는 모델에는 `runtime_adapter.ml:511-536` 이 블록의 세 필드만 행 위에 얹는다. `runtime_schema.ml:160-181` 에서 `option` 인 `max_output_tokens`, `declared_thinking_control_format`, `reasoning_streaming_format` 이다. `supports_*` 15개와 `emits_usage_tokens` 는 평범한 `bool` 이라 "안 적음" 과 "false 로 적음" 이 구별되지 않고, 행이 있는 모델에서는 조용히 버려진다 (#36994). 원칙 2를 필드 단위로 실행하려면 presence 가 먼저다.

## 3. 설계

단계마다 PR 하나다. 앞 단계가 머지된 뒤에 다음 단계를 연다.

### 3.a 근거 있는 값만 카탈로그에 적는다

**무엇.** 행이 preset 에서 받는 값은 1,959쌍이다. preset 값이 `default_capabilities` 와 다른 필드 1,473개와, preset 이 기본값과 같은 값을 일부러 적은 필드 486개다. 뒤쪽 예로 `glm_capabilities` 의 `supports_structured_output = false` 는 문서 근거와 함께 적은 선언이다 (`capabilities.ml:695-704`).

이 중 **근거가 있는 값만** 행에 적는다. 근거는 공식 문서 링크나 실측 기록과 확인 날짜다. 적을 때 `models.toml:3065-3071` 형식의 행 주석으로 그 근거를 같이 적는다.

근거가 없는 값은 적지 않는다. 아무도 적지 않은 값이므로 원칙 2 의 `unknown` 이다. `default_capabilities` 에서만 오는 값 4,134개와 같은 취급이다. 근거 없는 값을 행에 적고 "이건 근거가 없다" 고 표시하는 키는 만들지 않는다. 그런 키는 한 필드에 "선언" 과 "unknown" 말고 세 번째 상태를 만들고, 비울 기한 없는 목록을 남긴다.

**첫 산출물: 근거를 붙일 수 있는 값의 수.** 1,959쌍 중 근거를 붙일 수 있는 쌍이 몇 개인지는 아직 아무도 세지 않았다. 이 PR 은 값을 적기 전에 그 수를 두 묶음(1,473 과 486)으로 나눠 PR 본문에 먼저 적는다. 그 수가 이 PR 이 적을 값이고, 나머지는 3.c·3.d 에서 `unknown` 이 될 값이다.

**도구.** Python 으로 resolver 를 다시 구현하지 않는다. 이미 두 구현이 어긋났다(1.7). `llm_provider` 를 링크한 OCaml 실행 파일이 `Capabilities.apply_catalog_entry` 를 불러 지금 값을 뽑는다. 근거와 이 값을 나란히 놓고 쌍마다 판정한다.

**wire 에 따라 답이 다른 행.** `ollama_cloud` 행 40개는 wire 마다 세 필드가 다르다(1.7). 한 행에 값 하나로 적을 수 없다. 적는 형식은 열린 질문 Q1 이다.

**두 resolver 가 다른 행.** 이 PR 은 먼저 두 resolver 가 다른 레코드를 내는 행을 모두 뽑아 PR 본문에 적는다. 이 수는 아직 재지 않았다(dune 실행 필요). 0이 아니면 그 행은 한쪽 경로의 동작이 바뀐다. 행마다 어느 쪽 값이 맞는지 적는다.

**바뀌는 파일.** `packages/agent_core/models.toml`, 새 실행 파일과 dune 규칙.

**wire 변화.** 근거가 지금 값과 같으면 없다. 근거가 지금 값과 다르면 그 행의 요청이 바뀐다. 적지 않은 값은 `base` 가 아직 남아 있어 이 단계에서는 preset 에서 그대로 온다. 그 값들이 사라지는 것은 필드마다 3.c 이고, 3.c 가 옮기지 않은 필드는 3.d 다.

**검증.** 변경 전후 요청 스냅샷에서 달라지는 행이 근거를 보고 고친 행과 정확히 같다. 두 resolver 모두 확인한다.

### 3.b 남은 값의 근거를 만든다

**무엇.** 3.a 뒤에 남은 값은 지금 근거를 찾을 수 없는 값이다. 공급자 문서를 다시 읽거나 엔드포인트를 재서 근거를 만들고, 값을 행에 적는다. PR 은 공급자 하나 또는 사실 한 종류 단위로 나눈다. 값마다 공식 문서 링크나 실측 기록, 확인 날짜를 행 주석에 적는다. `models.toml:3065-3071` 의 형식을 따른다. 끝까지 근거를 못 만든 값은 적지 않는다. 그 필드는 `unknown` 으로 남는다.

첫 후보(1.3, 1.4):

| 대상 | 행 | 확인할 것 |
|---|---|---|
| Gemini `max_output_tokens = 65000` | 10 | 모델 문서의 출력 상한 |
| Kimi `max_output_tokens = 32768` | 7 | 기본값이 아니라 상한인지 |
| GLM 이미지 행 `max_context_tokens`·`max_output_tokens` | 2 | 이미지 생성 모델에 이 필드가 뜻이 있는지 |
| GLM `supports_parallel_tool_calls` | 30 | 2026-09-18 실측은 `glm-5.3-flash` 1개 모델뿐이다. 잰 행만 `true` 로 적는다 |
| `ollama_cloud` `supports_parallel_tool_calls = true` | 64 | 모델마다 잰 기록 |

**wire 변화.** 값을 적은 행만 바뀐다. `max_output_tokens` 는 호출자가 상한보다 큰 값을 요청할 때 깎이는 값과 Anthropic 필수 필드 값이 바뀐다. GLM 행을 `true` 로 적으면 그 행 요청에서 `parallel_tool_calls:false` 가 빠진다.

**검증.** 적은 값마다 근거 링크나 실측 기록이 있다. 변경 전후 요청 스냅샷에서 달라지는 행이 값을 적은 행과 정확히 같다.

### 3.c 적지 않은 사실은 typed unknown 으로 둔다

**무엇.** 필드 하나씩 `unknown` 을 표현할 수 있는 타입으로 바꾼다. `bool option` 대신 전용 variant 를 쓴다. `Option.value ~default` 가 다시 기본값을 끼워 넣을 틈을 막기 위해서다.
첫 필드는 `supports_parallel_tool_calls` 다.

```ocaml
type parallel_tool_calls =
  | Parallel_tool_calls_supported
  | Parallel_tool_calls_unsupported
  | Parallel_tool_calls_undeclared
```

TOML 키가 `true` 면 `Supported`, `false` 면 `Unsupported`, 없으면 `Undeclared` 다. 파싱할 때 한 번 정한다.
끄기 요청 판단은 이렇게 바뀐다.

```ocaml
match caller_disabled, declared with
| true, (Parallel_tool_calls_supported | Parallel_tool_calls_unsupported
       | Parallel_tool_calls_undeclared) -> Disable
| false, Parallel_tool_calls_unsupported -> Disable
| false, (Parallel_tool_calls_supported | Parallel_tool_calls_undeclared) -> Leave_to_provider
```

도구가 있을 때만 필드를 싣는 조건은 backend 마다 지금 코드를 그대로 쓴다.

**바뀌는 파일 (측정).** `capabilities.ml(i)` 레코드와 `effective_disable_parallel_tool_use` (`:307-313`), `backend_openai_request.ml:487-495`, `backend_openai_responses.ml:540-545`, `backend_anthropic.ml:414-418`, `backend_ollama.ml:161-170`, `exact_output_catalog_binding.ml:231`·`:549`, `model_catalog.ml:420-421`, `capability_manifest.ml:475`, `provider_catalog.ml:635-636`·`:676-677`, masc `runtime_schema.ml:165`·`:189`, `runtime_schema.mli:141`, `runtime_toml.ml:915`, `runtime_adapter.ml:553`, `server_dashboard_http_runtime_info.ml:1738`·`:1853`·`:1997`.

**wire 변화.** 필드를 적지 않은 행 중 지금 `false` 로 읽히는 행이 요청에서 끄기 필드를 뺀다. 3.b 전 기준으로 GLM 30행이다. 필드를 직접 `false` 로 적은 OpenRouter 12행은 계속 보낸다. 나머지 행은 지금도 `true` 라 바뀌지 않는다.
3.a·3.b 가 근거와 함께 적지 않은 값은 필드마다 이 단계에서 사라진다. 그 목록이 이 wire 변화이고, 아래 검증이 스냅샷으로 대조한다.

**필드마다 unknown 이 wire 에서 뜻하는 것.** 필드마다 따로 정한다. 지금까지 확인한 것만 적는다. 나머지는 Q2 다.

| 필드 | 선언이 없을 때 지금 | 제안 |
|---|---|---|
| `max_output_tokens` | 이미 `option`. 선택 필드는 생략하고, Anthropic 필수 필드는 요청 실패 (`backend_anthropic.ml:202-230`) | 그대로 |
| `max_context_tokens` | 이미 `option` (#36512, `capabilities.ml:459-467`) | 그대로 |
| `supports_parallel_tool_calls` | `false` → 도구가 있으면 끄기 필드 전송 | 필드를 보내지 않는다 |
| `emits_usage_tokens` | `true` → usage 가 없으면 drift 관찰 (`capabilities.ml:2294-2295`) | drift 관찰을 만들지 않는다 |
| `supports_image_input` | `false` → 이미지를 이름표로 바꿈 (`backend_gemini.ml:651-666`) | Q2 |
| `supports_tools`, `supports_*_tool_choice` | `false` → 도구 끔·forced 요청 거절 | Q2 |
| `thinking_control_format` | `No_thinking_control` 이 "제어 없음" 과 "모름" 을 함께 뜻함 | Q2 |

**어느 필드가 언제 옮겨지나.** 이 RFC 가 타입과 판단까지 적은 필드는 `supports_parallel_tool_calls` 하나다. `max_output_tokens` 와 `max_context_tokens` 는 이미 `option` 이라 바꿀 것이 없고, `emits_usage_tokens` 는 방향만 적었다. 표에 없는 필드와 "Q2" 로 남긴 세 줄은 unknown 이 wire 에서 무엇을 뜻하는지가 정해져야 옮길 수 있고, 그 결정은 필드마다 그 필드의 PR 에서 한다. 옮기기 전까지 그 필드의 값은 `default_capabilities` 에서 온다. 측정 기준 커밋에서 이 레코드에서만 오는 (행, 필드) 쌍이 4,134개다. 3.d 는 모든 필드가 옮겨진 뒤에 열리므로, 마지막 단계는 Q2 가 필드마다 답해질 때까지 열리지 않는다.

**검증.** 변경 전후 요청 스냅샷에서 달라지는 행이 위 wire 변화 목록과 정확히 같다. match 에 `_` 를 쓰지 않아 variant 를 더하면 컴파일러가 빠진 자리를 알려 준다.

### 3.d preset 과 `base` 상속을 지운다

**무엇.** 근거 있는 값은 3.a·3.b 가 행에 적었고, 나머지 필드는 3.c 가 `unknown` 으로 옮겼으므로 preset 을 지운다. 3.c 가 모든 필드를 옮긴 뒤에 이 PR 을 연다. 남은 필드가 있으면 그 필드의 요청 변화가 이 PR 에 한꺼번에 몰린다.

- `capabilities.ml:241-749` preset 13개, `:773-781` `capabilities_of_kind`, `:783-792` `provider_kind_alias_of_label`, `:802-818` `capabilities_for_provider_label`, `:945-984` 의 `base_label`, `capabilities.mli:197-219`·`:319-352` 공개 선언.
- `model_catalog.ml:311` 의 `base` 키, `model_provider_catalog.ml:24-25`·`:113-114`·`:199-215`·`:288-295` 의 `capabilities_base`, `capabilities_base_by_identity_kind`.
- `capability_vocab.ml:726-752` `base_label_values`.
- 카탈로그: `models.toml` 201행의 `base`, 공급자 25곳의 `capabilities_base`, `ollama_cloud` 의 `capabilities_base_by_identity_kind`.
- `default_capabilities` 는 이름을 바꿔 "아무것도 선언하지 않음" 레코드로 남긴다. 3.c 가 필드를 옮길수록 이 레코드의 기본값이 줄어든다.

**코드에만 있는 규칙 다섯 개(1.5).**

| # | 제안 | 이유 |
|---|---|---|
| R1 | 행 필드로 옮긴다 (예: thinking 중 forced tool_choice 허용 여부) | 공급자 kind 가 아니라 모델 계약이다. DeepSeek Anthropic 호환 행이 이미 필드로 적는다 |
| R2 | 행 필드 `ignored_sampling_parameters_when_thinking` 으로 옮긴다 | 이미 있는 `ignored_sampling_parameters` 와 같은 모양이다. DeepSeek 사실이 wire 형식 이름에 붙어 있다 |
| R3 | 규칙을 지운다 | 해당 5행이 `accepted_reasoning_efforts = ["high", "max"]` 로 같은 사실을 적는다. 모든 경로에서 검증이 직렬화보다 먼저 도는지는 이 PR 에서 확인한다 |
| R4 | 행 필드로 옮긴다. `uncontrolled_reasoning` 과 합칠지는 Q3 | "요청에 제어가 없을 때 엔드포인트가 무엇을 하나" 는 엔드포인트 사실이다 |
| R5 | 새 필드를 만들지 않는다 | 3.b·3.c 뒤에는 GLM 행이 끄기 필드를 보내지 않는다. 필드를 지키지 않는 엔드포인트에 `Unsupported` 를 적어야 하는 행이 생기면 그때 더한다 |

`uncontrolled_reasoning`, `emits_usage_tokens` 에 `models.toml` 키를 만든다. `supported_models` 는 3.f 의 단일 resolver 가 넘긴다.

**wire 변화.** 카탈로그 행이 있는 config 는 없다. 근거 있는 값은 행에 있고, 나머지 필드는 3.c 가 이미 `unknown` 으로 옮겼다.
행이 없는 config 는 아직 3.e 전이라 "아무것도 선언하지 않음" 레코드를 받는다. 1.6 의 1·2·3번과 나머지가 이 시점에 같은 답을 내게 된다.
카탈로그에 없는 모델의 `runtime.toml` 선언도 바뀐다. `runtime_adapter.ml:545` 가 쓰는 `capabilities_of_kind` 가 없어지므로, 선언할 키가 없는 15개 필드(1.6)가 wire preset 값 대신 "아무것도 선언하지 않음" 값을 받는다. 그 전에 Q5 를 정한다.

**검증.** `rg -n '_capabilities\b|capabilities_base|base_label'` 가 운영 코드에서 0건. 3.c 까지의 요청 스냅샷이 그대로 통과한다.

### 3.e 행이 없을 때의 답을 하나로 만든다

**무엇.** `Provider_config.capabilities_for_config_model` 을 `(capabilities, unknown_model) result` 로 바꾼다. 오류 이름은 RFC-AC-018 의 `Unknown_model` 을 따른다. 1.6 의 11곳과 라벨 기본값 6곳에서 기본값 갈래를 지우고 오류를 처리한다.

- 요청을 만드는 backend 는 HTTP 전에 typed 오류로 요청을 끝낸다.
- masc `keeper_effective_tool_surface.ml` 은 오류를 도구 표면 판정에 그대로 올린다.
- masc `runtime_adapter.ml:537-577` 은 `runtime.toml` 선언을 wire 기본값 위에 얹지 않는다. 선언이 적지 않은 필드는 `unknown` 이다. 선언할 키가 없는 필드는 Q5 의 결정을 따른다.
- `for_provider_label_base` 를 지운다. 공급자는 알지만 행이 없으면 `Unknown_model` 이다. provider 이름 없는 행으로 대신 답하지 않는다.

**wire 변화.** 카탈로그에 행이 없는 config 는 지금 preset 값으로 요청을 보낸다. 바뀐 뒤에는 요청 전에 거절된다. 출력 토큰 영수증의 `Catalog_model` 은 실제로 행에서 온 값에만 붙는다.

**영향 측정.** masc 기동 검사는 카탈로그에도 `runtime.toml` 선언에도 없는 binding 을 이미 거절한다 (`runtime.ml:1039`, `:1148`). 그래서 masc 런타임 영향은 작을 것 같지만 재지 않았다. 이 PR 은 실제 배포 `runtime.toml` 로 행이 없는 binding 을 먼저 센다.

**검증.** 인라인 테스트 `complete_common.ml:140-153` ("model 이 없으면 provider default") 은 `Unknown_model` 을 기대하도록 바뀐다. 1.6 의 11곳에 대해 행이 없는 config 가 같은 오류를 내는 테스트를 둔다.

### 3.f 행 읽기를 하나로 만든다

**무엇.** `capabilities_of_catalog_binding` (`exact_output_catalog_binding.ml:416-577`) 을 지우고 `Capabilities` 의 함수 하나만 남긴다. exact-output 슬롯(`exact_output_resolver.ml:698`)도 그 함수로 행을 읽는다. 1.7 표의 다섯 차이는 이 함수 하나의 동작으로 정한다. 틀린 문자열은 로드 실패로 둔다.

**wire 변화.** 1.7 표의 차이가 걸린 행에서 한쪽 경로의 값이 바뀐다. 3.a 가 센 "두 resolver 가 다른 행" 이 그 목록이다. 40개 `ollama_cloud` 행의 wire 별 세 필드는 Q1 의 결정을 따른다.

**검증.** exact-output 슬롯과 일반 요청이 같은 행에서 같은 레코드를 받는다. 값이 바뀐 행이 3.a 가 적은 목록과 같다.

### 3.g preset 값을 붙잡는 테스트를 카탈로그 데이터 검사로 바꾼다

**현재 (측정, 휴리스틱).** preset 필드나 라벨 조회 결과를 직접 확인하는 테스트 파일이 8개다.
preset 을 fixture 바탕이나 인자로만 쓰는 파일이 20개다. `capabilities.ml` 인라인 테스트는 59개다(preset 과 무관한 것도 섞여 있다).
이름을 거치지 않고 값을 붙잡는 테스트도 있다. `test/test_runtime_provider_auth_headers.ml:1344-1345` 는 공급자 기본 경로로 40,960 을 확인한다. 이런 테스트는 이름 검색으로 다 못 찾는다. 3.d 에서 테스트를 돌려야 드러난다.
테스트 안 TOML 문자열에서 `base`·`capabilities_base` 를 쓰는 파일은 14개, 56줄이다.

**무엇.**

- preset 값을 확인하는 테스트는 지운다. 대신 카탈로그 데이터 검사를 둔다.
  - 모든 행이 필수 필드를 적었는가. 빠진 필드는 `unknown` 으로 세고, 필드별 개수를 출력한다.
  - `max_output_tokens <= max_context_tokens` 같은 행 안 일관성.
  - 단일 resolver 의 결과를 행별 스냅샷으로 고정한다. 행에 값이 더해지면 이 스냅샷이 그 행을 짚고, 근거는 리뷰가 본다.
- fixture 는 3.d 의 "아무것도 선언하지 않음" 레코드 위에 필요한 필드만 얹는다.

**검증.** 테스트가 preset 이름이나 preset 에서 나온 숫자를 참조하지 않는다.

## 4. 건드리지 않는 것, 위험, 열린 질문, 겹치는 PR

### 4.1 건드리지 않는 것

- 프로토콜 코드. 기본 요청 경로(`provider_config.ml:21-26`), 인증 헤더(`provider_config.ml:253-269`, `exact_output_plan.ml:331-332`, `http_client.ml:1314`, `provider_files.ml:80`), `/responses` 판정(`provider_config.ml:725`). 이 리터럴은 인라인 테스트 밖에서 4파일 13곳이다.
- "이 wire 에는 그런 필드가 없다" 는 경고 (`backend_gemini.ml:21-41`, `backend_ollama.ml:155-170`).
- `Provider_kind.t`. wire 종류의 이름이다 (RFC-AC-023 §7.3 경계).
- 모델 id 로 capability 를 고르는 코드. 인라인 테스트 밖에서 모델 id 모양 문자열은 22곳이다. 공급자 별칭 2, codec 이름 2, Gemini 진단 경로 17, 인라인 테스트 도우미 1이다. 모델 id 로 판정하는 곳은 없다.
- 가격 필드(`input_per_million` 등). 이미 행 데이터다. `pricing.ml` 의 기본값은 이 RFC 에서 재지 않았다.
- masc RFC-0370 §3.2 의 턴 타임아웃 fallback.
- Discovery 가 `/props` 에서 읽는 실측값 (RFC-AC-034 B5).

### 4.2 위험

- **단계마다 요청이 바뀐다.** 근거 없는 값을 행에 적지 않으므로, 그 값이 사라지는 시점마다 요청이 바뀐다. 필드마다 3.c 이고, 남은 필드가 있으면 3.d 다. 기계적 이동과 의미 수정을 갈라 두는 단계는 없다. 대신 3.a·3.b·3.c 가 모두 같은 방법으로 확인한다. 달라지는 행을 PR 본문에 먼저 적고, 변경 전후 요청 스냅샷이 그 목록과 같은지 본다.
- **근거를 못 만든 값이 남는다.** 3.b 가 문서를 다시 읽어도 근거가 안 나오는 값이 있다. 그 필드는 `unknown` 이 되고, 원칙 2 에 따라 요청에서 빠진다. 엔드포인트가 그 기능을 실제로는 지원하는데 요청이 그것을 못 쓰게 되는 경우가 생길 수 있다. 이때 답은 기본값을 되살리는 것이 아니라 그 행을 재서 근거를 만드는 것이다.
- **교체 카탈로그가 기동을 막는다.** 3.d 뒤에 `base` 는 모르는 키다. `model_catalog.ml:363-375` 가 그 행을 거절한다. masc 는 `AGENT_CORE_MODEL_CATALOG` 파일을 `Model_catalog.load_file` 로 읽고, 실패하면 기동 오류를 낸다 (`server_runtime_bootstrap.ml:40-50`). `base` 를 적은 교체 카탈로그를 쓰는 배포는 3.d 릴리스에서 기동이 멈춘다. `models.toml:29-34` 는 이 변수를 쓰는 배포가 지금 없다고 적는다. 3.d 는 릴리스 노트에 교체 카탈로그 변환을 적는다.
- **두 resolver 중 한쪽 동작이 바뀐다.** 1.7 의 차이 때문에 3.a·3.f 에서 한쪽 경로의 값이 반드시 바뀐다. 3.a 가 먼저 그 행을 센다.
- **행이 없는 lane 이 멈춘다.** 3.e 뒤에는 preset 으로 돌던 config 가 요청 전에 거절된다. 3.e 가 실제 배포 기준으로 먼저 센다.
- **외부 소비자.** `capabilities.mli` 는 preset 을 공개한다. 이 저장소 밖 `agent_core` 사용자가 있는지는 모른다.
- **변경이 잦은 파일이다.** 2026-09-10 이후 `capabilities.ml`, `model_catalog.ml`, `exact_output_catalog_binding.ml`, `reasoning_dialect.ml`, `provider_config.ml`, `models.toml` 을 건드린 커밋이 23개다. 단계마다 PR 을 작게 유지한다.

### 4.3 열린 질문

- **Q1. wire 마다 값이 다른 행을 어떻게 적나.** `ollama_cloud` 40행은 wire 에 따라 `thinking_control_format`, `uncontrolled_reasoning`, `accepted_reasoning_efforts` 가 다르다.
  (a) 행 안에 wire 별 하위 표를 둔다. (b) 행 identity 에 wire 를 넣어 행을 나눈다. (c) `[[providers]]` 에 wire 별 값을 둔다.
  (c) 는 공급자 값을 행이 물려받는 구조라 원칙 2와 부딪힌다. (a) 를 권한다. 행 하나를 읽으면 그 모델의 모든 wire 가 보인다.
- **Q2. 필드마다 unknown 이 wire 에서 무엇을 뜻하나.** 3.c 표에서 "Q2" 로 남긴 필드다. 기준 후보는 "모르는 기능은 요청하지 않는다" 다. 도구·이미지처럼 요청 자체를 바꾸는 필드는 거절과 생략이 사용자에게 다르게 보인다. 필드마다 PR 에서 정한다.
- **Q3. R4 와 `uncontrolled_reasoning` 을 하나로 합치나.** 둘 다 "요청에 제어가 없을 때 엔드포인트가 reasoning 을 켜는가" 에 답한다.
- **Q4. JSON 두 경로를 같이 지우나.** `Capability_manifest` 와 `Provider_catalog` 는 capability 를 만드는 세 번째·네 번째 경로다. 이 저장소에서 운영 코드가 `set_global` 을 부르지 않는다. 둘 다 `base_label` 을 쓰므로 3.d 에서 함께 지우기를 권한다. 외부 소비자 여부는 모른다.
- **Q5. 카탈로그에 없는 모델은 선언할 키가 없는 필드를 어디서 받나.** 지금은 15개 필드를 wire preset 에서 받는다 (1.6). 그중 `chat_output_budget_field`, `assistant_tool_content_format` 은 wire 가 정하는 값이라 원칙 3의 프로토콜에 가깝다. `accepted_reasoning_efforts`, `reasoning_replay_override`, `uncontrolled_reasoning` 은 엔드포인트가 정하는 값이다. 3.d 가 preset 을 지우기 전에 필드마다 가른다. 앞의 것은 wire 코드에 두고, 뒤의 것은 `runtime.toml` 에 선언 키를 열거나 `unknown` 으로 둔다.

### 4.4 다른 PR 과 겹침

- 2026-09-19 기준 열린 PR 48개 중 `packages/agent_core/lib/llm_provider/` 나 `models.toml` 을 건드리는 것은 넷이다.
  - **#37044** — `Provider_config` 의 tool_choice override 필드를 지운다. 1.6 의 2번 `tool_choice_capabilities_for_config` 는 남고, 행이 없을 때의 답(Glm 은 glm, 나머지는 default)도 같다. `provider_config.ml` 의 줄 번호만 밀린다.
  - **#37022**, **#37026** — `model_catalog` 식별자를 opaque 타입으로 바꾼다. 3.a·3.d·3.f 가 고칠 `model_catalog.ml(i)`, `capabilities.ml`, `exact_output_catalog_binding.ml` 을 같이 건드린다.
  - **#36969** — `models.toml` 의 `ollama_cloud` `kimi-k2.6` 행을 고친다. 3.a 가 세는 "preset 과 다른 값" 목록을 바꾸므로, 3.a 를 열 때 개수를 다시 잰다.
- 요청에서 언급된 #36944 는 2026-09-17T17:06:37Z 에 머지됐다. 바꾼 파일은 `agent.mli`, `agent_types.ml(i)`, `test_agent_core.ml`, keeper 도구 검색 파일들이다. 이 RFC 의 파일과 겹치지 않는다.
- 최근 머지된 PR 중 이 RFC 와 방향이 같은 것: #37009·#37016 (공급자·모델 사실을 내장 카탈로그 한 벌로 모았다. 원칙 1), #36981 (Ollama 가 서빙하는 deepseek 행의 재전송 정책을 행에서 고쳤다. 2.2), #36512 (OpenAI 호환 preset 에서 context 값을 뺐다. 원칙 2의 선례), #36412 (`uncontrolled_reasoning` 도입, 키는 만들지 않았다), #35254 (1.7 의 두 resolver 어긋남), #36139 (스트리밍 파서가 선언된 멤버만 읽는다).
- 방향이 반대인 것: #36991 이 `openrouter_capabilities` preset 을 더했다. 이 preset 을 받는 행은 없어서(1.1) 3.a 가 적을 값은 없고, 3.d 가 지울 preset 에 든다.
- `docs/rfc/` 의 frontmatter 검사(#36898)는 `docs/rfc/RFC-*.md` 만 본다 (`scripts/rfc-generate-index.py:23`, `:231`). 이 파일은 대상이 아니다. 형식은 RFC-AC-039 의 머리 표를 따랐다.

## 부록 A. 검증 명령

모든 명령은 worktree 루트에서 `origin/main` `e50d28963b` 기준으로 돌렸다.

### A.1 preset·행·상속·어긋남·병렬·리터럴·테스트 (1.1–1.4, 1.7, 3.a, 3.d, 3.g, 4.1)

`python3 rfc040_measure.py` 로 아래 스크립트를 돌렸다. 출력 요약:

```text
presets 13 | assignments in non-default presets 109 | of which differ from default 85 | record fields 38
[models.toml] rows 214 | with base 201 | provider-scoped 105 | providers 25 | providers with capabilities_base 25
  pairs inheriting a preset value that differs from default_capabilities: 1473
  rows inheriting at least one such value: 214
  inherited limit max_context_tokens gemini 1_000_000 ×4, glm 200_000 ×2
  inherited limit max_output_tokens gemini 65_000 ×10, glm 40_960 ×2, kimi 32_768 ×7
  parallel inherited: ollama_cloud true 64, openai_chat true 35, glm false 30, openai_chat_extended true 17,
           gemini true 14, anthropic true 10, ollama true 8, kimi true 7, nvidia true 4
  parallel stated: openai_chat_extended false 12, openai_chat true 8, openai_chat_extended true 5
  stated anthropic ctx {1000000:10} out {128000:6, 384000:2, 64000:2}
  stated gemini ctx {1000000:8, 1048576:2} out {65536:2, 64000:2}
  stated glm ctx {200000:13, 128000:12, 1000000:2, 1048576:1} out {128000:15, 96000:3, 4096:3, 32768:3, 16384:2, 131072:2}
  stated kimi ctx {256000:7}
  rows scoped to ollama_cloud 40 | stating thinking_control_format 11 | stating accepted_reasoning_efforts 0
model-id-shaped literals outside inline tests: 22   (glm-coding ×2, codec names ×2, gemini.* diagnostics ×17, test helper ×1)
protocol literals outside inline tests: 13 in 4 files
test files asserting a preset field or label lookup: 8
test files using a preset only as fixture base/argument: 20
unstated pairs by origin: differs 1473, explicit-default 486, only-default 4134
```

행의 preset 은 "행의 `base`, 없으면 공급자 `capabilities_base`" 로 골랐다. exact-output 경로와 같은 규칙이다. `ollama_cloud` 행의 wire 별 base 는 반영하지 않았다(1.7).
테스트 분류는 정규식 휴리스틱이다. `test_provider_registry.ml:343-345` 는 registry 를 거쳐 preset 값을 확인하지만 fixture 쪽으로 분류됐다.
1.6 의 "선언할 키가 없는 15개 필드" 는 `default_capabilities` 의 필드 38개에서 `runtime_adapter.ml:546-575` 의 레코드가 대입하는 23개를 뺀 것이다.

<details>
<summary>rfc040_measure.py</summary>

```python
import re, tomllib, glob, subprocess
from collections import Counter, defaultdict

def strip(s):  # OCaml comments -> spaces, keeps line numbers
    out, d, i, q = [], 0, 0, False
    while i < len(s):
        c, t = s[i], s[i:i+2]
        if d == 0 and c == '"' and s[i-1] != "\\": q = not q
        if not q and t == "(*": d += 1; i += 2; continue
        if not q and t == "*)" and d: d -= 1; i += 2; continue
        out.append(c if d == 0 else ("\n" if c == "\n" else " ")); i += 1
    return "".join(out)

def split_top(b):
    parts, d, cur = [], 0, ""
    for ch in b:
        d += ch in "([{"; d -= ch in ")]}"
        if ch == ";" and d == 0: parts.append(cur); cur = ""
        else: cur += ch
    return [p.strip() for p in parts + [cur] if p.strip()]

src = strip(open("packages/agent_core/lib/llm_provider/capabilities.ml").read())
own, P = {}, {}
for m in re.finditer(r"^let ([a-z0-9_]+_capabilities) =\s*\{(.*?)\}\s*;;", src, re.S | re.M):
    body, base = m.group(2), None
    w = re.match(r"\s*([a-z0-9_]+)\s+with\b(.*)", body, re.S)
    if w: base, body = w.group(1), w.group(2)
    own[m.group(1)] = (base, {k.strip(): " ".join(v.split()) for k, _, v in (i.partition("=") for i in split_top(body))})
def res(n):
    if n not in P:
        b, f = own[n]; P[n] = {**(res(b) if b else {}), **f}
    return P[n]
for n in own: res(n)
D = P["default_capabilities"]
nondef = [n for n in own if n != "default_capabilities"]
print("presets", len(own), "| assignments in non-default presets", sum(len(own[n][1]) for n in nondef),
      "| of which differ from default", sum(1 for n in nondef for k, v in own[n][1].items() if D[k] != v), "| record fields", len(D))

kind = dict(re.findall(r"Provider_kind\.([A-Za-z_]+) -> ([a-z0-9_]+_capabilities)", src))
canon = {"Anthropic": "anthropic", "Kimi": "kimi", "OpenAI_compat": "openai_compat", "Ollama": "ollama", "Gemini": "gemini", "Glm": "glm"}
L = {canon[k]: v for k, v in kind.items() if k in canon}
for labs, k in re.findall(r'\|\s*((?:"[^"]+"\s*\|?\s*)+)-> Some Provider_kind\.([A-Za-z_]+)', src):
    L.update({l: kind[k] for l in re.findall(r'"([^"]+)"', labs)})
for labs, p in re.findall(r'\|\s*((?:"[^"]+"\s*\|?\s*)+)->\s*Some ([a-z0-9_]+_capabilities)', src):
    L.update({l: p for l in re.findall(r'"([^"]+)"', labs)})

cat = tomllib.load(open("packages/agent_core/models.toml", "rb"))
prov = {p["id"].lower(): p for p in cat["providers"]}
def label(r):  # row base, then the provider's capabilities_base
    return r.get("base") or prov.get((r.get("provider_name") or "").lower(), {}).get("capabilities_base")
KEY = {"reasoning_replay": "reasoning_replay_override"}
SKIP = ("supported_models", "serving_constraint")

rows, provs = cat["models"], cat["providers"]
print(f"\n[models.toml] rows {len(rows)} | with base {sum('base' in r for r in rows)} | provider-scoped {sum('provider_name' in r for r in rows)} | providers {len(provs)}"
      f" | providers with capabilities_base {sum('capabilities_base' in p for p in provs)}")
pairs, lim, par, stated = 0, Counter(), Counter(), defaultdict(Counter)
for r in rows:
    p = L[label(r)]; st = {KEY.get(k, k) for k in r}
    pairs += sum(1 for f in D if f not in st and f not in SKIP and P[p][f] != D[f])
    for f in ("max_context_tokens", "max_output_tokens"):
        if f in r: stated[(p, f)][r[f]] += 1
        elif P[p][f] != "None": lim[(f, p, P[p][f])] += 1
    par[(p, "stated" if "supports_parallel_tool_calls" in r else "inherited",
         r.get("supports_parallel_tool_calls", P[p]["supports_parallel_tool_calls"]))] += 1
print("  (row, field) pairs inheriting a preset value that differs from default_capabilities:", pairs)
print("  rows inheriting at least one such value:", sum(1 for r in rows if any(
    f not in {KEY.get(k, k) for k in r} and f not in SKIP and P[L[label(r)]][f] != D[f] for f in D)))
for k, v in sorted(lim.items()): print("  inherited limit", k, v)
for k, v in sorted(par.items(), key=lambda x: -x[1]): print("  parallel", k, v)
for k, v in sorted(stated.items()):
    if P[k[0]][k[1]] != "None": print("  stated", k, "preset", P[k[0]][k[1]], dict(v.most_common()))
oc = [r for r in rows if (r.get("provider_name") or "").lower() == "ollama_cloud"]
print("  rows scoped to ollama_cloud", len(oc), "| stating thinking_control_format", sum("thinking_control_format" in r for r in oc),
      "| stating accepted_reasoning_efforts", sum("accepted_reasoning_efforts" in r for r in oc))

def prod_lines(path):  # lines outside let%test blocks and [@@@coverage off] tails
    intest = cov = False
    for i, l in enumerate(strip(open(path).read()).split("\n"), 1):
        cov = cov or l.startswith("[@@@coverage off]")
        intest = intest or bool(re.match(r"let%(test|expect_test)", l))
        if not (intest or cov): yield i, l
        if intest and l.startswith(";;"): intest = False
ids = re.compile(r'"(claude|gpt|glm|gemini|kimi|deepseek|qwen|llama|mistral|minimax|o[1-4]|grok|gemma|nemotron|cogview|mimo)[-.:0-9][^"]*"', re.I)
proto = re.compile(r'"(/v1/messages[^"]*|/chat/completions|/responses|/api/chat|x-api-key|x-goog-api-key|anthropic-version|Authorization)"')
lib = sorted(glob.glob("packages/agent_core/lib/**/*.ml", recursive=True))
hits = [(f, i, m.group(0)) for f in lib for i, l in prod_lines(f) for m in ids.finditer(l)]
print("\nmodel-id-shaped literals outside inline tests:", len(hits))
for h in hits: print("  ", *h)
ph = [(f, i, m.group(1)) for f in lib for i, l in prod_lines(f) for m in proto.finditer(l)]
print("protocol literals outside inline tests:", len(ph), "in", len({f for f, _, _ in ph}), "files")

names = r"(?:default|anthropic|kimi|openai_compat_chat|openai_compat_chat_extended|mimo|provider_l|ollama|ollama_cloud|ollama_cloud_v1|glm|gemini)_capabilities"
files = subprocess.run(["rg", "-l", names + "|capabilities_for_provider_label|capabilities_of_kind", "--type", "ocaml", "test", "packages/agent_core/test"], capture_output=True, text=True).stdout.split()
pin, fx = [], []
for f in sorted(files):
    T = open(f).read().split("\n"); hit = False
    for i, l in enumerate(T):
        m = re.search(r"let\s+(\w+)\s*=\s*(?:Llm_provider\.)?(?:Capabilities|Caps)\.(" + names + r")\s*in", l)
        win = "\n".join(T[i+1:i+15])
        if m and (re.search(r"(check|assert|Alcotest)[^\n]*\b" + m.group(1) + r"\.", win) or re.search(r"\b" + m.group(1) + r"\.[a-z_]+\s*=", win)): hit = True
        if re.search(r"(?:Capabilities|Caps)\.(" + names + r")\s*\.\s*[a-z_]+", l): hit = True
        if re.search(r'(capabilities_for_provider_label|capabilities_of_kind)\s+(?:"|\(?(?:Llm_provider\.)?Provider_kind)', l): hit = True
    (pin if hit else fx).append(f)
print("test files asserting a preset field or label lookup:", len(pin), pin)
print("test files using a preset only as fixture base/argument:", len(fx))

def assigned_by_chain(n):  # fields some non-default preset in n's chain assigns explicitly
    out = set()
    while n and n != "default_capabilities":
        b, f = own[n]; out |= set(f); n = b
    return out
tot = Counter()
for r in rows:
    p = L[label(r)]; st = {KEY.get(k, k) for k in r}; ch = assigned_by_chain(p)
    for f in D:
        if f in st or f in SKIP: continue
        if P[p][f] != D[f]: tot["differs from default"] += 1
        elif f in ch: tot["preset assigns the default value explicitly"] += 1
        else: tot["only default_capabilities"] += 1
print("\nunstated (row, field) pairs by origin:", dict(tot))
```

</details>

### A.2 행이 없을 때의 기본값 자리 (1.6)

```sh
rg -n 'Capabilities\.(default|anthropic|kimi|openai_compat_chat|glm|gemini|ollama)_capabilities\b|capabilities_of_kind' \
  packages/agent_core/lib/llm_provider/provider_config.ml packages/agent_core/lib/llm_provider/backend_anthropic.ml \
  packages/agent_core/lib/llm_provider/backend_openai_request.ml packages/agent_core/lib/llm_provider/complete_common.ml \
  packages/agent_core/lib/provider_runtime_binding.ml packages/agent_core/lib/llm_provider/reasoning_dialect.ml \
  packages/agent_core/lib/llm_provider/backend_ollama.ml packages/agent_core/lib/llm_provider/backend_gemini.ml \
  lib/keeper/keeper_effective_tool_surface.ml
```

인라인 테스트 줄(`reasoning_dialect.ml` 700번대 이후, `complete_common.ml` 140번대, `backend_ollama.ml:655`)을 빼면 1.6 표의 11곳이다. 라벨 기본값 자리는 `rg -n 'default_capabilities|capabilities_for_provider_label' --type ocaml -g '!**/test/**' .` 결과에서 인라인 테스트를 뺀 것이다. 1.6 의 masc `runtime_adapter.ml:545` 는 위 명령의 대상 파일 밖이라 `rg -n 'capabilities_of_kind' lib/runtime/runtime_adapter.ml` 로 따로 찾았다.

### A.3 JSON 경로의 운영 호출 (1.5, Q4)

```sh
rg -n 'Capability_manifest\.set_global|Provider_catalog\.set_global' --type ocaml lib bin packages/agent_core/lib
```

결과는 `capabilities.ml:1983`(`[@@@coverage off]` 뒤 인라인 테스트)와 `provider_registry.mli:63`(문서 주석) 두 줄이다.

### A.4 1210 사고와 40,960 (1.3)

```sh
rg -n '1210|40960|40_960' --type ocaml --type toml .
```

결과 중 이 사고와 40,960 에 관한 줄은 `models.toml:3068-3070`, `:3109-3111`, `test_model_catalog_default.ml:428-430`, `test_output_token_receipt.ml:285-286`, `test_runtime_provider_auth_headers.ml:1345`, `test_llm_provider_cov.ml:1225`, `capabilities.ml:674-679`, `keeper_vision_tool.ml:263` 이다. 나머지는 GLM 오류 코드 분류(`backend_glm.ml:71`, `test_backend_glm_coverage.ml:74`), 그 코드를 흉내 낸 테스트 응답(`test_keeper_vision_tool.ml:922`), 다른 행의 주석(`models.toml:3460`), 테마 색 값이다.

### A.5 테스트 TOML·변경 빈도 (3.g, 4.2)

```sh
rg -l 'capabilities_base|base = \\"|base=\\"' --type ocaml test packages/agent_core/test | wc -l                        # 14
rg -c 'capabilities_base|base = \\"|base=\\"' --type ocaml test packages/agent_core/test | awk -F: '{s+=$2} END {print s}'  # 56
rg -c 'let%test|let%expect_test' packages/agent_core/lib/llm_provider/capabilities.ml                                  # 59
git log e50d28963b --since=2026-09-10 --oneline -- packages/agent_core/lib/llm_provider/{capabilities,model_catalog,exact_output_catalog_binding,reasoning_dialect,provider_config}.ml packages/agent_core/models.toml | wc -l  # 23
```

### A.6 열린 PR 겹침 (4.4)

```sh
gh pr list --repo jeong-sik/masc --state open --json number,title,files --limit 200 \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d)); [print(p["number"]) for p in d if any(f["path"].startswith("packages/agent_core/lib/llm_provider/") or "models.toml" in f["path"] for f in p["files"])]'
gh pr view 36944 --repo jeong-sik/masc --json state,mergedAt,files
```

첫 명령은 2026-09-19 에 `48` 과 `37044`, `37026`, `37022`, `36969` 를 출력했다. 둘째 명령은 `MERGED`, `2026-09-17T17:06:37Z` 와 4.4 절에 적은 파일들을 돌려줬다.

### A.7 코드를 읽어 확인한 것 (실행하지 않음)

다음은 코드 읽기로만 확인했다. dune 으로 돌려 보지 않았다.

- 1.3 영수증의 `Catalog_model` 표시가 preset 값에도 붙는다는 것 (`capabilities.ml:1446-1471` → `backend_openai_request.ml:216-237`).
- 1.6 표의 kind 별 답과 `runtime_adapter.ml:537-577` 이 wire preset 에서 받는 15개 필드.
- 1.7 두 resolver 의 다섯 차이.
- 3.d R3 에서 검증이 직렬화보다 먼저 도는지 여부.
