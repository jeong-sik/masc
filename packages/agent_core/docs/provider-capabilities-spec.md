# Provider Capabilities Specification

Defines what an agent SDK needs to know about an LLM provider/model
to make correct runtime decisions.

Historical baseline from the March 2026 capability survey. Structured
output notes in this document were revalidated against official provider
docs and the current OAS serializers on 2026-04-21. GLM/Ollama thinking
wire notes were revalidated against official docs and a live Ollama Cloud
smoke on 2026-06-29.

## Historical Baseline (v0.71.0)

```ocaml
type capabilities = {
  supports_tools: bool;
  supports_tool_choice: bool;
  supports_required_tool_choice: bool;
  supports_reasoning: bool;
  supports_response_format_json: bool;
  supports_multimodal_inputs: bool;
  supports_native_streaming: bool;
  supports_top_k: bool;
  supports_min_p: bool;
}
```

8 boolean fields. No numeric limits. `supports_reasoning` conflates
4 distinct mechanisms. `supports_multimodal_inputs` conflates 3 modalities.

Current OAS code has already added many of the proposed fields in
`lib/llm_provider/capabilities.ml`. This document is still useful as a
design note, but the structured output section below is the authoritative
reference for the difference between official provider support and current
OAS wiring.

## Proposed: 3-Tier Capability Model

### Tier 1: Limits (numeric, agent crashes without these)

| Field | Type | Why |
|-------|------|-----|
| `max_context_tokens` | `int option` | Provider-declared context capacity for discovery and exact capability reporting. None = unknown. |
| `max_output_tokens` | `int option` | agent_config.max_tokens must not exceed this. Range: 8K-128K. Silent truncation if exceeded. |

Discovery fills these for local models (`ctx_size` from `/props`).
Cloud provider limits come from the validated provider/model catalog; runtime code does not
infer them from model names.

### Tier 2: Feature flags (boolean, affects agent behavior)

| Field | Current | Change | Rationale |
|-------|---------|--------|-----------|
| `supports_tools` | exists | keep | |
| `supports_tool_choice` | exists | keep | |
| `supports_required_tool_choice` | exists in code | keep separate | Required/any forced tool selection can differ from named forced tool selection. |
| `supports_named_tool_choice` | exists in code | keep separate | Named forced tool selection can differ from `required`/`any` forced selection and from mere auto/none tool choice support. |
| `supports_parallel_tool_calls` | exists | keep | Request builders derive effective `disable_parallel_tool_use` from caller intent plus provider/model capability. |
| `assistant_tool_content_format` | exists in code | keep separate | Assistant tool-call content shape (`content:null` vs `content:""`) is a provider wire-contract axis, independent from reasoning replay. |
| `supports_system_prompt` | missing | add | Most models support it, but some fine-tuned/distilled variants do not. Agent must fold system into first user message. |
| `supports_reasoning` | exists | **split into 4** | See Thinking Taxonomy below. |
| `supports_extended_thinking` | missing | add | budget_tokens control. Claude, Gemini, GPT-5.4. |
| `supports_think_tool` | missing | add | Anthropic-only. Mid-reasoning pause between tool calls. |
| `supports_adaptive_reasoning` | missing | add | Model auto-selects depth. Opus 4.6, Gemini 3 dynamic. |
| `supports_reasoning_budget` | missing | add | budget_tokens (Anthropic), reasoning_effort (OpenAI), thinking_level (Gemini). |
| `accepted_reasoning_efforts` | exists in code | keep separate | Optional model-specific subset of canonical effort values. Do not infer this from `supports_reasoning_budget`; omit unless provider docs or live evidence confirm the accepted values. |
| `thinking_control_format` / `preserve_thinking_control_format` | exists in code | keep separate | Enable/depth wire shape and historical reasoning replay wire shape are independent axes. |
| `supports_structured_output` | exists in code | keep, tighten semantics | Use only for provider-native schema-constrained output APIs. Do not use it for JSON mode or "prompt with schema text + app-side validator" patterns. |
| `supports_response_format_json` | exists in code | keep, separate from schema guarantee | JSON mode means "return valid JSON" only. It is not a subset of native schema support and still requires caller-side shape validation. |
| `supports_caching` | missing | add | Prompt caching: Anthropic (90% savings), OpenAI, Gemini, DeepSeek. |
| `supports_computer_use` | missing | add | Claude, GPT-5.4 native. New tool category. |
| `supports_code_execution` | missing | add | Gemini built-in, OpenAI code_interpreter. Server-side sandbox. |
| `supports_native_streaming` | exists | keep | |
| `supports_multimodal_inputs` | exists | **split into 3** | See Multimodal Taxonomy below. |
| `supports_image_input` | missing | add | Most models except DeepSeek, Cohere. |
| `supports_audio_input` | missing | add | Gemini only (native audio tokens). |
| `supports_video_input` | missing | add | Gemini, Qwen 3.5 large. |
| `supports_top_k` | exists | keep | |
| `supports_min_p` | exists | keep | |

