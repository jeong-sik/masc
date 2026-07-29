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
implementation_prs: []
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

No consumer may derive context pressure, compaction advice, attention state, or
continuity state from `last_turn_usage`.

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
  -> operator attention and compaction wording
```

The numerator is a provider usage counter for one response. It is not an
owner-boundary measurement of the currently retained conversation state.
Clamping makes the unit error look like a legitimate 100% occupancy.

## 3. Scope

This RFC authorizes one implementation slice:

1. Remove `last_input_tokens` and resolved model budget from the fallback
   context snapshot.
2. Represent missing context measurement with a closed OCaml reason and a
   stable JSON tag.
3. Preserve last-turn usage under a separate name.
4. Ensure unknown context does not contribute to backend or Dashboard
   attention, urgency, sorting, pressure watchlists, or compaction copy.
5. Render unknown context as unavailable, not `0%`.
6. Correct the Keeper manual and system event/snapshot inventory.
7. Add a regression fixture using `790360` input tokens and a `256000` model
   budget.

The implementation changes read-side projection only. It does not change
Keeper turn scheduling, heartbeat cadence, compaction admission, provider
routing, checkpoints, or OAS.

## 4. Typed contract

### 4.1 Context observation

The operator projection owns a closed availability reason:

```ocaml
type context_metrics_unavailable_reason =
  | Context_measurement_missing
  | Storage_read_failed of Dated_jsonl.read_error
  | Malformed_metrics_row of {
      path : string;
      line_number : int option;
      detail : string;
    }
```

`keeper_context_snapshot` remains the query projection:

```ocaml
type keeper_context_snapshot = {
  context_ratio : float option;
  context_tokens : int option;
  context_max : int option;
  context_source : string option;
  context_metrics_unavailable :
    context_metrics_unavailable_reason option;
}
```

The valid shapes are:

- observed: ratio, tokens, max, and source are present; unavailable is absent;
- unavailable: ratio, tokens, max, and source are absent; unavailable is
  present.

A partial numeric shape is not accepted as a trusted observation.

### 4.2 Trusted persisted measurement

For this Phase 0 cut, a persisted row is a context measurement only when:

- `snapshot_source` is the typed source `keeper_context_status`; and
- `context_ratio`, `context_tokens`, and `context_max` are all present; and
- `context_ratio` is finite and in `[0,1]`; and
- `context_tokens >= 0`; and
- `context_max > 0`.

Rows lacking the complete shape are not malformed metrics rows. They simply do
not contain a context measurement. If no valid measurement exists in the read
window, the result is `Context_measurement_missing`.

This is a read-side trust boundary, not a claim that the current heartbeat
writer already emits token occupancy. It does not.

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

## 5. Information flow after the change

```text
metrics row with complete keeper_context_status measurement
  -> context observation
  -> context display and pressure thresholds

missing/incomplete measurement
  -> Context_measurement_missing
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
- no complete persisted context measurement;

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

### 6.2 Trusted-measurement positive case

A complete, valid `keeper_context_status` measurement remains visible and
retains its ratio, tokens, max, and source.

A partial or invalid measurement is not promoted to trusted context.

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
- Keepers without a trusted measurement have null context fields and the typed
  missing reason;
- the screenshot's `790.4K / 256.0K` context meter is absent;
- the same Keeper is not in an attention band solely because of last-turn
  usage;
- last-turn usage remains inspectable under its own label.

Source, CI, merge, deployment, and live verification are separate gates.

## 7. Blast radius

Expected implementation files:

- `lib/operator/operator_control_context_snapshot.{ml,mli}`
- `lib/operator/operator_control_snapshot.ml`
- `lib/operator/operator_control_snapshot_persistent_agents.ml`
- `test/test_operator_control_snapshot.ml`
- Dashboard Keeper/operator types and normalizers
- fleet telemetry and roster consumers plus focused tests
- `docs/KEEPER-USER-MANUAL.md`
- `docs/SYSTEM-EVENT-AND-SNAPSHOT-INVENTORY.md`

If implementation requires changing a Keeper write owner, compaction policy, or
OAS response contract, that work is outside this RFC and must stop for a new
design decision.

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

### Change compaction admission in the same PR

Rejected. RFC-0349 concerns a control policy. This RFC removes a false
read-side projection and cannot make that usage counter load-bearing.

## 9. Workaround rejection check

- This removes fabricated telemetry; it does not add telemetry in place of a
  fix.
- It introduces no prose or substring classifier.
- Backend, Dashboard normalization, attention, and documentation are closed in
  one slice rather than leaving an N-of-M compatibility path.
- It adds no cap, cooldown, deduplication, repair loop, or silent fallback.
- `Context_measurement_missing` is an explicit domain fact, not a generic
  default.
