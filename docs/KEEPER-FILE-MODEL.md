---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/keeper/
  - config/
---

# Keeper File Model

**Status**: Active
**Audience**: operator, keeper implementer, dashboard maintainer
**One sentence**: keeper data is split into identity (`persona`), deployment declaration (`keeper.toml`), durable runtime state (`keeper.json`), and append-only runtime artifacts (`.masc/keepers/<name>/...`).

## Example

```text
basepath/.masc/config/personas/sangsu/profile.json
basepath/.masc/config/keepers/sangsu.toml
basepath/.masc/keepers/sangsu.json
basepath/.masc/keepers/sangsu/<many runtime artifacts>
```

## Ownership Model

| Path | Meaning | Truth class | Human edit surface |
| --- | --- | --- | --- |
| `.masc/config/personas/<name>/profile.json` | Identity. What this keeper is. | Authored config | Yes |
| `.masc/config/keepers/<name>.toml` | Deployment declaration. How this identity is launched here. | Authored config | Yes |
| `.masc/keepers/<name>.json` | Durable runtime state. What state this keeper is currently in. | System-owned runtime snapshot | No |
| `.masc/keepers/<name>/...` | High-cardinality runtime artifacts. Metrics, decisions, traces, checkpoints, etc. | System-owned append-only artifacts | No |

Short mnemonic:

- `persona` = who
- `keeper.toml` = where / how launched
- `keeper.json` = current saved state
- `keeper/` directory = detailed runtime history

## Non-Negotiable Rules

1. Identity belongs in `profile.json`.
2. Deployment defaults belong in `keeper.toml`.
3. Durable runtime state belongs in `.masc/keepers/<name>.json`.
4. High-cardinality history belongs under `.masc/keepers/<name>/`.
5. Do not manually edit runtime files to change authored intent.
6. `allowed_paths` is not part of persona identity.
7. `keeper.toml` should be thin. Prefer `persona_name` plus only exceptional overrides.

## 1. Persona Profile

Path:

```text
<basepath>/.masc/config/personas/<name>/profile.json
```

Purpose:

- Define keeper identity, tone, intent, and default behavior.
- Act as the blueprint used by `masc_keeper_create_from_persona`.
- Provide fallback defaults when a same-name keeper TOML is absent.

### Canonical top-level fields

| Field | Required | Meaning | Notes |
| --- | --- | --- | --- |
| `name` | Optional | Human display name | Used by persona listing / dashboard. |
| `role` | Optional | Short role description | Summary metadata only. |
| `background` | Optional | Longer descriptive background | Human-facing metadata. |
| `trait` | Optional | Short temperament label | Summary metadata only. |
| `tone` | Optional | Tone hints array | Human-facing metadata. |
| `top_expressions` | Optional | Signature phrases | Human-facing metadata. |
| `emoji_usage` | Optional | Emoji guidance | Human-facing metadata. |
| `expertise` | Optional | Structured capability notes | Human-facing metadata. |
| `relationship` | Optional | How the persona relates to the user/system | Human-facing metadata. |
| `integration` | Optional | Trigger / mode metadata | Human-facing metadata. |
| `keeper` | Required for an operational persona | Keeper defaults block | Without this, the file is metadata-only. |

### `keeper` object: canonical fields

These are the identity fields that should live in persona by default.

| Field | Required | Meaning | Notes |
| --- | --- | --- | --- |
| `instructions` | Optional | Persona-specific behavior and voice instructions | Used as prompt default unless a keeper TOML overlay overrides it. |
| `mention_targets` | Optional | Default mention aliases | If omitted, create-from-persona falls back to `[persona_name]`. |

There is no compatibility-only persona surface. Removed or unknown fields are
rejected instead of being interpreted as alternate state/config protocols.

## 2. Keeper Declaration

Path:

```text
<basepath>/.masc/config/keepers/<name>.toml
```

Purpose:

- Bind a concrete keeper name to a persona.
- Override only deployment-specific behavior for this basepath.
- Stay as small as possible.

### Canonical minimal form

```toml
[keeper]
persona_name = "analyst"
```

### Canonical fields

