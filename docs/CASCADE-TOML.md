# `cascade.toml` Manual

Authoring guide for the cascade configuration. When `cascade.toml` exists, the
runtime loads it directly into memory — no intermediate `cascade.json` is
written to disk (TOML-only mode, RFC-0058).

## Start Here

- Live config root: `$MASC_BASE_PATH/.masc/config/cascade.toml`
- Repo seed/fallback: [`config/cascade.toml`](../config/cascade.toml)
- If only `cascade.json` exists (legacy), it is read directly

`config/cascade.toml` is the supported human-authored source. The runtime
parses TOML and converts to JSON in memory. No sibling `cascade.json` is
needed or generated.

## TOML-Only Mode (RFC-0058)

When `cascade.toml` is present alongside `cascade.json`:

| Behavior | Description |
|----------|-------------|
| **TOML loaded in-memory** | TOML is parsed, converted to JSON string, fed to Yojson |
| **JSON NOT written** | No `cascade.json` file is created or updated on disk |
| **JSON left untouched** | If a stale JSON exists, it remains as-is |
| **TOML is source of truth** | All edits go to TOML; JSON is ignored |

Legacy `cascade.json`-only mode remains supported for backward compatibility.

## Provider/Model-Free Contract

`models = ["provider:model"]` entries are **configuration data**, not permission
for MASC code to branch on provider or model literals.

The runtime contract is:

- MASC owns routes, profile selection, fallback, admission, health cooldown,
  receipt, dashboard, and keeper-facing assignment policy.
- OAS owns the generic single-provider runtime contract: provider catalog,
  model/capability/pricing manifests, request/response adapters, and
  non-interactive transport metadata.
- MASC bridge/adapter code may parse provider/model labels and project
  `cascade.toml` facts into OAS generic provider/capability contracts.
- MASC core code must not hardcode vendor/model names for routing decisions.
  It should route by logical use, declared capability, profile order, health,
  and capacity.

In practical terms, adding a cloud API provider that already follows an
existing OAS wire protocol should be:

1. Add or override an OAS provider catalog entry (`OAS_PROVIDER_CATALOG` or
   embedding-time catalog install).
2. Add the provider id/model label to `cascade.toml`.
3. Add capability/pricing facts through OAS manifests when the defaults are not
   enough.
4. Run the cascade materialization and OAS boundary checks.

Adding a subscription-backed CLI runtime is the same shape: the provider
catalog declares `transport = "cli"`, cached-login auth, non-interactive
readiness, and daemon safety; `cascade.toml` only references the opaque
provider id selected by the operator.

## TOML Schema Reference

### Top-Level Comment

```toml
comment = "Description of this configuration."
```

### `[profiles.<name>]` — Capability Profiles

Declare named capability requirement sets. Used by profiles with
`required_capability_profile = "<name>"` to filter models at load time.

```toml
[profiles.tool_strict]
required_capabilities = [
  "runtime_mcp_tools",
  "runtime_tool_events",
  "runtime_mcp_http_headers",
]

[profiles.inline_tools]
required_capabilities = ["inline_tools", "inline_tool_choice"]

[profiles.lite]
required_capabilities = ["runtime_mcp_tools", "runtime_tool_events"]

[profiles.local]
required_capabilities = []
```

Valid capability names (must match `Cascade_capability_schema.known_capability_fields`):

| Capability | Description |
|-----------|-------------|
| `runtime_mcp_tools` | Provider supports MCP tool calling at runtime |
| `runtime_tool_events` | Provider emits tool use events |
| `runtime_mcp_http_headers` | Provider passes MCP HTTP headers |
| `inline_tools` | Provider supports inline tool definitions |
| `inline_tool_choice` | Provider supports tool_choice parameter |

### `[routes]` — Logical Route Mapping

Maps logical call-site names to concrete cascade profiles.

```toml
[routes]
keeper_turn = "big_three"
phase_recovery = "big_three"
tool_required = "big_three"
governance_judge = "big_three"
llm_rerank = "tool_rerank"
simple_task = "tier_small"
moderate_task = "tier_medium"
```

