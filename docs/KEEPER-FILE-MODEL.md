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
| `goal` | Required for a standalone operational persona | Primary goal | If absent, a caller must override it explicitly. |
| `short_goal` | Optional | Short-horizon goal | Defaults to `goal` in create paths. |
| `mid_goal` | Optional | Mid-horizon goal | Defaults to `goal` in create paths. |
| `long_goal` | Optional | Long-horizon goal | Defaults to `goal` in create paths. |
| `will` | Optional | Keeper self-model: will | Identity field. |
| `needs` | Optional | Keeper self-model: needs | Identity field. |
| `desires` | Optional | Keeper self-model: desires | Identity field. |
| `instructions` | Optional | Persona-specific instructions | Identity field. |
| `mention_targets` | Optional | Default mention aliases | If omitted, create-from-persona falls back to `[persona_name]`. |
| `tool_preset` | Optional | Default tool policy preset | Canonical place for default tool intent. |
| `tool_also_allow` | Optional | Additional tools layered onto preset | Use sparingly. |
| `tool_denylist` | Optional | Tools to remove from the resolved preset | Optional policy refinement. |
| `policy_voice_enabled` | Optional | Whether voice tools should be surfaced | Policy default, not runtime state. |
| `shards` | Optional | Default tool shards | Optional specialization hook. |

### `keeper` object: compatibility-only fields

These may still be parsed today, but they are **not** the preferred place to encode the concept.

| Field | Status | Preferred owner |
| --- | --- | --- |
| `allowed_paths` | Ignored by design | nowhere in persona |
| `cascade_name` | Compatibility-only | `keeper.toml` |
| `work_discovery_*` | Compatibility-only | `keeper.toml` or runtime policy |
| `telemetry_feedback_*` | Compatibility-only | `keeper.toml` or runtime policy |
| `max_turns_per_call*` | Compatibility-only | `keeper.toml` |

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
| `sandbox_profile` | Optional | Process/filesystem sandbox profile | `local` runs on the host with fs scoped to the keeper playground. `docker` runs in a hardened ephemeral container; the basic-mode git/gh dispatcher can upgrade network+credential mounts per-command. Hard mode requires `docker`. |
| `network_mode` | Optional | Sandbox network policy | `docker` defaults to `none` (basic-mode git/gh dispatcher can promote to `inherit`); `local` defaults to `inherit`. Hard mode requires `none`. |
| `cascade_name` | Optional | Deployment-specific cascade override | Only when not using the default cascade. |
| `tool_preset` | Optional | Deployment-specific policy override | Only when intentionally overriding persona default. |
| `github_identity` | Optional | Bound GitHub CLI identity bundle | Resolves to `.masc/github-identities/<identity>/gh` for keeper-scoped `gh` auth. Required when `MASC_KEEPER_SANDBOX_HARD_MODE=true`. |
| `git_identity_mode` | Optional | Commit identity policy | `keeper_alias` keeps git author separate from GitHub auth; `github_identity` is reserved for future explicit coupling. |
| `active_goal_ids` | Optional | Goal-scoped claim filter | When set, `keeper_task_claim` claims only tasks linked to these goals. If the scoped pool has no task claimable with the keeper's current capabilities, the claim stops; only auto-repaired keeper-purpose goals may fall back to all claimable tasks. |

### Additional supported overlay fields

These are still accepted by the loader, but for consistency they should be used only when a basepath-specific override is genuinely necessary.

| Field | Type | Meaning |
| --- | --- | --- |
| `goal`, `short_goal`, `mid_goal`, `long_goal` | string | Override persona goals |
| `will`, `needs`, `desires`, `instructions` | string | Override persona self-model / prompt |
| `mention_targets` | string array | Override persona mention aliases |
| `policy_voice_enabled` | bool | Override persona voice policy |
| `proactive_enabled` | bool | Override default proactive scheduling |
| `proactive_idle_sec`, `proactive_cooldown_sec` | int | Proactive scheduling intervals |
| `room_signal_prompt_enabled` | bool | Override room-signal prompt behavior |
| `allowed_paths` | string array | Exceptional path override only; prefer empty and rely on the single sandbox root |
| `tool_also_allow` | string array | Extra tool names added to the preset surface |
| `tool_denylist` | string array | Tool names blocked regardless of preset |
| `active_goal_ids` | string array | Declarative goal scope for task claim eligibility |
| `work_discovery_enabled` | bool | Enable work discovery loop |
| `work_discovery_sources` | string array | e.g. `["github_issues", "stale_tasks"]` |
| `work_discovery_interval_sec` | int | Scan interval |
| `work_discovery_guidance` | string | Hint string fed into the work-discovery prompt |
| `telemetry_feedback_enabled` | bool | Surface recent telemetry in the keeper prompt |
| `telemetry_feedback_window_hours` | int | Window size for telemetry summarization |
| `max_turns_per_call`, `max_turns_per_call_scheduled_autonomous` | int | Per-keeper turn budget override |
| `shards` | string array | Tool shard override |

