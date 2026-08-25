# Provider Catalog

OAS supports an external provider catalog for adding or overriding provider
connection metadata without changing SDK code. This is the provider-side
companion to `Capability_manifest`: capabilities describe what a model can do,
while the provider catalog describes how a runtime connects to that model.

The catalog is intentionally coordinator-neutral. It must not contain
downstream orchestration concepts such as domain roles, workflow queues,
operator-facing UI, or product-specific routing policies. Coordinators may
project their own configuration into this catalog shape, but OAS only consumes
generic provider/runtime facts.

## Loading

Load a JSON file and install the parsed catalog explicitly during application
bootstrap:

```ocaml
let catalog =
  match Provider_catalog.load_file "/home/app/.config/oas/providers.json" with
  | Ok catalog -> catalog
  | Error message -> failwith message
in
Provider_catalog.set_global catalog
```

Resolution order:

1. Explicit overlay installed with `Provider_catalog.set_global`
2. Embedded OAS `models.toml` provider rows

The OAS-owned `models.toml` also carries shareable provider identity rows under
`[[providers]]`. Those rows are data, not OCaml vendor branches: OAS embeds that
file at build time and uses it to register default provider entries. A selected
provider id is carried separately from its endpoint in `Provider_config`; OAS
never reverse-matches a URL, request path, or model id to choose a provider.
Linked applications need no catalog file beside their executable.

OAS never discovers a provider or model catalog from the process environment.
File selection, reload policy, and parse-error handling belong to the embedding
application. A caller that needs a custom file loads it explicitly with
`Provider_catalog.load_file` and installs it with `Provider_catalog.set_global`.

Catalog entries overwrite embedded provider ids when exact ids collide.
`Provider_registry` registers only the declared `id`; aliases remain selector
names at the catalog/runtime-binding boundary.

## Lookup and collisions

| Surface | Collision rule |
|---|---|
| `Provider_catalog.of_entries` / `of_json` | **Reject the whole catalog.** Ids and aliases share one case-insensitive identity namespace. |
| `Provider_registry` overlay (catalog vs. embedded) | **Catalog overwrites embedded data** by id when registered (`Hashtbl.replace`). The catalog overlay is applied last in `Provider_registry.default ()`. |

`Provider_catalog.lookup` remains a catalog-local, case-insensitive id/alias
query. `Provider_registry.find` is deliberately different: it accepts a
declared registry id, while `Provider_runtime_binding.find` accepts the
validated id or alias.

Invalid identifiers are rejected:

- Empty or padded ids/aliases → `Error`.
- Duplicate ids, duplicate aliases, and id/alias collisions → `Error`.
- Aliases are not inserted into `Provider_registry`, whether the catalog came
  from JSON or was constructed programmatically.

## Schema

Embedded TOML provider rows:

```toml
[[providers]]
id = "mimo"
kind = "openai_compat"
base_url = "https://token-plan-sgp.xiaomimimo.com/v1"
base_url_env = "MIMO_BASE_URL"
request_path = "/chat/completions"
api_key_env = "MIMO_API_KEY"
default_model = "mimo-v2.5-pro"
capabilities_base = "mimo"
```

`base_url_env` is consulted only when the row names it explicitly. It changes
the connection address, never provider identity. Selection uses the row's exact
`id` or alias and stores its canonical id in `Provider_config.provider_id`.

Runtime JSON overlay:

```json
{
  "schema_version": 1,
  "providers": [
    {
      "id": "vllm-local",
      "aliases": ["subscriber-local"],
      "kind": "openai_compat",
      "base_url": "http://127.0.0.1:8000",
      "request_path": "/v1/chat/completions",
      "auth": {"type": "none"},
      "default_model": "local-model",
      "capabilities_base": "openai_chat",
      "capabilities": {
        "max_context_tokens": 131072,
        "supports_tools": true,
        "supports_tool_choice": true
      }
    }
  ]
}
```

Required fields:

| Field | Type | Description |
|---|---|---|
| `schema_version` | integer | Must be `1`. |
| `providers[].id` | string | Opaque provider id. This is config identity, not a vendor branch in code. |

Important provider fields:

| Field | Type | Description |
|---|---|---|
| `kind` | string | Existing HTTP wire/runtime kind, for example `openai_compat`, `anthropic`, or `gemini`. Defaults to `openai_compat`. |
| `base_url` | string | HTTP endpoint base URL. |
| `request_path` | string | Completion request path. Defaults from `kind`. |
| `auth` | object | Credential mode. See below. |
| `default_model` | string | Used when a caller selects the provider without a model. |
| `aliases` | string array | Catalog-local lookup names. They are not provider registry ids. |
| `capabilities_base` | string | Provider preset from `Capabilities.capabilities_for_provider_label`. |
| `capabilities` | object | Optional capability overrides. |
| `credential_scope` | string | Human-readable credential scope label. |

Auth modes:

| `auth.type` | Extra field | Use case |
|---|---|---|
| `none` | | Local unauthenticated endpoints. |
| `api_key_env` | `env` | Cloud APIs using an API key environment variable. |
| `setup_token_env` | `env` | Setup/bootstrap token environment variable. |

