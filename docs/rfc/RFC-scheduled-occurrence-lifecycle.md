---
rfc: "scheduled-occurrence-lifecycle"
title: "Separate schedule definitions, occurrence delivery, and work outcomes"
status: Draft
created: 2026-07-24
updated: 2026-07-24
author: vincent
supersedes: []
superseded_by: null
related: ["0234", "0290", "0315", "connector-ambient-attention-wake"]
implementation_prs: []
---

# RFC: Scheduled occurrence lifecycle and terminal evidence authority

## 0. Summary

MASC currently closes a scheduled execution as `Succeeded` when the synchronous
schedule consumer returns `Ok` after durable Keeper queue enqueue. The actual
Keeper lifecycle continues asynchronously: the target may be unregistered or
not running, the stimulus may wait in the queue, a turn may start much later,
and the turn may ACK, requeue, escalate, or be cancelled. Those later facts are
durably recorded, but they do not flow back into the schedule execution state.

This is not a collection of unrelated bugs. It is one ownership error:

> A schedule occurrence is an asynchronous delivery saga, but the schedule
> runner models it as a synchronous consumer call and declares terminal success
> at the first durable handoff.

This RFC preserves the surviving boundary decision from withdrawn RFC-0234:

1. the Scheduler persists future intent and due conditions;
2. the Scheduler wakes the owning Keeper lane when an occurrence becomes due;
3. the consumer owns payload interpretation;
4. every external effect still crosses the ordinary Keeper Gate at execution
   time.

The RFC adds the missing lifecycle model:

- `ScheduleDefinition` owns recurrence and future intent;
- `ScheduleOccurrence` owns one exact due instant and its delivery lifecycle;
- `DeliveryAttempt` owns queue and wake admission evidence;
- `WorkOutcome` is optional evidence owned by a typed executor, never inferred
  from a natural-language Keeper wake.

An append-only, per-schedule occurrence ledger becomes the authority for
operator truth. The existing Keeper event queue remains the authority for
leases and settlements. Its durable outbox commits exact transition rows to the
reaction ledger, and a non-blocking projector carries schedule rows back to the
occurrence ledger. Dashboard and health surfaces derive from the occurrence
ledger rather than reconstructing completion from queue absence and partial
reaction evidence.

The central invariant is:

> No terminal status exists without exact, durable terminal evidence for the
> same occurrence identity.

For `masc.keeper_wake`, terminal delivery ACK means that the Keeper event
queue's settlement policy accepted the exact source as handled. It does **not**
mean that the model performed the natural-language request. Only a future typed
job contract with a source-owned terminal receipt may claim business work
success.

## 1. Problem

### 1.1 The synchronous consumer boundary closes asynchronous work

`Schedule_runner.consumer.dispatch` returns:

```ocaml
(Yojson.Safe.t, consumer_dispatch_error) result
```

The production Keeper-wake consumer:

1. validates enough of the payload to build `Schedule_due`;
2. durably enqueues the stimulus;
3. records stimulus evidence;
4. calls `Keeper_registry.wakeup_running`;
5. logs the wake admission outcome;
6. returns `Ok receipt`.

`Schedule_runner.dispatch_candidate` interprets that `Ok` as completion and
calls `Schedule_store.complete_running`. The store marks the matching execution
`Execution_succeeded`; a one-shot definition becomes `Succeeded`, and a
recurring definition advances immediately to its next `Scheduled` due time.

The returned receipt says `occurrence_status=awaiting_ack`, which is itself
proof that the occurrence has not reached a terminal queue settlement. The
schedule status nevertheless says succeeded.

The type cannot express the real result:

```text
accepted asynchronously, queue durable, wake deferred, terminal pending
```

That missing variant is the first corrupted boundary.

### 1.2 One mutable request row represents two different entities

`Schedule_domain.schedule_request` contains:

- durable definition facts: actors, recurrence, payload, source;
- the next mutable `due_at`;
- a `status` sum containing both definition states and occurrence states:
  `Scheduled | Due | Running | Succeeded | Failed | Cancelled | Expired`.

For a recurring schedule, the same row moves back to `Scheduled` as soon as the
consumer accepts one occurrence, even while that occurrence remains pending or
inflight in the Keeper event queue. The row therefore cannot answer:

- how many occurrences are outstanding;
- which occurrence is deferred, leased, requeued, or escalated;
- whether cancellation applies to future due instants or already accepted
  occurrences;
- whether expiry still applies after queue acceptance;
- whether another occurrence may overlap the current one.

`execution_record` does not repair this mismatch. It records the short runner
dispatch attempt and stores the consumer receipt, but it is named and projected
as execution history. Its `Execution_succeeded` does not represent Keeper work
terminal success.

### 1.3 There is no owner for the cross-store saga

The production path crosses these durable authorities:

```text
schedules.json snapshot
  -> schedule wake-signal JSONL
  -> signal_keys.json fence
  -> Keeper durable event queue
  -> Keeper transition outbox
  -> Keeper reaction ledger
  -> Keeper turn/provider/tool evidence
```

Each subsystem contains useful local safety mechanisms. The event queue has
exact stimulus identity, durable leases, typed settlements, and a transition
outbox. The reaction ledger has deterministic event ids and replay-safe
projection. The occurrence id is derived from stable persisted facts.

What is missing is an aggregate that owns the transition between those stores.
Consequences include:

- signal JSONL append and `signal_keys.json` commit are not failure-atomic;
- a wake admission outcome is reduced to a log line;
- a startup `Running` recovery failure can be attempted only once and then
  disappear behind green idle ticks;
- recurring definitions advance while old occurrences remain outstanding;
- Dashboard must join mutable snapshots and several ledgers heuristically;
- one global schedule snapshot grows and rewrites with all execution history.

This is a distributed transaction implemented as unrelated local writes rather
than an explicit idempotent saga.

### 1.4 A Keeper wake cannot prove business work success

`masc.keeper_wake` carries a natural-language `message`. The event queue ACKs a
claimed source when the Keeper cycle reaches the queue settlement policy's
acknowledged outcome. A completed turn can ACK even if the model read the
message and chose another action. This is intentional for other stimulus
families: delivery of an approval resolution, for example, is distinct from
whether the model consumes the durable grant in that turn.

