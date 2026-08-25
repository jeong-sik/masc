# RFC-OAS-023: Capability axis reshape — model × transport

| | |
|---|---|
| Status | Draft (skeleton) |
| Author | jeong-sik |
| Created | 2026-05-26 |
| Target | `agent_sdk` (oas) — `lib/llm_provider/`, `lib/provider.ml` |
| Supersedes (partial) | RFC-0001 vendor purge (naming policy portion) — see §7.1 |
| Supplements | RFC-OAS-018 catalog externalization (adds axis reshape on top of externalization) — see §7.2 |
| Sibling | RFC-OAS-017 (coordinator-shape leak) |
| Boundary | masc-mcp depends on `Provider_kind.t` variant names (RFC-0174~0177) — see §7.3 |

## 0. Summary

OAS capability catalog가 두 가지 동시 결함을 가지고 있다.

1. **표기 결함** — RFC-0001 후 brand가 알파벳 부호로 1:1 치환되었다 (`Anthropic → Provider_a`, `Kimi → Provider_c`, `OpenAI_compat → Provider_d_compat` 등 14×N). [feedback_vendor_brand_substitution_is_encryption_not_abstraction] 메모리(2026-05-24)의 자기 비판이 그대로 적용된다 — abstraction이 아니라 encryption.
2. **축 결함** — capability의 1차 축은 *model*인데 catalog는 *provider* 부호로 분류되어 있다. 같은 모델(`kimi-k2.6`)이 여러 provider(Moonshot direct / Ollama Turbo cloud / OpenRouter / local quantization)로 갈 수 있고, capability는 `model_caps ∩ transport_caps`의 cross-product에서 결정되는데, 지금 catalog는 두 record를 한 record로 압축하여 *둘 다*를 잃었다.

본 RFC는 두 결함을 동시에 해결한다:

- **Naming policy (hybrid)**: model 축은 brand 그대로 (`kimi-k2.6`, `claude-opus-4`, `gpt-5`), transport 축은 wire-protocol (`messages_v1`, `chat_completions_v1`, `gemini_generate_v1`, `ollama_chat_v1`).
- **Two-record capability**: `effective_caps(model_id, provider) = model_caps(model_id).applyMask(transport_caps(provider))`.

## 1. Problem

### 1.1 RFC-0001 substitution = encryption

RFC-0001은 "OAS 가 그쪽이니까 같이 폭파에 동참하자", "전체 폭파 . 어차피 레거시 지원 안할거임" 지시로 14개 brand를 알파벳 부호로 1:1 치환했다. 결과:

```
Anthropic       → Provider_a
Moonshot        → Provider_b
Kimi            → Provider_c
OpenAI_compat   → Provider_d_compat
Gemini          → Provider_f
DeepSeek        → DeepSeek
DashScope       → Provider_h
Mistral         → Provider_j
Glm/GLM         → Provider_k
Qwen            → Provider_h_3
Claude_code     → Cli_tool_d
Gemini_cli      → Cli_tool_b
Kimi_cli        → Cli_tool_c
Codex_cli       → Cli_tool_a
```

[feedback_vendor_brand_substitution_is_encryption_not_abstraction] (2026-05-24, masc-mcp RFC-0174~0177 sweep 후):

> Vendor brand → 알파벳 부호 1:1 substitution 은 abstraction 아닌 *암호화*. coupling 본질 보존 + 가독성 감소 + 매핑 테이블 외부 분산.

증상:

- 새 maintainer가 `base = "provider_d_chat"` manifest entry를 적으려면 `capabilities_for_provider_label` 매핑을 *역추적*해야 한다 ("끝말풀이").
- cascade.toml의 model id는 brand 그대로(`kimi-k2.6:cloud`, `deepseek-v4-pro:cloud`)인데 OAS catalog만 부호 — 양쪽이 만나는 모든 경계에서 매핑 테이블이 필요해진다.
- 부호의 *의미*는 코드 어디에도 명시되어 있지 않다 (`provider_d_chat`이 OpenAI chat completions wire를 가리킨다는 사실은 `backend_openai.ml` 파일명을 봐야 추정 가능).

### 1.2 Axis confusion — capability의 1차축이 model

`capabilities_for_provider_label : string -> capabilities option` 함수가 존재한다 (capabilities.ml:953). 이 함수는 provider label 단독으로 capability를 결정한다 — *모델 정보 없이*. 그러나 실제로 capability의 압도적 다수(context window, reasoning 지원, tool calling, image input, vision, audio)는 *모델 본체*의 속성이다. 같은 OpenAI chat completions wire를 통과한다고 해서 GPT-4와 GPT-5가 같은 capability를 갖지 않는다.

`for_model_id`가 이미 존재하지만 (capabilities.ml:1057), `provider.ml:288-296`의 fallback chain이 *miss 시 provider-default를 복원*함으로써 model 축의 진실성을 부정한다:

```ocaml
| OpenAICompat { base_url; _ } ->
  ...
  (match Llm_provider.Capabilities.for_model_id model_id with
   | Some caps -> caps
   | None -> default_provider_d_compat_capabilities model_id)  (* ← silent default *)
```

증상: 카탈로그에 없는 모델이 `provider_d_chat_capabilities` (reasoning=false)로 fallback → 실제 응답에 thinking block이 있어 `Thinking_returned_but_declared_unsupported` drift WARN. 이는 *catalog miss*를 *capability 사실*로 silent하게 변환한 결과.

### 1.3 Cross-product collapse — model × transport

같은 모델이 여러 provider로 갈 수 있다:

```
kimi-k2.6  →  Moonshot direct           (chat_completions_v1)
           →  Ollama Turbo cloud         (ollama_chat_v1)
           →  OpenRouter                 (chat_completions_v1, cache_control stripped)
           →  Local llama-server         (chat_completions_v1, context windowed down)
```