| Field | Required | Meaning | Notes |
| --- | --- | --- | --- |
| `persona_name` | Required | Which persona blueprint this keeper uses | Primary field in the target model. |
| `name` | Optional | Override keeper handle | Usually redundant because filename is already the keeper name. |
| `sandbox_profile` | Optional | Process/filesystem sandbox profile | `local` runs on the host with fs scoped to the keeper playground. `docker` runs in a hardened ephemeral container. Hard mode requires `docker`. |
| `network_mode` | Optional | Sandbox network policy | `docker` defaults to `none`; `local` defaults to `inherit`. Hard mode requires `none`. |

### Additional supported overlay fields

These are still accepted by the loader, but for consistency they should be used only when a basepath-specific override is genuinely necessary.

| Field | Type | Meaning |
| --- | --- | --- |
| `instructions` | string | Override persona prompt identity |
| `mention_targets` | string array | Override persona mention aliases |
| `proactive_enabled` | bool | Override default proactive scheduling |
| `proactive_idle_sec`, `proactive_cooldown_sec` | int | Proactive scheduling intervals |
| `allowed_paths` | string array | Exceptional path override only; prefer empty and rely on the single sandbox root |
| `telemetry_feedback_enabled` | bool | Surface recent telemetry in the keeper prompt |
| `telemetry_feedback_window_hours` | int | Window size for telemetry summarization |

The retired `shards` field is rejected in both persona `keeper` objects and
Keeper TOML. Tool-family membership is not a Keeper configuration axis; the
flat Tool catalog and execution-time Gate are the only relevant boundaries.

Runtime/model selection is not a keeper TOML field. Assign keepers in
`runtime.toml` under `[runtime.assignments]`, keyed by keeper name. Unassigned
keepers use `[runtime].default`.

### Allowed value sets

Enumerated fields only accept the values below. The loader rejects invalid input with an explicit error.

| Field | Allowed values |
| --- | --- |
| `sandbox_profile` | `local`, `docker` |
| `network_mode` | `none`, `inherit` |

Deprecated personality-state axes are not allowed public keeper TOML values.
The retired non-public keeper input list is currently empty in code.

### Sandbox Example

```toml
[keeper]
persona_name = "analyst"
sandbox_profile = "docker"
network_mode = "none"
```

Operational intent:

- private writable lane: the keeper sandbox. The current local/docker storage path is `.masc/playground/<keeper>/...`, but keeper tools should use sandbox-relative paths such as `repos/<repo>` and `mind/<file>`.
- no arbitrary shared writable shell directory
- `sandbox_profile=docker`는 `allowed_paths=["*"]`를 거부하고, private sandbox root 밖 경로도 허용하지 않는다
- `MASC_KEEPER_SANDBOX_HARD_MODE=true`에서는 Docker container의 ambient operator credential 사용이 꺼지고, keeper TOML 필드로 credential을 선택하지 않는다.

### Removed / forbidden fields (hard-rejected)

These keys are **rejected at load time** with an `Error`. They are retained only to flag drift from older configs so that stale deployments fail loud instead of silently mis-configuring keepers.

| Field | Replacement / rationale |
| --- | --- |
| `goal`, `active_goal_ids` | Legacy Goal inputs are removed. Planned work is represented by Workspace Tasks, not Keeper profile scope. |
| `tool_access`, `tool_denylist`, `shards`, `policy_voice_enabled` | Per-Keeper tool hierarchies are removed. The immutable catalog and descriptor/registry projection define which typed tools exist; each concrete external effect then reaches the Gate. |
| `runtime_id`, `model`, `runtime_ref` | Runtime assignment lives in `runtime.toml` `[runtime.assignments]`, keyed by keeper name. |
| `models`, `allowed_models`, `active_model` | Models are resolved from the assigned runtime. Do not pin per-keeper. |
| `allowed_providers` | Provider/model ownership lives in `runtime.toml` and OAS runtime receipts. Do not pin providers per keeper. |
| `presence_keepalive`, `presence_keepalive_sec` | Use `paused` in runtime JSON; keepalive is managed by the keepalive fiber. |
| `trigger_mode`, `policy_action_budget` | Removed with the legacy policy engine. |
| `initiative_scope`, `initiative_enabled`, `initiative_idle_sec`, `initiative_cooldown_sec` | Renamed to `proactive_*` (see above). |
| `policy_mode`, `policy_shell_mode` | Removed with the legacy policy engine. |