Therefore these claims have different strength:

| Evidence | What it proves | What it does not prove |
|---|---|---|
| signal persisted | an occurrence was durably materialized | queue acceptance |
| queue accepted | the exact stimulus is durable or already present | runnable Keeper |
| wake signaled | a running Keeper sleep was interrupted | turn start |
| wake deferred | the queue preserved the stimulus | delivery failure |
| turn started | a cycle leased the stimulus | completed cycle |
| queue ACK | event-queue settlement accepted the source as handled | requested business action |
| typed work receipt | the owning executor reached a stated terminal | unrelated effects |

The current vocabulary collapses the first two rows into `Succeeded`, and the
Dashboard may label even `stimulus recorded` or `turn started` as `완료`.

### 1.5 Exact reaction evidence discards negative settlement meaning

The reaction ledger stores closed settlement kinds:

- `Event_queue_ack`
- `Event_queue_cancelled`
- `Event_queue_requeued`
- `Event_queue_escalated`
- `Event_queue_no_compaction`

The exact evidence projection exposed to scheduled automation retains ACK and
cancellation booleans, but it does not retain requeue or escalation as an
occurrence result. The Dashboard then treats `matched_stimulus`,
`matched_turn_started`, and `matched_consumed_ack` as the same healthy drained
state.

The projection is not merely missing presentation detail. It removes precisely
the evidence needed to distinguish a successful delivery from retry or
terminal escalation.

### 1.6 Payload, ownership, and time invariants are validated too late

The schedule core intentionally treats the payload as an opaque typed envelope.
That does not require accepting unvalidated future intent.

Current `masc.keeper_wake` behavior has three authorities for one target:

- `scheduled_by.id` controls pre-due Keeper visibility;
- `payload.body.keeper_name` controls actual dispatch;
- the authenticated dispatch context identifies the producer.

They may disagree. Unknown body fields may be persisted and then silently
dropped by the consumer. The full message is durable in the queue, but the
prompt renders only a bounded preview and points to no deterministic
schedule-occurrence detail surface.

Timestamp fields also accept non-finite or unsupported epoch values. A value can
be committed before ISO presentation fails, leaving one malformed input in the
global snapshot's failure domain.

Opaque scheduling and closed producer contracts are compatible: the schedule
core need not understand consumer fields, but the producer/consumer schema
authority must validate the complete envelope before persistence.

### 1.7 Live evidence

The 2026-07-24 runtime audit on
`3691462b32b97c4082b557d6a45d82de280d13a3` observed:

- one hourly Keeper schedule with 17 pending `Schedule_due` stimuli;
- deferred dispatches logged as unregistered while runner dispatch recorded
  `succeeded`;
- one occurrence enqueued at `02:00:05Z`, delivered at `03:08:49Z`, and
  escalated at `03:08:54Z`, while its schedule execution remained `succeeded`;
- 27 observed v4 schedule stimuli conserved as 18 pending, 7 ACK, and
  2 escalation records;
- no duplicate occurrence in the observed signal sample, but no crash-window
  proof for signal append versus fence persistence.

The substrate is real and usually conserves work. The operator semantics are
what fail.

## 2. Goals

1. Give every due instant one exact, durable `ScheduleOccurrence` identity.
2. Preserve queue acceptance, wake admission, lease, requeue, escalation,
   cancellation, expiry, and ACK as distinct typed facts.
3. Make occurrence projection monotonic and replayable from append-only events.
4. Keep schedule definition state separate from occurrence delivery state.
5. Keep business work outcome separate from Keeper wake delivery.
6. Apply recurrence misfire and overlap policy identically whether the
   Scheduler, Keeper, or provider was unavailable.
7. Preserve owning-Keeper lane independence: one corrupt schedule cannot block
   unrelated schedules or Keeper lanes.
8. Validate target, payload schema, actors, and timestamps before durable
   admission.
9. Make Dashboard, API, health, and telemetry consume the same typed occurrence
   projection.
10. Reuse the existing event queue, transition outbox, reaction ledger, and
    occurrence identity rather than creating a second delivery engine.

## 3. Non-goals

- The Scheduler does not authorize external effects. Keeper Gate remains the
  only effect authorization boundary.
- This RFC does not infer business success from model text, tool-name matching,
  turn completion, or queue ACK.
- This RFC does not make a natural-language Keeper wake into a deterministic
  job.
- This RFC does not unify every Keeper stimulus family under the schedule
  domain. It reuses their common event-queue settlement substrate.
- This RFC does not promise distributed exactly-once execution. It requires
  durable at-least-once handoff with idempotent, exact-id transitions.
- This RFC does not add an external database. Existing workspace-local durable
  primitives are sufficient.
- This RFC does not retain parallel legacy and new authorities after cutover.

## 4. Terminology and semantic contract

### 4.1 ScheduleDefinition

Future intent owned by one Keeper lane:

```ocaml
type definition_state =
  | Active
  | Paused
  | Exhausted
  | Cancelled
  | Expired

type schedule_definition =
  { schedule_id : Schedule_id.t
  ; owner_lane : Keeper_name.t
  ; requested_by : Schedule_actor.t
  ; scheduled_by : Schedule_actor.t
  ; created_at : Finite_timestamp.t
  ; first_due_at : Finite_timestamp.t
  ; payload : Schedule_payload.t
  ; recurrence : Schedule_recurrence.t
  ; backlog_policy : Schedule_backlog_policy.t
  ; definition_state : definition_state
  ; definition_version : int
  }
```

Definition state never becomes `Running`, `Succeeded`, or `Failed`. Those words
describe an occurrence or work result, not future intent.

`Exhausted` means the definition has no future due instant. A one-shot
definition becomes exhausted when its only occurrence is materialized,
regardless of that occurrence's later delivery result.

`owner_lane` is outside the opaque payload and is the only target used by
pre-due visibility, dispatch, cancellation authorization, and queue routing.

`next_due_at` is a rebuildable projection from `first_due_at`, recurrence, and
the last materialized/skipped occurrence evidence. It is not an independently
mutable definition fact.

### 4.2 ScheduleOccurrence