Runtime code uses the logical route key; config chooses the concrete profile.
Unknown route keys are rejected as config/code drift.

### Cascade Profile Sections `[<name>]`

Each cascade profile is a top-level TOML table. The table name becomes the
profile name.

```toml
[my_profile]
comment = "Description of this profile."
models = [
  "claude_code:auto",
  "gemini_cli:auto",
  { model = "glm-coding:auto", supports_tool_choice = true },
]
temperature = 0.2
max_tokens = 16384
keeper_assignable = true
fallback_cascade = "other_profile"
```

#### All Allowed Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `comment` | string | — | Human-readable description; stored as `_comment_<name>` in JSON |
| `models` | array | `[]` | Model list. Entries: `"provider:model"` or `{ model = "...", weight = N, supports_tool_choice = bool }` |
| `temperature` | float | — | Sampling temperature |
| `max_tokens` | int | — | Maximum output tokens |
| `thinking_enabled` | bool | `false` | Enable extended thinking |
| `thinking_budget` | int | — | Token budget for thinking (when `thinking_enabled = true`) |
| `keeper_assignable` | bool | `false` | Whether keepers can be assigned to this profile |
| `strategy` | string | `"failover"` | Cascade strategy: `failover`, `weighted_random`, `priority_tier`, etc. |
| `fallback_cascade` | string | — | Profile name to fall back to when all models exhausted |
| `required_capability_profile` | string | — | Name from `[profiles]` for capability filtering |
| `max_cycles` | int | — | Maximum retry cycles |
| `backoff_base_ms` | int | — | Exponential backoff base in milliseconds |
| `backoff_cap_ms` | int | — | Backoff cap in milliseconds |
| `ollama_max_concurrent` | int | — | Max concurrent Ollama requests |
| `cli_max_concurrent` | int | — | Max concurrent CLI provider requests |
| `sticky_ttl_ms` | int | — | Sticky model selection TTL |
| `num_ctx` | int | — | Ollama context window size |
| `latency_baseline_ms` | float | — | Baseline latency for priority calculations |
| `rate_limit_skip_after` | int | — | Skip model after N rate-limit errors |
| `rate_limit_recency_window_s` | float | — | Rate-limit error recency window |
| `rate_limit_decay_base` | float | — | Rate-limit decay factor |
| `server_error_skip_after` | int | — | Skip model after N server errors |
| `server_error_recency_window_s` | float | — | Server error recency window |
| `server_error_decay_base` | float | — | Server error decay factor |
| `tiers` | array of arrays | — | Priority tier groups: `[["model_a"], ["model_b", "model_c"]]` |
| `api_key_env` | string or table | — | API key environment variable or `{ provider = "env_var" }` |
| `keep_alive` | string | — | Ollama keep_alive duration (e.g., `"5m"`, `"24h"`) |
| `timeout_sec` | float | — | **Legacy** — accepted but ignored. Use runtime timeout knobs. |

Unknown fields cause a load error. This is intentional: typos and stale fields
are caught at config load time, not at runtime.

### Model Entry Formats

```toml
# Simple string
models = ["claude_code:auto", "gemini_cli:gemini-3-flash-preview"]

# Extended with weight (for weighted_random strategy)
models = [
  { model = "claude_code:auto", weight = 3 },
  { model = "gemini_cli:auto", weight = 1 },
]

# Extended with tool choice support flag
models = [
  { model = "glm-coding:auto", supports_tool_choice = true },
]

# Combined
models = [
  "claude_code:auto",
  { model = "glm-coding:auto", supports_tool_choice = true, weight = 2 },
]
```

Provider ids in the examples above are repo seed examples only. Operators may
use catalog-defined ids such as `"acme-cloud:acme-large"` or
`"subscriber-codex:auto"` without requiring MASC code changes, provided the
corresponding OAS provider/catalog capability contract exists.

## Checked-In Seed Policy

The repo seed stays intentionally small.

- Keeper-assignable set: `big_three` for general turns.
- System-only lanes: `tool_rerank` for short rerank/scoring calls.
- Logical usages (`governance_judge`, `cross_verifier`, etc.) go under
  `[routes]` — they are route keys, not profile names.
