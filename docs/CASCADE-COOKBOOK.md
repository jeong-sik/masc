# Cascade Cookbook

Copy-paste examples for declarative `config/cascade.toml`.

The old flat profile cookbook is retired. Do not write top-level profile tables
with inline model lists; declare providers, models, bindings, tiers,
tier-groups, and routes explicitly.

## GLM Coding Plan + Kimi CLI

```toml
[providers.glm-coding]
display-name = "Zhipu GLM Coding"
protocol = "openai-http"
endpoint = "https://api.z.ai/api/coding/paas/v4"

[providers.glm-coding.credentials]
type = "env"
key = "ZAI_API_KEY"

[providers.kimi_cli]
display-name = "Moonshot Kimi CLI"
protocol = "kimi-cli"
command = "kimi"
is-non-interactive = true

[providers.kimi_cli.credentials]
type = "env"
key = "MOONSHOT_API_KEY"

[models.glm-5-turbo]
api-name = "glm-5-turbo"
max-context = 128000
tools-support = true
streaming = true

[models.kimi-coding]
api-name = "kimi-for-coding"
max-context = 128000
tools-support = true
streaming = true

[glm-coding.glm-5-turbo]
is-default = true
max-concurrent = 2

[kimi_cli.kimi-coding]
is-default = true
max-concurrent = 1

[tier.coding_plan]
members = ["glm-coding.glm-5-turbo", "kimi_cli.kimi-coding"]
strategy = "failover"

[tier-group.coding_plan]
tiers = ["coding_plan"]
strategy = "priority_tier"
fallback = true

[routes.keeper_turn]
target = "tier-group.coding_plan"
```

## Ollama Fallback

Use the same shape for local Ollama or a compatible remote Ollama endpoint.
Only the provider `endpoint` changes.

```toml
[providers.ollama]
display-name = "Ollama HTTP"
protocol = "ollama-http"
endpoint = "http://localhost:11434"

[models.qwen3]
api-name = "qwen3"
max-context = 262144
tools-support = true
streaming = true

[ollama.qwen3]
is-default = true
max-concurrent = 1

[tier.local_recovery]
members = ["ollama.qwen3"]
strategy = "failover"

[tier-group.local_recovery]
tiers = ["local_recovery", "coding_plan"]
strategy = "priority_tier"
fallback = true

[routes.phase_recovery]
target = "tier-group.local_recovery"
```

## Notes

- Routes should target `tier-group.<name>` unless a caller intentionally needs a
  single tier or binding.
- Keep provider credentials in provider sub-tables; do not recreate per-profile
  `api_key_env` blocks.
- The checked-in seed is `config/cascade.toml`.
