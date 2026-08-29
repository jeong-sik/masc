# System Event and Snapshot Inventory

Validated against the current code on 2026-07-30.

This document is the operator-facing SSOT for:

- dashboard-visible system events
- snapshot surfaces and their refresh timing
- the actual trigger semantics of `keeper_composite_changed`
- when `operator_digest` is computed versus when it is broadcast

## Scope

- Dashboard event type union: `dashboard/src/types/sse.ts`
- Keeper composite signal path: `lib/keeper/keeper_registry.ml`
- Keeper heartbeat snapshot path: `lib/keeper/keeper_keepalive.ml`
- Server-push snapshot loops: `lib/server/server_dashboard_http_core.ml`, `lib/server/server_dashboard_http_execution_surfaces.ml`
- Agent Core Event_bus bridge: `lib/keeper/keeper_event_bridge.ml`

## Read Model Rules

- SSE is freshness transport, not the authoritative read model.
- `keeper_composite_changed` is signal-only. Consumers re-fetch `/api/v1/keepers/:name/composite`.
- `operator_snapshot` and `operator_digest` are cached server-push surfaces. Default HTTP reads usually return the cache.
- Agent Core events are replayable because `Keeper_event_bridge` persists them under `.masc/agent-core-events/`.
- Keeper context occupancy and last-turn provider usage are separate observations.
  There is currently no owner-boundary context measurement, so
  operator/execution snapshots expose typed `not_observed`. They neither
  synthesize context from `last_input_tokens` nor decode versionless metrics
  rows. Current metrics rows require `schema="keeper.metrics.v1"` and a typed
  `record_kind`.

## Timing and Trigger Semantics

| Surface / event | When it happens | Payload model | Notes |
| --- | --- | --- | --- |
| `keeper_composite_changed` | After every successful `Keeper_registry.dispatch_event*` application, including no-phase-change updates | Signal-only: `{name, ts_unix}` | Consumers must re-fetch the full composite payload. |
| `keeper_heartbeat` | When a heartbeat snapshot is actually written | Lightweight SSE envelope without context numbers | Not emitted on every keepalive cycle. |
| `operator_snapshot` | Background proactive refresh loop | Cached payload wrapped as `{type, payload, ts_unix}` | Default root/summary HTTP path returns cache. |
| `operator_digest` | Background proactive refresh loop | Cached payload wrapped as `{type, payload, ts_unix}` | Default root HTTP path returns cache; non-default requests recompute. |
| `execution_snapshot` | Background proactive refresh loop | Cached payload wrapped as `{type, payload, ts_unix}` | Used by execution dashboard surfaces. |
| `transport_health_snapshot` | Background proactive refresh loop | Cached payload wrapped as `{type, payload, ts_unix}` | Used for transport diagnostics. |
| `project_snapshot` | After project-snapshot recomposition from cached surfaces | Cached payload wrapped as `{type, payload, ts_unix}` | Project dashboard snapshot. |

## Keeper Context Observation Contract

The current operator and execution projections always carry:

```json
{
  "context_ratio": null,
  "context_tokens": null,
  "context_max": null,
  "context_source": null,
  "context_metrics_unavailable": {
    "kind": "not_observed",
    "reason": "context_measurement_missing"
  },
  "last_turn_usage": {
    "input_tokens": 790360,
    "output_tokens": 17,
    "total_tokens": 790377,
    "observed_at": "2026-07-30T00:00:00Z",
    "source": "keeper_runtime_usage"
  }
}
```

`last_turn_usage` may be present while context is unobserved. Its input token
count is not a context-window numerator. The heartbeat producer writes message
metadata but no context source or numeric occupancy. Historical
`snapshot_source="keeper_context_status"` rows are not decoded.

Direct `keeper_heartbeat` messages are transport events. They do not override
the operator projection's missing-measurement fact.

## `keeper_composite_changed`

### What it really means

