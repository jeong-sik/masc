---
rfc: "keeper-remove-per-call-max-turns"
title: "Remove per-call max_turns budget, delegate to OAS SDK default"
status: Draft
created: 2026-06-25
updated: 2026-06-25
author: vincent
supersedes: []
superseded_by: null
related: ["0082", "0096", "0271"]
implementation_prs: []
---

# RFC (keeper-remove-per-call-max-turns): Remove per-call max_turns budget

Status: Draft · MASC sets a per-call turn cap (`max_turns`) on every keeper
`Agent.run`, sourced from a MASC-owned config surface (`reactive_max_turns_per_call`
default 30, `autonomous_max_turns_per_call` default 10) and extended at runtime by a
self-extending `extend_turns` tool. The OAS SDK already owns a turn cap with its own
default. This RFC removes the MASC-side duplicate and delegates the cap to the SDK,
deleting the `max_turns_per_call` config surface and the `extend_turns` tool.

**Surfaces (CLAUDE.md agent_delegation)**: `lib/keeper/*` turn-execution
(`keeper_agent_run`, `keeper_run_tools_setup`, `keeper_runtime_resolved`,
`keeper_extend_turns`, `keeper_turn_runtime_budget*`, `keeper_types_profile*`),
`config/tool_policy.toml`, and dashboard config-resolution surfaces. Not
credential/operator/sandbox/hooks — outside the mandatory-RFC list — but authored as
RFC because it deletes an operator-visible config contract (two env vars + two
per-keeper TOML keys) and changes keeper turn behavior.

## 1. Problem

`max_turns` is the per-call ceiling on agent steps inside one `Agent.run`. MASC
currently owns this number in three overlapping places:

1. **Config surface** — `Keeper_runtime_resolved.{reactive,autonomous}_max_turns_per_call`
   resolves it from env (`MASC_KEEPER_OAS_MAX_TURNS_PER_CALL` default 30,
   `..._SCHEDULED_AUTONOMOUS` default `min(reactive,10)`), clamped to `[1,100]`, and
   per-keeper TOML overrides (`max_turns_per_call`, `max_turns_per_call_scheduled_autonomous`).
2. **Threading** — `keeper_agent_run.run_turn ?max_turns` defaults to the reactive value
   and threads it through `keeper_run_tools_setup`, `keeper_turn_runtime_budget`
   (telemetry field), and the OAS call.
3. **Runtime tool** — `keeper_extend_turns.make` registers an `extend_turns` tool (a
   survival-critical, policy-bypassing core tool) that lets the model raise its own
   `max_turns` mid-session up to a ceiling.

This duplicates state the OAS SDK already holds: `Agent_sdk` resolves `max_turns` from
its own `default_config.max_turns` (`agent_sdk/lib/base/types.ml`) when the caller
passes none. The MASC layer adds a second source of truth, a self-mutating tool, and a
config envelope on top of it.

The per-call budget is also implicated in the livelock/display-latch class: RFC-0082
documents `"[turn budget exhausted: 10/10 turns used]"` becoming a frozen display latch
when subsequent cycles fail before producing text. The per-call cap is the thing being
exhausted there. Removing the MASC-side cap removes that surface.

## 2. Decision

Delete the MASC-side per-call turn budget. Specifically:

- Remove `reactive_max_turns_per_call` / `autonomous_max_turns_per_call` (fields,
  `_live` resolvers, `[1,100]` clamp constants, yojson, accessors) from
  `Keeper_runtime_resolved`.
- Remove `?max_turns` from `keeper_agent_run.run_turn` and the threading chain
  (`keeper_run_tools`, `keeper_run_tools_setup`, `keeper_turn_runtime_budget`,
  `keeper_turn_runtime_budget_provider_timeout`). The OAS call no longer passes
  `~max_turns`; the SDK applies its own default.
- Delete `keeper_extend_turns.ml/.mli` and the `extend_turns` tool registration
  (`core_always_tools`, `keeper_run_tools_setup`, `tool_policy.toml`, telemetry
  noisy-name set).
