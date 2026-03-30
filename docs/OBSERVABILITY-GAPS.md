# Observability Gaps

Providers verified by static contract only (no live E2E).

## Verified (static contract)

| Provider | Label format | `provider_name_of_label` | `parse_model_string` |
|----------|-------------|--------------------------|---------------------|
| Anthropic | `anthropic:<model>` | OK | None (no API key in CI) |
| OpenAI | `openai:<model>` | OK | None (no API key in CI) |
| OpenRouter | `openrouter:<model>` | OK | Untested (not in registry) |
| 3034 proxy | `custom:<model>@<url>` | OK (returns "custom") | Untested |

## Verified (live + static)

| Provider | Label format | `parse_model_string` | Live E2E |
|----------|-------------|---------------------|----------|
| Gemini | `gemini:<model>` | OK | Pending harness |
| GLM | `glm:<model>` | OK | Pending harness |
| llama | `llama:<model>` | OK | Pending harness |

## Remaining work

- Live smoke harness for llama/Gemini/GLM: `scripts/harness/workload/observability_smoke_*.sh`
- Live E2E for Anthropic/OpenAI when API keys are available in CI
- OpenRouter registry entry (currently not in Provider_registry)
- 3034 proxy custom URL format live test

## References

- Static contracts: `test/test_observability_provider_contracts.ml`
- Redaction contracts: `test/test_observability_redact.ml`
- Surface SSOT: `test/test_tool_surface_ssot.ml`
- Issues: #3953, #3954, #3955
