# Cascade Cookbook

Copy-paste examples for `cascade.toml`.

Use this document for local/private live config under:

- `~/.masc/config/cascade.toml`
- `$MASC_BASE_PATH/.masc/config/cascade.toml`

Do not treat these examples as checked-in repo defaults. Repo defaults live in
[`config/cascade.toml`](../config/cascade.toml) and use the RFC-0058
declarative provider/model/tier schema. Operator live configs may stay smaller
when the goal is to pin one machine to one provider lane.

## Quick Rules

- Edit the live file, not the repo seed, for machine-specific routing.
- Use `glm-coding:<model>` or `glm-coding:auto` for Z.AI GLM Coding Plan.
- Do not use `glm-coding-plan:<model>` in new configs. The checked-in provider
  id is `glm-coding`.
- GLM Coding Plan must use the Z.AI Coding endpoint:
  `https://api.z.ai/api/coding/paas/v4`.
- The general Z.AI endpoint is `https://api.z.ai/api/paas/v4`; do not use it
  for Coding Plan traffic.
- Put API keys in environment variables or secret loaders. Do not write keys
  into TOML.
- Keep personal experiments in the live config. Commit only docs or seed
  changes that other operators should inherit.

Source checked on 2026-05-12: Z.AI's official API docs say GLM Coding Plan uses
the dedicated Coding endpoint instead of the general endpoint:
https://docs.z.ai/api-reference/introduction

## Example 1: Single Z.AI Coding Plan Lane

Use this when the machine should route every keeper/operator use to one GLM
Coding Plan lane.

This is intentionally small. It is useful for debugging, rate-limit control, or
temporary operation when you want to remove local 27B/70B-style classification
from the live config.

```toml
# ~/.masc/config/cascade.toml
# or $MASC_BASE_PATH/.masc/config/cascade.toml

comment = "Single Z.AI Coding Plan cascade. Machine-local live config."

[routes]
keeper_turn = "coding_plan"
phase_recovery = "coding_plan"
phase_buffer = "coding_plan"
tool_required = "coding_plan"
governance_judge = "coding_plan"
operator_judge = "coding_plan"
cross_verifier = "coding_plan"
verifier = "coding_plan"
autoresearch = "coding_plan"
adversarial_reviewer = "coding_plan"
auto_responder = "coding_plan"
routing = "coding_plan"
openai_compat = "coding_plan"
persona_generation = "coding_plan"
provider_benchmark = "coding_plan"
llm_rerank = "coding_plan"
simple_task = "coding_plan"
moderate_task = "coding_plan"
complex_task = "coding_plan"

[coding_plan]
comment = "Only active live profile. glm-coding resolves to the Z.AI Coding endpoint."
models = [
  { model = "glm-coding:auto", weight = 1 },
]
temperature = 0.2
max_tokens = 16384
strategy = "failover"
keeper_assignable = true

[coding_plan.api_key_env]
"glm-coding" = "ZAI_API_KEY"
```

Expected diagnostic shape:

```bash
./_build/default/bin/main_eio.exe doctor config \
  --base-path "$HOME/me" \
  --json
```

The important fields are:

- `active_config_root` points at `$MASC_BASE_PATH/.masc/config`.
- `catalog_validation.status` is `validated`.
- `catalog_validation.snapshot.profile_count` is `1`.
- `catalog_validation.snapshot.default_profile_name` is `coding_plan`.
- Candidate `base_url` values are `https://api.z.ai/api/coding/paas/v4`.

Docker sandbox warnings can make the doctor command exit non-zero while the
cascade catalog is still valid. Read `catalog_validation` separately from
`sandbox_preflight`.

## Example 2: Z.AI Coding Plan With Kimi CLI Fallback

Use this when you want GLM Coding Plan as the first cloud lane and Kimi CLI as a
second lane. Keep this live-only unless the fallback order is meant to become a
shared default.

