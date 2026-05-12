# Cascade Cookbook

Copy-paste examples for `config/cascade.toml`.

Use this document for local/private live config under:

- `~/.masc/config/cascade.toml`
- `$MASC_BASE_PATH/.masc/config/cascade.toml`

The runtime will materialize sibling `cascade.json` automatically.

Do not treat these examples as a mandate for checked-in repo defaults. Repo
defaults must stay limited to providers that the currently pinned OAS runtime
can execute when selected.

## Quick Rules

- Use explicit `provider:model_id` labels in committed defaults when review-stable pinning matters; use `provider:auto` only when the adapter default is the intended contract.
- A cascade profile is a top-level TOML table such as `[keeper_unified]`.
- `comment` at the root maps to the runtime `_comment`; `[profile].comment`
  maps to `_comment_<profile>`.
- `[default]` acts as fallback for cascades that omit per-profile values.
- `[profile].keeper_assignable = false` keeps a profile visible in the catalog
  but hides it from keeper assignment dropdowns.
- `[profile.api_key_env]` maps provider ids to env var names.
- `kimi_cli:auto` is the preferred Kimi lane for current live configs when you
  want the CLI/runtime-MCP tool path.
- `glm-coding:auto` is the preferred GLM coding lane for current live
  configs.
- Direct `kimi:` still exists for Moonshot/OpenAI-compatible routing, but keep
  it as an explicit choice rather than the default cookbook path.

## Example 1: GLM Coding + Kimi CLI + Local Ollama Fallback

Use this when your keepers are primarily coding/text agents and you want:

- `glm-coding` as the main tool-using cloud path
- `kimi_cli` as the secondary coding cloud path
- local `ollama` as the cheap fallback/recovery lane

```toml
comment = "Local/private live config example. Requires valid GLM/Kimi credentials and local fallback runtime health."

[default]
temperature = 0.2
max_tokens = 8192
models = [
  { model = "glm-coding:auto", weight = 45 },
  { model = "kimi_cli:auto", weight = 35 },
  { model = "ollama:qwen3.5:35b-a3b-nvfp4", weight = 20, supports_tool_choice = true },
]

[default.api_key_env]
glm = "ZAI_API_KEY_SB"
"glm-coding" = "ZAI_API_KEY_SB"
kimi_cli = "KIMI_API_KEY_SB"

[keeper_unified]
temperature = 0.2
max_tokens = 16384
strategy = "circuit_breaker_cycling"
max_cycles = 2
backoff_base_ms = 250
backoff_cap_ms = 2000
ollama_max_concurrent = 1
models = [
  { model = "glm-coding:auto", weight = 45 },
  { model = "kimi_cli:auto", weight = 35 },
  { model = "ollama:qwen3.5:35b-a3b-nvfp4", weight = 20, supports_tool_choice = true },
]

[local_recovery]
temperature = 0.1
max_tokens = 8192
models = ["ollama:qwen3.5:35b-a3b-nvfp4"]

[tool_rerank]
temperature = 0.0
max_tokens = 200
keeper_assignable = false
```

Operational notes:

- Keep `glm-coding` first if you want reliable cloud tool use.
- Keep `ollama` in `local_recovery_*` even if the main cascade already contains
  it; recovery profiles should stay deterministic and cheap.
- `supports_tool_choice` on the local candidate is only a hint for known local
  models that do obey tool-choice overrides.

## Example 2: GLM Coding + Kimi CLI + Local MLX-VLM Fallback

Use this when the local lane is an OpenAI-compatible MLX-VLM endpoint instead
of `ollama`.

```toml
comment = "Local/private live config example. Requires valid GLM/Kimi credentials and an OpenAI-compatible MLX-VLM endpoint."

[default]
temperature = 0.2
max_tokens = 8192
models = [
  { model = "glm-coding:auto", weight = 45 },
  { model = "kimi_cli:auto", weight = 35 },
  { model = "custom:mlx-community/Huihui-Qwen3.6-35B-A3B-abliterated-4.4bit-msq@http://127.0.0.1:18080/v1", weight = 20 },
]

[default.api_key_env]
glm = "ZAI_API_KEY_SB"
"glm-coding" = "ZAI_API_KEY_SB"
kimi_cli = "KIMI_API_KEY_SB"

[keeper_unified]
temperature = 0.2
max_tokens = 16384
strategy = "circuit_breaker_cycling"
max_cycles = 2
backoff_base_ms = 250
backoff_cap_ms = 2000
models = [
  { model = "glm-coding:auto", weight = 45 },
  { model = "kimi_cli:auto", weight = 35 },
  { model = "custom:mlx-community/Huihui-Qwen3.6-35B-A3B-abliterated-4.4bit-msq@http://127.0.0.1:18080/v1", weight = 20 },
]

[local_mlx_vlm_qwen36]
temperature = 0.2
max_tokens = 16384
models = [
  "custom:mlx-community/Huihui-Qwen3.6-35B-A3B-abliterated-4.4bit-msq@http://127.0.0.1:18080/v1",
]

[tool_rerank]
temperature = 0.0
max_tokens = 200
keeper_assignable = false
```

Operational notes:

- Keep the `custom:` model on a canonical localhost URL so telemetry and
  troubleshooting stay stable.
- If the MLX-VLM lane is only for vision-heavy work, consider assigning it to a
  separate keeper via `cascade_name` instead of making it your main keeper
  default.

## Choosing Between Ollama and MLX-VLM

- Choose `ollama` when the local fallback is mostly text/code and you want the
  most boring operational path.
- Choose `mlx-vlm` when the local fallback must accept image-heavy or multimodal
  turns through an OpenAI-compatible endpoint.
- Keep `glm-coding` first unless you explicitly want local-first
  economics and are comfortable with tool-call fallback behavior.

## Where This Connects

- Schema reference: [docs/spec/14-configuration.md](./spec/14-configuration.md)
- Checked-in authoring seed: [config/cascade.toml](../config/cascade.toml)
- Materialized runtime artifact: [config/cascade.json](../config/cascade.json)
- Reload contract: [README.md](../README.md)