Definitive list: `removed_keeper_input_key_names` in [`lib/keeper/keeper_config.ml`](../lib/keeper/keeper_config.ml).

### Unknown-key warning

Keys under `[keeper]` that are neither canonical (above) nor hard-rejected are **silently ignored by the loader, but a warning is emitted**:

```text
keeper TOML <path> has unknown keys: keeper.legacy_scope, keeper.scope_kind
```

Historically, dead config like `legacy_scope` and `scope_kind` accumulated here. Treat these warnings as drift signals and clean up the TOML. The warning does not block boot.

Definitive canonical list: `canonical_keeper_toml_key_names` in [`lib/keeper/keeper_types_profile.ml`](../lib/keeper/keeper_types_profile.ml).

## 3. Keeper Runtime State

Path:

```text
<basepath>/.masc/keepers/<name>.json
```

Purpose:

- Persist durable runtime state across process restarts.
- Store the keeper's current save-state, not the authored blueprint.

### Canonical required fields

These are the fields that define the durable runtime snapshot itself.

| Field | Required | Meaning |
| --- | --- | --- |
| `name` | Required | Keeper handle |
| `agent_name` | Required | Canonical runtime agent handle |
| `trace_id` | Required | Current trace/session id |
| `paused` | Required | Whether the keeper is paused |
| `autoboot_enabled` | Required | Whether the keeper should auto-start |
| `created_at` | Required | Initial creation timestamp |
| `updated_at` | Required | Last durable update timestamp |

### Common optional runtime fields

| Field | Required | Meaning |
| --- | --- | --- |
| `current_task_id` | Optional | Currently assigned task id |
| `last_blocker` | Optional | Latest runtime blocker summary |
| `max_context_override` | Optional | Runtime context override if set |
| `last_turn_ts`, `last_model_used`, `last_latency_ms` | Optional | Last-turn runtime summary |
| `total_turns`, `total_tokens`, `total_cost_usd` | Optional | Accumulated runtime counters |
| `compaction_count`, `last_compaction_ts` | Optional | Compaction runtime counters |
| `proactive_count_total`, `last_proactive_ts` | Optional | Proactive runtime counters |
| `telemetry_feedback_*` state | Optional | Runtime feedback state |

### Runtime snapshot note

The runtime may snapshot identity text such as `instructions` into `keeper.json`
for status and prompt assembly. Removed `goal` values are rejected rather than
read, migrated, or scrubbed.

Operational rule:

- edit authored intent in `profile.json` or `keeper.toml`
- treat `keeper.json` as system-owned runtime state

## 4. Keeper Runtime Artifacts

Path:

```text
<basepath>/.masc/keepers/<name>/
```

Purpose:

- Store high-cardinality append-only runtime history that does not belong in the single `keeper.json` snapshot.

### Typical artifact families

| Artifact | Required | Meaning |
| --- | --- | --- |
| `metrics/**/*.jsonl` | Optional | Runtime metrics samples |
| `decisions.jsonl` | Optional | Decision/event log |
| checkpoints / trajectory / evidence subtrees | Optional | Detailed per-turn or per-trace artifacts |

These files are event-driven and may be absent for a keeper that has not yet produced that artifact class.

There is no single stable JSON schema for the directory as a whole.

## Recommended Editing Policy

| Surface | Edit policy |
| --- | --- |
| `profile.json` | Human-edited |
| `keeper.toml` | Human-edited |
| `.masc/keepers/<name>.json` | System-owned |
| `.masc/keepers/<name>/...` | System-owned |

## Recommended Minimal Trio

For the default seed cohort (`analyst`, `scholar`, `executor`):

- keep persona identity in `config/personas/<name>/profile.json`
- keep `config/keepers/<name>.toml` to only `persona_name`
- leave runtime files entirely system-owned

Example:

```toml
[keeper]
persona_name = "executor"
```
