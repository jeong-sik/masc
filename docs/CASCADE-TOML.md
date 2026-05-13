# Cascade TOML

`config/cascade.toml` is declarative-only. Retired flat profile tables with
inline model lists are no longer a supported authoring format. Use the RFC-0058
five-layer schema instead:

1. `[providers.<provider>]`
2. `[models.<model>]`
3. `[<provider>.<model>]`
4. `[tier.<tier>]`
5. `[tier-group.<group>]`
6. `[routes.<logical-use>]`

The runtime materializer rejects unknown top-level profile tables so old flat
TOML fails early instead of silently producing stale catalog entries.

## Provider Boundary

Cascade TOML is configuration data, not permission for MASC code to branch on
provider or model literals.

- MASC owns routes, profile selection, fallback, admission, health cooldown,
  receipts, dashboard surfaces, and keeper-facing assignment policy.
- OAS owns the generic single-provider runtime contract: provider catalog,
  model/capability/pricing manifests, request/response adapters, and
  non-interactive transport metadata.
- MASC bridge/adapter code may parse provider/model labels and project
  `cascade.toml` facts into OAS provider/capability contracts.
- MASC core code should route by logical use, declared capability, profile
  order, health, and capacity rather than vendor/model literals.

## Minimal Example

```toml
[providers.glm-coding]
display-name = "Zhipu GLM Coding"
protocol = "openai-http"
endpoint = "https://api.z.ai/api/coding/paas/v4"

[providers.glm-coding.credentials]
type = "env"
key = "ZAI_API_KEY"

[models.glm-5-turbo]
api-name = "glm-5-turbo"
max-context = 128000
tools-support = true
streaming = true

[glm-coding.glm-5-turbo]
is-default = true
max-concurrent = 2

[tier.coding_plan]
members = ["glm-coding.glm-5-turbo"]
strategy = "failover"

[tier-group.coding_plan]
tiers = ["coding_plan"]
strategy = "priority_tier"
fallback = true

[routes.keeper_turn]
target = "tier-group.coding_plan"
```

## Ollama

Ollama is still a supported HTTP provider. The endpoint is data, not a
hardcoded local-only assumption, so private configs may point it at a local
daemon or at a compatible remote endpoint such as Ollama Cloud.

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
tiers = ["local_recovery"]
strategy = "priority_tier"
fallback = true

[routes.phase_recovery]
target = "tier-group.local_recovery"
```

## Checked-In Seed Policy

The repo seed stays intentionally small.

- Keeper-assignable default: `big_three` for general turns.
- System-only lanes: `tool_rerank` for short rerank/scoring calls.
- Logical usages (`governance_judge`, `cross_verifier`, etc.) go under
  `[routes.*]`; they are route keys, not profile names.
- Personal experiments and machine-specific profiles go in live config
  (`$MASC_BASE_PATH/.masc/config/cascade.toml`), not the repo seed.

## Validation

Focused local checks:

```bash
scripts/dune-local.sh build test/test_cascade_config_validity.exe
scripts/dune-local.sh build test/test_cascade_toml_materializer_admission.exe
```

Useful source references:

- `config/cascade.toml`
- `lib/cascade/cascade_toml_materializer.ml`
- `lib/cascade/cascade_declarative_hotpath.ml`
- `docs/rfc/RFC-0058-terminal-fallback-capability-exemption.md`