- It means “a keeper registry state-machine event was applied; the composite view may have changed.”
- It does not carry the composite snapshot itself.
- It is emitted both when phase changes and when the event updates conditions without a phase change.

### Exact producer

- `Keeper_registry.dispatch_event_with_audit` emits `keeper_composite_changed` after the registry entry is updated.
- This happens in both the phase-change branch and the no-phase-change success branch.
- Turn sub-FSM mutation helpers also emit `keeper_composite_changed` after they update observer-visible turn/composite fields.

### Direct turn helper trigger cases

The following direct registry mutation helpers update fields that the composite observer reads, and now emit `keeper_composite_changed` when they actually change a live turn observation:

- `mark_turn_started`
- `mark_turn_measurement`
- `set_turn_decision_stage`
- `set_turn_runtime_state`
- `set_turn_phase`
- `set_turn_selected_model`
- `mark_turn_finished`

Current code cross-check: `keeper_unified_turn.ml` still calls these helpers directly in the live turn path
(`mark_turn_started`, `mark_turn_measurement`, `set_turn_*`, `mark_turn_finished`), so this is not dead API surface. The helpers are active and are part of the composite freshness contract.

| Helper | Current direct caller(s) | Composite fields touched | Emits `keeper_composite_changed`? |
| --- | --- | --- | --- |
| `mark_turn_started` | live turn entry | installs `current_turn_observation`, initializes `turn_phase=prompting` | Yes |
| `mark_turn_measurement` | live turn measurement bind | binds pending measurement into the current turn snapshot | Yes, when a pending measurement exists |
| `set_turn_decision_stage` | live turn decision path | updates `decision_stage` to `guard_ok` when measurement is present | Yes, when a live turn exists |
| `set_turn_runtime_state` | runtime attempt path | updates `runtime_state`, and via `turn_phase_of_runtime_state` also changes `turn_phase` | Yes, when a live turn exists |
| `set_turn_phase` | terminal/error path, tool hook path | forces `turn_phase` outside the runtime-state transition | Yes, when a live turn exists |
| `set_turn_selected_model` | successful runtime attempt path | stores `selected_model` after a successful runtime attempt | Yes, when a live turn exists |
| `mark_turn_finished` | turn finally block | clears `current_turn_observation`, ending the live turn snapshot and freezing `last_completed_turn` | Yes, when a live turn exists |

By contrast, the nearby `dispatch_keeper_phase_event` calls in the overflow-retry path
(`keeper_unified_turn.ml:1939-1946`) eventually go through
`Keeper_registry.dispatch_event_with_audit`, so those phase-machine events *do* emit
`keeper_composite_changed`. Direct turn-mutation helpers and state-machine dispatch now both produce the same signal-only tick, while consumers still re-fetch `/api/v1/keepers/:name/composite` for the authoritative payload.

## Keeper Heartbeat Snapshot Timing

### Base timing

- Keepalive loop base interval: `300s`
- Keepalive sleep: exact resolved `keeper.keepalive_interval_sec`
- Snapshot write interval: runtime param `keeper.snapshot_sec`
- Current default `keeper.snapshot_sec`: `300s`

### Actual behavior

- After each cycle the keepalive loop sleeps for the exact resolved interval;
  a directed Keeper wake or explicit stop can interrupt that sleep.
- Snapshot write is gated by `now_ts - last_snapshot_ts >= snapshot_interval_sec`.
- Busy/idle/activity/observer state never skips a cycle. Snapshot distance can
  still exceed the interval while the preceding cycle itself is running.
- When a snapshot is written, two things happen together:
  - JSONL metrics append
  - `keeper_heartbeat` SSE broadcast

### Practical consequence

If you are watching dashboard freshness:

- `keeper_heartbeat` is a snapshot cadence signal, not a raw “loop tick” signal.
- absence of `keeper_heartbeat` for under `300s` is not automatically suspicious
- absence beyond the expected snapshot interval should be interpreted together with cycle duration and explicit lifecycle events

## `operator_digest`

### Background refresh path