One exact due instant:

```ocaml
type occurrence_key =
  { occurrence_id : Schedule_occurrence_id.t
  ; schedule_id : Schedule_id.t
  ; definition_version : int
  ; due_at : Finite_timestamp.t
  ; payload_digest : Payload_digest.t
  }
```

The existing occurrence-id derivation from `schedule_id`, `due_at`, and
`payload_digest` remains valid. `definition_version` is persisted as evidence
and must be covered by the digest or the occurrence-id derivation if it can
change dispatch meaning.

An occurrence owns delivery, not future recurrence.

### 4.3 DeliveryAttempt

A retryable handoff attempt for one occurrence:

```ocaml
type wake_admission =
  | Signaled
  | Deferred_unregistered
  | Deferred_not_running of Keeper_phase.t
  | Deferred_lifecycle of Keeper_lifecycle_admission.denial

type delivery_settlement =
  | Acknowledged
  | Cancelled of cancellation_evidence
  | Escalated of Keeper_event_queue.escalation_reason
  | Expired_before_lease
  | Superseded of Schedule_occurrence_id.t

type delivery_attempt =
  { occurrence_id : Schedule_occurrence_id.t
  ; attempt : int
  ; queue_acceptance : queue_acceptance option
  ; wake_admission : wake_admission option
  ; lease_id : Keeper_event_queue.Lease_id.t option
  ; settlement : delivery_settlement option
  }
```

`Requeue` is an attempt transition, not an occurrence terminal. It closes the
current lease attempt, increments the delivery attempt ordinal, and returns the
same occurrence identity to ready/pending state.

### 4.4 WorkOutcome

Optional evidence from an executor that owns a typed job:

```ocaml
type completion_contract =
  | Delivery_only
  | Typed_source_terminal of
      { source_kind : string
      ; schema_version : int
      }
```

`masc.keeper_wake` is always `Delivery_only`. Its strongest success is
`delivery_settlement=Acknowledged`.

A future typed scheduled job may use `Typed_source_terminal`, but only if:

- the payload schema identifies the executor;
- the executor preserves `occurrence_id`;
- its terminal receipt has a closed success/failure/cancelled sum;
- its external effects still cross Keeper Gate;
- the occurrence ledger records the source receipt without reinterpreting it.

The schedule subsystem may display such a receipt but does not manufacture it.

### 4.5 Identity chain

The E2E chain preserves distinct identities rather than renaming one id at each
boundary:

| Identity | Meaning | Relationship |
|---|---|---|
| `schedule_id` | future-intent definition | parent of occurrences |
| `occurrence_id` | one exact due instant | stable across every delivery retry |
| `stimulus_id` | event-queue source identity | exactly `occurrence_id` for `Schedule_due` |
| `delivery_attempt_id` | one lease/retry attempt | derived from occurrence id + ordinal |
| `lease_id` | event-queue lease authority | referenced by attempt evidence |
| `turn_id` | Keeper cycle correlation | optional link from lease/turn evidence |
| `execution_id` | actual provider/tool execution | optional work correlation, never occurrence identity |

The legacy schedule `execution_id` is imported as a legacy dispatch-attempt
reference. New schedule delivery does not mint a second generic execution id.

## 5. Authority model

| Fact | Authoritative owner | Projections/consumers |
|---|---|---|
| definition and recurrence | append-only definition event ledger | definition projection, tools, Dashboard, runner |
| due occurrence identity | occurrence ledger | runner, Dashboard, telemetry |
| queue pending/inflight | Keeper event queue | occurrence settlement projector |
| wake admission | Keeper registry typed outcome recorded as occurrence event | health, Dashboard |
| lease settlement | Keeper event queue transition/outbox | reaction ledger; occurrence projector consumes its exact rows |
| Keeper turn/provider/tool result | Keeper turn/execution stores | optional typed work receipt |
| operator view | occurrence projection | Dashboard/API only |

No Dashboard code, health counter, or log parser may become a lifecycle
authority.

The reaction ledger remains the durable, replayable fan-out journal for
Keeper-runtime transitions. The schedule occurrence ledger is the schedule
product authority. The occurrence settlement projector consumes the exact
transition receipt already preserved in reaction-ledger rows and uses that
source event id as its idempotency identity. It never infers a settlement from
reaction-ledger absence.

## 6. Definition and occurrence event algebra

### 6.1 Definition events

Definition mutation is append-only and actor-bearing:

```ocaml
type definition_event =
  | Created of created_definition
  | Updated of
      { previous_version : int
      ; next_version : int
      ; changed_fields : definition_change list
      }
  | Paused of actor_reason
  | Resumed of actor_reason
  | Cancelled of
      { actor_reason : actor_reason
      ; scope : cancellation_scope
      }
  | Definition_expired of expiry_evidence
  | Due_window_skipped of
      { first_due_at : Finite_timestamp.t
      ; last_due_at : Finite_timestamp.t
      ; count : int
      ; policy : misfire_policy
      ; reason : skip_reason
      }
  | Latest_due_coalesced of
      { previous_watermark : Finite_timestamp.t option
      ; latest_due_at : Finite_timestamp.t
      ; coalesced_count : int
      ; blocked_by : Schedule_occurrence_id.t
      }
  | Legacy_definition_imported of legacy_definition_evidence
  | Definition_evidence_quarantined of quarantine_evidence
```

Every mutation carries authenticated actor, source surface, timestamp, reason,
previous definition version, and next definition version. The JSON definition
record is a rebuildable materialized projection, not a lifecycle audit
authority.

There are no schedule-specific `Approved` or `Rejected` definition events.
Those labels in the historical #21955 proposal belonged to the approval
hierarchy withdrawn by RFC-0234. External-effect Gate decisions remain in the
ordinary Gate/effect evidence, not the schedule lifecycle.

### 6.2 Occurrence events

The append-only ledger uses a closed event sum. Names below are semantic; exact
OCaml module names are implementation detail.

