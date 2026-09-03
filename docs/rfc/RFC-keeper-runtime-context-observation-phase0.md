---
rfc: "keeper-runtime-context-observation-phase0"
title: "Keeper runtime context observation Phase 0"
status: Draft
created: 2026-07-30
updated: 2026-07-30
author: codex
supersedes: []
superseded_by: []
related: ["0140", "0150", "0349"]
---

# Keeper runtime context observation Phase 0

## 1. Decision

The Keeper fleet surface must stop treating the last turn's provider usage as
the current conversation-context occupancy.

Until an owner-boundary context measurement exists, the operator snapshot
publishes:

```json
{
  "context_ratio": null,
  "context_tokens": null,
  "context_max": null,
  "context_source": null,
  "context_metrics_unavailable": {
    "kind": "not_observed",
    "reason": "context_measurement_missing"
  }
}
```

The last turn's usage remains available under a separately named observation:

```json
{
  "last_turn_usage": {
    "input_tokens": 790360,
    "output_tokens": 0,
    "total_tokens": 790360,
    "observed_at": "2026-07-29T14:15:00Z",
    "source": "keeper_runtime_usage"
  }
}
```

No consumer may derive context pressure, attention state, or continuity
state from `last_turn_usage`.

## 2. Evidence and failure flow

Checked against live MASC `0.21.2` on 2026-07-30 01:10 KST:

- `rondo` was executing turns with
  `context_source=fallback_metadata`,
  `context_tokens=962937`,
  `context_max=256000`, and `context_ratio=1.0`.
- The execution endpoint is built with `lightweight_summary=true`.
- The lightweight operator snapshot calls
  `fallback_keeper_context_snapshot`.
- That function reads `meta.runtime.usage.last_input_tokens`, divides it by a
  resolved model budget, clamps the quotient to `[0,1]`, and labels the result
  as context.

`[근거]` `curl -fsS --max-time 15
'http://127.0.0.1:8935/api/v1/dashboard/execution?force=1'` and
`lib/operator/operator_control_snapshot.ml`,
`lib/operator/operator_control_context_snapshot.ml`; checked
2026-07-30 01:10 KST; confidence High.

The actual data flow is:

```text
last provider response usage.input_tokens
  -> keeper meta runtime.usage.last_input_tokens
  -> fallback_keeper_context_snapshot
  -> context_tokens / context_ratio
  -> execution / briefing / roster / fleet thresholds
  -> operator attention wording
```

The numerator is a provider usage counter for one response. It is not an
owner-boundary measurement of the currently retained conversation state.
Clamping makes the unit error look like a legitimate 100% occupancy.

## 3. Scope

This RFC authorizes one hard-cut implementation slice:

1. Delete the fabricated context fallback and its persisted-row reader.
2. Publish one shared `not_observed` context projection and keep last-turn
   usage under a separate name.
3. Ensure unknown context contributes to no attention, urgency, sorting, or
   pressure projection.
4. Add the mandatory `keeper.metrics.v1` + `record_kind` identity to current
   turn and heartbeat writers; current readers reject versionless rows without
   a migration path.
5. Persist current `tools_used`/`tool_call_count` and remove tool-name aliases,
   decision-log guessing, and zero-call fabrication.
6. Remove producer-less metrics context, model, drift, fallback, event, and
   history surfaces instead of filling them with defaults.
7. Delete the dormant context-bearing agent_core keeper snapshot publisher and its
   Dashboard decoder/state.
8. Make the direct `keeper_context_status` tool output and both of its
   descriptors state checkpoint/session facts without promising unobserved
   context-window occupancy.
9. Correct the Dashboard, Keeper manual, inventory, and regression fixtures.

The implementation changes observation writers and read models. It does not
change Keeper turn scheduling, heartbeat cadence, provider routing,
checkpoints, or the agent_core runtime contract.

## 4. Typed contract

### 4.1 Current context projection

Phase 0 has one current wire shape:

```json
{
  "context_ratio": null,
  "context_tokens": null,
  "context_max": null,
  "context_source": null,
  "context_metrics_unavailable": {
    "kind": "not_observed",
    "reason": "context_measurement_missing"
  }
}
```

There is no owner-boundary context-measurement producer in this phase, so there
is no persisted-row decoder. Metrics JSONL rows cannot create context authority
from `snapshot_source`, field presence, or any legacy shape.

### 4.2 Producer boundary

A future observed context surface must introduce its live producer, typed
transport, projection, consumers, and tests in the same implementation slice.
It may then derive ratio from the producer-owned token count and assigned
Runtime budget with an explicit blast radius.

Phase 0 does not pre-install a reader for that future design. In particular it
does not scan old heartbeat or metrics rows, accept a
`snapshot_source="keeper_context_status"` string as authority, or keep
compatibility/migration logic for historical rows.

### 4.3 Last-turn usage

