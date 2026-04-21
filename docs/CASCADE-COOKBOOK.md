# Cascade Cookbook

Copy-paste examples for `config/cascade.json`.

Use this document for local/private live config under:

- `~/.masc/config/cascade.json`
- `$MASC_BASE_PATH/.masc/config/cascade.json`

Do not treat these examples as a mandate for checked-in repo defaults. Repo
defaults must stay limited to providers that the currently pinned OAS runtime
can execute when selected.

## Quick Rules

- Use explicit `provider:model_id` labels in committed defaults.
- A cascade profile is any `{name}_...` key group such as
  `keeper_unified_models`, `keeper_unified_temperature`,
  `keeper_unified_strategy`.
- `default_*` acts as fallback for cascades that omit per-profile values.
- `{name}_keeper_assignable = false` keeps a profile visible in the catalog but
  hides it from keeper assignment dropdowns.
- Kimi direct uses the built-in Moonshot/OpenAI-compatible `kimi:` lane here.
  Prefer current model IDs such as `kimi:kimi-k2.5`.
- Legacy `kimi:kimi-for-coding` is normalized to `kimi:kimi-k2.5` at parse time for
  backward compatibility with older live configs.

## Example 1: GLM Coding + Kimi Direct + Local Ollama Fallback

Use this when your keepers are primarily coding/text agents and you want:

- `glm-coding` as the main tool-using cloud path
- `kimi` direct as the secondary coding cloud path
- local `ollama` as the cheap fallback/recovery lane

```json
{
  "_comment": "Local/private live config example. Requires valid GLM/Kimi credentials and local fallback runtime health.",
  "default_models": [
    {"model": "glm-coding:glm-5.1", "weight": 45},
    {"model": "kimi:kimi-for-coding", "weight": 35},
    {"model": "ollama:qwen3.5:35b-a3b-nvfp4", "weight": 20, "supports_tool_choice": true}
  ],
  "default_temperature": 0.2,
  "default_max_tokens": 8192,
  "default_api_key_env": {
    "glm": "ZAI_API_KEY_SB",
    "glm-coding": "ZAI_API_KEY_SB",
    "kimi": "KIMI_API_KEY_SB"
  },

  "keeper_unified_models": [
    {"model": "glm-coding:glm-5.1", "weight": 45},
    {"model": "kimi:kimi-for-coding", "weight": 35},
    {"model": "ollama:qwen3.5:35b-a3b-nvfp4", "weight": 20, "supports_tool_choice": true}
  ],
  "keeper_unified_temperature": 0.2,
  "keeper_unified_max_tokens": 16384,
  "keeper_unified_strategy": "circuit_breaker_cycling",
  "keeper_unified_max_cycles": 2,
  "keeper_unified_backoff_base_ms": 250,
  "keeper_unified_backoff_cap_ms": 2000,
  "keeper_unified_ollama_max_concurrent": 1,

  "local_recovery_models": [
    "ollama:qwen3.5:35b-a3b-nvfp4"
  ],
  "local_recovery_temperature": 0.1,
  "local_recovery_max_tokens": 8192,

  "tool_rerank_temperature": 0.0,
  "tool_rerank_max_tokens": 200,
  "tool_rerank_keeper_assignable": false
}
```

Operational notes:

- Keep `glm-coding` first if you want reliable cloud tool use.
- Keep `ollama` in `local_recovery_*` even if the main cascade already contains
  it; recovery profiles should stay deterministic and cheap.
- `supports_tool_choice` on the local candidate is only a hint for known local
  models that do obey tool-choice overrides.

## Example 2: GLM Coding + Kimi Direct + Local MLX-VLM Fallback

Use this when the local lane is an OpenAI-compatible MLX-VLM endpoint instead
of `ollama`.

```json
{
  "_comment": "Local/private live config example. Requires valid GLM/Kimi credentials and an OpenAI-compatible MLX-VLM endpoint.",
  "default_models": [
    {"model": "glm-coding:glm-5.1", "weight": 45},
    {"model": "kimi:kimi-for-coding", "weight": 35},
    {"model": "custom:mlx-community/Huihui-Qwen3.6-35B-A3B-abliterated-4.4bit-msq@http://127.0.0.1:18080/v1", "weight": 20}
  ],
  "default_temperature": 0.2,
  "default_max_tokens": 8192,
  "default_api_key_env": {
    "glm": "ZAI_API_KEY_SB",
    "glm-coding": "ZAI_API_KEY_SB",
    "kimi": "KIMI_API_KEY_SB"
  },

  "keeper_unified_models": [
    {"model": "glm-coding:glm-5.1", "weight": 45},
    {"model": "kimi:kimi-for-coding", "weight": 35},
    {"model": "custom:mlx-community/Huihui-Qwen3.6-35B-A3B-abliterated-4.4bit-msq@http://127.0.0.1:18080/v1", "weight": 20}
  ],
  "keeper_unified_temperature": 0.2,
  "keeper_unified_max_tokens": 16384,
  "keeper_unified_strategy": "circuit_breaker_cycling",
  "keeper_unified_max_cycles": 2,
  "keeper_unified_backoff_base_ms": 250,
  "keeper_unified_backoff_cap_ms": 2000,

  "local_mlx_vlm_qwen36_models": [
    "custom:mlx-community/Huihui-Qwen3.6-35B-A3B-abliterated-4.4bit-msq@http://127.0.0.1:18080/v1"
  ],
  "local_mlx_vlm_qwen36_temperature": 0.2,
  "local_mlx_vlm_qwen36_max_tokens": 16384,

  "tool_rerank_temperature": 0.0,
  "tool_rerank_max_tokens": 200,
  "tool_rerank_keeper_assignable": false
}
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
- Keep `glm-coding` first unless you explicitly want local-first economics and
  are comfortable with tool-call fallback behavior.

## Where This Connects

- Schema reference: [docs/spec/14-configuration.md](./spec/14-configuration.md)
- Checked-in seed example: [config/cascade.json](../config/cascade.json)
- Reload contract: [README.md](../README.md)