### Tier 3: Protocol (how to talk to the provider)

Already covered by `Provider_config.provider_kind` and
`Provider_config.request_path`.
Consider adding:

| Field | Rationale |
|-------|-----------|
| `Openai_responses` request_kind | OpenAI Responses API: server-side state, built-in tools, remote MCP. Distinct from chat completions. |
| `supports_remote_mcp` | OpenAI Responses API passes MCP servers as API parameters. |

## Structured Output Semantics (updated 2026-05-05)

Use two layers when discussing structured output support:

- Official provider capability: what the provider's documented API can do.
- Current OAS wiring: what the current serializer path actually sends on
  the wire today.

Semantic contract:

- `supports_response_format_json` — the provider can be asked to return
  syntactically valid JSON. The caller must still validate the shape.
- `supports_structured_output` — the provider exposes a native request
  field for schema-constrained output, so the schema is enforced by the
  provider rather than only by prompt instructions or app-side retries.

The two flags are related but not interchangeable:

- OpenAI, Gemini, Anthropic, and Ollama officially support both JSON mode
  and native schema-constrained output.
- GLM's current official docs describe JSON mode via
  `response_format = {"type":"json_object"}` plus prompt/schema guidance,
  but do not document a separate native JSON-schema request field.
- Generic OpenAI-compatible servers must be treated as host-specific. Do
  not infer native schema support from wire compatibility alone.

### Structured Output: Official Support vs Current OAS Wiring

| Provider | Official API surface | Guarantee level | Current OAS wiring | Note / risk |
|----------|----------------------|-----------------|--------------------|-------------|
| OpenAI | `response_format: {type: "json_schema", ...}` plus JSON mode `json_object` | Native schema guarantee + JSON mode | `backend_openai.ml` emits `json_schema` for `JsonSchema _` and `json_object` for `JsonMode` | OAS accepts native schema when both the model capability and concrete endpoint declaration pass `Provider_config.validate_output_schema_request`. |
| Gemini | `generationConfig.responseMimeType = "application/json"` plus `responseJsonSchema` / `responseSchema` | Native schema guarantee + JSON mode | `backend_gemini.ml` emits `responseMimeType` plus `responseJsonSchema` for `JsonSchema _`; `JsonMode` keeps `responseMimeType` only | OAS uses `responseJsonSchema`; other documented field names remain provider aliases. |
| Anthropic | `output_config.format` for JSON outputs; strict tool use is separate | Native schema guarantee for JSON outputs; strict tool use validates tool names and inputs, not assistant text shape | `backend_anthropic.ml` emits `output_config.format`; `lib/structured.ml` direct extraction uses native schema output | Strict tool use remains separate; do not describe Anthropic structured output as "tool-use only". |
| Ollama | `/api/chat` `format` accepts `"json"` or a JSON schema | JSON mode or native schema guarantee, depending on `format` | `backend_ollama.ml` emits `/api/chat format` as `"json"` or a JSON schema | Native schema still depends on the target Ollama server honoring `format`. |
| DashScope (Qwen) | `response_format: {type: "json_schema", "json_schema": {...}}` plus JSON mode `json_object` on the OpenAI-compatible endpoint (`dashscope-intl.aliyuncs.com/compatible-mode/v1`) | Native schema guarantee + JSON mode for Qwen3 series and newer models | OAS forwards `response_format = JsonSchema _` via `backend_openai.ml`; `validate_output_schema_request` accepts `DashScope` kind unconditionally without per-model capability check | All Qwen3 / qwen-max / qwen-turbo models support this on the OpenAI-compat endpoint. Ref: DashScope structured output guide — checked 2026-05-05. |
| GLM | `response_format = {"type":"json_object"}` plus prompt/schema-in-text guidance | JSON mode only in the current official docs | OAS keeps GLM on the OpenAI-style `json_object` path and rejects `response_format = JsonSchema _` up front | Keep caller-side validation; do not treat this as provider-native schema enforcement. |
| Generic OpenAI-compatible / llama.cpp | Varies by server, release, and host integration | Host-specific; do not assume schema support | OAS rejects native schema by default for generic OpenAI-compatible hosts; verified provider/runtime catalog entries may declare endpoint support explicitly | OpenAI-compatible wire shape is not enough evidence for native schema support. |