`last_turn_usage` is copied from the Keeper meta usage record. It is an
observation of the last recorded turn response and keeps its own source and
timestamp. It has no context-capacity denominator and no ratio.

The field is absent when no positive usage observation has been recorded.

### 4.4 Dashboard

Dashboard types preserve `context_ratio: number | null`. They do not normalize
missing context to zero.

All threshold consumers use an explicit numeric guard:

```ts
row.context_ratio != null
  && row.context_ratio >= PRESSURE_WARN_RATIO
```

The roster and selected detail render:

- a context percentage only for an observed context measurement;
- `—` or `측정 없음` for unavailable context;
- last-turn usage as a separately labelled value when present.

### 4.5 Current metrics ledger

Every current metrics row carries:

```json
{
  "schema": "keeper.metrics.v1",
  "record_kind": "turn"
}
```

`record_kind` is `turn` or `heartbeat`. Turn rows carry the current typed
`turn_mode`, `tools_used`, and `tool_call_count`; heartbeat rows do not mimic a
turn event. Versionless rows are opaque to current status,
Dashboard, cost, handoff, and operator-audit readers. No compatibility decoder
or migration routine exists.

## 5. Information flow after the change

```text
no owner-boundary context measurement
  -> context_measurement_missing
  -> null context fields
  -> no context-derived attention

keeper meta runtime usage
  -> last_turn_usage
  -> informational selected-detail value only
```

There is no path from `last_turn_usage` to a context threshold.

## 6. Acceptance

### 6.1 Backend counterfactual

Given:

- `last_input_tokens=790360`;
- resolved model budget `256000`;
- no owner-boundary context measurement;

the operator snapshot must produce:

- `last_turn_usage.input_tokens=790360`;
- `context_ratio=null`;
- `context_tokens=null`;
- `context_max=null`;
- `context_source=null`;
- `context_metrics_unavailable.kind=not_observed`;
- `context_metrics_unavailable.reason=context_measurement_missing`.

Reintroducing `last_input_tokens` into the fallback context snapshot must make
this regression test fail.

### 6.2 Retired-row counterfactual

A versionless persisted row containing
`snapshot_source="keeper_context_status"`, context-looking numbers, or old
tool aliases contributes to no current projection.
Reintroducing any versionless metrics decoder must make the regression tests
fail.

### 6.3 Dashboard

- A null context ratio does not classify a healthy Keeper as attention.
- A null context ratio contributes no urgency points.
- A null context ratio does not enter a pressure watchlist.
- A null context ratio renders as unavailable, never `0%`.
- Last-turn usage is labelled as usage and never as window occupancy.

### 6.4 Live

After merge, build, and restart:

- `/api/v1/dashboard/execution?force=1` has no
  `context_source=fallback_metadata`;
- Keepers have null context fields and the typed missing reason;
- the screenshot's `790.4K / 256.0K` context meter is absent;
- the same Keeper is not in an attention band solely because of last-turn
  usage;
- last-turn usage remains inspectable under its own label.

Source, CI, merge, deployment, and live verification are separate gates.

## 7. Blast radius

Implementation blast radius:

- current metrics identity and writers:
  `keeper_metrics_record`, `keeper_unified_metrics_snapshot`,
  `keeper_heartbeat_snapshot`;
- current-only metrics readers: Keeper status/detail, Dashboard series/cost/
  harness, and operator tool audit;
- shared missing-context projection and operator/status call sites;
- direct `keeper_context_status` output, model schema, and internal descriptor;
- Dashboard Keeper/agent_core types, normalizers, telemetry panels, and focused tests;
- deletion of the private context snapshot decoder, producer-less history
  options, tool-alias facade, dormant agent_core snapshot publisher/decoder,
  and their tests;
- `docs/KEEPER-USER-MANUAL.md` and
  `docs/SYSTEM-EVENT-AND-SNAPSHOT-INVENTORY.md`.

Provider routing and agent_core request/response serialization remain outside
this RFC.

## 8. Rejected alternatives

### Stop or restart a Keeper at 100%

Rejected. The displayed percentage is not a context measurement, so using it
as control authority would turn a display bug into a runtime outage.

### Keep the number but rename the label

Rejected. A clamped ratio between different semantic quantities remains
invalid even with softer copy.

### Backend null with Dashboard `?? 0`

Rejected. It replaces “full” with “empty” and preserves the same fabrication
class.

### Match “No-work report”

Rejected. Model prose is not a state transport and is orthogonal to context
measurement.

## 9. Workaround rejection check

- This removes fabricated telemetry; it does not add telemetry in place of a
  fix.
- It introduces no prose or substring classifier.
- Backend, Dashboard normalization, attention, and documentation are closed in
  one slice rather than leaving an N-of-M compatibility path.
- It adds no cap, cooldown, deduplication, repair loop, or silent fallback.
- `context_measurement_missing` is an explicit domain fact, not a generic
  default.
- It adds no persisted-row compatibility decoder or migration path.
