# Capability Manifest

OAS supports an **external JSON capability manifest** that lets operators and
model deployers describe the capabilities of custom, quantized, or future
model variants without requiring an OAS code change.

Provider connection metadata is handled separately by
[`docs/provider-catalog.md`](provider-catalog.md). Use the provider catalog for
endpoint/auth/transport/default-model facts, and use this capability manifest
for model-specific feature and limit facts.

## Why

`Capabilities.for_model_id` resolves model facts from the model catalog first,
then from the capability manifest. The manifest layer is still useful for
custom deployments and local variants, but it cannot override an authoritative
catalog row for the same model prefix.

## Priority

```
Explicit model catalog override or embedded OAS model catalog row (prefix match)
    ↓ miss
Explicitly installed manifest entry (prefix match)
    ↓ miss
No declaration (`Capabilities.for_model_id` returns `None`)
```

## Quick Start

Create `~/.config/oas/caps.json` (or any path):

```json
{
  "schema_version": 1,
  "models": [
    {
      "id_prefix": "my-llama-q4",
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
  match Capability_manifest.load_file "/home/app/.config/oas/caps.json" with
  | Ok manifest -> manifest
  | Error message -> failwith message
in
Capability_manifest.set_global manifest
```

Any model whose ID starts with `my-llama-q4` (case-insensitive) will now use
these capabilities when no model catalog row matches that model prefix.

## Schema Reference

See [`docs/schemas/capability-manifest-v1.json`](schemas/capability-manifest-v1.json)
for the full JSON Schema (draft-07).

### Top-level

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schema_version` | integer (must be `1`) | ✅ | Version discriminator. |
| `models` | array of entries | ✅ | Ordered list; earlier entries win on prefix collision. |

### Model entry

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `id_prefix` | string | — | **Required.** Case-insensitive prefix matched against the model ID. |
| `base` | string | `default_capabilities` | Provider preset. See [Base presets](#base-presets) below. |
| `max_context_tokens` | integer | from base | Context window size in tokens. |
| `max_output_tokens` | integer | from base | Maximum output tokens. |
| `supports_tools` | bool | from base | Tool/function calling. |
| `supports_tool_choice` | bool | from base | Forced tool selection. |
| `supports_required_tool_choice` | bool | from base | Required/any forced tool selection. |
| `supports_named_tool_choice` | bool | from base | Named forced tool selection. |
| `supports_parallel_tool_calls` | bool | from base | Multiple tool calls per turn. |
| `assistant_tool_content_format` | string | from base | Wire shape for assistant messages with tool calls and no visible text. Accepted values: `null`, `empty_string`. |
| `supports_reasoning` | bool | from base | Any reasoning capability (union). |
| `supports_extended_thinking` | bool | from base | budget\_tokens-controlled thinking. |
| `supports_reasoning_budget` | bool | from base | Reasoning effort control. |
| `accepted_reasoning_efforts` | string[] | from base | Optional model-specific subset of canonical reasoning effort values. Accepted values: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`. Omit unless verified for that model. |
| `supports_response_format_json` | bool | from base | JSON mode (valid JSON, no schema). |
| `supports_structured_output` | bool | from base | Provider-native schema output. |
| `supports_multimodal_inputs` | bool | from base | Any non-text input (union). |
| `supports_image_input` | bool | from base | Image inputs. |
| `supports_audio_input` | bool | from base | Audio inputs (native tokens). |
| `supports_video_input` | bool | from base | Video inputs. |
| `supports_document_input` | bool | from base | Document inputs (e.g. PDF). Not implied by `supports_image_input`: a row that omits it has its documents rejected at serialization rather than relabelled as images. |
| `supports_native_streaming` | bool | from base | SSE streaming. |
| `supports_system_prompt` | bool | from base | System prompt field. |
| `supports_caching` | bool | from base | Prompt caching. |
| `supports_prompt_caching` | bool | from base | Explicit cache breakpoints. |
| `supports_top_k` | bool | from base | top\_k sampling parameter. |
| `supports_min_p` | bool | from base | min\_p sampling parameter. |
| `supports_seed` | bool | from base | Deterministic seed. |
| `supports_computer_use` | bool | from base | Computer-use tools. |
| `supports_code_execution` | bool | from base | Server-side code sandbox. |
| `thinking_control_format` | string | from base | Thinking enable/depth wire control. Accepted values: `none`, `thinking_object`, `thinking_object_adaptive`, `thinking_object_only`, `chat_template_kwargs`, `chat_template_token`, `ollama_think`, `reasoning_effort`, `enable_thinking`. |
| `thinking_control_token` | string | absent | Exact chat-template token used when `thinking_control_format = "chat_template_token"`; blank values and leading/trailing whitespace are rejected. |
| `preserve_thinking_control_format` | string | from base | Historical reasoning replay/preserve wire control. Accepted values: `none`, `thinking_object_keep_all`, `chat_template_kwargs_preserve_thinking`, `top_level_preserve_thinking`, `always_preserved`. |
| `reasoning_output_format` | string | from base | Request-side reasoning output split control. Accepted values: `none`, `split_reasoning_fields`. |
| `reasoning_replay` | string | `default` | Optional multi-turn reasoning replay override. Accepted values: `default`, `no_replay`, `drop_without_tool`, `latest_user_turn_tool_calls`, `preserve_always`. |