- Personal experiments and machine-specific profiles go in live config
  (`$MASC_BASE_PATH/.masc/config/cascade.toml`), not the repo seed.

## Edit Workflow

1. Edit [`config/cascade.toml`](../config/cascade.toml).
2. Run focused checks:

```bash
dune runtest --root . test/test_cascade_toml_materialization.exe
dune runtest --root . test/test_cascade_phase1_smoke.exe
dune exec --root . ./test/test_keeper_cascade_profile.exe
```

Optionally verify JSON output:

```bash
dune exec --root . ./bin/cascade_materialize.exe -- config/cascade.json
```

## Examples

### Minimal Profile

```toml
[my_local]
models = ["ollama:qwen3:8b"]
temperature = 0.7
max_tokens = 2000
keeper_assignable = false
```

### Profile with Thinking

```toml
[reasoning]
models = ["claude_code:claude-sonnet-4-6"]
temperature = 1.0
max_tokens = 32768
thinking_enabled = true
thinking_budget = 16000
keeper_assignable = true
fallback_cascade = "big_three"
```

### Weighted Random Strategy

```toml
[diverse_sampling]
models = [
  { model = "claude_code:auto", weight = 3 },
  { model = "gemini_cli:auto", weight = 2 },
  { model = "codex_cli:gpt-5.3-codex-spark", weight = 1 },
]
temperature = 0.5
max_tokens = 4096
strategy = "weighted_random"
keeper_assignable = true
```

### Tiered Priority

```toml
[tiered_cascade]
models = [
  "claude_code:claude-sonnet-4-6",
  "gemini_cli:gemini-3-flash-preview",
  "ollama:qwen3:8b",
]
temperature = 0.3
max_tokens = 8192
strategy = "priority_tier"
tiers = [
  ["claude_code:claude-sonnet-4-6"],
  ["gemini_cli:gemini-3-flash-preview"],
  ["ollama:qwen3:8b"],
]
keeper_assignable = false
```

### Capability-Filtered Profile

```toml
[profiles.my_strict]
required_capabilities = ["runtime_mcp_tools", "runtime_mcp_http_headers"]

[cloud_tools]
models = ["claude_code:auto", "kimi_cli:kimi-for-coding"]
temperature = 0.2
max_tokens = 16384
required_capability_profile = "my_strict"
keeper_assignable = true
```

### Fallback Chain

```toml
[primary]
models = ["claude_code:auto", "gemini_cli:auto"]
temperature = 0.2
max_tokens = 16384
fallback_cascade = "secondary"

[secondary]
models = ["codex_cli:gpt-5.3-codex-spark", "kimi_cli:kimi-for-coding"]
temperature = 0.3
max_tokens = 8192
fallback_cascade = "big_three"
```

### Local-Only with Keep Alive

```toml
[local_fast]
models = ["ollama:qwen3:8b", "ollama:phi-3-mini"]
temperature = 0.5
max_tokens = 1000
ollama_max_concurrent = 2
keep_alive = "5m"
num_ctx = 8192
keeper_assignable = false
```

### Route Mapping with Tier Fallback

```toml
[routes]
keeper_turn = "tier_fast"
simple_task = "tier_small"
moderate_task = "tier_medium"
complex_task = "big_three"
llm_rerank = "tool_rerank"

[tier_small]
models = ["ollama:qwen3:8b"]
temperature = 0.3
max_tokens = 1000
keeper_assignable = false
fallback_cascade = "tier_medium"

[tier_medium]
models = ["glm-coding:glm-4.7-flashx"]
temperature = 0.2
max_tokens = 4096
keeper_assignable = false
fallback_cascade = "big_three"
```

## Related Docs

- Extended local/private examples: [`docs/CASCADE-COOKBOOK.md`](./CASCADE-COOKBOOK.md)
- Reload semantics: [`docs/TOML-RELOAD-MATRIX.md`](./TOML-RELOAD-MATRIX.md)
- Schema reference: [`docs/spec/14-configuration.md`](./spec/14-configuration.md)
- Cascade design index: [`docs/cascade/README.md`](./cascade/README.md)
