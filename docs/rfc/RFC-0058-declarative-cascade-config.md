# RFC-0058: Declarative Cascade Configuration

| Field | Value |
|-------|-------|
| Status | Draft |
| Author | Claude (agent), Vincent (architect) |
| Created | 2026-05-10 |
| Supersedes | RFC-0055 (cascade fallback tier routing), RFC-0027 (capability typed cascade) |
| Depends | RFC-0042 (keeper terminal code closed sum) |

## 1. Problem

Current cascade system has capability profiles as a **closed OCaml variant**:

```ocaml
type profile = Tool_strict | Inline_tools | Lite | Local_inline | Local
```

Adding a new profile requires OCaml compilation. Provider/model/vendor traits are
hardcoded in `required_capabilities_of`. The system cannot express:

1. Per-provider concurrency/capacity
2. Model-level capability declarations (verified/declared/unsupported)
3. Alias composition (provider + model + options)
4. Group cascade (ordered fallback within and between alias groups)
5. Strategy as secondary concern, not primary routing axis

**Root cause**: `cascade_capability_profile.ml` (105 LOC) is the architectural bottleneck.
`cascade_toml_materializer.ml` already passes capability profile as string — no change needed there.

## 2. Design: 4-Layer Declarative TOML

### 2.1 Layer Overview

```
[providers]  →  URL, API key, kind, concurrency
[models]     →  specs, capability declarations
[aliases]    →  provider + model + options (thinking, env, params)
[groups]     →  ordered alias list (cascade within group)
[cascade]    →  ordered group list (cascade between groups)
```

### 2.2 TOML Schema

```toml
# ── Layer 1: Providers ──────────────────────────────────────────────
[providers.claude_api]
kind = "cloud_api"
base_url = "https://api.anthropic.com/v1"
api_key_env = "ANTHROPIC_API_KEY"
concurrency = 4
headers = { "anthropic-version" = "2023-06-01" }

[providers.ollama_local]
kind = "local"
base_url = "http://localhost:11434"
concurrency = 2

[providers.gemini_cli]
kind = "cli"
command = "gemini"
concurrency = 1

[providers.openai_api]
kind = "cloud_api"
base_url = "https://api.openai.com/v1"
api_key_env = "OPENAI_API_KEY"
concurrency = 4

# ── Layer 2: Models ─────────────────────────────────────────────────
[models.claude-sonnet-4-6]
provider = "claude_api"
model_id = "claude-sonnet-4-6-20250514"
context_window = 200000

[models.claude-sonnet-4-6.capabilities]
inline_tools = "verified"
inline_tool_choice = "verified"
runtime_mcp_tools = "verified"
runtime_tool_events = "verified"
runtime_mcp_http_headers = "verified"
thinking = "verified"
structured_output = "verified"

[models.gemini-2.5-pro]
provider = "gemini_cli"
model_id = "gemini-2.5-pro"
context_window = 1048576

[models.gemini-2.5-pro.capabilities]
inline_tools = "verified"
inline_tool_choice = "verified"
runtime_mcp_tools = "verified"
runtime_tool_events = "declared"
runtime_mcp_http_headers = "unsupported"
thinking = "verified"

[models.qwen3-27b]
provider = "ollama_local"
model_id = "qwen3:27b"
context_window = 262144

[models.qwen3-27b.capabilities]
inline_tools = "verified"
inline_tool_choice = "verified"
runtime_mcp_tools = "unsupported"
runtime_tool_events = "unsupported"
runtime_mcp_http_headers = "unsupported"
thinking = "verified"

# ── Layer 3: Aliases ────────────────────────────────────────────────
[aliases.strict]
model = "claude-sonnet-4-6"
thinking = { type = "enabled", budget_tokens = 16000 }
temperature = 1.0
system_prompt_suffix = ""

[aliases.fast]
model = "claude-sonnet-4-6"
thinking = { type = "disabled" }
temperature = 0.7

[aliases.pro]
model = "gemini-2.5-pro"
thinking = { type = "enabled", budget_tokens = 32000 }
temperature = 1.0

[aliases.local_recovery]
model = "qwen3-27b"
thinking = { type = "disabled" }
temperature = 0.5

[aliases.local_thinking]
model = "qwen3-27b"
thinking = { type = "enabled", budget_tokens = 8000 }
temperature = 0.7

# ── Layer 4: Groups (cascade of aliases) ────────────────────────────
[groups.keeper_bound_safe]
strategy = "sequential"
aliases = ["strict", "fast"]

[groups.tier_fast]
strategy = "sequential"
aliases = ["fast", "local_recovery"]

[groups.cloud_strict]
strategy = "sequential"
aliases = ["strict", "pro"]

[groups.local_recovery]
strategy = "sequential"
aliases = ["local_recovery"]

[groups.tool_rerank]
strategy = "sequential"
aliases = ["strict", "fast", "pro"]

# ── Cascade: group ordering ─────────────────────────────────────────
[cascade.default]
groups = ["keeper_bound_safe", "tier_fast", "local_recovery"]

[cascade.tool_heavy]
groups = ["cloud_strict", "tool_rerank", "local_recovery"]
required_capabilities = ["inline_tools", "runtime_mcp_tools"]

[cascade.local_first]
groups = ["local_recovery", "local_thinking"]
```