```ocaml
type occurrence_event =
  | Materialized of materialized
  | Queue_accepted of queue_receipt
  | Wake_admission_recorded of wake_admission
  | Lease_started of lease_receipt
  | Turn_started of turn_receipt
  | Requeued of requeue_receipt
  | Delivery_acknowledged of ack_receipt
  | Delivery_cancelled of cancellation_receipt
  | Delivery_escalated of escalation_receipt
  | Expired_before_lease of expiry_receipt
  | Superseded of supersession_receipt
  | Work_terminal_recorded of typed_work_receipt
  | Legacy_evidence_imported of legacy_evidence
  | Evidence_quarantined of quarantine_evidence
```

Every row contains:

- `schema`;
- deterministic `event_id`;
- `occurrence_id`;
- `schedule_id`;
- `owner_lane`;
- `recorded_at`;
- event payload;
- source authority and source event id;
- actor/reason where applicable.

### 6.3 Projection states

The event stream projects to:

```ocaml
type delivery_phase =
  | Materialized
  | Queue_pending
  | Leased
  | Turn_in_progress
  | Retry_wait of requeue_reason
  | Settled of delivery_settlement
  | Evidence_invalid of quarantine_reason

type occurrence_projection =
  { phase : delivery_phase
  ; latest_wake_admission : wake_admission option
  ; attempts : delivery_attempt list
  ; work_outcome : typed_work_receipt option
  }
```

Wake admission is an evidence axis, not a delivery phase. `Signaled` means a
currently running Keeper's sleep was interrupted; a deferred value explains why
that hint was not applied. The durable queue may still be leased later through
registration recovery or a periodic cycle, so neither outcome controls the
phase transition.

`Turn_started` does not imply ACK. `Delivery_acknowledged` requires an exact
event-queue settlement receipt. Escalation and cancellation are terminal and
cannot be overwritten by later ACK. Conflicting terminal events quarantine the
occurrence and degrade schedule health.

```text
Materialized
  -> Queue_pending
       |    `-- wake admission evidence: Signaled | Deferred_*
       `-> Leased -> Turn_in_progress
                       |-> Requeued -> Queue_pending
                       |-> Delivery_acknowledged
                       |-> Delivery_escalated
                       `-> Delivery_cancelled

Materialized/Queue_pending -> Expired_before_lease
Materialized/Queue_pending -> Superseded
```

### 6.4 Transition invariants

1. `Materialized` is the first event.
2. An event for another `schedule_id` or payload digest cannot join the
   occurrence.
3. `Queue_accepted` is idempotent for one occurrence.
4. `Wake_admission_recorded` cannot precede queue acceptance, but lease and
   settlement do not require a `Signaled` wake event.
5. Each lease start has one exact lease/attempt ordinal.
6. Requeue closes only its matching attempt and preserves occurrence identity.
7. ACK, cancellation, escalation, expiry, and supersession are mutually
   exclusive occurrence delivery terminals.
8. `Work_terminal_recorded` cannot change delivery settlement.
9. `Delivery_acknowledged` cannot manufacture `Work_terminal_recorded`.
10. Duplicate deterministic event ids are replay, not additional transitions.
11. Unknown event variants or impossible transitions produce typed quarantine;
    they never become permissive success.
12. Projection is deterministic and independent of filesystem enumeration
    order.
13. Definition update never mutates an already materialized occurrence; the
    occurrence retains its immutable owner, due time, payload snapshot/digest,
    deadline, and definition version.
14. `owner_lane` is immutable. Moving future intent to another lane creates a
    new definition with explicit provenance.

## 7. Storage layout and isolation

The current global `schedules.json` combines every definition and execution
record in one rewrite and decode failure domain. Replace it with a versioned,
owner- and schedule-partitioned namespace:

```text
.masc/schedules/occurrence-v1/
  owners/<owner-lane>/
    definitions/<schedule-id>/projection.json
    definitions/<schedule-id>/events/YYYY-MM/DD.jsonl
    occurrences/<schedule-id>/YYYY-MM/DD.jsonl
    occurrence-index/<schedule-id>.json
    outbox/<occurrence-id>.json
  migration.json