이들은 같은 모델이지만 *transport가 깎는 capability*가 다르다:

- Ollama Turbo: tool_choice 강제 불가, cache_control 미지원
- OpenRouter: cache_control 운반 못 함 (proxy), thinking_control_format 일부만 운반
- Local quantization: max_context_tokens가 quantization config에 의해 잘림
- Moonshot direct: 모든 모델 capability 운반 가능 (canonical)

지금 catalog는 이 cross-product를 *한 record로 압축*하고 있다 — `provider_d_chat_capabilities`는 "OpenAI 호환 chat completions wire를 통과한 어떤 가상 모델의 보수적 caps"라는 chimera. model도 transport도 아닌 중간 존재.

증상:

- 같은 `kimi-k2.6`을 다른 provider로 라우팅할 때 capability가 정확히 표현되지 않는다.
- `apply_manifest_entry`에서 `base_label` 인터페이스가 부자연스럽다 (base로 무엇을 골라야 할지 model/transport 어느 축에서 잡을지 모호).

### 1.4 Scope boundary — OAS doesn't know about consumers

본 RFC 의 *operational scope* 는 OAS 자체 의 lib/+test/+bin/ 에 한정한다. **OAS 는 자신의 consumer (masc-mcp, cascade.toml, 기타) 를 모른다** — RFC-OAS-018 §0 자매 약속의 그대로 적용 ("같은 SDK 가 'MASC 를 모른다' 와 자매 약속인 'Ollama / Qwen / Gemma / Kimi 를 모른다'").

함의:

- **권고 범위**: 본 RFC 본문이 "masc-mcp 와 동시 cross-cut PR" 같은 *consumer 측 operational 권고* 를 *하지 않는다*. consumer migration timeline 은 consumer 책임.
- **외부 evidence 인용 가능**: consumer-side 측정 (§7.3 286 callsite, §5.1 0/13 audit) 은 *evidence-only*.
- **결정 권한 분리**: SDK 의 variant 명명 / capability schema 는 OAS 의 결정. consumer 가 그 SDK 를 어느 timeline 에 받을지 / 어떤 alias 를 자기 routing 에 쓸지는 consumer 의 결정.

**PR self-check** (본 RFC 의 모든 stack PR 이 통과 의무):
1. ☐ consumer 의 *operational action* (cross-cut PR, 동시 머지, etc.) 권고 *안* 하는가?
2. ☐ consumer-side 측정이 "informational only / external evidence" 명시되었는가?
3. ☐ SDK 의 결정 만 own 하고 consumer migration timeline 은 own 하지 *않는가*?

## 2. Decision

### 2.1 Hybrid naming

| 축 | 명명 정책 | 예 |
|----|----------|----|
| **Model id** | Brand 그대로 (RFC-0001 substitution 역방향) | `kimi-k2.6`, `claude-opus-4`, `gpt-5`, `gemini-2.5-pro`, `glm-5.1`, `deepseek-v4-pro`, `qwen-3.5-35b` |
| **Transport / wire protocol** | Wire-protocol 명명 (brand 노출 없음) | `messages_v1`, `chat_completions_v1`, `gemini_generate_v1`, `ollama_chat_v1`, `glm_native_v1` |
| **Model family** (관용적 grouping) | Brand + size/version | `claude-4-family`, `gpt-5-family`, `k2-family` |

근거: capability는 model 축의 속성이고 model은 brand와 분리 불가능하다 (brand가 곧 model의 고유 식별자). transport는 wire protocol 그 자체이지 brand가 아니다 (chat completions wire는 OpenAI 외에 Ollama, OpenRouter, llama-server 등 다수가 *동일하게 구현*하므로 brand로 명명하면 잘못된다).

### 2.2 Two-record capability composition

```ocaml
(* Pseudo-code *)
type model_caps = {
  max_context_tokens : int option;
  max_output_tokens : int option;
  supports_reasoning : bool;
  supports_reasoning_budget : bool;
  supports_tools : bool;
  supports_image_input : bool;
  supports_video_input : bool;
  supports_audio_input : bool;
  ... (* 모델 본체의 속성만 *)
}

type transport_caps = {
  can_carry_cache_control : bool;
  can_carry_tool_choice : bool;
  supports_streaming : bool;
  thinking_control_format : Thinking_control_format.t;
  carries_reasoning_summary_blocks : bool;
  max_output_tokens_cap : int option;   (* provider-side quota cap *)
  ... (* wire 가 깎는 표면만 *)
}

val effective_caps : model_id:string -> provider:provider -> capabilities
(* Lookup: model_caps (brand catalog) + transport_caps (protocol catalog)
   Compose: intersection / mask. *)
```

`effective_caps`는 두 record의 *교집합*. transport가 *깎는* 표면만 transport_caps에 들어가고, 나머지는 model_caps 그대로 통과.

## 3. Architecture

### 3.1 Lookup 진입점

```
                      ┌─────────────────────────────┐
   call site ────────►│ effective_caps              │
                      │   ~model_id ~provider       │
                      └──┬───────────────────┬──────┘
                         ▼                   ▼
            ┌─────────────────────┐   ┌───────────────────────┐
            │ model_caps_for_id   │   │ transport_caps_for_   │
            │   string -> caps    │   │   provider/protocol   │
            │                     │   │                       │
            │ brand catalog       │   │ wire-protocol catalog │
            │ (manifest + static) │   │ (closed set)          │
            └─────────────────────┘   └───────────────────────┘
```

### 3.2 Unknown model 정책 — fail closed

`provider.ml:296`의 silent default fallback (`default_provider_d_compat_capabilities`)을 폐지한다. catalog miss는:

- (a) RFC-OAS-018에서 도입한 manifest layer로 *재시도* (operator escape hatch),
- (b) 그래도 miss면 `Capability_unknown { model_id }` 에러를 *큰소리로* 호출자에 전달.