- Remove the per-keeper TOML keys `max_turns_per_call` /
  `max_turns_per_call_scheduled_autonomous` from the profile-defaults record and its
  parser/normalizer/IO surfaces. Unknown TOML keys are already surfaced as drift via
  `warn_unknown_keeper_toml_keys`, so stale keys become visible rather than silently
  honored.
- Remove the dashboard `reactive_max_turns_per_call` / `autonomous_max_turns_per_call`
  resolved-config rows and the `max_turns` field of the provider-timeout telemetry
  type.

Runaway remains bounded by three mechanisms that do not depend on the MASC cap:
the SDK's own `max_turns` default, `max_idle_turns` (the OAS loop guard, kept), and the
token budget.

## 3. Safety analysis

The retained comment in `keeper_config.ml` records the known danger envelope: *1000
turns caused 787s+ latency per turn; 20 turns caused 6.7GB RSS in 2 minutes with 3
concurrent keepers*. The load-bearing question is whether delegating to the SDK default
stays inside that envelope.

`agent_sdk/lib/base/types.ml` sets `default_config.max_turns = 10`. The keeper
`Agent.create` path resolves through `builder.ml` / `agent_sdk.ml` to this default when
no `max_turns` is passed. So after this change:

| channel | before (MASC) | after (SDK default) | direction |
|---|---|---|---|
| reactive | 30 | 10 | lower (more conservative) |
| autonomous | `min(reactive,10)` = 10 | 10 | unchanged |

10 is below both documented danger thresholds (20-turn RSS, 1000-turn latency). The
change moves the reactive cap *down*, not up — it cannot regress into the danger
envelope. The SDK still enforces 10 as a hard per-call cap, so "runaway" is bounded by
the SDK, not removed.

## 4. Migration / operator impact

- **Env vars** `MASC_KEEPER_OAS_MAX_TURNS_PER_CALL` and
  `MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS` become no-ops (the resolver
  is deleted). `BOOT-ENV-STATE-INVENTORY.md` knob count drops 75 → 73.
- **Per-keeper TOML** keys `max_turns_per_call[_scheduled_autonomous]` become no-ops and
  are reported as unknown-key drift on boot instead of applied.
- **Behavior**: reactive keepers get 10 steps per call instead of 30 before the turn
  ends. Continuity is preserved — a keeper that needs more work resumes on the next
  heartbeat from its checkpoint (the keeper loop is checkpoint-driven, not single-call).

## 5. Tradeoffs

- **Lost knob**: operators can no longer raise the per-call turn cap (env or TOML) for a
  keeper that legitimately needs long single-call runs. Counter: the knob was a footgun
  — the per-call budget is exactly the exhaustion surface RFC-0082 latched on, and
  raising it re-enters the 20-turn RSS envelope. Long work is expressed across turns via
  checkpoint, which is the keeper model's intended unit, not a bigger single call.
- **Lost `extend_turns`**: the model can no longer self-extend mid-session. Counter:
  self-extension is a per-call concept that disappears with the per-call budget; the
  SDK default + idle guard bound the run without it.
- **reactive 30 → 10** is a real reduction. If a reactive channel empirically needs >10
  steps in one call this will truncate it earlier; the mitigation is checkpoint resume,
  which is observable and bounded rather than a single long run.

## 6. Scope

61 files, +34 / −538. OCaml: `lib/keeper/*` (turn execution, runtime-resolved, profile
types, extend_turns deletion), `lib/operator/operator_control_snapshot*` (max_turns
override source), `lib/otel_genai`, `lib/unified_tool_registry`. Config:
`config/tool_policy.toml`, `config/prompts/keeper.unified.system.md`. Dashboard:
`store-normalizers`, `keeper-store-normalize`, `config-resolution-panel`, `types/core`,
`types/dashboard-execution`. Docs: `BOOT-ENV-STATE-INVENTORY`, `KEEPER-FILE-MODEL`,
`spec/05-keeper-agent`, `RFC-0082`. Tests updated to drop the removed assertions.

## 7. Verification

- `dune build lib/` clean (whole `masc` library compiles with the removal).
- Touched OCaml tests build/run: `test_runtime_toml_overrides`,
  `test_operator_control_snapshot`, `test_keeper_toml`, `test_keeper_tool_resolution`.
- Dashboard `tsc` clean (the removed resolved-config fields and telemetry `max_turns`).
