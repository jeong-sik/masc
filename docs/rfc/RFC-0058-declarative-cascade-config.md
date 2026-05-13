# RFC-0058: Declarative Cascade Configuration (v2)

| Field | Value |
|-------|-------|
| Status | Draft |
| Author | Vincent (architect), Claude (agent) |
| Created | 2026-05-10 |
| Updated | 2026-05-10 |
| Supersedes | RFC-0055 (cascade fallback tier routing), RFC-0058 Phase 1 (TOML-only loader hotpath, PR #14460) |
| Depends | agent_sdk `Provider_kind.t` elimination (breaking) |
| Breaking | Yes — current `cascade.toml` profile format incompatible |

---

## 1. Problem

Phase 1 (PR #14460) moved the cascade loader to TOML-only mode, but the schema
remains a flat profile structure where provider, model, capacity, and strategy
are interleaved in a single `[profile_name]` TOML table.

More fundamentally, the runtime hardcodes provider identity as an OCaml variant:

```ocaml
(* agent_sdk: provider_config.ml *)
type provider_kind =
  | Anthropic | Kimi | OpenAI_compat | Ollama | Gemini
  | Glm | DashScope | Claude_code | Gemini_cli | Kimi_cli | Codex_cli
```

Adding a provider requires OCaml compilation. The system cannot express:

1. Per-provider×model concurrency/capacity slots
2. Same provider registered twice (e.g., two Anthropic accounts)
3. Aliases — per-use overrides of a provider×model binding
4. Routing by tier/group composition, not by hardcoded profile name

**Root cause**: `Provider_kind.t` is a closed sum type. Provider identity
should be a config-defined string, not a variant constructor.

## 2. Design: 5-Layer Declarative TOML

### 2.1 Absolute Principle

**Code never knows provider names or model names.**

- `Provider_kind.t` (11 constructors) → replaced by `api_format` (3 constructors) + `transport` (2 constructors)
- No string literals: `"claude_code"`, `"gemini_cli"`, `"ollama"`, etc.
- No provider-branded module names: `Claude_code_provider`, `Ollama_http_adapter` — forbidden
- Provider/model identity = `string` from config, not from code
- All routing, selection, and dispatch driven by config

### 2.2 Layer Overview

```
Layer 1: [providers.*]     — How to connect (protocol, transport, credentials)
Layer 2: [models.*]        — What it can do (capabilities, context window)
Layer 3: [<p>.<m>]         — How much, at what cost (capacity, pricing)
Layer 4: [<p>.<m>.<a>]     — Per-use overrides (aliases)
Layer 5: [tier.*] + [tier-group.*] + [routes] — Routing strategy
```

The naming convention IS the reference: `[claude-code.haiku]` implicitly
requires `[providers.claude-code]` and `[models.haiku]` to exist.
Cross-reference validation happens at load time.

### 2.3 Runtime Internal Model

```ocaml
(** Code knows API formats, not provider brands. *)
type api_format =
  | Messages_api           (* Anthropic Messages API spec *)
  | Chat_completions_api   (* OpenAI Chat Completions spec *)
  | Ollama_api             (* Ollama native API spec *)

type transport =
  | Http of string         (* endpoint URL *)
  | Cli of string          (* command name *)

type credential_config =
  | Env of string          (* Environment variable name *)
  | File of string         (* Path to credential file *)
  | Inline of string       (* Direct token — DEV ONLY *)

type provider = {
  id : string;               (* config-defined, e.g. "claude-code" *)
  display_name : string;     (* human-readable, e.g. "Anthropic Claude Code CLI" *)
  api_format : api_format;
  transport : transport;
  is_non_interactive : bool;
  credentials : credential_config;
}

type model_spec = {
  id : string;                (* config-defined, e.g. "haiku" *)
  api_name : string;          (* actual API model name, e.g. "claude-haiku-4-5-20251001" *)
  tools_support : bool;
  max_context : int;
  thinking_support : bool;
  max_thinking_budget : int option;
  streaming : bool;
}

type binding = {
  provider_id : string;       (* references [providers.<p>] *)
  model_id : string;          (* references [models.<m>] *)
  is_default : bool;
  max_concurrent : int;       (* per-binding capacity slot *)
  price_input : float option;
  price_output : float option;
}

type alias = {
  provider_id : string;
  model_id : string;
  name : string;              (* e.g. "for-scoring" *)
  max_input : int option;
  max_output : int option;
  temperature : float option;
}

type tier = {
  name : string;
  members : string list;      (* "provider.model" or "provider.model.alias" *)
  strategy : strategy;
  max_concurrent : int option; (* tier-level cap *)
}

type tier_group = {
  name : string;
  tiers : string list;
  strategy : strategy;
}

type system_route = {
  name : string;              (* e.g. "governance" *)
  target : string;            (* "provider.model.alias" *)
}
```

### 2.4 Protocol Adapters

Thin adapter modules (100-200 LOC each). Code dispatches by `api_format`,
never by provider name.

| Protocol string in TOML | `api_format` in code | Adapter module | Wire format |
|--------------------------|---------------------|----------------|-------------|
| `"anthropic-cli"` | `Messages_api` | `Messages_api_adapter` | Anthropic Messages |
| `"anthropic-http"` | `Messages_api` | `Messages_api_adapter` | Anthropic Messages |
| `"google-cli"` | `Chat_completions_api` | `Chat_completions_cli_adapter` | Google format |
| `"ollama-http"` | `Ollama_api` | `Ollama_api_adapter` | Ollama native |
| `"openai-http"` | `Chat_completions_api` | `Chat_completions_api_adapter` | OpenAI format |
| `"kimi-cli"` | `Chat_completions_api` | `Kimi_cli_adapter` | Kimi format |

Adding a new provider that uses an existing protocol = TOML entry only.
Adding a new protocol = thin adapter module + TOML protocol string registration.

Note: vLLM, LM Studio, and other OpenAI-compatible servers all use
`"openai-http"` — no code change needed.

## 3. TOML Schema

### 3.1 Reserved Top-Level Namespaces

`providers`, `models`, `system`, `tier`, `tier-group`, `routes`, `profiles`

Any provider alias that collides with a reserved namespace is a load-time error.

### 3.2 Layer 1: Providers

```toml
[providers.claude-code]
display-name = "Anthropic Claude Code CLI"
protocol = "anthropic-cli"
command = "claude"
is-non-interactive = true

[providers.claude-code.credentials]
type = "env"
key = "ANTHROPIC_API_KEY"

[providers.claude-code-alt]
display-name = "Anthropic Claude Code CLI (alt account)"
protocol = "anthropic-cli"
command = "claude"
is-non-interactive = true

[providers.claude-code-alt.credentials]
type = "file"
path = "~/.config/claude-alt/key"

[providers.kimi-code]
display-name = "Moonshot Kimi Code"
protocol = "kimi-cli"
command = "kimi"
is-non-interactive = true

[providers.ollama]
display-name = "Ollama Local"
protocol = "ollama-http"
endpoint = "http://localhost:11434"

[providers.gemini-cli]
display-name = "Google Gemini CLI"
protocol = "google-cli"
command = "gemini"
is-non-interactive = true

[providers.codex]
display-name = "OpenAI Codex CLI"
protocol = "openai-http"
endpoint = "https://api.openai.com"

[providers.codex.credentials]
type = "env"
key = "OPENAI_API_KEY"
```

**Provider fields:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `display-name` | string | yes | Human-readable name |
| `protocol` | string | yes | Protocol adapter selector |
| `command` | string | CLI only | CLI command name |
| `endpoint` | string | HTTP only | Base URL |
| `is-non-interactive` | bool | no | Default `false` |
| `headers` | table | no | Additional HTTP headers |

**Credential sub-table `[providers.<p>.credentials]`:**

| Field | Type | Description |
|-------|------|-------------|
| `type` | `"env"` / `"file"` / `"inline"` | Credential source |
| `key` | string | For `env`: variable name |
| `path` | string | For `file`: file path |

#### 3.2.1 No provider liveness sub-table

Attempt liveness is deliberately not a provider schema field. The
runtime starts with an explicit bootstrap budget, then learns from
recent successful samples for each concrete provider/model candidate.
Failed, killed, rejected, or cancelled attempts do not train the
budget. This keeps model-size labels and provider ids out of the
liveness taxonomy.

### 3.3 Layer 2: Models

```toml
[models.haiku]
api-name = "claude-haiku-4-5-20251001"
tools-support = true
max-context = 200000
streaming = true

[models.sonnet]
api-name = "claude-sonnet-4-6"
tools-support = true
max-context = 200000
thinking-support = true
max-thinking-budget = 16000
streaming = true

[models.qwen3-8b]
api-name = "qwen3:8b"
tools-support = true
max-context = 32768
streaming = true
```

**Model fields:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `api-name` | string | yes | Actual model ID used in API calls |
| `tools-support` | bool | no | Default `false` |
| `max-context` | int | yes | Context window size |
| `thinking-support` | bool | no | Default `false` |
| `max-thinking-budget` | int | no | Required when `thinking-support = true` |
| `streaming` | bool | no | Default `true` |

### 3.4 Layer 3: Provider×Model Bindings

The table name `<provider>.<model>` IS the cross-reference. TOML tables at
the top level that are not reserved namespaces are treated as provider aliases.
Each sub-table name is a model reference.

```toml
[claude-code.haiku]
is-default = true
max-concurrent = 3
price-input = 0.80
price-output = 4.00

[claude-code.sonnet]
max-concurrent = 2
price-input = 3.00
price-output = 15.00

[claude-code-alt.haiku]
max-concurrent = 2
price-input = 0.80
price-output = 4.00

[ollama.qwen3-8b]
max-concurrent = 1
```

**Binding fields:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `is-default` | bool | no | Default `false`. At most one per provider. |
| `max-concurrent` | int | yes | Per-binding capacity slot |
| `price-input` | float | no | Cost per 1M input tokens |
| `price-output` | float | no | Cost per 1M output tokens |
| `keep-alive` | string | no | Ollama keep_alive duration |
| `num-ctx` | int | no | Ollama context window override |

### 3.5 Layer 4: Aliases (Per-Use Overrides)

```toml
[claude-code.haiku.for-scoring]
max-output = 1024
temperature = 0.1

[claude-code.haiku.for-governance]
max-input = 8192
max-output = 2048
temperature = 0.1

[ollama.qwen3-8b.fast-local]
max-output = 500
temperature = 0.3
```

Three-level TOML table: `<provider>.<model>.<alias>`. Inherits all binding
fields, overrides specified fields.

**Alias fields:**

| Field | Type | Description |
|-------|------|-------------|
| `max-input` | int | Override input token limit (≤ model `max-context`) |
| `max-output` | int | Override output token limit |
| `temperature` | float | Override temperature |
| `thinking-enabled` | bool | Override thinking |
| `thinking-budget` | int | Override thinking budget |

### 3.6 Layer 5: Tiers, Tier-Groups, and Routes

```toml
[tier.rerank]
members = ["claude-code.haiku.for-scoring"]
strategy = "failover"

[tier.primary]
members = ["claude-code.sonnet", "claude-code.haiku"]
strategy = "failover"
max-concurrent = 5

[tier.local]
members = ["ollama.qwen3-8b"]
strategy = "failover"

[tier-group.primary]
tiers = ["primary", "local"]
strategy = "priority_tier"
fallback = true

[tier-group.rerank-only]
tiers = ["rerank"]
strategy = "failover"

[routes]
keeper_turn = "primary"
governance_judge = "primary"
scoring = "rerank-only"
simple_task = "local"

[system.governance]
target = "claude-code.haiku.for-governance"
```

**Tier fields:**

| Field | Type | Description |
|-------|------|-------------|
| `members` | string[] | Binding or alias references |
| `strategy` | string | `"failover"`, `"weighted_random"`, `"priority_tier"` |
| `max-concurrent` | int | Tier-level cap (sum of member caps ≥ this value) |

**Tier-group fields:**

| Field | Type | Description |
|-------|------|-------------|
| `tiers` | string[] | Tier references in priority order |
| `strategy` | string | Group-level strategy |
| `fallback` | bool | Whether this group serves as fallback target |

## 4. Load-Time Validation

1. Every `[<p>.<m>]` must have `[providers.<p>]` AND `[models.<m>]`
2. Every `[<p>.<m>.<a>]` must have `[<p>.<m>]`
3. Alias `max-input` ≤ binding's effective `max-input` ≤ model's `max-context`
4. Tier members must resolve to valid bindings or aliases
5. Tier-group tiers must resolve to valid tiers
6. Route targets must resolve to valid tier-groups
7. Provider alias must not collide with reserved namespaces
8. `is-default = true` — at most one per provider
9. Unknown fields in any table = load error (catch typos at config time)

Validation errors are fatal at startup. The system refuses to start with
an invalid cascade config rather than silently degrading.

## 5. Capacity Model

Each `[<p>.<m>]` binding declares `max-concurrent`. The runtime maintains
per-binding capacity slots, replacing the current URL-based
`Cascade_client_capacity` registry.

```
[claude-code.sonnet]  →  slot: { max: 2, active: 0 }
[claude-code.haiku]   →  slot: { max: 3, active: 1 }
[ollama.qwen3-8b]     →  slot: { max: 1, active: 0 }
```

Tier-level `max-concurrent` is a cap: the sum of member binding caps must be
≥ the tier cap. Load-time validation enforces this.

## 6. Migration

**Breaking change.** Current `cascade.toml` profile format is incompatible.
The migration path:

| Current | New |
|---------|-----|
| `[primary]` profile with `models = [...]` | `[tier.primary]` members referencing bindings |
| `"claude_code:auto"` model strings | `[claude-code.haiku]` binding + `[models.haiku]` |
| `_required_capability_profile` field | Per-model `tools-support` + per-route filtering |
| `cascade_capability_profile.ml` closed variant | Config-driven `api_format` + `transport` |
| `Provider_kind.t` 11-variant closed sum | `api_format` 3-variant + `transport` 2-variant |
| URL-based capacity registry | Per-binding capacity slot |

A migration script converts the current `config/cascade.toml` to the new schema.
Existing tests that reference flat profiles are updated to reference the new
binding/alias path.

## 7. Files Affected

### Rewrite (breaking)

| File | Current LOC | Role |
|------|-------------|------|
| `provider_kind_resolver.ml` | 80 | String→variant dispatch → config-driven resolution |
| `cascade_transport.ml` | 200+ | Provider-kind CLI dispatch → protocol adapter dispatch |
| `cascade_capability_profile.ml` | 105 | Closed variant → eliminated (config-driven) |
| `cascade_tier.ml` | 22 | Tier def → expanded with new types |
| `cascade_client_capacity.ml` | 100 | URL-based → binding-based capacity |
| `cascade_toml_materializer.ml` | 595 | Flat profile parser → 5-layer parser |

### Moderate changes

| File | Role |
|------|------|
| `cascade_config_loader.ml` | Profile loading → declarative config loading |
| `cascade_catalog_runtime.ml` | Profile snapshot → binding/tier snapshot |
| `cascade_config.ml` | Re-exports → updated types |
| `cascade_routes.ml` | Route mapping → tier-group routing |
| `cascade_strategy.ml` | Strategy selection → config-driven strategy |
| `cascade_pool.ml` | Model pool → binding pool |
| `cascade_inventory.ml` | Inventory → binding inventory |

### New modules

| Module | Role |
|--------|------|
| `cascade_declarative_types.ml` | 5-layer type definitions |
| `cascade_declarative_parser.ml` | TOML → typed config parser |
| `cascade_declarative_validator.ml` | Cross-reference validation |
| `messages_api_adapter.ml` | Anthropic Messages protocol |
| `chat_completions_api_adapter.ml` | OpenAI/Google HTTP protocol |
| `ollama_api_adapter.ml` | Ollama native protocol |
| `kimi_cli_adapter.ml` | Kimi CLI protocol |

## 8. Implementation Phases

### Phase 0: RFC + Types (this document)
- Write RFC-0058 v2
- Define `cascade_declarative_types.ml` with internal types

### Phase 1: Schema + Parser
- `cascade_declarative_parser.ml` — TOML → typed config
- `cascade_declarative_validator.ml` — cross-reference checks
- Unit tests for parser and validator

### Phase 2: Protocol Adapters
- `api_format` dispatch replacing `provider_kind` dispatch
- Thin adapter modules per protocol
- CLI invocation logic moved into adapters

### Phase 3: Runtime Integration
- Adapter layer: new types → existing `Cascade_catalog` interface
- Binding-based capacity slots replacing URL-based registry
- Existing integration tests pass through adapter

### Phase 4: Migration + Dashboard
- Migration script: old `cascade.toml` → new schema
- Dashboard JSON removal (absorbed into TOML-only mode)
- `ensure_materialized_json` eliminated

### Phase 9: `cascade.json` elimination (split into 3 PRs)

The acceptance criterion "*`cascade.json` no longer generated or consumed*"
unwinds in three steps. The work splits not because there are many
*readers* (most readers go through `Cascade_config_loader.load_json`,
which is already in-memory — see Phase 9.1) but because there are two
remaining *writers* that materialise `config/cascade.json` on disk:
`lib/dashboard_cascade.ml` (two `ensure_materialized_json` call sites)
and the standalone `bin/cascade_materialize` CLI. Eliminating those
writers in the same change that also drops the source-tracked JSON
would couple a docs/test cleanup (9.1) with two behavioural rewrites
(9.2) and the type-system shrink that follows (9.3), so each phase
ships independently.

- **Phase 9.1 — Stop tracking the committed JSON** *(landed in #14578)*:
  drop the committed `config/cascade.json` and the byte-equality test
  that pinned it to the TOML render. Runtime behaviour is unchanged
  because the disk JSON has only two writers, and consumers that read
  the cascade do not depend on its presence on disk:
  - `Cascade_config_loader.load_json` (lib/cascade/cascade_config_loader.ml:96)
    branches on `source_info.kind`. Under the current TOML SSOT the
    branch is always `Toml`, which routes through
    `load_toml_in_memory` → `Cascade_toml_materializer.render_toml_to_json_string`
    and never opens the JSON sibling. The `Json` branch (which would
    `read_json_file`) is unreachable until someone removes the TOML.
  - The two writers that *do* materialise `config/cascade.json` on disk
    are `lib/dashboard_cascade.ml` (two `ensure_materialized_json` call
    sites, kept so the dashboard can serve the rendered file) and the
    `bin/cascade_materialize` CLI. Both keep working after Phase 9.1 —
    the JSON they emit is now a runtime artefact rather than a tracked
    source.
  Net effect of Phase 9.1: nothing in the runtime read path changes.
  The source-tracked copy is gone, so `git status` no longer shows a
  tracked diff when the regenerated file drifts from the old committed
  bytes. The runtime-materialised copy that the dashboard / CLI write
  *will* keep appearing as an **untracked** file in `git status` until
  Phase 9.2 stops the disk write and Phase 9.3 removes the write path
  entirely. Phase 9.1 intentionally does not add `config/cascade.json`
  to `.gitignore` — silencing the untracked entry would advertise the
  disk artefact as permanent, which is the opposite of the §9
  acceptance criterion.
- **Phase 9.2 — Migrate the remaining disk writers off JSON**: rework
  `lib/dashboard_cascade.ml` and `bin/cascade_materialize` to serve /
  emit the rendered JSON in memory via
  `Cascade_toml_materializer.render_toml_to_json_string`. After this
  phase no production code calls `ensure_materialized_json`. (The
  earlier framing of "migrate ~20 consumers off `load_json`" was based
  on the incorrect assumption that `load_json` still hit disk; it does
  not, so this phase shrinks to the two real writers.)
- **Phase 9.3 — Delete the JSON path entirely**: remove
  `ensure_materialized_json`, drop the `Json` variant from
  `Cascade_toml_materializer.source_kind` (now unreachable), retire the
  `read_json_file` branch in `Cascade_config_loader.load_json`, and
  audit-grep `lib/` + `bin/` for any residual `cascade.json`
  references.

## 9. Acceptance Criteria

- [ ] TOML file defines all 5 layers
- [ ] No provider/model string literals in code (grep-verified)
- [ ] `Provider_kind.t` eliminated from cascade code paths
- [ ] Code dispatches by `api_format` (3 variants), not provider name (11 variants)
- [ ] Per-binding capacity slots work
- [ ] Cross-reference validation catches all invalid configs at startup
- [ ] Existing cascade routes expressible in new schema
- [ ] Tier/tier-group routing works (within-tier failover + between-tier priority)
- [ ] Adding a new provider = TOML entry only (no compilation for existing protocols)
- [ ] All existing integration tests pass (migrated to new schema)
- [ ] `cascade.json` no longer generated or consumed

## 10. Risks

| Risk | Mitigation |
|------|------------|
| agent_sdk `Provider_kind.t` is used outside cascade | Adapter layer wraps cascade-internal types; agent_sdk boundary is explicit |
| CLI adapter complexity (claude, gemini, kimi differ) | Ugly internals are acceptable; each adapter is isolated (100-200 LOC) |
| Migration breaks running keepers | Migration script + staged rollout; old schema supported during transition |
| Cross-reference validation performance | O(n) single-pass at startup; not in hot path |
| TOML parsing edge cases | Existing `Toml` library (otoml) already proven in Phase 1 |

## 11. Related Documents

- `docs/CASCADE-TOML.md` — current TOML authoring guide (to be rewritten)
- `docs/rfc/RFC-0058-terminal-fallback-capability-exemption.md` — terminal fallback semantics
- `docs/rfc/RFC-0055.md` — GADT cascade tier routing (superseded)
- `config/cascade.toml` — current seed config (to be migrated)
- `docs/cascade/README.md` — cascade design index
