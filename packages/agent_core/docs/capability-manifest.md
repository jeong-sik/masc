# Capability Manifest

agent_core supports an **external JSON capability manifest** that lets operators and
model deployers describe the capabilities of custom, quantized, or future
model variants without requiring an agent_core code change.

Provider connection metadata is handled separately by
[`docs/provider-catalog.md`](provider-catalog.md). Use the provider catalog for
endpoint/auth/transport/default-model facts, and use this capability manifest
for model-specific feature and limit facts.

## Why

`Capabilities.for_model_id` resolves model facts from the model catalog first,
then from the capability manifest. The manifest layer is still useful for
custom deployments and local variants, but it cannot override an authoritative
catalog row for the same exact model ID.

## Priority

```
Explicit model catalog override or embedded agent_core model catalog row (exact match)
    ↓ miss
Explicitly installed manifest entry (exact model ID, ASCII case-insensitive)
    ↓ miss
No declaration (`Capabilities.for_model_id` returns `None`)
```

## Quick Start

Create `~/.config/agent_core/caps.json` (or any path):

```json
{
  "schema_version": 2,
  "models": [
    {
      "model_id": "my-llama-q4",
      "base": "openai_chat",
      "max_context_tokens": 131072,
      "supports_tools": true,
      "supports_top_k": true,
      "supports_min_p": true
    }
  ]
}
```

Load and install it during application bootstrap:

```ocaml
let manifest =
  match Capability_manifest.load_file "/home/app/.config/agent_core/caps.json" with
  | Ok manifest -> manifest
  | Error message -> failwith message
in
Capability_manifest.set_global manifest
```

The exact model `my-llama-q4` (ASCII case-insensitive) can use this declaration
when no model catalog row matches. Other release or quantization IDs need their
own explicit declarations.

Installation makes the manifest available to the capability lookup APIs shown
below. Provider-bound request resolution has its own authority contract:
declared providers and anonymous OpenAI-compatible requests do not borrow the
global manifest. Installing it alone does not change those request policies.
Custom deployments can apply a validated entry explicitly through their
provider configuration, or declare the exact model with its provider in the model catalog.

## Schema Reference

See [`docs/example-capability-manifest.json`](example-capability-manifest.json)
and `lib/llm_provider/capability_manifest.mli` for the authoritative schema contract.