## Thinking Taxonomy

`supports_reasoning: bool` is insufficient. 2025-2026 models have 4 distinct mechanisms:

| Mechanism | When | Control | Models |
|-----------|------|---------|--------|
| Extended thinking | Before response | `budget_tokens` | Claude, Gemini, GPT-5.4 |
| Think tool | Between tool calls | Declared as tool | Claude only |
| Adaptive reasoning | Automatic | None (model decides) | Opus 4.6, Gemini 3 |
| Interleaved thinking | Mixed with tool calls | Beta header | Claude only |

Proposal: keep `supports_reasoning` as the union (any of the above),
add specific flags for SDK features that depend on the distinction.

Minimum viable split:
- `supports_extended_thinking` — enables `thinking_budget` in agent config
- `supports_reasoning_budget` — enables cost-aware thinking control
- `accepted_reasoning_efforts` — constrains which canonical effort values may be serialized for a model
- `thinking_control_format` — request-time enable/depth wire shape
- `preserve_thinking_control_format` — historical reasoning replay/preserve wire shape

### GLM / Z.AI vs Ollama-hosted Thinking

Do not derive the thinking wire shape from the model family name alone. GLM
served by the Z.AI API and a GLM-named model served through Ollama Cloud are
different provider contracts.

| Surface | Request control | Historical reasoning replay | Response / stream reasoning | Tool / structured notes |
|---------|-----------------|-----------------------------|-----------------------------|-------------------------|
| Z.AI standard API / OpenAI-compatible `api.z.ai/api/paas/v4` | `thinking: {type, clear_thinking}`; GLM-5.2/5.1/5/4.7 thinking defaults on, disable with `type=disabled` | Preserved Thinking is off by default on the standard API; enable by sending `clear_thinking=false` and replay unmodified `reasoning_content` in the original sequence | Chat/stream deltas use `reasoning_content` for the thinking side channel | `tool_choice` only supports `auto`; streaming tool calls use Z.AI `tool_stream=true`; structured output docs describe JSON mode `response_format={"type":"json_object"}` plus caller-side/schema validation |
| Z.AI Coding Plan endpoint | Same GLM `thinking` object | Preserved Thinking is enabled by default according to Z.AI docs | Same Z.AI `reasoning_content` channel | Treat endpoint defaults as provider/endpoint config, not model-family inference |
| Ollama native `/api/chat` or `/api/generate`, including Ollama Cloud `https://ollama.com/api/chat` GLM models | `think` bool/level on the request; OAS records this as `ollama_think` | No Z.AI `clear_thinking` contract and no `reasoning_content` replay field | Native response uses `message.thinking` separate from `message.content`; streaming interleaves thinking chunks before answer chunks | Do not send Z.AI `thinking`, `clear_thinking`, `tool_stream`, or historical `reasoning_content` fields to native Ollama |

GLM-5.2's model page is a capability overview: 1M context, 128K output,
thinking mode, streaming output, function calling, context caching,
structured output, and MCP. It is not itself the wire contract for every
surface hosting a GLM-named model. Use the per-capability Z.AI docs for the
Z.AI API contract, and Ollama docs/live probes for Ollama native contract.

## Multimodal Taxonomy

`supports_multimodal_inputs: bool` conflates 3 modalities with different
availability:

| Modality | Models |
|----------|--------|
| Image | Claude, GPT, Gemini, Qwen 3.5 large, Llama 4, Mistral, Grok |
| Audio | Gemini only (native tokens) |
| Video | Gemini, Qwen 3.5 large only |

Minimum viable split: `supports_image_input`, keep `supports_multimodal_inputs`
as the union. Audio/video can be added later.

## Model Capability Matrix (reference)

Structured column note: values below describe official provider capability,
not necessarily current OAS serializer wiring. See the table above for the
runtime distinction.