- Refresh interval source: `MASC_OPERATOR_REFRESH_INTERVAL_S`
- Default interval: `60s`
- Warm-cache delay on cold start: `150s`
- Refresh loop uses `Proactive_refresh`

### HTTP read path

- Default namespace/root request returns `_operator_digest_cache`.
- Non-default requests recompute immediately:
  - non-root `target_type`
  - `target_id`
  - explicit `include_workers`
  - explicit actor override

### Broadcast path

- Successful recompute stores the cache first, then calls the operator digest broadcast hook.
- Broadcast is changed-only.
- If the JSON payload hash matches the previous payload, SSE broadcast is skipped.

### Practical consequence

- “digest happened” and “`operator_digest` SSE arrived” are different events.
- The digest may recompute without any outbound SSE if the payload is unchanged.
- A default HTTP read may return a fresh-enough cached digest even if no recent SSE was emitted.

## Termination Semantics

### Graceful shutdown

- Process-level graceful shutdown handles `SIGTERM` and `SIGINT`.
- Structured shutdown phases are `Notify -> Drain -> Cleanup -> Exit`.
- Cleanup closes SSE/WS sessions and flushes in-memory buffers.

### Crash and force-kill

- There is no dedicated `*_shutdown_snapshot` or `*_sigkill_snapshot` event.
- Keeper crash state is recorded via lifecycle and crash persistence, not via a special shutdown snapshot.
- Crash persistence uses an in-memory queue drained every `2s`.
- A hard `SIGKILL` can bypass cleanup and can lose queued-but-not-yet-flushed crash records.

### Operator interpretation

- Graceful stop should show lifecycle transitions and normal cleanup.
- Abrupt termination should be diagnosed from:
  - `agent_core:masc:keeper:lifecycle` / crash detail
  - registry crash state
  - `crash-events/` durable records
  - missing follow-up snapshot traffic

## Event Inventory by Family

### 1. Dashboard typed SSE union

Source of accepted event names on the dashboard side: `dashboard/src/types/sse.ts`.

| Family | Event names |
| --- | --- |
| Workspace / workspace | `agent_bound`, `agent_unbound`, `broadcast`, `task_update` |
| Board and notification compatibility | `board_post`, `masc/board_post`, `board_comment`, `masc/board_comment`, `board_delete`, `masc/board_delete`, `post_created`, `comment_added`, `post_voted`, `comment_voted` |
| Keeper direct SSE | `keeper_heartbeat`, `keeper_handoff`, `masc/keeper_handoff`, `keeper_phase_changed`, `keeper_composite_changed`, `keeper_tool_call`, `masc/keeper_tool_call`, `keeper_turn_complete`, `masc/keeper_turn_complete` |
| Gate / HITL | `client_input_approved`, `client_input_rejected`, `client_input_updated`, `approval:pending`, `approval:resolved` |
| agent core bridge | `agent_core:masc:keeper:lifecycle`, `agent_core:agent_started`, `agent_core:agent_completed`, `agent_core:tool_called`, `agent_core:tool_completed`, `agent_core:turn_started`, `agent_core:turn_completed`, `agent_core:masc:harness:verdict_recorded`, `agent_core:masc:harness:handoff` |
| Server-push snapshots | `project_snapshot`, `execution_snapshot`, `operator_snapshot`, `operator_digest`, `transport_health_snapshot` |

### 2. Agent Core custom events published by MASC

Domain publishers emit typed `Agent_core.Event_bus.Custom` payloads and
`Keeper_event_bridge` relays them.

| Event name | Meaning |
| --- | --- |
| `masc:board_post` | board post created |
| `masc:keeper:lifecycle` | keeper lifecycle update |
| `masc:institution_episode` | institution episode recorded |
| `masc:harness:verdict_recorded` | harness verdict persisted |
| `masc:harness:handoff` | harness handoff observation |

### 3. Removed names