### 2.3 Capability Levels

| Level | Meaning |
|-------|---------|
| `"verified"` | Tested in CI, known to work correctly |
| `"declared"` | Provider claims support, not verified in CI |
| `"unsupported"` | Known to not work or not available |

Capability resolution at startup:
- Cascade route requires `["inline_tools", "runtime_mcp_tools"]`
- Alias `local_recovery` → model `qwen3-27b` → `runtime_mcp_tools = "unsupported"`
- Result: skip alias, proceed to next in group

### 2.4 Cross-Validation at Startup

```
provider disabled/unreachable
  → all models using that provider: mark unavailable
    → all aliases using those models: mark unavailable
      → groups containing only unavailable aliases: log warning
        → cascade routes referencing unavailable groups: log error

model capability < route required_capabilities
  → alias skipped at resolution time (not startup)
```

## 3. Migration from Current System

### 3.1 Current State

| File | Lines | Role | Change |
|------|-------|------|--------|
| `cascade_capability_profile.ml` | 105 | Closed variant → **rewrite** |
| `cascade_capability_profile.mli` | 105 | Interface → **rewrite** |
| `cascade_toml_materializer.ml` | 595 | TOML→JSON → **minimal** (already passes strings) |
| `cascade_config_loader.ml` | 933 | JSON parsing → **moderate** (profile validation) |
| `cascade_catalog_validator.ml` | 356 | Validation → **moderate** |
| `cascade_tier.ml` | 22 | Tier def → **rewrite** |

### 3.2 Mapping: Current JSON → New TOML

Current `~/.masc/config/cascade.json`:
```json
{
  "keeper_bound_safe_models": "claude-sonnet-4-6-20250514,...",
  "keeper_bound_safe_temperature": "1.0",
  "keeper_bound_safe_required_capability_profile": "tool_strict"
}
```

New `config/cascade.toml`:
```toml
[groups.keeper_bound_safe]
aliases = ["strict", "fast"]
# capability_profile replaced by per-model capability declarations
```

### 3.3 Migration Phases

| Phase | Scope | Files |
|-------|-------|-------|
| **Phase 0** | Types + TOML parser | `cascade_declarative_types.ml`, `cascade_declarative_parser.ml`, seed `cascade.toml` |
| **Phase 1** | Capability matrix | Replace closed variant with config-driven `required_capabilities : string list` |
| **Phase 2** | Group resolution engine | Sequential cascade within groups, group→group cascade |
| **Phase 3** | Legacy migration tool | JSON→TOML converter, backward compat layer |

## 4. New Modules

### 4.1 `cascade_declarative_types.ml`

Core types for the 4-layer model:

```ocaml
type capability_level = Verified | Declared | Unsupported

type provider_kind = Cloud_api | Local | Cli

type provider_config = {
  kind : provider_kind;
  base_url : string option;
  api_key_env : string option;
  concurrency : int;
  headers : (string * string) list;
  command : string option;  (* for CLI providers *)
}

type model_capability = {
  inline_tools : capability_level;
  inline_tool_choice : capability_level;
  runtime_mcp_tools : capability_level;
  runtime_tool_events : capability_level;
  runtime_mcp_http_headers : capability_level;
  thinking : capability_level;
  structured_output : capability_level option;
}

type model_config = {
  provider : string;
  model_id : string;
  context_window : int;
  capabilities : model_capability;
}

type thinking_config =
  | Disabled
  | Enabled of { budget_tokens : int }

type alias_config = {
  model : string;  (* references [models.<name>] *)
  thinking : thinking_config;
  temperature : float option;
  system_prompt_suffix : string option;
}

type group_config = {
  strategy : [> `Sequential ];
  aliases : string list;  (* references [aliases.<name>] *)
}