| Model | ctx | out | tools | parallel | thinking | structured | vision | cache |
|-------|-----|-----|-------|----------|----------|------------|--------|-------|
| Claude Opus 4.6 | 1M | 128K | Y | Y | adaptive | schema | Y | Y |
| Claude Sonnet 4.6 | 1M | 64K | Y | Y | extended | schema | Y | Y |
| GPT-5.4 | 1.05M | 128K | Y | Y | Y | schema | Y | Y |
| Gemini 3.1 Pro | 1M | 65K | Y | Y | dynamic | schema | Y+A+V | Y |
| Gemini 3 Flash | 1M | 64K | Y | Y | dynamic | schema | Y+A+V | Y |
| Qwen 3.5 (397B) | 262K | ? | Y | Y | Y | Y | Y+V | cloud |
| Qwen 3.5-35B | 262K | ? | Y | Y | Y | Y | N | N |
| Llama 4 Scout | 10M | ? | Y | ? | N | platform | Y | N |
| DeepSeek V3.2 | 128K | 8K | Y | ? | Y | JSON only | N | Y |
| DeepSeek R1 | 128K | 8K | **N** | N | CoT | N | N | Y |
| Mistral Large 3 | 260K | ? | Y | Y | N | Y | Y | Y |
| Mistral Small 4 | 256K | ? | Y | Y | Y | Y | Y | Y |
| Cohere Command A | 256K | 32K | Y | Y | N | Y | N | ? |
| Grok 4 | 2M | ? | Y | Y | Y | Y | limited | Y |
| GLM-5 | 200K | 128K | Y | ? | Y | JSON only | ? | ? |

## Implementation Plan

### Phase 1: Numeric limits + critical booleans
- Add `max_context_tokens`, `max_output_tokens` to capabilities
- Add `supports_parallel_tool_calls`, `supports_system_prompt`
- Add lookup table for known models (keyed by model_id prefix)
- Wire Discovery.ctx_size into capabilities

### Phase 2: Thinking split + structured output
- Split `supports_reasoning` → keep as union + add `supports_extended_thinking`
- Keep `supports_structured_output` and `supports_response_format_json` as distinct contracts
- Wire native schema request paths only where the official provider API exposes them
- Keep JSON mode + caller-side validation for providers whose current official docs stop at `json_object`
- Add `supports_caching`
- Add `supports_reasoning_budget`

### Phase 3: New modalities
- Add `supports_computer_use`, `supports_code_execution`
- Split multimodal → `supports_image_input` (keep union)

### Phase 4: Protocol evolution
- Add `Openai_responses` request_kind
- Add `supports_remote_mcp`

## Sources

Structured output claims in this pass were revalidated against official
docs on 2026-04-21. Other rows in the broader matrix remain background
reference from the March 2026 survey unless otherwise noted.

- [근거] OpenAI Structured Outputs: https://platform.openai.com/docs/guides/structured-outputs — checked 2026-04-21 — High
- [근거] Gemini Structured Outputs: https://ai.google.dev/gemini-api/docs/structured-output — checked 2026-04-21 — High
- [근거] Anthropic Structured Outputs: https://platform.claude.com/docs/en/build-with-claude/structured-outputs — checked 2026-04-21 — High
- [근거] Ollama Structured Outputs: https://docs.ollama.com/capabilities/structured-outputs — checked 2026-04-21 — High
- [근거] Ollama `/api/chat` format field: https://docs.ollama.com/api/chat — checked 2026-04-21 — High
- [근거] GLM Structured Output overview: https://docs.z.ai/guides/capabilities/struct-output — checked 2026-04-21 — High
- [근거] DashScope (Qwen) Structured Output / `response_format.json_schema` on OpenAI-compatible endpoint: https://www.alibabacloud.com/help/en/model-studio/structured-output — checked 2026-05-05 — High
- [근거] GLM-5.2 model overview: https://docs.z.ai/guides/llm/glm-5.2 — checked 2026-06-29 — High
- [근거] Z.AI GLM thinking mode and preserved thinking: https://docs.z.ai/guides/capabilities/thinking-mode — checked 2026-06-29 — High
- [근거] Z.AI function calling / `tool_choice=auto`: https://docs.z.ai/guides/capabilities/function-calling — checked 2026-06-29 — High
- [근거] Z.AI streaming tool calls / `tool_stream=true`: https://docs.z.ai/guides/capabilities/stream-tool — checked 2026-06-29 — High
- [근거] Ollama thinking / `think` and `message.thinking`: https://docs.ollama.com/capabilities/thinking — checked 2026-06-29 — High
- Qwen 3.5 blog (qwen.ai)
- Meta Llama 4 (llama.com)
- DeepSeek API docs (api-docs.deepseek.com)
- Mistral docs (docs.mistral.ai)
- Cohere docs (docs.cohere.com)
- xAI Grok docs (docs.x.ai)
- MCP specification 2025-11-25
- arxiv: SimpleTool (2603.00030), SelfBudgeter (2505.11274), Agent Skills (2602.12430)

Structured output section revalidated: 2026-05-05.
Full matrix baseline: 2026-03-20.