| Event name | Status | Notes |
| --- | --- | --- |
| `keeper_lifecycle` | removed legacy direct SSE | Replaced by `keeper_phase_changed` for observer-facing FSM transitions and `agent_core:masc:keeper:lifecycle` for lifecycle detail. |
| `workspace_truth_snapshot` | removed legacy alias | Replaced by `project_snapshot`; same payload shape, canonical event name only. |

## Representative Messages

These examples are shaped directly from the current producers.

### 1. Direct SSE: `keeper_composite_changed`

```json
{
  "type": "keeper_composite_changed",
  "name": "keeper-a",
  "ts_unix": 1710000000.123
}
```

Meaning:

- signal-only tick
- downstream must fetch `/api/v1/keepers/keeper-a/composite`

### 2. Direct SSE: `keeper_heartbeat`

```json
{
  "type": "keeper_heartbeat",
  "name": "keeper-a",
  "generation": 3,
  "ts_unix": 1710000000.123
}
```

Meaning:

- emitted only when heartbeat snapshot write actually happened
- lightweight envelope, not the full heartbeat snapshot JSONL row

### 3. Server-push snapshot: `operator_digest`

```json
{
  "type": "operator_digest",
  "payload": {
    "health": "ok",
    "generated_at": "2026-04-16T12:34:56Z"
  },
  "ts_unix": 1710000000.123
}
```

Meaning:

- server cache projection
- changed-only SSE fanout
- payload body is large and surface-specific; example above is intentionally minimal

### 4. agent core-relayed SSE: `agent_core:masc:keeper:lifecycle`

```json
{
  "type": "agent_core:masc:keeper:lifecycle",
  "event_type": "masc:keeper:lifecycle",
  "ts_unix": 1710000000.123,
  "correlation_id": "corr-...",
  "run_id": "run-...",
  "payload": {
    "keeper_name": "keeper-a",
    "event": "started",
    "phase": "running",
    "detail": "supervised",
    "timestamp": 1710000000.123
  }
}
```

Meaning:

- observer and agent stream sessions both receive the live agent core tail
- lifecycle detail now carries `phase`, so the payload can replace the removed legacy direct SSE
- dashboard runtime state ingests this as agent core telemetry, while main keeper transition journaling still comes from `keeper_phase_changed`

## Variantization Status

## What is already typed

- Dashboard-side SSE names are modeled as a TypeScript string union in `dashboard/src/types/sse.ts`.
- Dashboard agent core monitor types are separately modeled in `dashboard/src/types/agent-core.ts`.
- Composite observer internals are variantized:
  - TLA action names mirrored as OCaml variants
  - invariant keys mirrored as OCaml variants
  - composite snapshot schema validated on the dashboard side

## What is still stringly typed

- Direct SSE producers emit raw JSON objects with string `"type"` fields.
- agent core custom events are published as `Agent_core.Event_bus.Custom (name, payload)`, where `name` is still a free string.
- The bridge preserves that string name as `event_type` and prefixes it into `type = "agent_core:" ^ event_type`.

## Practical conclusion

- This is partially variantized, not end-to-end variantized.
- Domain contracts inside the composite observer are strongly typed.
- Dashboard agent core monitor events are now modeled as a discriminated union rather than a wide product type.
- Transport event names themselves are still mostly string-labeled protocols.

## Source Pointers

- Dashboard event union: `dashboard/src/types/sse.ts`
- Composite signal router: `dashboard/src/sse-store.ts`, `dashboard/src/composite-signals.ts`
- Composite producer: `lib/keeper/keeper_registry.ml`
- Heartbeat snapshot writer: `lib/keeper/keeper_keepalive.ml`
- MASC domain event publisher: `lib/keeper/keeper_event_publisher.ml`
- Agent Core bridge + durable replay: `lib/keeper/keeper_event_bridge.ml`
- Server-push snapshot loops: `lib/server/server_dashboard_http_core.ml`, `lib/server/server_dashboard_http_execution_surfaces.ml`, `lib/server/server_dashboard_http_namespace_truth.ml`
