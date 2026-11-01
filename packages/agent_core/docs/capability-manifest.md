# Capability Manifest

agent_core supports an **external JSON capability manifest** that lets operators and
model deployers describe the capabilities of custom, quantized, or future
model variants without requiring an agent_core code change.

Provider connection metadata is handled separately by
[`docs/provider-catalog.md`](provider-catalog.md). Use the provider catalog for
endpoint/auth/transport/default-model facts, and use this capability manifest
for model-specific feature and limit facts.

## Compose one model catalog

JSON is an input format for the immutable model catalog. Parse the file and
compose it with `Model_catalog.with_model_overrides` before selecting provider
bindings or freezing requests. Capabilities, Anthropic thinking controls,
request preparation and exact-output admission then read the same catalog row.

An exact bare model identity in the JSON replaces that row's capability
fields. Undeclared fields inherit the JSON declaration's preset/default.
Pricing, cache multipliers, task, client suggestions and serving constraints
remain those of the exact previous bare row. A new model has none of that
metadata. Scoped rows retain precedence and are never replaced by a bare JSON
entry. Exact identity uses ASCII case folding; no prefix or separator expansion
is performed.

Provider declarations still own permission to use bare model rows. A declared
provider must list the exact ID in `serves_bare_models`. Anonymous native wires
can read bare rows; anonymous OpenAI-compatible endpoints cannot acquire them
from their URL. Compose first, then select a provider from the resulting
`Provider_declarations` snapshot.

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

Load and compose it during application bootstrap:

```ocaml
match Model_catalog.load_default () with
| Error detail -> report_configuration_error detail
| Ok catalog ->
  match Capability_manifest.load_file caps_path with
  | Error detail -> report_configuration_error detail
  | Ok input -> Model_catalog.set_global (Model_catalog.with_model_overrides catalog input)
```

`caps_path` and error handling belong to the embedding application. Install
only the complete successfully parsed value. An existing selected binding or
frozen request keeps its captured policy when a new catalog is installed;
new selections see the new catalog. There is no separate global manifest.

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
| `anthropic`, `claude` | Anthropic Messages preset |
| `gemini` | Gemini native preset |
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

To select a provider without changing process-global state:

```ocaml
let select catalog input provider_id =
  let catalog = Model_catalog.with_model_overrides catalog input in
  match Provider_declarations.of_catalogs ~models:(Some catalog) ~providers:None with
  | Error error -> Error (Provider_declarations.error_to_string error)
  | Ok declarations ->
    match Agent_core.Provider_runtime_binding.find_in_declarations declarations provider_id with
    | None -> Error "provider is not declared"
    | Some binding -> Ok binding
```

Convert the selected binding with `Provider_runtime_binding.to_provider_config`.
That config carries the admitted model policy. Request preparation does not
re-read the JSON input. Explicit provider JSON overlays remain a separate
provider declaration input; pass that parsed value to `of_catalogs` instead of
`None` when needed. Replacing a provider declaration cannot inherit the replaced
seed's bare-model permissions.

For read-only bare-model inspection from an explicit catalog:

```ocaml
let inspect catalog model_id =
  match Model_identifiers.Model_id.of_string model_id with
  | Error _ -> None
  | Ok id ->
    Model_catalog.lookup catalog id
    |> Option.map (Capabilities.apply_catalog_entry ~provider_entry:None ~wire:None)
```

`Capabilities.for_model_id` reads the installed model catalog for the same
inspection use. Execution selects the provider explicitly rather than deriving
provider ownership from a bare model name.

## Notes

- `schema_version = 2`, `model_id` and an explicit `models` list are required.
  Empty `models` declares no overrides. Unknown fields, wrong types, blank or
  padded identities, and duplicate normalized IDs are rejected.
- Each served quantization or release ID needs an exact declaration.
- File selection, reload policy and error handling belong to the embedding
  application. Agent Core performs no environment-based file discovery.
- JSON capability composition does not grant provider ownership or remove
  serving evidence. The declared context window and evidence-backed serving
  constraint remain distinct.
- Pricing is read from the active model catalog. Capability snapshot tests do
  not establish pricing immutability after a response.
