# Measuring Keeper preparation

An old source timestamp does not measure queue waiting or task preparation.
Record each boundary under its original event, task and execution identity:

1. Admission transform committed into the Keeper's durable pending queue.
2. Original work admitted to a turn or resumed continuation.
3. First useful action on that work, including the tool/input/result evidence.
4. Verified task outcome or an explicit failed/unfinished outcome.

Queue residence is only the first interval's still-pending observation. It does
not prove that a model is preparing a task, that a turn is stalled, or that the
whole task became faster. The result-recovery provider experiments measure a
different interval after a composition result has already been produced.

## Recorded queue admission

`Keeper_event_queue_state.pending_selection.first_admitted_at` records the epoch
clock sampled in the first accepted durable admission transform. The timestamp
is published with the pending entry after commit; it is not the source's creation
time or the end of an fsync. Ordinary enqueue/update and target transfer admission
record the clock. Already-present entries retain their original recorded value.
Deferral, checkpoint retention, scope binding and reprioritization preserve it.
Removal followed by a new admission receives new evidence for the new queue entry.

The codec validates a supplied finite numeric clock. Missing clock evidence stays
absent; a later read or update never fills it from `arrived_at`, revision, mtime or
the current clock. Pure `with_pending` can therefore express an unrecorded entry.
No runtime action, expiry, priority or authorization is derived from this value.

Fleet/health and reaction-ledger projections expose the same closed observation:

| Status | Duration | Meaning |
|---|---|---|
| `observed` | `oldest_age_seconds`, with `oldest_admitted_at_unix` | Every pending entry has finite admission evidence and the observation follows every recorded admission. |
| `empty` | `null` | The authoritative pending queue is empty. No duration is invented. |
| `unknown` / `first_admission_not_recorded` | `null` | At least one pending entry has no admission clock. |
| `unknown` / `queue_observation_incomplete` | `null` | Required queue/discovery evidence could not be read completely. |
| `unknown` / `clock_observation_invalid` | `null` | The clock is non-finite, predates a recorded admission, or the duration is non-finite. |

An aggregate cannot select the oldest *known* entry while ignoring unrecorded
ones. Health carries the canonical observation without converting source age into
residence, a stalled-state verdict or an operator action. Dashboard API decoding
preserves the union and rejects incoherent status/number combinations.

Epoch observations can be compared across a fresh process, but clock regressions
remain unknown rather than being clamped to a convincing zero. They are not a
monotonic end-to-end latency measurement.

## Source-bound turn entry

The private runtime manifest's existing `Turn_started` row records
`decision.intake_sources` from the exact immutable batch supplied to that cycle.
Each selection retains its canonical stimulus id, source snapshot reference,
admitted revision and optional first-admission clock, in intake order. An empty
batch records an empty list. Source payload text is not copied, and public
manifest projection does not expose these identities.

Join this row by Keeper, trace and Keeper turn number, then compare the full
source selection tuple. A matching post id or nearby timestamp alone is not a
join. This is initial turn-entry observation: provider-dispatch validation can
later withdraw a source. The row proves neither delivery, acknowledgement nor
the start of a useful effect. It does not change the reaction ledger, whose
`Turn_started` reactions have separate replay/deduplication semantics.

The manifest retains its existing wall-clock timestamp and clock provenance.
It does not add a monotonic admission-to-turn measurement or fill missing clocks.
The isolated paired protocol harness saves the actual persisted manifest and
requires this exact source/turn join for both arms. Its successful useful-action
observer follows tool result/log commit. Neither that single synthetic pair nor
the new identity join establishes real-model speedup or fleet latency.

## Verification and remaining intervals

The focused fleet feature scenario uses actual durable enqueue, duplicate intake,
checkpoint retention, reprioritization, deferral, a fresh independent reader
process and removal. Its receipt separates actual source age from measured queue
residence. Additional scenarios preserve unknown evidence, incomplete reads,
mixed recorded/unrecorded entries and invalid clocks. Health and Dashboard direct
consumers retain the measured observation without changing the work verdict.

Before using a before/after preparation percentage, measure those boundaries with
comparable clocks, freeze the same task/provider/tool conditions, and include
failed, missing and unfinished samples in the denominator. This admission change
alone does not establish an installed runtime result or a preparation
speedup by itself. Effectful job ownership/resume and fresh Ask Question TUI
evidence remain separately tracked in #42799.