이유: "가능한 모든 것의 카탈로그가 있어야 한다"는 사용자 입장에서, silent default는 *catalog의 부재를 가시화*하지 못한다. drift WARN은 사후 가시화이지 사전 차단이 아니다.

**제거 비용 정량 (Decision #5, 2026-05-26)**:

- `default_provider_d_compat_capabilities` callers in `test/`: **3 파일 (7 사이트)** (test_capabilities × 1, test_capabilities_wiring × 1, test_llm_provider_cov × 5)
- Lock 패턴: `rg "expect.*provider_d_chat|Alcotest.check.*default" test/` → **0 matches**, `rg "let%expect_test" test/` → **0 matches**
- [feedback_tests_locking_anti_pattern_behavior] 의 lock 패턴이 OAS test/ 에 *부재*

→ Decision #5 hard error 전환 비용 *예상보다 낮음*. 73 callsite migration 이 *값 expectation 깨짐 없이* 안전.

> **[DECISION NEEDED #5 — RESOLVED (권고)]** 옵션 (a) **silent default 폐지 + `Capability_unknown` hard error** 권고.

### 3.3 `capabilities_for_provider_label` 폐지

`capabilities_for_provider_label : string -> capabilities option` 함수는 의미상 model 축의 사실을 provider 축으로 *위장*시킨다. 폐지하고 다음 두 함수로 대체:

```ocaml
val transport_caps_for_protocol : Wire_protocol.t -> transport_caps
val model_family_default_caps : Model_family.t -> model_caps
  (* family-level default; per-model override는 catalog에서 *)
```

`apply_manifest_entry`의 `base_label` 인터페이스는 `Model_family.t` 또는 `Wire_protocol.t` 중 하나를 명시하도록 변경.

**의존도 측정 (Decision #3, 2026-05-26)**:

| 사이트 | callsite | 성격 |
|---|---|---|
| `capabilities.ml` | 28 | 자기 정의 + 내부 helper |
| `capabilities.mli` | 2 | signature export |
| `provider_catalog.ml` | 2 | **외부 caller — migration 대상** |
| `capability_manifest.mli` | 1 | **외부 caller — `base_label` 인터페이스** |

**실 외부 caller: 3 사이트**. 폐지 비용 *낮음*.

silent default (`default_provider_d_compat_capabilities`) 의 의존도는 *별개 큰 비용*: lib/ 60 callsite + test/ 73 callsite = **133 사이트** (Decision #5 §3.2 측정). 두 Decision (#3 함수 폐지 + #5 silent default 제거) 가 *분리 가능*.

> **[DECISION NEEDED #3 — RESOLVED (권고)]** 옵션 (a) **`capabilities_for_provider_label` 완전 폐지** 권고 (외부 caller 3 사이트 migration).

### 3.4 Per-wire-protocol `transport_caps` matrix

`lib/llm_provider/backend_*.ml` 의 wire 변환 코드를 capability 표면별로 grep 한 결과 (2026-05-26):

| Surface | `messages_v1` | `chat_completions_v1` | `gemini_generate_v1` | `ollama_chat_v1` | `glm_native_v1` |
|---|---|---|---|---|---|
| `cache_control` carriage | **4** (exclusive) | 0 | 0 | 0 | 0 |
| `tool_choice` | 8 | **57** | 2 | 1 | 0 |
| `thinking_control_format` | 2 | **39** | 1 | 8 | 7 |

핵심 관찰:

1. **Cache control 은 Anthropic 만 운반** — 다른 모든 wire 에서 0 사이트.
2. **`chat_completions_v1` 의 thinking_control_format 이 비대칭 복잡** (39 사이트) — 단일 wire 가 여러 thinking 변형 (Kimi K2.5, Qwen `enable_thinking`, OpenAI `reasoning_effort`) 동시 처리. `provider_d_chat_extended_capabilities` 가 별도 존재한 *이유* 이자 axis confusion 의 가장 선명한 증거.

`transport_caps` record schema 1차 안:

```ocaml
type thinking_wire_variant =
  | Anthropic_messages | OpenAI_o1_reasoning_effort
  | Kimi_k2_thinking_field | Qwen_enable_thinking_kwarg
  | Ollama_thinking_native | Glm_enable_thinking | None_supported

type transport_caps = {
  can_carry_cache_control : bool;
  can_carry_tool_choice : bool;
  tool_choice_strictness : [ `Required | `Suggested | `None ];
  supports_streaming : bool;
  thinking_wire : thinking_wire_variant;            (* closed sum — exhaustive match *)
  carries_reasoning_summary_blocks : bool;
  max_output_tokens_cap : int option;
  multimodal_carriage : [ `Image_url | `Image_base64 | `None ];
}
```

`thinking_wire` closed sum 으로 현행 `String.starts_with` 35-dispatcher (CLAUDE.md §Workaround Sig #2 string classifier) 일소.

## 4. Naming sweep

### 4.1 Provider_kind.t variant 복원

| RFC-0001 (현행) | RFC-OAS-023 (목표) | 축 |
|----------------|---------------------|-----|
| `Provider_a` | `Anthropic` | model brand |
| `Provider_b` | `Moonshot` | model brand |
| `Provider_c` | `Kimi` | model brand |
| `Provider_d` | `OpenAI` | model brand |
| `Provider_d_compat` | `Chat_completions_v1` | **wire protocol** (OpenAI-호환 wire를 의미하므로) |
| `Provider_f` | `Gemini` | model brand |
| `DeepSeek` | `DeepSeek` | model brand |
| `Provider_h` | `DashScope` | model brand |
| `Provider_h_3` (Qwen family) | `Qwen` | model brand |
| `Provider_j` | `Mistral` | model brand |
| `Provider_k` | `GLM` | model brand |
| `Cli_tool_a` | `Codex_cli` | tool brand |
| `Cli_tool_b` | `Gemini_cli` | tool brand |
| `Cli_tool_c` | `Kimi_cli` | tool brand |
| `Cli_tool_d` | `Claude_code_cli` | tool brand |

핵심 관찰: `Provider_d_compat`만 wire-protocol로 가는 이유 — 이 variant는 brand가 아니라 *protocol*을 의미했다 (Ollama, OpenRouter, llama-server, vLLM 모두 같은 chat completions wire를 구현). 나머지는 brand 그대로 복원.

### 4.2 함수/타입 명명 sweep

```
provider_a_capabilities             → anthropic_model_caps
provider_d_chat_capabilities        → chat_completions_v1_transport_caps + openai_model_default_caps (분리)
provider_d_chat_extended_capabilities → 폐지 (Provider_h가 wire가 아니라 model이므로 model_caps에 흡수)
provider_c_capabilities             → kimi_model_default_caps
provider_k_capabilities             → glm_model_default_caps
...
```

`provider_d_chat_extended_capabilities`의 사례가 axis confusion의 가장 선명한 증거 — "OpenAI 호환 wire의 *Qwen-3 확장*"이라는 명명 자체가 두 축을 한 record로 압축했다는 자기 진술.

### 4.3 함수/타입 명명 sweep (full mapping table)

**Model caps 함수 (brand-based)**:

| RFC-0001 (현행) | RFC-OAS-023 (목표) |
|---|---|
| `provider_a_capabilities` | `anthropic_model_caps` |
| `provider_c_capabilities` | `kimi_model_caps` |
| `provider_f_capabilities` | `gemini_model_caps` |
| `deepseek_v4_pro_capabilities` | `deepseek_v4_pro_model_caps` |
| `provider_h_3_capabilities` | `qwen_3_model_caps` |
| `provider_j_large_capabilities` | `mistral_large_model_caps` |
| `provider_k_capabilities` | `glm_model_caps` |
| `agent_llm_a_opus_4_*` | `claude_opus_4_*_model_caps` |

**Transport caps 분리 (wire-protocol based)**:

| RFC-0001 | RFC-OAS-023 |
|---|---|
| `provider_d_chat_capabilities` | `chat_completions_v1_transport_caps` + `openai_model_caps` (분리) |
| `provider_d_chat_extended_capabilities` | **폐지** — Qwen-3 부분은 `qwen_3_model_caps` 흡수 |

**파일명 rename**:

| RFC-0001 | RFC-OAS-023 |
|---|---|
| `backend_provider_a.ml/.mli` | `backend_messages_v1.ml/.mli` |
| `backend_provider_d.ml + _parse/_request/_serialize` | `backend_chat_completions_v1.ml + ...` |
| `backend_provider_f.ml` | `backend_gemini_generate_v1.ml` |
| `backend_provider_k.ml` | `backend_glm_native_v1.ml` |
| `transport_provider_d_compat.ml` | `transport_chat_completions_v1_http.ml` |
| `transport_cli_tool_[abcd].ml` | `transport_codex_cli.ml` / `_gemini_cli.ml` / `_kimi_cli.ml` / `_claude_code_cli.ml` |
| `api_provider_a.ml/.mli` | `api_anthropic.ml/.mli` |

**Error type rename**:

| RFC-0001 | RFC-OAS-023 |
|---|---|
| `provider_k_error_class` | `glm_error_class` |
| `Provider_k_quota_exceeded` | `Glm_quota_exceeded` |
| `classify_provider_k_error` | `classify_glm_error` |

위 모든 rename 은 *3-axis 동시* — (a) variant/function 정의 + (b) 파일명 + (c) caller reference. dune `--keep-going` 으로 cascading 일괄 처리 (§6.3).

## 5. Inventory

### 5.1 cascade.toml × OAS catalog 커버리지 (2026-05-26 audit)

`<MASC_BASE>/.masc/config/cascade.toml` 의 모든 `api-name` 을 OAS `Capabilities.for_model_id` 의 prefix table (capabilities.ml `String.starts_with` 30 prefixes) 과 대조한 결과:

| api-name (wire에 흐르는 그대로) | Brand | RFC-0001 cipher | OAS prefix가 기대하는 형태 | Match |
|---|---|---|---|---|
| `gpt-5.3-codex-spark` | OpenAI | Provider_d | `model-d-5*` | **MISS** |
| `gpt-4.1` | OpenAI | Provider_d | `model-d-4.1*` | **MISS** |
| `glm-5.1` | GLM | Provider_k | (no `provider_k-*` prefix) | **MISS** |
| `glm-5-turbo` | GLM | Provider_k | — | **MISS** |
| `glm-5` | GLM | Provider_k | — | **MISS** |
| `gemma4:e2b` | Gemma | legacy Provider_f | `google/gemma-4*` | **MISS** |
| `glm-5.1:cloud` | GLM | Provider_k | — | **MISS** |
| `qwen3.5` | Qwen | Provider_h_3 | `provider_h-3*` | **MISS** |
| `kimi-k2.6:cloud` | Kimi | Provider_c | `provider_c-k2*` | **MISS** |
| `deepseek-v4-pro:cloud` | DeepSeek | DeepSeek | `deepseek-v4-pro*` | **MISS** |
| `deepseek-v4-flash:cloud` | DeepSeek | DeepSeek | `deepseek-v4-flash*` | **MISS** |
| `qwen` | Qwen | Provider_h_3 | `provider_h-3*` | **MISS** |
| `qwen-local-35b-a3b` | Qwen | Provider_h_3 | `provider_h-3*` | **MISS** |

**Hit rate: 0/13 (0%)**.

해석:

- RFC-0001 이 *source-level brand* 는 cipher 로 바꿨지만, *wire 에 들어오는 model_id 문자열* 은 brand 그대로다. cascade 가 `kimi-k2.6:cloud` 를 그대로 흘리는데 OAS catalog 의 prefix table 은 `provider_c-k2*` 를 기대 — 100% miss.
- 결과적으로 cascade.toml 의 모든 모델이 `default_provider_d_compat_capabilities` (≡ `provider_d_chat_capabilities`, reasoning=false) 보수적 default 로 fallback 중. 즉 cascade.toml 의 `[models.X.capabilities]` 블록에 사용자가 *명시적으로 적은* capability 선언이 OAS 가 보는 effective_caps 와 *전혀 일치하지 않는다*.
- drift WARN (`Thinking_returned_but_declared_unsupported`, `Tools_used_but_declared_unsupported` 등) 이 *전체 cascade 모델* 에서 발생 가능 상태. kimi-k2.6 만 본 것이 아니라 *시스템 전체* 가 catalog miss 영역에 있다.

평면 불일치 문제로서의 함의:

- catalog 에 새 entry 를 추가하는 식의 *etry-by-entry fix* 는 *원천적으로 불가능*. RFC-0001 정책상 새 entry 의 `id_prefix` 도 cipher 여야 하는데 wire 는 brand 를 그대로 흘리므로 매핑이 닫히지 않는다.
- RFC-OAS-018 catalog externalization 도 이 평면 불일치를 *해결하지 못함*. JSON manifest 로 빼내도 `id_prefix` 를 brand 로 쓸지 cipher 로 쓸지가 또 결정점이 된다.
- 즉 **RFC-OAS-023 (hybrid: model=brand 복원) 이 RFC-OAS-018 보다 *논리적으로 선행*** 한다. RFC-OAS-023 으로 catalog 의 key 평면을 wire 평면과 일치시킨 *후에* 만 RFC-OAS-018 의 externalization 이 의미 있는 데이터를 받을 수 있다.

**Runtime evidence (2026-05-26 16:42 라이브 prod log)**:

```
[2026-05-26 16:42:27] [llm_provider] [INFO] capability_observation
    model=kimi-k2.6:cloud provider=provider_d_compat
    capability_source=provider_default confidence=low
    observations=[Thinking_returned_but_declared_unsupported]
[2026-05-26 16:42:58] [llm_provider] [INFO] capability_observation
    (동일)
```

- **1분 안 2회** 동일 drift WARN — cascade 호출마다 emit. 시간당 X회 누적.
- `capability_source:"provider_default"` 라벨이 *OAS observability code 의 self-report* — catalog miss 명시. RFC merge + Phase 5 catalog 채움 후 `model_specific` 로 전환되는 게 성공 metric.
- **0/13 audit 의 runtime confirmation** — 평면 불일치가 *현 시점 prod state* 에서 가시화 진행 중. §5.2 +91% literal leak 와 함께 *비용 정량 의 두 축*.

### 5.2 RFC-OAS-018 inventory refresh

RFC-OAS-018 의 inventory (2026-05-12 측정) 를 14일 후 재측정 (2026-05-26):

| Surface | 2026-05-12 | 2026-05-26 | Δ | 해석 |
|---|---|---|---|---|
| `lib/llm_provider/` 내 model_id literal | 240 | **458** | **+91% (+218)** | **leak 가속 — 14일에 거의 2배** |
| `String.starts_with` dispatcher | 35 | 32 | -3 (-9%) | 약간 감소, string-classifier anti-pattern 잔존 |
| `Provider_kind.t` closed-sum variants | 11 | 11 | 0 | 안정 |
| `capabilities.ml` LoC | 1238 | 1537 | +24% (+299) | 같은 기간 sweep 누적 |

**핵심 관찰: model_id literal leak 이 *자가 가속*** —

- 14일 동안 +218 literal = ~15 literal/일
- RFC-0001/0018 미해결 상태에서 새 PR 들이 *literal 을 더 박는* 패턴 지속
- §5.1 의 0/13 audit + 16:42 runtime drift WARN 과 일관 — catalog 가 평면 불일치 상태라 entry-by-entry fix 동기 약함

**시급성**: 현재 추세 (15 literal/일) 가 유지되면 3개월 후 ~1800 literal 누적, 비가역화. RFC-OAS-023 + RFC-OAS-018 즉시 진행 안 하면 self-fulfilling spiral.

`capabilities.ml` LoC 1537 도 CLAUDE.md "300줄+ 분할 검토" 기준 5배 초과 — sweep 동시 sub-library 분해 (§7.2 RFC-OAS-018 supplement) 고려.

### 5.3 Phase 5 catalog 채움 draft — cascade.toml × OAS catalog 1:1 mapping

#1777 권고 (cascade alias verbatim 을 catalog key) 적용 시 Phase 5 의 *시작점 mapping*:

| cascade api-name | model_caps brand-id | 시작 draft capability |
|---|---|---|
| `gpt-5.3-codex-spark` | same | { context: 128K (cascade), tools: true } |
| `gpt-4.1` | same | { context: 1M, tools: true, reasoning: false }* |
| `glm-5.1` / `glm-5-turbo` / `glm-5` / `glm-5.1:cloud` | same | { context: 64-128K, tools: true } |
| `gemma4:e2b` | same | { context: 32K, tools: false }* |
| `qwen3.5` / `qwen` / `qwen-local-35b-a3b` | same | { context: 128K, tools: true, thinking: enable_thinking_kwarg } |
| `kimi-k2.6:cloud` | same | { context: 200K, tools: true, native_streaming: true, thinking: top-level } |
| `deepseek-v4-pro:cloud` / `deepseek-v4-flash:cloud` | same | { context: 1M / 64K, tools: true } |

`*` = vendor docs 확인 필요. **`:cloud` suffix 는 별 entry** — 동일 모델의 cloud passthrough 도 별도 model_caps (§1.3 cross-product). cascade declaration 은 4/29 모델 (14%) 만 명시 — 나머지는 vendor docs / runtime probe primary.

**Phase 5 작업 순서**:

1. Catalog skeleton (cascade alias 13 entry 의 빈 record) — RFC merge 직후
2. cascade declared capability 흡수 (4 모델)
3. Vendor docs 인용 (Anthropic / OpenAI / GLM / Kimi / DeepSeek / Qwen)
4. Runtime probe 보강 (`discovery.ml` `/props` `/slots`)
5. Drift detector 검증 (16:42 같은 WARN 0건 도달)

> Boundary: cascade.toml audit 은 *external evidence* (§1.4). Phase 5 의 catalog 채움은 *OAS 자체 결정*. mapping 은 *시작점 reference* 일 뿐.

## 6. Migration

### 6.1 Single big PR vs phased

[feedback_radical_improvement_over_diff_size] / [feedback_big_bang_refactor_preference]를 따라 *single big PR* 기본. 다만 다음 audit 의무를 PR body에 명시적으로 충족:

- [feedback_dead_export_sweep_2026_05_23_anti_pattern] — 5-prong dead-export audit (direct grep + module alias + re-export `let x = M.x` + `include Module` + paired test file)
- [feedback_module_name_grep_misses_open_bare_names] — bare function-name grep도 함께
- [feedback_partial_module_orphan_check_all_exports] — `.mli` 전체 exports 확인 후 부분 삭제 금지

대안 phased (B):

- Phase 1: `Provider_kind.t` variant rename 단독 (data 변경 없음, 이름만)
- Phase 2: `model_caps` / `transport_caps` 분리 (record 재구조화)
- Phase 3: `capabilities_for_provider_label` 폐지 + caller 수정
- Phase 4: silent default fallback 제거 + Unknown 정책 적용
- Phase 5: cascade.toml audit 기반 model catalog 채움

**Phase 1 단독 OAS 내부 size estimate (2026-05-26)**:

| Surface | Count |
|---|---|
| Total cipher callsite (`lib/+test/+bin/`) | **1159** |
| 영향 파일 | **138** |
| Paired test 파일 | **38** |

**Phase 1 dry-run 정밀화** (§6.4 참조):

- 14 cipher × 평균 ~83 caller ≈ 1162 callsite (위 측정 일관)
- 14 cipher × 4 facade layer = 56 facade 동기 변경 위치
- ~12 cipher-named 파일 rename
- paired test 38 file 각 sync
- **실 size: ~140-150 file, ~1200+ callsite, 추정 -200/+1500 line**

OAS standalone scope (§1.4) — consumer (masc-mcp 등) 영향은 *consumer 측 책임*. 286 consumer callsite (§7.3) 는 evidence-only.

> **[DECISION NEEDED #1 — RESOLVED (권고)]** **Single big PR** (OAS standalone, ~140-150 file). [feedback_radical_improvement_over_diff_size] + [feedback_big_bang_refactor_preference] 정합. 조건: §6.2 audit 5-prong 의무 + §6.3 `dune --keep-going` + `_build/` cache clear.

### 6.2 Audit obligations

각 변경마다:

```
1. rg "<old_name>" lib/ test/ bin/      # direct
2. rg "<short_function_name>" lib/      # opener-unqualified (open Module 후 bare call)
3. rg "include <Module>" lib/           # facade re-export
4. rg "module .* = <Module>" lib/       # alias
5. find . -name "test_<module>.ml"      # paired test
```

5가지 모두 0 이어야 삭제 안전. PR body에 audit 결과 인용 의무.

**외부 evidence — 유사 sweep 사고 사례 (informational only)**:

OAS 외부 codebase 에서 vendor sweep 진행 후 발생한 사고 (`gh pr list --search "dead-export OR orphan after:2026-05-20"` 결과, 2026-05-26):

| PR # | 사고 유형 |
|---|---|
| #17886 | dead-helper cascade (tool_misc_admin) |
| #17846 | partial-module orphan (operator) |
| #17945, #17952 | full-module orphan (.mli 3 exports dead) |
| #18085, #18098 | sweep aftermath cleanup |
| **#18090** | **prior sweep PRs (#18015, #18026) incorrectly removed LIVE exports → restore PR** |
| #18173 | audit tooling v3 (filename-based discovery) |
| #18308 | dashboard sweep (-2,713 lines) |

핵심 관찰:

- **#18090** — 이전 sweep PR 들이 *live export 를 잘못 삭제* → restore PR 필요. 5-prong audit (특히 `include Module` facade re-export + opener-unqualified bare names) 의 *부재* 가 직접 원인.
- **#18173** — audit tooling 이 *v3 까지 반복 진화*. 정적 grep 만으로는 *filename cipher* 못 잡음.

> Boundary: 위 PR 목록은 외부 codebase 데이터. OAS 는 그 operational state 를 own 하지 않음 (§1.4). audit 의무의 importance 보강용 *현실 세계 evidence* 인용일 뿐.

### 6.3 Test 운영 + Sweep 도구 운영 (§6.4 dry-run 발견 반영)

**Build 운영**:

- `dune build --keep-going` 으로 cascading error 일괄 수집. dune first-error halt 가 sweep cycle 길이 과도하게 늘림 (§6.4 dry-run: 1 변경 → 1 error).
- **fix-and-retry loop**: 1 cycle = `build --keep-going` → error sample N → batch fix → 재build. 5-10 cycle 수렴 예상.
- **`_build/` cache 클리어 시점**: 파일 rename / module discovery 변경 시 `rm -rf _build/` 필수.
- **Sandbox config**: `MASC_CONFIG_DIR` 등 env 의존성 없음 — OAS standalone (§1.4).

**Test fixture sync**:

- 5-prong audit #5 (paired test) 강제 적용 — alcotest case name 안 cipher 포함된 경우 (`let%test "provider_a has cache_control"`) 도 string literal 까지 sweep.

**Drift detector + CI baseline reset**:

- `detect_drift` 가 PR 직후 *오히려 더 많은 WARN emit* 가능 (silent default 제거 #1776 → catalog miss 가 hard error). Phase 5 (#1783) catalog 채움 완료 후 baseline lock.
- `bisect_ppx` coverage CI floor — rename PR 직후 coverage drift 가능, PR 시점 floor 유지 또는 임시 완화 결정.
- **Runtime evidence reset**: §5.1 의 16:42 drift WARN 같은 logging 이 *0건* 되어야 Phase 5 완료 signal.

**TLA+ spec**:

- OAS 에 capability TLA+ spec *없음* (현재 0). 새로 작성 *선택* — `thinking_wire_variant` closed-sum exhaustiveness 검증 case 로 적합 (masc-mcp `KeeperOASAdvanced.tla` 의 `BugAction` 패턴 적용 가능).

### 6.4 Phase 1 dry-run findings (2026-05-26)

본 RFC stack 작업 중 *최소 단위 변경* 으로 Phase 1 의 *실 size* 측정. variant 1개 (`Provider_a → Anthropic`) 만 `provider_kind.ml` + `provider_kind.mli` rename 후 `dune build lib/llm_provider/`:

| 발견 | 정량 | 함의 |
|---|---|---|
| **Facade 반복 declare** | `provider_kind.ml/.mli` + `provider_config.ml/.mli` 모두 *type 을 재선언* | §6.2 audit #3 (`include Module` / re-export) 의 *실증*. dead-export 안전망 *반드시* 의무 |
| **`Provider_a` reference 분포** | `lib/` 55+ 파일 (single variant 만) | §6.1 의 1159 callsite / 138 file 의 *실측 근거* (cipher 당 평균 ~83) |
| **파일명 cipher 침투** | `backend_provider_a.ml/.mli`, `api_provider_a.ml/.mli`, `transport_provider_d_compat.ml` 등 ~12 파일 | Sweep 가 *파일 시스템 rename* 까지 own. 정적 grep 만으로는 *filename cipher* 못 잡음 |
| **dune first-error halt** | 1 변경 → 1 error 만 보고 | `--keep-going` 또는 fix-and-retry loop 필수 (§6.3) |

**Sweep 패턴 권고** (Phase 1 본격 작업):

1. 14 cipher 모두 *3-axis 동시 rename*: (a) variant 정의 (양 facade) + (b) 파일명 + (c) caller reference
2. `dune --keep-going` 으로 cascading error 일괄 수집
3. 5-prong audit (§6.2) 각 prong PR body 인용
4. `rm -rf _build/` 후 fresh build

> Dry-run artifact: `.worktrees/phase1-dryrun-provider-a` (`feat/phase1-dryrun-provider-a` branch) 에 evidence 보존. 정리는 사용자 명시 신호 또는 RFC merge 후.

## 7. Relations

### 7.1 RFC-0001 vendor purge — supersede partial

RFC-0001의 **명명 정책 부분**을 *역방향으로 supersede*. 즉 RFC-0001의 14×N 부호 매핑을 표 그대로 *반대 방향으로 sweep*. RFC-0001의 다른 동기(SDK 경계 폐쇄, masc-mcp와의 일관성)는 유효하나 substitution이 abstraction이 아니라 encryption이었다는 자기 평가에 따라 폐기.

RFC-0001 status를 Draft → Withdrawn (superseded by RFC-OAS-023)로 변경.

### 7.2 RFC-OAS-018 catalog externalization — supplement

RFC-OAS-018의 4-phase plan (closed-sum dispatcher → external catalog)은 *직교* 작업이며 본 RFC와 합쳐서 진행. 단 RFC-OAS-018의 *전제* (catalog의 1차축이 provider)를 본 RFC가 *재조정* — 1차축은 model. RFC-OAS-018 §2 Decision의 catalog schema에서 `provider_id` 1차 키를 `model_id` 1차 키로 변경.

**Sequencing**:

```
RFC-OAS-023 stack merge (this RFC)
   │
   ├── Phase 1: variant + file rename sweep (§6.1 + §6.4) [Big PR ~140-150 files]
   ├── Phase 2: model_caps / transport_caps split (§3.4) [thinking_wire_variant closed-sum]
   ├── Phase 3: capabilities_for_provider_label 폐지 (§3.3) [3 caller]
   ├── Phase 4: silent default → Capability_unknown (§3.2) [73 callsite, lock 0]
   ├── Phase 5: cascade alias verbatim catalog (§5.3) [13 entry identity mapping]
   ├── (gate) drift detector 0건 + CI baseline reset
   │
   └── ─── RFC-OAS-018 진입 ────
                                  │
                                  ▼
            RFC-OAS-018 Phase 1: catalog externalization (JSON manifest)
                          [primary key 가 이미 model_id, schema 직접 적용]
            RFC-OAS-018 Phase 2: pricing 외재화
            RFC-OAS-018 Phase 3: discovery integration
            RFC-OAS-018 Phase 4: model_meta 폐지
```

**RFC-OAS-018 schema 영향**:

- `id_prefix` (capability_manifest schema) 를 *brand model_id* 기반으로 사용 (`"kimi-k2.6"`, `"claude-opus-4"`). cipher prefix 폐기.
- `base` label 은 `Wire_protocol.t` 또는 `Model_family.t` — `provider_d_chat` 같은 chimera 부호 폐지.
- JSON manifest entry 의 *transport-bound 필드* 와 *model-bound 필드* 분리 (§3.4 정합).

**가속 효과**: §5.2 의 +91% literal leak 가 RFC-OAS-018 진입 직전까지 자가 가속. Phase 1-5 sweep 이 catalog 데이터를 *brand 평면* 으로 정착시켜 RFC-OAS-018 시점 anchor 정확. 두 RFC 합쳐서 leak 곡선 *반전*.

### 7.3 masc-mcp RFC-0174~0177 boundary

masc-mcp는 OAS SDK의 `Provider_kind.t` variant 이름에 의존한다 (RFC-0174~0177 client-agnostic family에서 부호 매핑 적용). 본 RFC의 variant rename은 **breaking change**.

옵션:

- (a) masc-mcp에 *동시 PR*로 rename sweep — 두 repo cross-cut 작업.
- (b) OAS에서 `Provider_kind.t` variant alias 유지 (`Anthropic = Provider_a` deprecated alias) → masc-mcp는 점진 마이그레이션. 단 alias 자체가 cipher 잔존을 의미하므로 6.1의 phased 모드와 정합.

**masc-mcp 의존 강도 측정 (2026-05-26)** (informational only):

- `rg "Provider_kind|Provider_a\b|..." lib/ test/` in masc-mcp = **286 callsite**, 30+ 파일
- `lib/cascade/` 15 파일 의존 (라우팅 평면 cipher-bound)
- Top: `test_provider_kind_resolution.ml`(31), `test_provider_capability_matrix.ml`(18), `test_keeper_hooks_oas_telemetry.ml`(15), `cascade_runtime_candidate.ml`(11)

**Decision #2 권고 — OAS standalone**:

§1.4 boundary 적용: **OAS 는 masc-mcp 를 모름** (RFC-OAS-018 §0 자매 약속). 본 RFC 의 *operational scope* 는 OAS 자체 의 catalog/variant rename 에 한정.

- **OAS PR**: variant rename + axis reshape sweep, OAS 단독. masc-mcp 존재 *전제 안 함*.
- **masc-mcp PR**: 신 SDK variant 이름으로 286 import 마이그레이션 — **masc-mcp 측 별개 RFC/PR** 의 책임. 본 RFC 범위 밖.
- **타이밍**: OAS PR 머지 후 masc-mcp 가 consumer 로서 새 SDK 버전을 받아 자기 timeline 에. RFC body 가 cross-cut 권고 *안 함*.

이전 cross-cut PR 권고 시도는 RFC-OAS-018 자매 약속 위반 (정정 완료).

> **[DECISION NEEDED #2 — RESOLVED]** OAS standalone rename. masc-mcp consumer migration 은 별개 책임. cross-cut PR 패턴 폐기.

cascade phonebook TOML config / `<base-path>/.masc/config/cascade.toml` 영향은 *masc-mcp 측 책임* — 본 RFC 가 cross-reference 만 할 뿐 권고 안 함 (§1.4).

## 8. Non-goals

- cascade.toml과 OAS catalog 간 *자동 동기화* — OAS catalog가 진실원. cascade.toml은 routing 평면.
- Per-deployment quantization-specific capability tracking — model_caps는 *canonical model*의 사실. quantization-side cap은 transport_caps의 max_context_tokens_cap에 흡수.
- Pricing catalog (RFC-OAS-018 §pricing 별도).

## 9. Open questions / Decision points

| # | Decision | Status | 근거 sub-section |
|---|----------|--------|------------------|
| 1 | Single big PR vs phased | **RESOLVED — Big PR** | §6.1 + §6.4 |
| 2 | masc-mcp 동시 처리 | **RESOLVED — OAS standalone** | §1.4 + §7.3 |
| 3 | `capabilities_for_provider_label` | **RESOLVED — 완전 폐지** | §3.3 |
| 4 | RFC-OAS-018 작업 순서 | **RESOLVED — RFC-OAS-023 선행** | §5.2 + §7.2 |
| 5 | Unknown model 동작 | **RESOLVED — Hard error** | §3.2 |
| 6 | Model id 명명 | **RESOLVED — cascade alias verbatim** | §5.3 + §9.6 |

### 9.1 Decision #1 — Big PR

OAS 자체 1159 callsite × 138 file × 38 paired test (§6.1). dry-run 정밀화: ~140-150 file, ~1200+ callsite, -200/+1500 line (§6.4). Consumer 1명 SDK + [feedback_radical_improvement_over_diff_size] 정합. 조건: §6.2 audit 5-prong + §6.3 `dune --keep-going`.

### 9.2 Decision #2 — OAS standalone

RFC-OAS-018 §0 자매 약속 + §1.4 boundary. cross-cut PR 패턴 boundary 위반. 286 consumer callsite (§7.3) 는 evidence-only.

### 9.3 Decision #3 — 완전 폐지

외부 caller 3 사이트만 (§3.3). Decision #5 와 분리 가능 — 독립 phase.

### 9.4 Decision #4 — RFC-OAS-023 선행

14일 +91% literal leak 자가 가속 (§5.2). 0/13 audit (§5.1) + 16:42 runtime drift WARN 이 catalog externalization 의 *anchor 부재* 야기. brand 평면 정착 후에야 RFC-OAS-018 의미.

### 9.5 Decision #5 — Hard error

Test fixture lock 측정: 0건 (`Alcotest.check.*default` / `let%expect_test` 모두 0). 73 callsite migration 안전 (§3.2).

### 9.6 Decision #6 — Cascade alias verbatim

cascade api-name suffix 3 패턴 (`:cloud`, `-local-`, `:e`). 두 옵션 trade-off:

- **alias 그대로**: wire ↔ catalog key 일치, 0/13 즉시 해결, two-record model 정합, normalization layer 0
- canonical: 별도 normalization, [feedback_vendor_brand_substitution_is_encryption_not_abstraction] 회귀 위험

권고: **alias 그대로** (§5.3 mapping 이 identity function).

---

> Note: 본 RFC는 *skeleton*. §5 Inventory의 audit 결과, §6.3 Test 운영의 baseline 수치, §7.3 masc-mcp 의존 강도 측정이 차후 PR로 채워진다. Decision points는 사용자 검토 후 본문에 inline 결정.