### Top-level

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schema_version` | integer (must be `2`) | ✅ | Version discriminator. |
| `models` | array of entries | ✅ | Explicit declarations; duplicate normalized IDs are rejected and order does not affect lookup. |

### Model entry

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `model_id` | string | — | **Required.** Exact model ID; ASCII case-insensitive equality, with no family or separator fallback. |
| `base` | string | `default_capabilities` | Provider preset. See [Base presets](#base-presets) below. |
| `max_context_tokens` | integer | from base | Context window size in tokens. |
| `max_output_tokens` | integer | from base | Maximum output tokens. |
| `supports_tools` | bool | from base | Tool/function calling. |
| `supports_tool_choice` | bool | from base | Forced tool selection. |
| `supports_required_tool_choice` | bool | from base | Required/any forced tool selection. |
| `supports_named_tool_choice` | bool | from base | Named forced tool selection. |
| `supports_parallel_tool_calls` | bool | from base | Multiple tool calls per turn. |
| `assistant_tool_content_format` | string | from base | Wire shape for assistant messages with tool calls and no visible text. Accepted values: `null`, `empty_string`. |
| `supports_assistant_prefill` | bool | from base | Whether Anthropic Messages wire accepts a final assistant continuation prefill (e.g. `false` for Haiku 5.5). |
| `supports_reasoning` | bool | from base | Any reasoning capability (union). |
| `accepted_reasoning_efforts` | string[] | from base | Optional model-specific subset of canonical reasoning effort values. Accepted values: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, `ultra`. Omit unless verified for that model. |
| `supports_response_format_json` | bool | from base | JSON mode (valid JSON, no schema). |
| `supports_structured_output` | bool | from base | Provider-native schema output. |
| `supports_multimodal_inputs` | bool | from base | Any non-text input (union). |
| `supports_image_input` | bool | from base | Image inputs. |
| `supports_audio_input` | bool | from base | Audio inputs (native tokens). |
| `supports_video_input` | bool | from base | Video inputs. |
| `supports_document_input` | bool | from base | Document inputs (e.g. PDF). Not implied by `supports_image_input`: a row that omits it has its documents rejected at serialization rather than relabelled as images. |
| `modality_priority` | string | from base | Multimodal block ordering applied before serialization. Accepted values: `preserve_input_order` (aliases `preserve-input-order`, `preserve`), `visual_first` (alias `visual-first`). |
| `supports_native_streaming` | bool | from base | SSE streaming. |
| `supports_system_prompt` | bool | from base | System prompt field. |
| `supports_prompt_caching` | bool | from base | Explicit cache breakpoints. |
| `supports_top_k` | bool | from base | top\_k sampling parameter. |
| `supports_min_p` | bool | from base | min\_p sampling parameter. |
| `supports_seed` | bool | from base | Deterministic seed. |
| `thinking_control_format` | string | from base | Thinking enable/depth wire control. Accepted values: `none`, `thinking_object`, `thinking_object_adaptive`, `thinking_object_only`, `chat_template_kwargs`, `chat_template_token`, `ollama_think`, `reasoning_effort`. |
| `thinking_control_token` | string | absent | Exact chat-template token used when `thinking_control_format = "chat_template_token"`; blank values and leading/trailing whitespace are rejected. |
| `preserve_thinking_control_format` | string | from base | Historical reasoning replay/preserve wire control. Accepted values: `none`, `thinking_object_keep_all`, `chat_template_kwargs_preserve_thinking`, `always_preserved`, `thinking_object_clear_thinking`. |
| `reasoning_output_format` | string | from base | Request-side reasoning output split control. Accepted values: `none`, `split_reasoning_fields`. |
| `reasoning_streaming_format` | string | from base | Streaming reasoning parser format (`default`, `none`, `template_parser`, `delta:<field>`, `delta_details:<field>`). |
| `reasoning_replay` | string | `default` | Optional multi-turn reasoning replay override. Accepted values: `default`, `no_replay`, `drop_without_tool`, `latest_user_turn_tool_calls`, `preserve_always`, `preserve_responses_text`. The last option admits plaintext only on the Responses transport; it leaves other transports at their default and does not certify an endpoint. |
| `emits_usage_tokens` | bool | from base | Whether the standard response carries usage tokens (`input_tokens`/`output_tokens`). |
| `supported_models` | string[] | from base | Exact client-side model allow-list. Must be non-empty; blank, padded, or duplicate ids are rejected. |

Unknown fields and unknown enum values are rejected. Additive schema changes
must update the parser and this schema together.

### Base presets

The `base` field names a provider preset from
`Capabilities.capabilities_for_provider_label`.  When `base` is absent, agent_core uses
`default_capabilities`; undeclared fields keep that base's values.  Unrecognised `base` values
are rejected when the manifest is parsed.

| Label | Description |
|-------|-------------|
| `anthropic`, `claude` | Claude (1M ctx, extended thinking, caching) |
| `gemini` | Gemini (1M ctx, audio/video, code execution) |
| `glm`, `zhipu`, `glm-coding` | GLM / ZhipuAI |
| `kimi` | Kimi (262K ctx, reasoning) |
| `openai_compat` | OpenAI-compatible base preset |
| `ollama` | Ollama local server |
| `openai_chat` | OpenAI-compatible chat completions; declares no context window (per-model rows or the caller declare it) |
| `openai`, `openai_compat_chat_extended` | OpenAI-compatible aliases |
| `openai_chat_extended` | OpenAI GPT with reasoning + top\_k/min\_p |
| `ollama_cloud` | Ollama Cloud native `/api/chat`; parsed reasoning may be final visible text |
| `xai`, `mistral`, `cohere`, `mimo`, `nvidia` | Hosted provider presets |

## OCaml API

### Direct manifest lookup

```ocaml
(* Load a manifest from a file *)
let manifest = Capability_manifest.load_file "caps.json" |> Result.get_ok

(* Look up a specific model *)
let caps = Capabilities.for_model_id_with_manifest manifest "my-llama-q4"
```

### Process-wide manifest

```ocaml
let manifest = Capability_manifest.load_file "caps.json" |> Result.get_ok in
Capability_manifest.set_global manifest;

(* for_model_id checks the embedded/explicit model catalog first, then this manifest *)
let caps = Capabilities.for_model_id "my-llama-q4"
```

### Apply a manifest entry directly

```ocaml
let manifest =
  Capability_manifest.of_json (Yojson.Safe.from_string
    {|{"schema_version":2,"models":[{"model_id":"my-model","base":"openai_chat","max_context_tokens":65536,"supports_tools":true}]}|})
  |> Result.get_ok
in
let id = Model_identifiers.Model_id.of_string_exn "my-model" in
let caps =
  match Capability_manifest.lookup manifest id with
  | Some entry -> Capabilities.apply_manifest_entry entry
  | None -> invalid_arg "model is not declared"

```

## Bundling with a Model Deployment

A deployment can bundle `caps.json` alongside model files. The embedding
application loads it for its explicit capability lookup or applies the parsed
capabilities to its request configuration. Installing globally only affects
lookup paths that admit manifest authority:

```ocaml
let manifest = Capability_manifest.load_file "/models/caps.json" |> Result.get_ok in
Capability_manifest.set_global manifest
```

## Notes

- Schema version 2 requires `model_id` on every entry and an explicit `models`
  list at the root. `models: []` deliberately declares no overrides. Older
  versions and `id_prefix` fields are rejected rather than converted.
- Lookup uses the exact model ID with ASCII case-insensitive equality. Unknown
  variants do not inherit a declaration. Every served quantization or release
  ID needs its own entry. Duplicate normalized IDs are rejected; declaration
  order cannot change which entry an exact model receives.
- agent_core never discovers a manifest from the process environment. File selection,
  reload policy, and error handling belong to the embedding application.
- `load_file` returns an explicit `Result`; install only a successfully parsed
  manifest with `set_global`.
- Global `Capabilities.for_model_id` lookup keeps the model catalog primary.
  The explicit `for_model_id_with_manifest` API instead checks the supplied
  exact manifest entry first, then falls back to the catalog on a miss.