```

Exact filenames may change during implementation, but these properties are
required:

- one malformed definition cannot prevent decoding unrelated definitions;
- one malformed occurrence row is quarantined with schedule and row identity;
- history pagination for one schedule does not materialize or sort global
  history;
- mutation does not rewrite all historical execution events;
- outbox projections are exact-occurrence scoped and rebuildable from
  nonterminal `Materialized` events;
- paths derive from `Workspace_utils.config`; no ambient global root;
- owner and schedule path components use existing validated typed names/ids;
- append uses the existing atomic JSONL substrate;
- index writes are bounded per schedule and are rebuildable from the ledger.

The occurrence ledger event id is the logical idempotency fence. Replayed
physical rows with the same deterministic event id collapse to one transition.
The separate `signal_keys.json` authority is retired. An unchanged idle tick
performs no durable rewrite.

Definition mutation and occurrence materialization for one schedule are
serialized under its existing workspace file-lock discipline. The runner
re-reads the latest definition version after acquiring that lock. Concurrent
update or cancellation either commits before materialization and changes the
future occurrence, or commits after materialization and affects only later
occurrences; it cannot rewrite an occurrence already in the event queue.
Occurrence outbox and settlement projectors use the same per-schedule event
append lock, so they may repair causal prerequisites before appending a later
fact without racing another projector.

## 8. Failure-atomic handoff protocol

### 8.1 Materialization

For each due instant selected by recurrence policy, the sole authoritative
commit is one append of `Materialized`. The event contains:

- the complete occurrence key;
- the owner lane and immutable definition-version/payload-digest reference;
- the recurrence decision and next due cursor;
- the backlog-policy evidence;
- the enqueue intent.

Only after that append succeeds may projectors update the rebuildable
per-schedule index, definition due projection, and exact occurrence outbox
file. A crash between those projections is repaired by replaying nonterminal
`Materialized` events. The occurrence event is therefore the durable outbox
intent; the outbox file is an efficient projection, not a second authority.

If the event append fails, no queue side effect is allowed. On retry, the same
due facts derive the same occurrence id.

### 8.2 Queue handoff

The occurrence outbox projector:

1. reads the exact outbox entry and exact reaction evidence;
2. if an exact terminal settlement already exists, backfills any missing
   `Queue_accepted` evidence from that receipt, appends the terminal, and does
   not recreate the stimulus;
3. otherwise calls durable Keeper queue enqueue with `occurrence_id` as the
   idempotency identity;
4. receives `Enqueued | Already_present | Storage_error`;
5. appends `Queue_accepted` for either successful acceptance result;
6. records the typed `wakeup_running` outcome as
   `Wake_admission_recorded`;
7. retires the occurrence outbox only after both events are durable.

Crash cases are safe:

- crash before queue enqueue: outbox retries;
- crash after enqueue but before `Queue_accepted`: retry gets
  `Already_present`, or finds exact stimulus/settlement evidence after a fast
  drain, then appends the missing acceptance event;
- crash after event append but before outbox retirement: deterministic event id
  makes replay idempotent;
- wake signal lost with process death: the durable queue remains authoritative,
  and registration/recovery reloads it.

The wake outcome is never allowed to change queue acceptance into failure. A
deferred wake is a truthful nonterminal state with durable work preserved.

### 8.3 Queue settlement return

The existing Keeper event queue transition outbox remains single-purpose and
does not wait on schedule storage:

1. commit the queue transition and transition outbox entry;
2. append the complete typed transition receipt to the reaction ledger; for
   `Schedule_due`, the row preserves a typed source reference containing
   `occurrence_id`, `schedule_id`, `due_at`, and `payload_digest`;
3. retire the event-queue outbox under its existing idempotent contract;
4. let a separate occurrence settlement projector consume reaction-ledger rows
   whose stimulus kind is `Schedule_due`;
5. append the matching occurrence event using
   `stimulus_id=occurrence_id` and the reaction row's deterministic event id;
6. advance a per-owner settlement projection cursor only after durable
   occurrence append.

Before appending lease or settlement evidence, the projector verifies that
`Materialized` exists. If `Queue_accepted` is missing because the process died
after enqueue, the exact transition receipt is sufficient causal proof to
append a typed recovered acceptance before the later event. Recovery may
backfill evidence; it may not invent a wake admission outcome.

A lost cursor only causes replay; the deterministic source event id makes the
occurrence append idempotent. A schedule-store failure leaves reaction evidence
available for retry and degrades schedule health, but does not hold the Keeper
event queue's sole transition outbox or block unrelated stimuli in that lane.
The projector routes by the typed source reference; it must not parse a
human-readable stimulus summary or scan every schedule to discover ownership.

Reaction-ledger retention may not delete an unprojected schedule settlement
row. The per-owner occurrence projection cursor is therefore a retention fence.
Malformed rows that cannot carry an identity are recorded as shard-level
quarantine and advance by physical row position so one bad row cannot create an
infinite replay loop.

The projector maps:

| Event queue settlement | Occurrence event |
|---|---|
| `Ack` / accepted source terminal delivery | `Delivery_acknowledged` |
| `Cancel_accepted` | `Delivery_cancelled` |
| `Requeue reason` | `Requeued` |
| `Escalate reason` | `Delivery_escalated` |

An occurrence projection failure leaves schedule health degraded. It does not
roll back an already committed queue transition or block queue settlement for
another schedule, stimulus family, or Keeper lane.

### 8.4 Startup reconciliation

Startup no longer performs a best-effort one-shot mutation of all `Running`
schedule rows.

Before new materialization for an owner lane, a bounded reconciler:

1. rebuilds/drains occurrence outbox projections;
2. lets the existing event-queue projector drain transition outboxes to the
   reaction ledger;
3. replays the schedule settlement cursor over exact reaction rows;
4. replays nonterminal occurrence projections;
5. compares queue exact-id presence/lease state for unresolved handoffs;
6. repairs missing idempotent projection events;
7. records typed quarantine for contradictory evidence.

The owner lane remains `degraded_reconciling` until reconciliation succeeds or
reaches a typed operator-action terminal. Other owner lanes continue.

There is no process-local `Running` definition state to steal. Lease ownership
remains inside the Keeper event queue, which already owns process/restart
recovery.

## 9. Recurrence, overlap, expiry, and cancellation

### 9.1 Backlog policy

Every recurring definition carries a closed policy:

```ocaml
type misfire_policy =
  | Skip_missed of { grace_sec : int }
  | Fire_latest
  | Catch_up of
      { max_occurrences : int
      ; max_age_sec : int
      ; max_materialized_per_tick : int
      }

type overlap_policy =
  | Forbid_overlap
  | Keep_latest_pending
  | Allow_up_to of { max_outstanding : int }
```

The default for recurring `masc.keeper_wake` is:

```text
misfire = Fire_latest
overlap = Keep_latest_pending
```

Rationale: a natural-language wake is usually current-attention intent, not a
financial/event log that must replay every missed hour. The current unbounded
offline backlog is unsafe. Producers that require every occurrence must opt
into bounded `Catch_up`.

`Keep_latest_pending` means:

- at most one nonterminal occurrence exists for the definition;
- if a newer due instant arrives while an occurrence is pending, append a
  durable latest-due watermark, settle the pending occurrence as superseded,
  and materialize the watermark only after that terminal is durable;
- if an occurrence is leased, retain only the newest due instant as a durable
  coalesced watermark and materialize it after the lease terminal;
- each skipped/superseded due window is recorded with reason, first/last due
  instant, and count;
- no occurrence disappears silently.

Large missed windows are summarized as bounded range evidence. The runner must
not allocate or append one row for every theoretical due instant merely to
record that policy skipped or coalesced them. `Catch_up` is the only policy that
materializes multiple missed occurrences, and its count, age, outstanding, and
per-tick bounds are mandatory.

The same algorithm runs after Scheduler downtime and while a Keeper is
unregistered, paused, lifecycle-deferred, or provider-failing. Component
availability does not change recurrence semantics.

Outstanding counts come from nonterminal occurrence projections, not from a
best-effort queue snapshot. A forward wall-clock jump is handled as misfire;
a backward jump cannot rematerialize an already committed due instant because
its occurrence identity and due cursor are durable.

### 9.2 Expiry

Definition expiry prevents future occurrence materialization.

Each materialized occurrence also carries an immutable delivery deadline:

- expiry before queue acceptance: settle `Expired_before_lease`;
- expiry while pending: exact-id queue cancellation settles
  `Expired_before_lease`;
- expiry after lease start does not asynchronously kill a running Keeper turn;
  the lease reaches its normal settlement and records that the deadline passed
  during delivery.

No `Schedule_due` stimulus may outlive its occurrence deadline without an
explicit projected state.

### 9.3 Cancellation

Definition cancellation and occurrence cancellation are different commands.

The public API requires a typed scope:

```ocaml
type cancellation_scope =
  | Future_occurrences_only
  | Future_and_pending_occurrences