type cascade_route = {
  groups : string list;  (* references [groups.<name>] *)
  required_capabilities : string list;
}

type cascade_config = {
  providers : (string * provider_config) list;
  models : (string * model_config) list;
  aliases : (string * alias_config) list;
  groups : (string * group_config) list;
  cascades : (string * cascade_route) list;
}
```

### 4.2 `cascade_declarative_parser.ml`

TOML parsing via existing `Toml` library (already in opam dependencies):

```ocaml
val parse_cascade_toml : string -> (cascade_config, string) result
val resolve_alias : cascade_config -> string -> (resolved_alias, string) result
val resolve_group : cascade_config -> string -> (resolved_group, string) result
val resolve_cascade : cascade_config -> string -> (resolved_cascade, string) result
```

Resolution pipeline:
1. Parse TOML → `cascade_config`
2. Validate cross-references (alias→model→provider chain)
3. At runtime: resolve cascade → groups → aliases → filter by capability
4. Sequential attempt through resolved aliases

## 5. Concrete Example: Current Routes → New TOML

### Current `cascade.json` routes:

| Route | Models | Profile | Purpose |
|-------|--------|---------|---------|
| `keeper_bound_safe` | claude-sonnet-4-6 | tool_strict | Primary keeper turn |
| `tier_fast` | claude-sonnet-4-6, qwen3:27b | lite | Fast fallback |
| `cloud_strict` | claude-sonnet-4-6, gemini-2.5-pro | tool_strict | Cloud with alternatives |
| `local_recovery` | qwen3:27b | local_inline | Local-only fallback |
| `tool_rerank` | claude-sonnet-4-6, gemini-2.5-pro, qwen3:27b | inline_tools | Tool-heavy tasks |

### New `cascade.toml` equivalents:

All 5 routes map directly to `[groups.*]` sections. The `required_capability_profile`
field disappears — replaced by per-model `[models.*.capabilities]` + cascade-level
`required_capabilities` filter.

`tool_strict` profile becomes:
```toml
required_capabilities = ["inline_tools", "inline_tool_choice", "runtime_mcp_tools",
                          "runtime_tool_events", "runtime_mcp_http_headers"]
```

`lite` profile becomes:
```toml
required_capabilities = []  (* no hard requirements, any model works *)
```

`local_inline` profile becomes:
```toml
required_capabilities = ["inline_tools", "inline_tool_choice"]
# combined with provider_kind filter for local-only
```

## 6. Open Questions

1. **Provider health check**: Should TOML declare a health endpoint, or rely on
   runtime probe? Recommendation: runtime probe (current behavior).

2. **Hot reload**: Should `cascade.toml` changes take effect without server restart?
   Recommendation: Phase 0-2 no, Phase 3+ optional via SIGHUP.

3. **TOML discovery path**: Where does `cascade.toml` live?
   - `${base_path}/.masc/config/cascade.toml` (alongside current `cascade.json`)
   - Migration: both files valid, TOML takes precedence

4. **Backward compatibility**: Can JSON and TOML coexist during migration?
   Recommendation: Yes. If TOML exists, use it. If only JSON, use legacy path.
   Log warning if both exist.

5. **Strategy beyond sequential**: The schema uses `strategy = "sequential"` as
   placeholder. Future strategies (round-robin, weighted, cost-optimized) are
   out of scope for initial implementation.

## 7. Risks

| Risk | Mitigation |
|------|------------|
| TOML parsing differs from existing JSON pipeline | Existing `Toml` library, same `cascade_toml_materializer` patterns |
| Cross-reference validation misses cycles | Startup validation: topological sort on dependency graph |
| Migration breaks existing keeper turns | Phase 3: backward compat layer, TOML takes precedence only when present |
| Capability drift (declared ≠ actual) | Periodic runtime probe comparing declared vs observed (future work) |

## 8. Acceptance Criteria

- [ ] TOML file defines all 4 layers (providers, models, aliases, groups)
- [ ] Closed variant `cascade_capability_profile.ml` replaced by config-driven types
- [ ] Existing cascade routes (`keeper_bound_safe`, `tier_fast`, etc.) expressible in TOML
- [ ] Startup validation catches: missing provider, unreachable model, capability mismatch
- [ ] Sequential cascade within groups works (alias1→alias2→alias3)
- [ ] Sequential cascade between groups works (group1→group2→group3)
- [ ] Per-provider concurrency respected
- [ ] Existing tests pass (or are migrated to new types)
- [ ] Legacy JSON path still works when no TOML is present