Catalog entries describe HTTP execution only. A caller that owns a managed,
OAuth, or subprocess transport must inject that typed transport explicitly;
the catalog does not claim an execution mode that OAS cannot perform.

The JSON parser is fail-closed: root, provider, `auth`, and `capabilities`
objects reject duplicate or unknown fields; scalar and list values must have
their declared types; lists declared as non-empty must contain exact item
types; and positive integer fields must fit the OCaml native integer range.
JSON `null` is accepted only where the schema defines it as an omitted/default
value. A malformed provider entry rejects the catalog instead of being skipped.

## Cloud API Example

```json
{
  "schema_version": 1,
  "providers": [
    {
      "id": "acme-cloud",
      "kind": "openai_compat",
      "base_url": "https://api.acme.example/v1",
      "request_path": "/chat/completions",
      "auth": {"type": "api_key_env", "env": "ACME_API_KEY"},
      "default_model": "acme-large",
      "capabilities_base": "openai_chat",
      "capabilities": {
        "supports_tools": true,
        "supports_response_format_json": true
      }
    }
  ]
}
```

Use this for OpenAI-compatible cloud providers, hosted vLLM gateways,
OpenRouter-style aggregators, and private model APIs that already follow the
chat-completions contract.

## Capability Overrides

The `capabilities` object accepts the same capability field names used by
`Capabilities.capabilities`, including:

- `max_context_tokens`, `max_output_tokens`
- `supports_tools`, `supports_tool_choice`, `supports_parallel_tool_calls`
- `assistant_tool_content_format`
- `supports_reasoning`, `supports_extended_thinking`, `supports_reasoning_budget`
- `accepted_reasoning_efforts`
- `thinking_control_format`, `preserve_thinking_control_format`
- `reasoning_output_format`, `reasoning_streaming_format`
- `supports_response_format_json`, `supports_structured_output`
- `supports_image_input`, `supports_audio_input`, `supports_video_input`, `supports_document_input`
- `modality_priority`
- `supports_native_streaming`, `supports_system_prompt`
- `supports_top_k`, `supports_min_p`, `supports_seed`
- `emits_usage_tokens`, `supported_models`

Model-specific facts should live in the embedded/explicit model catalog or an
explicitly installed `Capability_manifest`. Provider catalog capabilities
should describe runtime/provider defaults.

Accepted `thinking_control_format` values are:

- `none`
- `thinking_object` (top-level `thinking` object plus `reasoning_effort`)
- `thinking_object_adaptive` (top-level `thinking` object with `type: "adaptive"` / `type: "disabled"`)
- `thinking_object_only` (top-level `thinking` object only)
- `chat_template_kwargs`
- `chat_template_token` (inject the catalog/manifest `thinking_control_token` into the chat template)
- `ollama_think` (Ollama native `/api/chat` top-level `think`)
- `reasoning_effort`
- `enable_thinking` (top-level `enable_thinking` plus optional `thinking_budget`)

Accepted `preserve_thinking_control_format` values are:

- `none`
- `thinking_object_keep_all` (`thinking.keep = "all"`)
- `chat_template_kwargs_preserve_thinking`
- `top_level_preserve_thinking`
- `always_preserved` (historical reasoning must be replayed; no request field)

Accepted `reasoning_output_format` values are:

- `none`
- `split_reasoning_fields` (emit provider split control such as `reasoning_split=true`)

Accepted `reasoning_streaming_format` values are:

- `default`
- `none`
- `template_parser`
- `delta:<field>` (parse the named streaming delta field as reasoning)

Accepted `accepted_reasoning_efforts` values are:

- `none`
- `minimal`
- `low`
- `medium`
- `high`
- `xhigh`
- `max`

Accepted `modality_priority` values are:

- `preserve_input_order`
- `preserve-input-order`
- `preserve`
- `visual_first`
- `visual-first`

Accepted `assistant_tool_content_format` values are:

- `null` (`content: null` for assistant tool-call messages with no visible text)
- `empty_string` (`content: ""` for assistant tool-call messages with no visible text)

## External Design References

The catalog shape follows a common pattern in current agent tools:

- Hermes Agent separates primary/fallback providers and provider credentials.
- OpenClaw exposes model/provider status, auth modes, and fallback chains.
- OpenAI Agents SDK separates `Model` from `ModelProvider`.
- Claude Agent SDK supports SDK and CLI-driven agent loops.
- Google ADK uses provider connectors such as LiteLLM for broad model coverage.

References were checked on 2026-05-12:

- https://hermes-agent.nousresearch.com/docs/user-guide/features/fallback-providers/
- https://docs.openclaw.ai/concepts/model-failover
- https://docs.openclaw.ai/cli/models
- https://docs.openclaw.ai/gateway/authentication
- https://openai.github.io/openai-agents-js/guides/models/
- https://code.claude.com/docs/en/agent-sdk
- https://adk.dev/agents/models/litellm/