Unknown fields and unknown enum values are rejected. Additive schema changes
must update the parser and this schema together.

### Base presets

The `base` field names a provider preset from
`Capabilities.capabilities_for_provider_label`.  When `base` is absent, OAS uses
`default_capabilities` (all flags false, no limits).  Unrecognised `base` values
are rejected when the manifest is parsed.

| Label | Description |
|-------|-------------|
| `anthropic`, `claude` | Claude (1M ctx, extended thinking, caching) |
| `dashscope` | DashScope |
| `gemini` | Gemini (1M ctx, audio/video, code execution) |
| `glm`, `zhipu`, `glm-coding` | GLM / ZhipuAI |
| `kimi` | Kimi (262K ctx, reasoning) |
| `openai_compat` | OpenAI-compatible base preset |
| `ollama` | Ollama local server |
| `openai_chat` | OpenAI GPT (chat completions, 128K ctx) |
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
let caps = Capabilities.for_model_id_with_manifest manifest "my-llama-q4-k4"
```

### Process-wide manifest

```ocaml
let manifest = Capability_manifest.load_file "caps.json" |> Result.get_ok in
Capability_manifest.set_global manifest;

(* for_model_id checks the embedded/explicit model catalog first, then this manifest *)
let caps = Capabilities.for_model_id "my-llama-q4-k4"
```

### Apply a manifest entry directly

```ocaml
let base_label =
  match Capability_manifest.base_label_of_string "openai_chat" with
  | Ok label -> label
  | Error msg -> invalid_arg msg
in

let entry : Capability_manifest.entry =
  { id_prefix = "my-model"
  ; base_label = Some base_label
  ; max_context_tokens = Some 65536
  ; supports_tools = Some true
  ; (* all other fields: None = inherit from base *)
    supports_tool_choice = None
  ; supports_required_tool_choice = None
  ; supports_named_tool_choice = None
  ; supports_parallel_tool_calls = None
  ; (* ... *)
  }
in
let caps = Capabilities.apply_manifest_entry entry
```

## Bundling with a Model Deployment

For Ollama or llama-server deployments, place a `caps.json` alongside the
model files and have the embedding application load and install it during
bootstrap:

```ocaml
let manifest = Capability_manifest.load_file "/models/caps.json" |> Result.get_ok in
Capability_manifest.set_global manifest
```

## Notes

- Prefix matching is **first-match-wins**.  The manifest is scanned in order
  and the first entry whose `id_prefix` is a prefix of the requested model ID
  is used.  If you need priority control (e.g. a general prefix and a more
  specific one), place the more-specific entry earlier in the list.
- OAS never discovers a manifest from the process environment. File selection,
  reload policy, and error handling belong to the embedding application.
- `load_file` returns an explicit `Result`; install only a successfully parsed
  manifest with `set_global`.
- The embedded model catalog remains the primary capability source. A manifest
  supplies facts only when no model-catalog row matches.