```

- both scopes stop future materialization;
- `Future_and_pending_occurrences` requests exact-id cancellation for all
  non-leased queue occurrences;
- an active lease is not physically deleted; cancellation races are resolved
  by the event queue's owner-fenced accepted-cancellation contract;
- actor, reason, requested scope, affected occurrence ids, and race outcome are
  append-only evidence.

There is no silent default that lets the tool response claim a broad cancel
while only mutating a definition snapshot.

## 10. Payload, ownership, and admission

### 10.1 One owner/target authority

For Keeper-owned schedule tools:

- `owner_lane` is derived from authenticated dispatch context;
- `keeper_name` is removed from the consumer payload body;
- visibility, dispatch, cancellation, recurrence, and storage partition use
  `owner_lane`.

For an operator creating a cross-Keeper schedule:

- the target Keeper is an explicit top-level typed `owner_lane`;
- the route requires the appropriate operator capability;
- requested actor, authenticated scheduling actor, owner lane, and reason are
  immutable definition events.

A payload cannot redirect work to another lane.

### 10.2 Closed producer schema

`masc.keeper_wake` v1 admits only:

- `message`;
- optional `title`;
- optional typed `urgency`.

Unknown fields are rejected before persistence. If a new field such as
connector channel routing is required, it receives a new schema version and an
end-to-end DTO, prompt, retrieval, and test contract.

The definition event for each immutable version owns the full validated
payload. An occurrence stores that version and payload digest, and the event
queue carries a delivery copy rather than becoming the content SSOT. The full
message remains retrievable by exact occurrence id from a typed schedule
occurrence detail tool/surface, which resolves the immutable definition version
and verifies the digest. Prompt truncation is presentation only and must include
that valid pointer. It must not point to a Board post that does not exist.

Occurrence detail requires either owner-lane identity or operator read
capability. Append-only payload history does not widen message visibility.

### 10.3 Time validation

One domain validator admits all schedule timestamps:

- finite only;
- within the supported ISO/`Unix.gmtime` range;
- consistent ordering for requested, due, expiry, and update times;
- stable typed rejection before persistence.

Persisted invalid rows are quarantined individually. List and Dashboard
surfaces show the affected schedule id and typed reason rather than failing the
whole fleet projection.

## 11. API and Dashboard semantics

### 11.1 API vocabulary

Remove unqualified `Succeeded` and `Failed` from schedule definition output.

Definition output uses:

- `active`
- `paused`
- `exhausted`
- `cancelled`
- `expired`

Occurrence delivery output uses:

- `materialized`
- `queue_pending`
- `leased`
- `turn_in_progress`
- `retry_wait`
- `delivery_acknowledged`
- `delivery_cancelled`
- `delivery_escalated`
- `expired_before_lease`
- `superseded`
- `evidence_invalid`

It exposes `wake_admission` separately as
`signaled | deferred_unregistered | deferred_not_running |
deferred_lifecycle | null`.

If a typed source terminal exists, it is a separate `work_outcome` object.

### 11.2 Dashboard labels

The Dashboard may display:

| Typed state | Korean operator label |
|---|---|
| `queue_pending` | 큐 대기 |
| `leased` / `turn_in_progress` | 처리 중 |
| `retry_wait` | 재시도 대기 |
| `delivery_acknowledged` | 전달 완료 |
| `delivery_cancelled` | 전달 취소 |
| `delivery_escalated` | 에스컬레이션 |
| `expired_before_lease` | 전달 전 만료 |
| `evidence_invalid` | 증거 격리 |

`wake_admission` may appear as a secondary `Wake 신호` or `Wake 보류` badge
beside a nonterminal phase. It is never the completion label.

It must not display generic `완료` for `stimulus_seen`, `turn_started`, queue
absence, or schedule definition state.

Queue snapshots remain useful live evidence, but absence is not a terminal
proof. The occurrence ledger terminal event is authoritative.

### 11.3 Health and telemetry

Health counters are derived from occurrence events/projections, not independently
incremented process-local structs:

- open occurrences by phase and bounded age bucket;
- wake admissions by closed outcome;
- requeue and escalation counts by bounded typed reason;
- pending occurrence/settlement outboxes;
- reconciliation status and oldest unresolved age;
- quarantined occurrence rows;
- recurrence skipped/coalesced counts.

Occurrence ids remain in logs/traces and detail APIs, not unbounded metric
labels.

Dead counters with no production event source are removed.

## 12. Crash and recovery matrix

| Crash/failure point | Durable fact before crash | Recovery action | Forbidden result |
|---|---|---|---|
| before materialization commit | none | recompute same due id | phantom queue item |
| after `Materialized`, before outbox projection | occurrence event | rebuild outbox, retry enqueue | lose due intent |
| after outbox projection, before queue enqueue | occurrence event + outbox projection | retry enqueue | mark delivery complete |
| after queue enqueue, before `Queue_accepted` | queue exact id | `Already_present`, append event | duplicate stimulus |
| after `Queue_accepted`, before wake event | queue + occurrence | retry wake hint or record current deferred outcome | erase queue acceptance |
| after wake signal, before turn | queue pending | registration/heartbeat drains | claim task success |
| after lease start, before turn record | queue lease | event queue lease recovery/requeue | second concurrent lease |
| after turn failure, before settlement projection | transition outbox | replay exact settlement event | green ACK |
| after occurrence settlement append, before cursor advance | deterministic event id | replay as duplicate | second terminal |
| occurrence row malformed | isolated row identity | quarantine one occurrence | fail every schedule |
| definition row malformed | isolated schedule identity | quarantine one definition | block another owner lane |
| migration interrupted | migration phase/commit marker | resume or refuse runner admission | partial dual authority |

Every row in this table requires a deterministic test using the production
write/projector path. Tests that inject already-aggregated health structs are
not proof of lifecycle wiring.

## 13. Migration and hard cut

This RFC rejects permanent dual-read or dual-write compatibility. The cutover
uses a versioned, one-time migration while schedule runner admission is closed.

### 13.1 Cutover fence

Migration does not stop unrelated Keeper work:

1. acquire a schedule-subsystem migration epoch;
2. stop the legacy runner from materializing/enqueuing new schedule stimuli;
3. make create/update/cancel return a typed `schedule_migrating` result;
4. leave existing Keeper event queues and turns running;
5. record a physical high-watermark for each owner reaction ledger;
6. import legacy snapshots/signals/queue state through those watermarks;
7. start the new occurrence settlement projector at the recorded cursors so
   rows appended while migration runs are tailed exactly once logically;
8. open new runner/tool admission only after the manifest and cursor handoff
   commit together.

An old pending schedule stimulus may therefore settle during migration without
being lost or requiring a fleet stop. The migration manifest records the epoch,
per-owner high-watermarks, imported counts, and new projector cursors.

### 13.2 Migration inputs

- current schedule definitions in `schedules.json`;
- current embedded execution records;
- schedule signal JSONL;
- Keeper event queue pending/inflight `Schedule_due` stimuli;
- reaction-ledger schedule occurrence evidence.

### 13.3 Migration rules

1. Active definitions are copied to isolated definition records with an exact
   count and digest manifest.
   For a legacy Keeper wake, `owner_lane` is taken from the validated dispatch
   target because that is the lane holding any queue/reaction evidence;
   `scheduled_by` remains actor provenance. A missing or invalid target
   quarantines the definition instead of guessing.
   Every distinct legacy payload version is preserved in an immutable
   definition event; occurrences reference its digest rather than duplicating
   content.
2. Existing execution `succeeded` is imported as
   `Legacy_evidence_imported { semantic = dispatch_acceptance_unknown }`, never
   as business success.
   Every imported occurrence first receives a synthetic `Materialized` event
   with `origin=legacy_migration`; later evidence cannot appear without an
   occurrence root.
3. A parseable Keeper-wake receipt may produce `Queue_accepted`.
4. Exact pending/inflight queue rows produce current nonterminal occurrence
   evidence.
5. Exact reaction settlements produce ACK, cancellation, requeue, or escalation
   events.
6. Missing or contradictory joins become `legacy_indeterminate` or quarantine;
   they are not silently dropped.
7. Actor/reason fields absent from legacy snapshots remain explicitly unknown.
8. Counts by definition, legacy execution, signal, queue, and settlement are
   written to the migration manifest.
9. Only a verified manifest writes the migration commit marker and opens runner
   admission.

After commit:

- legacy files remain read-only archive evidence;
- runtime paths read and write only the new namespace;
- no fallback to stale `.last-good` may silently replace newer occurrence
  truth;
- migration failure degrades the schedule subsystem without blocking unrelated
  Keeper lanes.

## 14. Implementation phases

Each phase is independently reviewable but must preserve the final vocabulary.
No phase may introduce a second terminal authority.

### Phase 0 — Operator-truth correction

Related: #24199, #25691.

- rename current execution output to dispatch/queue acceptance semantics;
- preserve typed wake admission in the receipt;
- project requeue and escalation as first-class evidence;
- remove `matched_stimulus` and `matched_turn_started` from completed UI states;
- remove or wire every runner health counter from a real typed production event.

This phase does not claim to solve occurrence persistence. It immediately stops
false-green operator output.

### Phase 1 — Definition and occurrence types

Related: #21955, #24199, #25687, #25689.

- add closed definition, occurrence event, projection, actor, target, timestamp,
  and backlog policy types;
- create isolated definition and append-only occurrence stores;
- add per-schedule cursor/index contract;
- validate closed payload and owner before persistence;
- prove event/projector state-machine properties.

### Phase 2 — Failure-atomic occurrence outbox

Related: #25690.

- make `Materialized` the sole durable enqueue intent;
- rebuild the exact outbox projection from nonterminal occurrence events;
- enqueue by exact occurrence id;
- append queue acceptance and wake admission;
- retire `signal_keys.json` and idle rewrites;
- add crash-boundary tests.

### Phase 3 — Settlement bridge and reconciler

Related: #25688, #25691.

- project exact schedule settlement rows from the reaction ledger to the
  occurrence ledger without blocking the event queue outbox;
- preserve ACK/requeue/escalation/cancellation exact receipts;
- add per-owner startup reconciliation and degraded health;
- replace one-shot schedule `Running` recovery.

### Phase 4 — Recurrence, cancellation, and expiry

Related: #25692.

- implement closed misfire and overlap policy;
- default Keeper wake to bounded latest delivery;
- implement explicit cancel scope and exact pending cancellation;
- carry occurrence deadline into queue admission;
- prove scheduler-down and Keeper-down policy equivalence.

### Phase 5 — Migration, cutover, and legacy removal

- run versioned one-time migration;
- verify evidence manifest;
- switch API/Dashboard/health to occurrence projection;
- remove embedded execution history and legacy runtime readers/writers;
- retain legacy files as read-only archive;
- complete production soak and RFC closeout.

## 15. Verification plan

### 15.1 Model/property tests

- every accepted event sequence projects deterministically;
- impossible transition order is rejected;
- duplicate event ids are idempotent;
- no two mutually exclusive terminals project as success;
- requeue preserves occurrence id and increments attempt;
- update/materialization and cancel/materialization races preserve one
  definition version and immutable occurrence facts;
- definition cancellation never rewrites historical occurrence evidence;
- one corrupt schedule/row cannot prevent another schedule projection;
- cursor pagination has no duplicate or omitted event under concurrent append.

### 15.2 End-to-end scenarios

1. registered, running Keeper: queue acceptance → signaled → lease → ACK;
2. unregistered Keeper: queue acceptance → deferred → later registration →
   lease → ACK;
3. paused/lifecycle-deferred Keeper with exact denial evidence;
4. provider retry: turn started → requeue → later ACK;
5. provider terminal: turn started → escalation, never completion;
6. cancellation before enqueue, while pending, and racing active lease;
7. expiry before enqueue, while pending, and after lease start;
8. restart at every crash-matrix boundary;
9. duplicate tick/projector invocation with exactly one occurrence/stimulus;
10. Scheduler downtime versus Keeper downtime under each backlog policy;
11. long downtime with bounded catch-up and rate;
12. owner mismatch, unknown payload field, oversized message retrieval pointer;
13. NaN, infinity, huge epoch, and supported timestamp boundaries;
14. malformed occurrence row isolated from another owner lane;
15. legacy migration with pending, ACK, escalation, and missing evidence rows.

The scenarios must call production adapters. Serialization-only tests over
synthetic status values do not satisfy the contract.

### 15.3 Runtime acceptance

- zero schedule executions labelled business success for `Delivery_only`;
- zero open occurrence absent from both an outbox and the Keeper queue without
  typed quarantine;
- zero dead health counters;
- bounded outstanding occurrence count matches each definition's policy;
- one deferred Keeper lane does not delay another lane's occurrence;
- restart reconciliation reaches a terminal state or remains visibly degraded;
- Dashboard occurrence detail can explain every visible label with exact event
  ids and timestamps.

## 16. Alternatives rejected

### 16.1 Rename `Succeeded` only

Truthful vocabulary is necessary as Phase 0, but it does not solve non-atomic
handoff, global history rewrite, recurrence backlog, cancellation, or recovery.

### 16.2 Make the Scheduler own Keeper work

Rejected. It violates the RFC-0234 boundary, duplicates Keeper Gate, and still
cannot prove fulfillment of an open-ended model instruction.

### 16.3 Join queue and reaction stores only at Dashboard read time

Rejected. That preserves multiple authorities, makes absence meaningful, loses
settlement reasons, and cannot drive deterministic recovery.

### 16.4 Treat turn start as success

Rejected. Start is not terminal and the live escalation counterexample disproves
the inference.

### 16.5 Treat queue ACK as business success

Rejected for `masc.keeper_wake`. ACK proves stimulus delivery through a completed
event-queue settlement, not execution of the natural-language request.

### 16.6 Keep signal JSONL plus a repaired `signal_keys.json`

Rejected as the final architecture. A repaired two-store fence would still
duplicate occurrence identity and leave settlement outside the schedule
authority. The occurrence event ledger is the fence.

### 16.7 Introduce a database transaction

Rejected for this scope. Exact-id enqueue, append-only stores, and durable
outboxes already provide the required idempotent saga substrate. A database
would not fix semantic ownership by itself.

## 17. Issue mapping

| Issue | RFC responsibility |
|---|---|
| #21955 | append-only definition/occurrence lifecycle and actor/reason evidence |
| #24199 | separate definition from occurrence history; truthful async lifecycle |
| #25687 | finite/range timestamp admission and row-level quarantine |
| #25688 | per-owner reconciler replacing one-shot `Running` recovery |
| #25689 | lossless closed payload, exact detail pointer, owner-lane authority |
| #25690 | occurrence ledger/outbox replacing non-atomic signal fence |
| #25691 | durable typed wake admission and production-derived health |
| #25692 | explicit misfire, overlap, expiry, cancellation, and backpressure |

These remain implementation issues under this RFC. Closing one does not imply
the RFC is implemented.

## 18. Closed decisions

- The Scheduler owns future intent and occurrence delivery, not external-effect
  authorization.
- `masc.keeper_wake` is delivery-only.
- Definition, occurrence delivery, and work outcome are separate types.
- The append-only occurrence ledger is schedule operator-truth authority.
- Keeper event queue remains lease/settlement authority.
- Settlement returns through the existing transition outbox → reaction ledger
  pattern and a non-blocking occurrence projector.
- Target Keeper is a top-level owner-lane fact, never duplicated in payload.
- Unknown v1 payload fields are rejected.
- Timestamp validation precedes persistence.
- Recurring Keeper wake defaults to latest bounded delivery, not unbounded
  catch-up.
- Dashboard never infers completion from stimulus, turn start, or queue absence.
- Cutover has no permanent dual authority or silent legacy fallback.

## 19. Open decisions before activation

These do not change the semantic model but must be fixed before Phase 5:

1. occurrence ledger retention duration and archive compaction;
2. exact bounded defaults for `grace_sec`, catch-up count/age, and materialize
   rate;
3. whether active-lease cancellation remains request-only or integrates a
   provider cancellation token for specific typed jobs;
4. operator capability required for cross-Keeper definition creation;
5. whether a true typed scheduled-job family receives a separate RFC.

No implementation may substitute heuristics for these decisions.

## 20. Workaround rejection self-check

- Telemetry-as-fix: rejected; events drive real recovery and projection.
- String matching: rejected; all lifecycle, wake, settlement, and policy values
  are closed typed sums.
- Silent fallback: rejected; corrupt/unknown evidence is quarantined.
- Retry without bound: rejected; catch-up and outstanding work are bounded.
- Queue cap without policy: rejected; bounds are part of explicit recurrence
  semantics and skipped/coalesced evidence remains visible.
- Dual authority migration: rejected; one verified hard cut.
- UI-only repair: rejected; Dashboard consumes authoritative occurrence events.
- Fake job success: rejected; delivery and work outcomes remain distinct.

## 21. Acceptance and closeout

This RFC may move to `Implemented` only when:

1. all Phase 0–5 implementation PRs are merged;
2. old production readers/writers for embedded execution history and
   `signal_keys.json` are removed;
3. the migration manifest is verified on a representative live workspace;
4. every crash-matrix row has a production-path deterministic test;
5. Dashboard and APIs expose no unqualified schedule `Succeeded` for
   `Delivery_only`;
6. deferred, requeued, escalated, cancelled, expired, and quarantined
   occurrences are individually explainable;
7. recurrence backlog remains within declared policy during Scheduler and
   Keeper downtime;
8. CI and an operator-observed restart soak are green;
9. #21955, #24199, and #25687–#25692 are either closed by implementation or
   explicitly superseded with evidence.
