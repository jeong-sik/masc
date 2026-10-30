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

Task Skill resolution now groups shared exact references before resolving them
under the captured Tool descriptors, then reuses that selection when setup has
the identical immutable inputs. The [Skill flow comparison](../SKILLS-FLOW.md#task-참조-준비의-as-is--to-be)
records the source call-count scope and changed-input behavior. Measure setup
time separately from first-request bytes, model roundtrips and first useful Tool
latency; a source lookup reduction does not establish those timing results.

The selection also retains an immutable catalog preparation and its derived
catalog, diagnostics and inventory. Prompt surfaces, executable setup, effective
Tool projection and continuation setup consume that product under matching frozen
snapshot and Tool objects. Another Keeper replacing the existing one-slot global
projection cache cannot evict this turn-owned value. Inventory derives rows by a
direct fold over prepared entries, including shadowed entries and independent
snapshot rejections, rather than searching the whole projection/effective lists
again for every item.

Compared with `6633d8223ca8ffe5eff597f3592f518c0cac322a`, `K` consumers of one bound
selection assemble the catalog/inventory once instead of `K` times. This is a
source-path expectation, not an executed count or latency result. Per-turn
sharing and lookup indexing are separate stages; the entire preparation path is
not claimed to be linear. Changed source or Tool objects and mixed
preparations derive a coherent new product, preserving exact Task provenance and
the existing unreadable-source failure semantics. Feature scenarios for
interleaving, source/Tool changes and shadowed/invalid entries are authored but
unexecuted in this unit. Measure cold and interleaved preparations separately from
same-binding reuse when collecting native/model Before/After evidence.

## Indexed exact lookup and cold projection

Compared with `c7c2194c116f165114f872e68cdef8cd01a53f6b`, immutable snapshot indexes
replace exact-entry and effective-name list searches. Task resolution uses the
snapshot's exact index, and catalog projection asks the same snapshot whether an
exact identity is effective. A retained catalog preparation indexes its projected
entries too, with the original entry-object check before reuse. Same-identity
entries from another frozen snapshot are projected independently.

For `E` exact entries and `F` effective entries, one exact/prepared lookup changes
from a linear scan to `O(log E)` Map lookup. Effective classification across the
catalog changes from up to `O(E*F)` comparisons to `O(E log F)`. Index construction
adds `O(E log E)` work and linear-sized retained indexes. These bounds describe
lookup operations, excluding I/O, document parsing/hashing, Composition compilation
and model roundtrips; they are not observed runtime counts or latency.

The ordered entries, first-source precedence, shadows and rejections remain the
serialization/revision inputs. Indexes retain original entry objects and do not
add public fields or execution authority. Authored compound scenarios cover
decoded shadow identities, missing exact packages with the same name, stale pins
across snapshots, rejected duplicate source digests and foreign projection
isolation. They are unexecuted in this unit. Keep cold index construction,
same-snapshot lookup and cross-Keeper interleaving separate in a matched native
comparison, and record memory/latency overhead rather than assuming a total
speedup from the source bounds.

## Name validation without schema construction

Compared with `97997af26ef5c0ada4d284af514207d578182492`, one tool setup derives
the common descriptor/Skill name list once for its official-client and Agent
Core membership checks. Each surface still applies its actual deferred builtin
names and attached-tool identity projection separately. Conversation-carried
schemas remain visible. Declared composition names, async controls and transient
draft names use the same typed row selection as the schema projection, without
constructing descriptions, input schemas or schema-only Tool objects.

With `C` declared compositions and the default transient-draft surface, the two
membership checks previously materialized `2 * (C + 4)` schema-only Tools; the
name-only path materializes none. The common base-name projection changes from
two calls to one per setup. A per-Skill composition profile now constructs only
its declared schema instead of that schema and four discarded control schemas.
These are source operation counts, not executed counters or latency results.
Actual executable Tool construction, Tool calls and request bytes are unchanged
by this unit. Profile bytes still cover the declared Tool's exact name,
description and serialized input schema, excluding shared controls and JSON
envelope framing. Authored scenarios compare profile bytes with the executable
bundle and cover named async work without transient drafts; they are unexecuted.

Measure cold setup and repeated same-binding setup separately. Retain the full
failed/cancelled/unfinished cohort when comparing first useful work; this source
reduction does not establish that interval or a current-head speedup.

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

## Runtime Skill preparation observations

The complete invocation-level preparation snapshot is separate from these cache
samples. Direct and autonomous Task entries retain their original preview writer
and append one `preparation_observed` manifest row after returning, raising or
being cancelled. `decision.preparation_report` keeps the original turn reference,
available execution scope, observation report UUID and actual preparation scopes.
The report UUID distinguishes snapshots of a continued execution; it is not an
execution or resume authority. A returned error remains a returned invocation,
with the rejected preparation scopes represented separately. Active scopes stay
active in the immutable report. Missing original identity is not inferred.

Publication uses the existing best-effort runtime manifest store and retention.
There is no per-scope write or history scan added to the default turns poll.
Report publication cost is additional and unmeasured. Saved reports can outlive
their live writer, but append failure and process exit before publication remain
coverage gaps. The expanded TUI now reads the selected completed journal's
existing runtime trace using its original turn reference and, for direct/batched
operations, its actual execution ID. Autonomous failure/cancellation needs no
reply receipt. A direct failure without its reply turn reference stays explicitly
unlinked. Partial scans, omitted rows, unknown records and duplicate report IDs
remain observation gaps. Saved active scopes describe the capture, not a current
running task. Same-journal revision reuse and request capabilities prevent repeated
frame reads and late selection responses; workspace retirement/explicit refresh
discard that state. JSON and report decoding run outside the render domain.
Standalone identity, complete paging and matched performance remain follow-ups.
Source scenarios were authored, not executed.

The isolated preparation trial's stage journal is experiment evidence, not a
runtime cache observation. Runtime Skill preparation now emits
`skill_preparation_observed` manifest rows at the direct and autonomous Task
resolution boundaries and executable setup. The owner supplies the original
`turn_ref`; the row keeps its Keeper, trace and absolute turn. Autonomous turns
with a recorded source batch can join that identity to
`Turn_started.intake_sources`. Existing Tool and Ask links require their own
original identities; missing Task/source/Ask links stay unrecorded. A nearby
timestamp or matching Task title is not a join.
One turn can contain multiple provider attempts; this row alone does not select
a particular provider request, Task or Ask continuation.

| Boundary | Before | After |
|---|---|---|
| Projection/product reuse | Source construction estimates or isolated trial stages. | Actual `constructed` / `reused` decisions from each cache access. |
| Waiting | No per-access boundary. | Actual lookup finish and binding-lock acquisition offsets; missing marks stay null. |
| Existing turn handle | Could be mistaken for another cache lookup. | `retained_turn_surface` reuse, with no invented lookup or lock marks. |
| Error, cancellation, missing observation | Not represented by cache timings. | Typed report/sample outcome and explicit non-Eio coverage; no success inferred from an empty sample list. |
| Runtime lens | No preparation event. | The existing Keeper lane includes this observation without treating it as context injection, a terminal event or a required completion gate. |

`decision.skill_preparation` contains the phase, original turn reference,
coverage, outcome, total elapsed nanoseconds and samples. Each sample retains
the exact snapshot revision, descriptor count, component and actual decision.
The revision describes the input; it is not the cache equality key or an
execution permission. Documents, paths, Tool inputs and exception text are not
copied. The public projection uses a dedicated allowlist for this payload.

All sample times are decimal-string nanosecond offsets from that report's
monotonic capture start. Use `lookup_finished_ns - entered_ns` for lookup and
`lock_acquired_ns - lookup_finished_ns` for binding-lock acquisition. The latter
includes uncontended overhead: a nonzero value does not prove another owner was
running. For a `constructed` sample, `decision_ns - lock_acquired_ns` covers the
locked construction through publication and observation marking. A reused
sample does not report a new construction. Retained-handle samples start after
binding validation; the enclosing scope includes validation work.

Nested or parallel samples can overlap. Do not sum their durations into a
whole-task latency; the enclosing elapsed time measures only its stated scope.
Uninstrumented gaps are not evidence of model reasoning or another wait cause.

Missing marks and unfinished samples remain missing/in progress. Nested captures
own their samples; child fibers inherit only their actual capture, and closure
prevents late inherited accesses from appending to a finished report. Cancellation
and exceptions retain their original propagation after recording. A crash before
scope settlement can leave no row; absence never proves success. Non-Eio scopes
say `non_eio_unobserved` instead of manufacturing zero cache accesses.

The envelope remains a logical observation. Its wall-clock write timestamp is
not a measured start or finish; runtime-lens clock edges keep both absent for this
event. Compare offsets within one report and matched durations across reports,
not absolute offsets across captures or process restarts.

Cache instrumentation reads clocks and retains scalar metadata in memory. One
best-effort manifest append happens after each covered operation settles and
outside cache locks. That append is outside the measured interval; its overhead,
clock/Atomic work and public projection cost have not been measured. The scope
does not include earlier Task/held-task filesystem reads, later provider work,
first useful action or whole TUI refresh. Operator inventory reads and continuation
wakes without a capture stay unobserved; they do not borrow another turn's clock.

Authored scenarios cover real cold/reused preparation, nested/parallel capture and caller
cancellation, a typed setup error, and original-turn durable/public/API readback.
They are unexecuted for this change. Runtime event generation, current native
visibility and matched Before/After latency remain unverified.

## Select only the status inspection needed

`masc_keeper_status` with `fast:true` skips repository checkout inspection by
default. `execution_context.repository_checkouts` reports `not_inspected` and
an empty `entries` list; this does not claim that the workspace has no repos.
Use `include_repository_checkouts:true` when checkout identity or freshness is
needed. `fast:false` keeps the full-inspection default, and an explicit false
can disable this section independently. The resolved choice is included in
`status_options`.

The Dashboard detail request explicitly selects checkout inspection because
its repository panel consumes that projection. Basic agent status reads can
leave it disabled, avoiding directory discovery, sandbox entry and Git calls
for that section. Other status sections retain their own controls.

The [captured baseline](../evidence/keeper-status-selective-checkouts-20261016/baseline.json)
records one existing live MCP response at 2026-10-16T08:02:38.820Z: 50,753 UTF-8
bytes and 32 checkout entries. Its checkout subdocument contains 15,082 bytes.
Replacing only that subdocument and recording the new section selection in the
same compact JSON predicts a 15,007-byte reduction (50,747 to 35,740 bytes).
That is a JSON projection estimate from a fixed captured document, not a
candidate execution result. The observed 4,674 ms RPC round trip includes all
status work and transport; it cannot be attributed to checkout inspection or
used as a task-preparation speedup. No candidate runtime was installed for this
observation.