```toml
comment = "GLM Coding Plan primary, Kimi CLI fallback. Machine-local live config."

[routes]
keeper_turn = "keeper_unified"
phase_recovery = "keeper_unified"
phase_buffer = "local_recovery"
tool_required = "keeper_unified"
governance_judge = "keeper_unified"
operator_judge = "keeper_unified"
cross_verifier = "keeper_unified"
verifier = "keeper_unified"
autoresearch = "keeper_unified"
adversarial_reviewer = "keeper_unified"
auto_responder = "keeper_unified"
routing = "keeper_unified"
openai_compat = "keeper_unified"
persona_generation = "keeper_unified"
provider_benchmark = "keeper_unified"
llm_rerank = "tool_rerank"
simple_task = "keeper_unified"
moderate_task = "keeper_unified"
complex_task = "keeper_unified"

[keeper_unified]
temperature = 0.2
max_tokens = 16384
strategy = "failover"
models = [
  { model = "glm-coding:auto", weight = 2 },
  { model = "kimi_cli:auto", weight = 1 },
]
keeper_assignable = true

[keeper_unified.api_key_env]
"glm-coding" = "ZAI_API_KEY"
kimi_cli = "MOONSHOT_API_KEY"

[local_recovery]
temperature = 0.1
max_tokens = 8192
models = ["glm-coding:auto"]
keeper_assignable = false

[local_recovery.api_key_env]
"glm-coding" = "ZAI_API_KEY"

[tool_rerank]
temperature = 0.0
max_tokens = 200
models = ["glm-coding:auto"]
keeper_assignable = false

[tool_rerank.api_key_env]
"glm-coding" = "ZAI_API_KEY"
```

Operational notes:

- Keep `glm-coding:auto` first when the subscription is GLM Coding Plan.
- Use `kimi_cli:auto` only when the CLI runtime and credential are healthy.
- Use the same `api_key_env` provider id as the model prefix:
  `"glm-coding" = "ZAI_API_KEY"`.
- If `ZAI_CODING_DEFAULT_MODEL` is set, `glm-coding:auto` follows that model.
  Otherwise it follows the adapter default documented in
  [`docs/spec/14-configuration.md`](./spec/14-configuration.md).

## Keeper Autoboot Example

Keeper startup is controlled by keeper TOML files, not by `cascade.toml`.

To leave exactly four keepers enabled, make only those files contain
`autoboot_enabled = true`, and set every other keeper to false.

```toml
# ~/.masc/config/keepers/taskmaster.toml
[keeper]
autoboot_enabled = true
cascade_name = "coding_plan"
```

```toml
# ~/.masc/config/keepers/some-other-keeper.toml
[keeper]
autoboot_enabled = false
cascade_name = "coding_plan"
```

Verification:

```bash
rg -l '^autoboot_enabled\s*=\s*true$' \
  "$HOME/me/.masc/config/keepers"/*.toml

rg -n 'cascade_name\s*=\s*"(?!coding_plan")' -P \
  "$HOME/me/.masc/config/keepers"/*.toml
```

The first command should list only the intended keepers. The second command
should print nothing when every keeper points at the live profile.

## Choosing A Shape

| Need | Recommended shape |
| --- | --- |
| One machine, one provider lane | Example 1 |
| One primary cloud lane plus a fallback | Example 2 |
| Shared repo defaults | Edit `config/cascade.toml` declarative provider/model/tier data |
| Per-keeper startup control | Edit `~/.masc/config/keepers/*.toml` |

## Where This Connects

- Schema reference: [docs/CASCADE-TOML.md](./CASCADE-TOML.md)
- Provider/env reference: [docs/spec/14-configuration.md](./spec/14-configuration.md)
- Checked-in authoring seed: [config/cascade.toml](../config/cascade.toml)
- Config doctor: [docs/CONFIG-DOCTOR.md](./CONFIG-DOCTOR.md)
- Reload contract: [docs/TOML-RELOAD-MATRIX.md](./TOML-RELOAD-MATRIX.md)