### Allowed value sets

Enumerated fields only accept the values below. The loader rejects invalid input with an explicit error.

| Field | Allowed values |
| --- | --- |
| `sandbox_profile` | `local`, `docker` |
| `network_mode` | `none`, `inherit` |
| `git_identity_mode` | `keeper_alias`, `github_identity` |
| `tool_preset` | `minimal`, `social`, `messaging`, `coding`, `research`, `delivery`, `full` |
| `social_model` | `bdi_speech_v1`, `magentic_ledger_v1` (non-public: rejected when passed via tool args; TOML-only) |
| `cascade_name` | any `<name>` such that `<name>_models` exists in `cascade.json` (e.g. `keeper_unified`, `nick0cave`) |

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
- `github_identity`가 설정된 keeper는 `.masc/github-identities/<identity>/gh`만 사용하고, bundle이 없으면 fail-closed 된다. operator 개인 `gh` config, ambient `GH_TOKEN`/`GITHUB_TOKEN`, SSH agent로는 fallback 하지 않는다.
- `github_identity`가 없는 keeper는 `.masc/github-identities/root/gh` root bundle만 fallback으로 사용한다. root bundle도 없으면 fail-closed 된다.
- `MASC_KEEPER_SANDBOX_HARD_MODE=true`에서는 Docker container의 git/gh network dispatch와 ambient operator credential 사용이 꺼지고, `keeper_shell op=gh` / `op=git_clone`만 host-side broker가 selected identity bundle의 `GH_CONFIG_DIR`로 실행한다.

### Removed / forbidden fields (hard-rejected)

These keys are **rejected at load time** with an `Error`. They are retained only to flag drift from older configs so that stale deployments fail loud instead of silently mis-configuring keepers.

| Field | Replacement / rationale |
| --- | --- |
| `also_allow` | Renamed to `tool_also_allow` in `keeper.toml`. Use `tool_access.also_allow` only inside the JSON `tool_access` object. |
| `models`, `allowed_models`, `active_model` | Models are resolved at runtime from `cascade_name` → `cascade.json`. Do not pin per-keeper. |
| `presence_keepalive`, `presence_keepalive_sec` | Use `paused` in runtime JSON; keepalive is managed by the keepalive fiber. |
| `trigger_mode`, `policy_action_budget` | Removed with the legacy policy engine. |
| `initiative_scope`, `initiative_enabled`, `initiative_idle_sec`, `initiative_cooldown_sec` | Renamed to `proactive_*` (see above). |
| `policy_mode`, `policy_shell_mode` | Removed with the legacy policy engine. |

Definitive list: `removed_keeper_input_key_names` in [`lib/keeper/keeper_config.ml`](../lib/keeper/keeper_config.ml).

### Unknown-key schema health

Keys under `[keeper]` that are neither canonical (above) nor hard-rejected are surfaced as blocking schema health:

```text
keeper_config_schema_status=blocked
keeper_config_schema_terminal_reason=config_unknown_keys
```

Historically, dead config like `legacy_scope` and `scope_kind` accumulated here. Treat this as an operator-action-required drift signal and clean up the TOML.

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
| `work_discovery_*` runtime counters | Optional | Work-discovery runtime counters |
| `telemetry_feedback_*` state | Optional | Runtime feedback state |

### Important compatibility note

Current implementation may still materialize some authored fields into `keeper.json`
for compatibility (`goal`, `instructions`, etc.).

Those fields are **not** the preferred edit surface.

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
