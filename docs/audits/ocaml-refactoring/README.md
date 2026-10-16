# OCaml refactoring backlog

The objective is to identify refactoring opportunities across MASC, maintain an
explicit list, and improve it in repeated reviewed changes. This is an active
backlog, not a claim that the repository is fully audited or refactored.

Baseline: `aea8424926ea79f110315eec5ab429ac51043598` (2026-10-16).
The [constitution](../../constitution.xml) and
[contributor workflow](../../guides/CONTRIBUTOR-WORKFLOW.md) govern execution.

## Scope and evidence

[Inventory metadata](inventory.json) classifies every tracked `.ml`/`.mli` file.
[The census reader](inventory.py) enumerates 2,583 implementations under
`lib/`, `bin/` and `packages/agent_core/lib/` directly from committed Git blobs.
The metadata records a SHA-256 of sorted path/blob pairs, physical line counts
and interface presence across 194 source areas (grouped by package/directory). Reproduce it with
`python3 docs/audits/ocaml-refactoring/inventory.py aea8424926ea79f110315eec5ab429ac51043598`. Production
also has 2,427 interfaces; tests, tooling and documentation/experiment files are
counted separately. These measurements are reading aids, not quality scores,
file-size targets or CI gates. Missing `.mli` alone is not a defect.

The earlier `lib/` + `bin/` inventory did not include the 233 Agent Core
implementations. This inventory includes them. The file census is complete for
its stated baseline and production scope; semantic review is selective and
continues. Consulted files below do not imply complete audits of those files.

The [earlier Godfile audit](../godfiles-20261008/README.md) remains historical
evidence. Its counts and open/closed claims must not be carried forward as live
state. Existing Memory OS work was refreshed through the GitHub Stacks API:
[#43347](https://github.com/jeong-sik/masc/pull/43347),
[#43348](https://github.com/jeong-sik/masc/pull/43348) and
[#43353](https://github.com/jeong-sik/masc/pull/43353) are open Draft members of
stack #43349, source-reviewed but unmerged at this round's observation.

## Reference basis

- [OCaml Programming Guidelines](https://ocaml.org/docs/guidelines): coherent
  modules, explicit interfaces, readable small functions and exhaustive matching.
- [OCaml Error Handling](https://ocaml.org/docs/error-handling): represent
  expected failure explicitly and retain distinctions callers need.
- [Jane Street Effective ML](https://blog.janestreet.com/effective-ml/): optimize
  for readers, make states precise, avoid elaborate type tricks, and keep
  mutation where it serves the problem.
- [Real World OCaml: Modules](https://dev.realworldocaml.org/files-modules-and-programs.html)
  and [Maps and Hash Tables](https://dev.realworldocaml.org/maps-and-hashtables.html):
  hide representation behind signatures; use immutable maps when retained
  values and explicit transformations simplify reasoning.

These principles are applied to the actual call graph and invariants. They do
not require importing Base/Core or rewriting all references, caches and locks.

## Iteration rules

1. Re-read the chosen candidate at current main and check active PR overlap.
2. Define its preserved behavior, actual consumer and relevant behavior suite.
3. Implement one coherent boundary on a Native Stack layer.
4. Assign an independent adversarial source reviewer while starting the next
   work unit; address substantive findings and bind the result to a concrete SHA.
5. Update the item's status and evidence. Parsing, type checking, tests, GitHub
   approval, merge and runtime observation are separate fields of evidence.
6. Return to the queue and widen semantic coverage. Do not treat a few successful
   extractions as completion of this broad goal.

`next` means the source supports a bounded useful change. `later` has a credible
boundary but needs broader coordination. `investigate` needs more evidence and
is not yet an established repair. These are work-order labels, not severity or
runtime gates. Source-review completion alone leaves a Draft item in review.

## Current queue

The queue now contains **25 concrete candidates**: 24 from the first semantic pass and A1 from a focused Agent Core follow-up. Three are implemented as Draft PRs with independent source review: `S1` in [#43367](https://github.com/jeong-sik/masc/pull/43367) isolates provider usage acceptance; `K1` in [#43370](https://github.com/jeong-sik/masc/pull/43370) preserves separate Librarian failure-policy axes; `D2` in [#43374](https://github.com/jeong-sik/masc/pull/43374) returns an explicit Goal commit result. Other `next` items remain queued; this ordering does not waive their coverage.

| ID | Priority | Status | Refactoring point |
| --- | --- | --- | --- |
| [K1](#k1) | next | in review | Compute librarian failure evidence once with explicit independent policy axes |
| [K2](#k2) | next | candidate | Give canonical child export selection a typed pure boundary |
| [K3](#k3) | next | candidate | Represent Board contention rearm tickets with one explicit phase |
| [K4](#k4) | later | candidate | Make request-evidence reset and projection ownership explicit per attempt |
| [K5](#k5) | later | candidate | Separate approval restart replay decisions from recovery effects |
| [K6](#k6) | investigate | candidate | Make Agent Core committed-batch scanning an explicit returned state |
| [K7](#k7) | later | candidate | Separate Memory receipt reconciliation selection from its durable plan |
| [D1](#d1) | next | candidate | Return an explicit task commit receipt instead of a cross-scope notification ref |
| [D2](#d2) | next | in review | Make Goal upsert a typed immutable transaction decision |
| [D3](#d3) | later | candidate | Isolate the Goal document codec and schema rejection contract |
| [D4](#d4) | investigate | candidate | Audit and retain typed Goal publication outcomes across the backend adapter |
| [D5](#d5) | later | candidate | Extract the Board vote decision from post/comment mutation shells |
| [D6](#d6) | later | candidate | Represent Board snapshot flush work and retry obligations explicitly |
| [D7](#d7) | next | candidate | Separate evidence persistence codec, judge transport and metadata projection from acquisition |
| [S1](#s1) | next | in review | Extract the provider usage acceptance/revocation reducer from the shared observation store |
| [S2](#s2) | next | candidate | Move lane edit decisions into a pure declared-configuration planner |
| [S3](#s3) | later | candidate | Separate Antigravity protocol transitions from persistence and stream callbacks |
| [S4](#s4) | investigate | candidate | Make provider-metrics cache refresh ownership explicit and cancellation-complete |
| [S5](#s5) | later | candidate | Consolidate full-health refresh bookkeeping into an immutable owned state machine |
| [S6](#s6) | later | candidate | Give connector status a common typed projection before JSON aggregation |
| [S7](#s7) | later | candidate | Replace connector ingress scheduling flag combinations with explicit lane lifecycle |
| [S8](#s8) | next | candidate | Separate durable provider-history decoding and daily projection from journal IO |
| [R1](#r1) | later | candidate | Credential batch ownership projection |
| [R2](#r2) | later | candidate | Fusion decision event ownership |
| [A1](#a1) | next | candidate | Separate stream error projection from optional diagnostic file I/O |

## Candidate evidence

Source coordinates are immutable baseline links. Consumer/test links are navigation aids; refresh them before implementation.

### K1

**Compute librarian failure evidence once with explicit independent policy axes**

Source: [lib/keeper/keeper_librarian_runtime.ml:460](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/keeper/keeper_librarian_runtime.ml#L460-L896).

Problem: The same Exact_output failure tree is traversed independently by flow_input_capacity_evidence, flow_has_invalid_output, flow_has_size_independent_failure, and walk_shows_size_flow; extraction_has_invalid_output, extraction_shows_size, extraction_meets_same_failure, and extraction_observed_input_capacity repeat the work over nested CLI fallback history. Constructor additions must be classified consistently in several places. These are deliberately different policies, so merging their booleans would be incorrect, but the repeated traversal obscures their common evidence and veto rules.

Change: Introduce a small pure failure-evidence record with separate fields for historical range-size evidence, named input-capacity refusal, invalid output, and size-independent execution failure. Classify each typed provider/CLI cause exhaustively and fold the exact-flow advances and final cause once. Derive existing public decisions from the record, retaining their current signatures. Keep prompt rendering, dispatch, and persistence in the runtime.

Preserve:

- A failure before generation dispatch is not provider size evidence.
- Historical range-window policy and admission input-capacity policy remain distinct; a timeout is not by itself an admission split permit.
- Invalid output vetoes capacity/size adaptation in either slot order as current callers require.
- Candidate rejection is not a dispatched size-independent execution failure.
- A later quota failure does not erase an earlier measured CLI capacity; equal capacities preserve walk order.
- Do not introduce accumulated turn, time, token, or cost gates.

Consumers: [lib/keeper/keeper_librarian_runtime.ml](../../../lib/keeper/keeper_librarian_runtime.ml), [lib/keeper/keeper_librarian_durable_consumer.ml](../../../lib/keeper/keeper_librarian_durable_consumer.ml), [lib/keeper/keeper_librarian_queue_refresh.ml](../../../lib/keeper/keeper_librarian_queue_refresh.ml), [lib/keeper/keeper_memory_admission_worker.ml](../../../lib/keeper/keeper_memory_admission_worker.ml).

Scenarios: [test/test_keeper_librarian_capacity_callback.ml](../../../test/test_keeper_librarian_capacity_callback.ml), [test/test_keeper_librarian_cli_lane.ml](../../../test/test_keeper_librarian_cli_lane.ml), [test/test_keeper_librarian_range.ml](../../../test/test_keeper_librarian_range.ml). **Not executed in this audit.**

Ordering rationale: Bounded pure policy work with existing end-to-end callback and admission-worker scenarios, including slot-order independence and invalid-output veto. It reduces constructor drift without changing dispatch/storage or duplicating the in-review Memory OS codecs.

Implementation: [#43370](https://github.com/jeong-sik/masc/pull/43370) adds a private immutable failure-evidence module. Runtime computes one summary for terminal callbacks; the public interface, dispatch evidence and callback order remain unchanged. Added equal-capacity slot-order cases and strengthened the admission-worker scenario to distinguish native input refusal from measured range-size evidence. Five changed OCaml files passed syntax parsing; scenarios are unexecuted. Review details and exact heads are recorded on the PR.

### K2

**Give canonical child export selection a typed pure boundary**

Source: [lib/keeper/keeper_tool_composition_surface.ml:1445](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/keeper/keeper_tool_composition_surface.ml#L1445-L1498), [lib/keeper/keeper_composition_dependency_result.ml:91](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/keeper/keeper_composition_dependency_result.ml#L91-L126).

Problem: The async worker dispatches a child-result read, preserves typed Deferred/Failed/Completed status, then decodes the canonical result/exports/available/value JSON envelope inline inside the effectful dispatch closure. Changes to export schema or selection must be reviewed alongside original activation authority, artifact publication, unavailable-result tracking, and sibling execution in a 3,026-line surface module. The storage reader exposes a generic execution result, so the canonical envelope contract is reconstructed at the consumer.

Change: Create a private pure selected-export decoder near the canonical dependency-result contract, accepting the declared Plan.export list and observed JSON and returning ordered export values or a closed selection error. Keep ownership validation, result-artifact publication, dispatch, and conversion to Tool_result in their current owners. Use direct calls to the new boundary rather than another surface facade.

Preserve:

- Only successful canonical named-composition results grant composable exports.
- No requested exports permits an absent exports object; declared exports must each be available and carry a value.
- Declared export order remains the output association order.
- Authoritative failed-child observations remain distinct from unavailable observations/publication failures.
- Deferred dependencies, retained artifacts, failure effect disposition, and original child activation authority remain intact.
- Reading a result never grants child submission or replay authority.

Consumers: [lib/keeper/keeper_tool_composition_surface.ml](../../../lib/keeper/keeper_tool_composition_surface.ml), [lib/keeper/keeper_composition_continuation_wake.ml](../../../lib/keeper/keeper_composition_continuation_wake.ml), [lib/keeper/keeper_tools_agent_core_bundle.ml](../../../lib/keeper/keeper_tools_agent_core_bundle.ml).

Scenarios: [test/test_keeper_composition_nested.ml](../../../test/test_keeper_composition_nested.ml), [test/test_keeper_composition_async_broker.ml](../../../test/test_keeper_composition_async_broker.ml), [test/test_keeper_tool_plan_executor.ml](../../../test/test_keeper_tool_plan_executor.ml). **Not executed in this audit.**

Ordering rationale: A narrow protocol boundary in a large effect owner; it improves reviewability without replacing the already typed execution and authority machinery. Existing nested-composition tests cover selected exports, child failure, and dependent dispatch.

### K3

**Represent Board contention rearm tickets with one explicit phase**

Source: [lib/keeper/keeper_board_attention_worker.ml:63](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/keeper/keeper_board_attention_worker.ml#L63-L98), [lib/keeper/keeper_board_attention_worker.ml:175](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/keeper/keeper_board_attention_worker.ml#L175-L387).

Problem: Each rearm entry represents ticket ownership using independent mutable pending and inflight options. Scheduling, firing, retry completion, cancellation, and reset all reconstruct which combinations are valid under the mutex, often matching the impossible both-present shape defensively. State changes and logging/fork decisions are spread across several functions, making stale-generation and reset-during-delivery reasoning harder than necessary.

Change: Use an explicit Idle/Pending ticket/Inflight ticket phase and a small pure transition function that returns the next entry plus Schedule/Deliver/Ignore/Record outcome. Keep the scheduler mutex, atomic publication of entry updates, fork/sleep/request callbacks, and logging in the existing effect owner. Do not make the shared scheduler globally immutable merely to remove mutation.

Preserve:

- A generation has at most one pending or inflight ticket.
- Ticket identity and partition generation, not elapsed age, decide whether a callback is current.
- Wake callbacks run outside the scheduler mutex.
- A reset during a failed wake suppresses retry of the old generation.
- Delivery error schedules the existing retry policy; sleeping/fork cancellation releases the corresponding pending ticket.
- No Board candidate is consumed or expired by scheduler cleanup.

Consumers: [lib/keeper/keeper_board_attention_worker.ml](../../../lib/keeper/keeper_board_attention_worker.ml), [lib/keeper/keeper_keepalive.ml](../../../lib/keeper/keeper_keepalive.ml).

Scenarios: [test/test_keeper_board_attention_worker.ml](../../../test/test_keeper_board_attention_worker.ml). **Not executed in this audit.**

Ordering rationale: The behavior suite already covers delayed deduplication (line 987), delivery retry (1147), callback outside lock (1188), and reset during callback (1239). The change targets invalid representable states, not the justified mutex-protected mutation itself.

### K4

**Make request-evidence reset and projection ownership explicit per attempt**

Source: [lib/keeper/keeper_agent_run.ml:1475](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/keeper/keeper_agent_run.ml#L1475-L1547), [lib/keeper/keeper_agent_run.ml:1910](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/keeper/keeper_agent_run.ml#L1910-L2065), [lib/keeper/keeper_agent_run.ml:2545](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/keeper/keeper_agent_run.ml#L2545-L2701).

Problem: Request attribution, wire evidence, projected provider content, and projected messages occupy four independently reset refs; the source comment explicitly documents that clearing only the final record cells lets a failed lane attempt leak its inputs into the next lane. Their updates and final projections are hundreds of lines apart. Turn-local model-input windows and last-response observations intentionally have different lifetimes, so a broad single optional evidence cell would also be wrong.

Change: Encapsulate attempt-local request evidence in a private state record with an explicit unprojected/projected projection variant and named begin_attempt/observe_projection/observe_wire/observe_native_input operations. Each operation returns the new state; one callback-owned cell may publish it. Keep turn-local window/response evidence and digest memo ownership separate. Expose immutable snapshots to receipt generation.

Preserve:

- Every materialized runtime attempt resets all attempt-local evidence together.
- Turn-local window cuts and last-response input observations survive a later runtime selection.
- A native client holding input is an explicit attribution gap, not zero bytes or an absent dispatch.
- A wire observation can exist without a serializable body or successful provenance and must retain that distinction.
- A turn-local digest memo is mutated only by its owning fiber after the awaited CPU job; cancellation does not hand shared mutable state to a worker.
- Persisted input snapshots and receipt runtime attribution use the actual observed attempt.

Consumers: [lib/keeper/keeper_agent_run.ml](../../../lib/keeper/keeper_agent_run.ml), [lib/keeper/keeper_turn.ml](../../../lib/keeper/keeper_turn.ml), [lib/keeper/keeper_turn_record_writer.ml](../../../lib/keeper/keeper_turn_record_writer.ml), [lib/keeper/keeper_provider_input_snapshot.ml](../../../lib/keeper/keeper_provider_input_snapshot.ml).

Scenarios: [test/test_keeper_prompt_metrics.ml](../../../test/test_keeper_prompt_metrics.ml), [test/test_keeper_model_input_ledger.ml](../../../test/test_keeper_model_input_ledger.ml), [test/test_keeper_projection_change.ml](../../../test/test_keeper_projection_change.ml), [test/test_keeper_model_input_demotion.ml](../../../test/test_keeper_model_input_demotion.ml), [test/test_keeper_official_client_host.ml](../../../test/test_keeper_official_client_host.ml). **Not executed in this audit.**

Ordering rationale: Causal historical risk is documented directly beside the reset code. High impact on observability integrity, but callback lifetime and mixed native/Agent Core paths make this less isolated than K1-K3. Existing helper tests do not by themselves prove a complete multi-attempt run_turn scenario.

### K5

**Separate approval restart replay decisions from recovery effects**

Source: [lib/keeper/keeper_approval_queue.ml:519](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/keeper/keeper_approval_queue.ml#L519-L787).

Problem: read_pending_log_unlocked combines durable-tail recovery, raw JSON line parsing, generation validation, pure log-row application, sequence calculation, and observation of settlement errors. load_snapshot_unlocked then combines decoded-state classification with cache publication, conditional compaction, error reporting, and a five-element result tuple. It is difficult to review which facts authorize a restart rewrite without following filesystem effects through both functions.

Change: Extract pure log replay over complete decoded rows into an explicit replay-state record, then a pure restart-plan result describing readable entry errors, classified pending/delivery maps, and whether durable rewrite is necessary. Keep tail recovery, fsync/compaction, locking, and cache publication in the store shell. Reuse existing codec and classify_restarted functions; do not invent a generic event-store framework.

Preserve:

- Older log generations are already represented by the snapshot; a future generation fails closed.
- Only an incomplete final append is recoverable as a tail; malformed complete rows preserve the store and fail.
- Monotonic next_sequence uses the maximum accepted row sequence.
- A missing snapshot is a reset store and does not authorize replaying orphan log rows.
- Readable entries and their explicit errors survive a partial snapshot; entry errors prevent restart rewrite.
- Durable snapshot/log compaction and published caches cannot describe different generations.
- Cancellation is re-raised; shared cache mutation remains under the existing store lock.

Consumers: [lib/keeper/keeper_approval_queue.ml](../../../lib/keeper/keeper_approval_queue.ml), [lib/keeper/keeper_gate.ml](../../../lib/keeper/keeper_gate.ml), [lib/keeper/keeper_gate_replay.ml](../../../lib/keeper/keeper_gate_replay.ml), [lib/server/server_runtime_bootstrap.ml](../../../lib/server/server_runtime_bootstrap.ml), [lib/keeper/keeper_shutdown_finalize.ml](../../../lib/keeper/keeper_shutdown_finalize.ml).

Scenarios: [test/test_keeper_approval_queue.ml](../../../test/test_keeper_approval_queue.ml), [test/test_keeper_hitl_replay_delivery.ml](../../../test/test_keeper_hitl_replay_delivery.ml). **Not executed in this audit.**

Ordering rationale: Direct restart scenarios already cover sequence persistence, generation serialization, partial snapshots, row replay, and incomplete-tail recovery. The change reduces audit complexity at an authority boundary, but must preserve the current recovery/write ordering exactly.

### K6

**Make Agent Core committed-batch scanning an explicit returned state**

Source: [packages/agent_core/lib/execution_event_store.ml:1240](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/packages/agent_core/lib/execution_event_store.ml#L1240-L1444).

Problem: scan_committed_batches nests a batch/event grammar inside file-frame reads, codec calls, cooperative yields, digest accumulation, and two outer refs that publish locations and replay events only after a valid footer. The commit visibility rule exists in control-flow placement rather than a named typed scan state, so a change to streaming or indexing can accidentally move partial-batch state across the commit boundary.

Change: First replace the two outer refs with explicit immutable scan accumulators passed through tail recursion. If that clarifies the boundary, isolate pure batch-header/footer/event-sequence validation over already decoded frames using a closed batch phase and a validated committed-batch value. Retain streaming file reads, incremental digest work, Eio cancellation checks and cooperative yields in the driver; do not preload the whole WAL or change its format.

Preserve:

- No event index entry or replay event is committed before matching batch identity, range, count, and digest checks.
- Event sequence and correlation identity remain exact and canonical bytes remain validated.
- Committed corruption is refused rather than truncated as an uncommitted tail.
- Read_only_events and Rebuild_durable_index return identical committed event order while differing only in index construction.
- Cancellation checkpoints and cooperative yielding remain present for large WALs.
- Writer claims, lifecycle hooks, fsync authority, and fencing stay in their existing effect owner.

Consumers: [packages/agent_core/lib/execution_event_store.ml](../../../packages/agent_core/lib/execution_event_store.ml), [packages/agent_core/lib/execution_journal.ml](../../../packages/agent_core/lib/execution_journal.ml).

Scenarios: [packages/agent_core/test/test_execution_event_store.ml](../../../packages/agent_core/test/test_execution_event_store.ml), [packages/agent_core/test/test_execution_journal.ml](../../../packages/agent_core/test/test_execution_journal.ml), [packages/agent_core/test/test_execution_lane_writer.ml](../../../packages/agent_core/test/test_execution_lane_writer.ml). **Not executed in this audit.**

Ordering rationale: Useful separation at a durable authority boundary with extensive corruption/recovery/cancellation scenarios. The current private mutable store and byte buffers are justified; no performance improvement is claimed, and a small accumulator-only slice should precede any larger grammar extraction.

### K7

**Separate Memory receipt reconciliation selection from its durable plan**

Source: [lib/keeper/keeper_memory_os_current.ml:705](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/keeper/keeper_memory_os_current.ml#L705-L788).

Problem: Receipt reconciliation interleaves cached fixed-point checks, lazy snapshot hashing, prepared-snapshot durability confirmation, pure eligibility filtering, first-occurrence deduplication in a local hash table, quarantine, cache marking, file removal, and rewriting. The receipt selection policy is therefore read together with its effect order even though it can be calculated from observed receipt/snapshot values.

Change: After the existing Memory stack integrates, extract a pure receipt selection result carrying ordered reconciled receipts and a typed unchanged/remove/rewrite decision. Use an immutable set for exact receipt-key deduplication or retain a private local hash table if measured cardinality justifies it; the substantive boundary is the returned decision. Leave snapshot sync, quarantine-before-rewrite, atomic I/O, and cache identity checks in the store.

Preserve:

- Prepared receipts become committed only for the exact snapshot revision and digest and after durability confirmation.
- Committed receipts remain valid at a higher authoritative snapshot revision.
- Duplicate keys retain their first input occurrence and existing order.
- Skipped receipt bytes are quarantined before any rewrite or removal forgets them.
- The fixed-point shortcut requires unchanged or newer authoritative snapshot evidence; missing/lower/different same-revision snapshots require reconciliation.
- Candidate consumption receipts survive unrelated snapshot commits and fact retirement.
- Coordinate after PRs 43347, 43348, and 43353; this candidate excludes their codec and successor-projection scope.

Consumers: [lib/keeper/keeper_memory_os_current.ml](../../../lib/keeper/keeper_memory_os_current.ml), [lib/keeper/keeper_librarian_durable_consumer.ml](../../../lib/keeper/keeper_librarian_durable_consumer.ml), [lib/keeper/keeper_memory_admission_worker.ml](../../../lib/keeper/keeper_memory_admission_worker.ml).

Scenarios: [test/test_keeper_memory_os_current.ml](../../../test/test_keeper_memory_os_current.ml), [test/test_keeper_librarian_durable_consumer.ml](../../../test/test_keeper_librarian_durable_consumer.ml), [test/test_keeper_memory_admission_queue.ml](../../../test/test_keeper_memory_admission_queue.ml). **Not executed in this audit.**

Ordering rationale: Distinct residual responsibility from the in-review Memory codec/successor slices. Existing tests include first-order receipt reconciliation, prepared exact-snapshot recovery, cache invalidation, no-change consumption, and retirement replay rejection. Defer until that stack lands to avoid overlapping ownership.

### D1

**Return an explicit task commit receipt instead of a cross-scope notification ref**

Source: [lib/workspace/workspace_task_transitions.ml:156](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/workspace/workspace_task_transitions.ml#L156-L162), [lib/workspace/workspace_task_transitions.ml:405](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/workspace/workspace_task_transitions.ml#L405-L447), [lib/workspace/workspace_task_transitions.ml:684](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/workspace/workspace_task_transitions.ml#L684-L731).

Problem: transition_task_outcome_r carries the public result and committed_verification_submission through separate channels. The latter ref is set after write_backlog, then inspected after the lock callback and its exception-to-IoError handler. Correct notification behavior therefore depends on an assignment happening at exactly the commit boundary, even when later projections fail. This is a real responsibility boundary, not a complaint about a local ref in isolation.

Change: Introduce a private closed transaction outcome describing no-op versus committed transition, carrying the verified submission obligation and response together. Separate pre-commit failure/compensation from post-commit projections and submission finalization. Replace the ref only after preserving the cases where a projection fails after the backlog has committed; do not simply map the successful public Result to a notification.

Preserve:

- Read and mutate the authoritative backlog under the existing lease/lock.
- Create the verification request before committing AwaitingVerification.
- Compensate only a failed pre-commit request; never undo a committed task.
- Delete a superseded verification request before announcing the new request.
- No-op/rejected transitions remain silent. Preserve Eio cancellation and existing post-commit scheduling semantics.

Consumers: [lib/workspace/workspace_task.ml](../../../lib/workspace/workspace_task.ml), [lib/task/tool_task.ml](../../../lib/task/tool_task.ml), [lib/verification_protocol.ml](../../../lib/verification_protocol.ml).

Scenarios: [test/test_task_transition_broadcast.ml](../../../test/test_task_transition_broadcast.ml), [test/test_verification.ml](../../../test/test_verification.ml), [test/test_workspace.ml](../../../test/test_workspace.ml). **Not executed in this audit.**

Ordering rationale: The current code explicitly documents commit-sensitive projection failures, and test_submit_schedules_review_after_log_failure plus test_raw_workspace_submission_notifies_once exercise the user-visible continuity. A typed receipt makes the commit/notification relation reviewable without moving I/O or changing task policy.

### D2

**Make Goal upsert a typed immutable transaction decision**

Source: [lib/goal/goal_store.ml:681](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/goal/goal_store.ml#L681-L700), [lib/goal/goal_store.ml:1018](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/goal/goal_store.ml#L1018-L1168).

Problem: upsert_goal_internal communicates created/updated action, refusal, and pending audit events through three refs. update_state uses physical identity (next_state == state) to mean do not write, including a rejected first creation. A future record-copy refactor can accidentally turn refusal into an empty-store write, and the three independent refs permit combinations that are impossible in the domain but require fallback failed-to-save handling.

Change: Compute an explicit result containing either a write error or an accepted immutable commit with the next state and returned value. Have a private lock-owning transaction persist only accepted commits and return the value directly. Keep row transformation separate from clock, identity and storage effects, and preserve the public upsert wrappers. The focused source audit found that every accepted existing upsert writes even when supplied fields are unchanged; there is no upsert no-op decision to add. `transact_goal` has its own equality-based no-op contract and remains separate.

Preserve:

- A refused first upsert writes no goals.json and leaves the source Uninitialized.
- Creation/update is decided inside the write lock from authoritative state.
- Criterion edits invalidate proof progress using Goal_phase.criterion_changed and keep suspension semantics.
- Returned updated action contains the previous goal, and the revision witness belongs to that exact commit.
- Audit intents remain in the same state write as the goal change; refusal must not mint events. An accepted unchanged-field upsert still advances the store revision and, with an actor, emits `Updated`.

Consumers: [lib/workspace_goals.ml](../../../lib/workspace_goals.ml), [lib/goal/goal_measurement.ml](../../../lib/goal/goal_measurement.ml), [lib/goal/goal_verification.ml](../../../lib/goal/goal_verification.ml).

Scenarios: [test/test_goal_store.ml](../../../test/test_goal_store.ml), [test/test_goal_upsert_fsm_bypass_10247.ml](../../../test/test_goal_upsert_fsm_bypass_10247.ml), [test/test_goal_suspension.ml](../../../test/test_goal_suspension.ml), [test/test_goal_tools.ml](../../../test/test_goal_tools.ml). **Not executed in this audit.**

Ordering rationale: This removes implicit control encoded by object identity and three mutable side channels. Existing tests explicitly cover refused first write, previous-row return, revision witnesses, criterion edits, and durable audit outbox behavior.

Implementation: [#43374](https://github.com/jeong-sik/masc/pull/43374) replaces the three refs and physical-identity signal with a private typed commit result, keeping pure row transformations apart from identity, clock and persistence effects. The unused public `update_state` helper is removed after repository caller/alias inspection; the three upsert interfaces remain unchanged. External package consumers were not verified. Added actual-store scenarios for audited refusal and accepted identical-field writes. Four changed OCaml files passed syntax parsing; scenarios are unexecuted.

### D3

**Isolate the Goal document codec and schema rejection contract**

Source: [lib/goal/goal_store.ml:16](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/goal/goal_store.ml#L16-L165), [lib/goal/goal_store.ml:168](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/goal/goal_store.ml#L168-L393).

Problem: Goal state, pending events and pending notifications share a persistence module with filesystem source classification, locking, writes and transactions. The codecs encode different deliberate contracts: unknown Goal fields are refused, suspended phases require restore state, event/notification objects have exact fields, missing optional outboxes are accepted, and duplicate identities are rejected. Readers changing source availability or transactions must currently retain all these wire-level details in context.

Change: Extract canonical Goal state data and a private document codec with explicit encode/decode/validate signatures. Keep load_source, errno handling, mirror observation and transaction effects in Goal_store. Move acceptance behavior unchanged first; do not silently tighten duplicate-field rules, change optional defaults, remove priority clamping or rewrite historical wire formats in the extraction.

Preserve:

- Preserve every currently accepted/rejected JSON shape, field order and schema_rejection field/detail.
- Unknown status/phase shapes remain refused; suspended Goal restore targets are preserved.
- Mirror data stays observation-only and is never served as authoritative Goal state.
- Pending event/notification order and their distinct identity checks remain unchanged.
- Public Goal_store type identity and API remain compatible.

Consumers: [lib/keeper/keeper_store_boot_reconcile.ml](../../../lib/keeper/keeper_store_boot_reconcile.ml), [lib/workspace_goals.ml](../../../lib/workspace_goals.ml), [lib/task/task_goal_assignment.ml](../../../lib/task/task_goal_assignment.ml).

Scenarios: [test/test_goal_store.ml](../../../test/test_goal_store.ml), [test/test_goal_notification_contract.ml](../../../test/test_goal_notification_contract.ml), [test/test_goal_suspension.ml](../../../test/test_goal_suspension.ml), [test/test_keeper_store_boot_reconcile.ml](../../../test/test_keeper_store_boot_reconcile.ml). **Not executed in this audit.**

Ordering rationale: The candidate is a trust-boundary split: exact persisted state validation can be reviewed independently of read-source policy and mutation. It is not a request to split by line count or to replace all parsers with a generic framework.

### D4

**Audit and retain typed Goal publication outcomes across the backend adapter**

Source: [lib/goal/goal_store.ml:514](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/goal/goal_store.ml#L514-L576), [lib/goal/goal_store.ml:592](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/goal/goal_store.ml#L592-L604), [lib/workspace/workspace_utils_ops.ml:257](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/workspace/workspace_utils_ops.ml#L257-L300), [lib/workspace/workspace_backlog.ml:215](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/workspace/workspace_backlog.ml#L215-L220).

Problem: Workspace_utils_ops already distinguishes a committed backend mutation with local mirror failure as Ok {mirror_error=Some _}. Its write_json_result compatibility adapter converts that outcome back to Error. Goal_store.write_state_result uses that adapter and returns Persist_failed to callers before advancing the projection generation, while Goal reads are direct local-file reads. Whether this is correct depends on which store is authoritative for each backend; the code exposes a semantic question rather than proof of a reproduced production bug.

Change: First trace Goal backend authority and add a focused fault scenario for backend success/local mirror failure. Then carry an explicit publication outcome if the backend commit is authoritative, or use a clearly local-authoritative writer if local goals.json is the authority. Reuse the existing typed write_json_commit capability instead of inventing string matching. Keep this separate from the pure upsert extraction.

Preserve:

- Never report a definitive pre-effect failure for a mutation that the chosen authority has committed.
- A recovery mirror failure remains a committed primary write, as the current test already requires.
- Unavailable or corrupt primary state must not authorize mutation through a fallback mirror.
- Projection generation and event delivery must be tied to the actual authoritative commit.
- Do not change backend authority without an explicit documented decision.

Consumers: [lib/workspace_goals.ml](../../../lib/workspace_goals.ml), [lib/goal/goal_measurement.ml](../../../lib/goal/goal_measurement.ml), [lib/goal/goal_verification.ml](../../../lib/goal/goal_verification.ml).

Scenarios: [test/test_goal_store.ml](../../../test/test_goal_store.ml), [test/test_workspace.ml](../../../test/test_workspace.ml), [test/test_goal_tools.ml](../../../test/test_goal_tools.ml). **Not executed in this audit.**

Ordering rationale: The exact flattening exists in current source, but the authority choice needs clarification from implementation and fault evidence. This is not a blanket change of every Result-returning writer; Workspace_backlog is a useful existing example of a committed-outcome boundary.

### D5

**Extract the Board vote decision from post/comment mutation shells**

Source: [lib/board/board_votes.ml:164](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/board/board_votes.ml#L164-L235), [lib/board/board_votes.ml:257](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/board/board_votes.ml#L257-L316).

Problem: Post and comment voting duplicate the previous-direction state machine and counter adjustments inside separate validate/append/re-read/mutate pipelines. A correction to same-direction rejection or flip arithmetic must be applied in both places and at both admission/commit stages. The effect ordering is intentional: a vote row is appended before in-memory mutation and the final decision uses a fresh read.

Change: Introduce a small private pure vote decision that maps previous vote and requested direction to Already_voted or a typed first-vote/flip delta. Apply that decision under each existing state lock, with separate post/comment record updates so post updated_at semantics remain explicit. Keep durable append and the fresh commit-stage recheck in the two effect shells.

Preserve:

- Validation or append failure leaves all vote counts and vote_log entries unchanged.
- Recheck after append; do not reuse stale staged post/comment records.
- Same-direction concurrent attempts remain Already_voted.
- Post updated_at and vote timestamp follow the current cast/flip time; comments do not acquire an invented timestamp field.
- Dirty flags, caches and restart replay remain consistent; do not change karma scoring or ledger ordering.

Consumers: [lib/board/board_dispatch.ml](../../../lib/board/board_dispatch.ml), [lib/board/board.ml](../../../lib/board/board.ml).

Scenarios: [test/test_board_vote_persistence.ml](../../../test/test_board_vote_persistence.ml), [test/test_board_dispatch.ml](../../../test/test_board_dispatch.ml), [test/test_board_karma_ledger.ml](../../../test/test_board_karma_ledger.ml). **Not executed in this audit.**

Ordering rationale: This isolates one closed domain decision without abstracting away legitimate Eio locks or forcing generic record lenses. Persistence-failure, flip, comment-vote and restart tests already provide meaningful consumer evidence.

### D6

**Represent Board snapshot flush work and retry obligations explicitly**

Source: [lib/board/board_votes.ml:789](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/board/board_votes.ml#L789-L920), [lib/board/board_votes.ml:966](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/board/board_votes.ml#L966-L1045).

Problem: delete_post and flush_dirty both snapshot several stores, clear dirty state under the state lock, persist outside it under the persistence lock, then re-mark affected stores on failure. They carry the work as positional tuples and independently encode which failed snapshot re-queues posts versus comments. Adding a snapshot kind or changing retry policy can produce a missing durable obligation even when the in-memory deletion succeeded.

Change: Use a private closed snapshot-kind batch and an explicit persistence result per kind. Extract the pure retry classification and batch selection while leaving snapshot capture/dirty clearing under store.mutex and all writes serialized by persist_mutex. Reuse the typed batch in deletion and ordinary flush; retain their distinct public result contracts.

Preserve:

- Keep persistence lock ordering: persist_mutex outside short state-lock sections.
- Never rewrite a partially loaded or unreadable snapshot.
- Concurrent edits after snapshot capture must remain dirty and must not be cleared by write completion.
- A failed posts/votes/reactions write re-queues the current post retry obligation; a failed comment write re-queues comments.
- Empty final snapshots still persist and retry, so deleted rows cannot resurrect after restart.
- Deletion_persistence_pending remains a post-effect result, not a pre-effect rejection.

Consumers: [lib/board/board_dispatch.ml](../../../lib/board/board_dispatch.ml), [lib/board/board_core_persist.ml](../../../lib/board/board_core_persist.ml).

Scenarios: [test/test_board_delete_rewrite_requeue.ml](../../../test/test_board_delete_rewrite_requeue.ml), [test/test_board_vote_persistence.ml](../../../test/test_board_vote_persistence.ml), [test/test_board_persistence_load_contract.ml](../../../test/test_board_persistence_load_contract.ml). **Not executed in this audit.**

Ordering rationale: The important duplication is the durable retry protocol and dirty-state coupling, not the tuple syntax alone. Existing tests inject each snapshot failure, cancellation during flush, unreadable sources and competing edits.

### D7

**Separate evidence persistence codec, judge transport and metadata projection from acquisition**

Source: [lib/workspace/workspace_verification_store.ml:3](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/workspace/workspace_verification_store.ml#L3-L78), [lib/workspace/workspace_verification_store.ml:81](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/workspace/workspace_verification_store.ml#L81-L627), [lib/workspace/workspace_verification_store.ml:811](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/workspace/workspace_verification_store.ml#L811-L829).

Problem: One module owns evidence variants, persisted JSON, judge transport, metadata-only redaction, aggregate content selection, artifact reads and binary-body storage. The three JSON surfaces deliberately differ: stored text can include a truncated prefix, judge transport withholds unusable content, and metadata omits evidence bodies. Keeping these policies beside file acquisition increases the risk of accidentally routing a persistence serializer to a privacy-sensitive or context-limited consumer.

Change: Move canonical evidence data and pure codecs/projections into cohesive private modules with separate explicit functions for persistence, judge transport and metadata. Keep owned-file validation, body persistence and request loading in the effect shell. Preserve the existing public API through narrow aliases where needed, and keep each projection explicit instead of a generic serializer with boolean flags.

Preserve:

- Invalid references remain payload-free and must not echo rejected paths.
- Stored evidence preserves submission-time bytes/digests; metadata and judge projections do not substitute for the stored snapshot.
- Truncated/aggregate-withheld content remains visibly unavailable with the existing tools/read instructions.
- Binary body bytes stay outside JSON and retain existing digest/path validation.
- Preserve evidence order, byte ceilings and collaboration-source metadata; this extraction does not redesign resource limits.
- No filesystem or clock effects are introduced into codecs.

Consumers: [lib/verification_protocol.ml](../../../lib/verification_protocol.ml), [lib/completion_authority_agent.ml](../../../lib/completion_authority_agent.ml), [lib/verification_authority_tools.ml](../../../lib/verification_authority_tools.ml), [lib/goal_verification_agent.ml](../../../lib/goal_verification_agent.ml), [lib/dashboard/dashboard_verification.ml](../../../lib/dashboard/dashboard_verification.ml), [lib/tui_decode.ml](../../../lib/tui_decode.ml).

Scenarios: [test/test_verification.ml](../../../test/test_verification.ml), [test/test_verification_collaboration_evidence.ml](../../../test/test_verification_collaboration_evidence.ml), [test/test_verification_operator_evidence.ml](../../../test/test_verification_operator_evidence.ml). **Not executed in this audit.**

Ordering rationale: This is a concrete separation of persistence, authority transport and operator metadata trust boundaries. Existing test_transport_projection_omits_truncated_prefix, test_transport_projection_bounds_the_evidence_total and collaboration evidence tests cover the causal risks; no UI-layout tests are proposed.

### S1

**Extract the provider usage acceptance/revocation reducer from the shared observation store**

Source: [lib/runtime/runtime_provider_usage_window.ml:858](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/runtime/runtime_provider_usage_window.ml#L858-L1008).

Problem: record intertwines complete-versus-sparse report policy, per-source snapshot watermarks, per-window freshness, accepted-report filtering, nested mutable hash tables and the durable observer callback. The public values are immutable, but the authoritative transition remains an in-place algorithm inside the mutex, so policy cannot be reviewed independently of publication and callback behavior.

Change: Introduce a private immutable per-scope state with ordered maps keyed by (limit_id, window_kind) and source. A pure reduce ~observed_at report state returns the next state and the exact accepted report option. Keep the scope table/mutex, clock initialization, observer invocation, cancellation propagation and sink diagnostics in the effect boundary. Do not combine this first slice with provider wire decoder rewrites.

Preserve:

- Empty sparse reports change nothing and do not notify the sink.
- A complete report revokes only older omitted windows owned by that same source.
- Equal/older window timestamps cannot replace a held observation, and a source snapshot watermark prevents old omitted windows returning.
- An empty complete report remains a reported_no_windows observation with its source and timestamp.
- The observer receives only the accepted report and runs after the lock is released; observer failure does not roll back the live observation.
- state ordering remains limit_id then the existing kind comparator; recorded scopes include complete empty reports.

Consumers: [lib/runtime/runtime_provider_usage_read.ml](../../../lib/runtime/runtime_provider_usage_read.ml), [lib/keeper/keeper_claude_code_runtime.ml](../../../lib/keeper/keeper_claude_code_runtime.ml), [lib/keeper/keeper_codex_runtime.ml](../../../lib/keeper/keeper_codex_runtime.ml), [lib/server/server_dashboard_runtime_resolved_json.ml](../../../lib/server/server_dashboard_runtime_resolved_json.ml), [lib/server/server_provider_usage_history.ml](../../../lib/server/server_provider_usage_history.ml).

Scenarios: [test/test_provider_usage_snapshots.ml](../../../test/test_provider_usage_snapshots.ml), [test/test_provider_usage_windows.ml](../../../test/test_provider_usage_windows.ml), [test/test_provider_usage_history_snapshots.ml](../../../test/test_provider_usage_history_snapshots.ml). **Not executed in this audit.**

Ordering rationale: A bounded immutable functional-core extraction with existing account-lifecycle scenarios: removed cap, complete empty report, disabled bucket and sparse Codex update. The durable sink and source watermark rules make it substantive; replacing every process-wide table is unnecessary.

### S2

**Move lane edit decisions into a pure declared-configuration planner**

Source: [lib/runtime/runtime.ml:3267](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/runtime/runtime.ml#L3267-L3729), [lib/runtime/runtime_config_text.ml:408](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/runtime/runtime_config_text.ml#L408-L437).

Problem: The lock/read/parse/commit wrapper is already identifiable, but conversation-lane create/rename/remove and exact-lane append/drop/move/replace decisions still occupy runtime.ml alongside persistence. Declaration validation, reference rewriting and slot placement are nested in effectful entrypoints, increasing the context needed to verify a single edit.

Change: Extract private planning functions over the freshly loaded source text and Runtime_schema.config. Return edited text or a closed lane-edit error; retain public API wrappers, CAS source-revision checks, lock warnings, whole-file validation and durable commit in runtime.ml. Treat conversation-lane reference edits and exact-output slot edits as separate work units if needed.

Preserve:

- Read declarations under the writer lock; never reconstruct edit inputs from the filtered/admitted runtime catalog.
- Rename the lane table, keeper assignments, runtime default and Fusion seat references together in one validated write.
- Preserve rejected-but-declared slots, declaration order and slots written by another writer before lock acquisition.
- Keep HTTP/catalog slots separate from CLI slots, prevent duplicate membership, and refuse removing the final exact-lane slot.
- Preserve inline/dotted-table refusal semantics and every existing source-revision conflict/lock-warning distinction.
- Do not move parse or reads outside the write transaction merely to make the planner appear pure.

Consumers: [lib/server/server_routes_http_routes_dashboard.ml](../../../lib/server/server_routes_http_routes_dashboard.ml), [lib/runtime/runtime_config_text.ml](../../../lib/runtime/runtime_config_text.ml), [lib/runtime/runtime.mli](../../../lib/runtime/runtime.mli).

Scenarios: [test/test_runtime_per_keeper_routing.ml](../../../test/test_runtime_per_keeper_routing.ml), [test/test_exact_output_catalog_precedence.ml](../../../test/test_exact_output_catalog_precedence.ml). **Not executed in this audit.**

Ordering rationale: The source explicitly documents previous lost-slot and partial-rename failures, and tests exercise real persisted TOML plus resolution. This refresh confirms the boundary remains at this baseline; existing edit_runtime_lanes should be retained as the effect shell.

### S3

**Separate Antigravity protocol transitions from persistence and stream callbacks**

Source: [lib/runtime/runtime_antigravity.ml:679](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/runtime/runtime_antigravity.ml#L679-L923), [lib/runtime/runtime_antigravity.ml:1000](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/runtime/runtime_antigravity.ml#L1000-L1060).

Problem: protocol_state combines optional init/result products, while apply_event validates protocol order, computes immutable next state, persists conversation readiness and emits stream events in one function. The mutable driver ref is an appropriate effect-boundary holder; the difficult part is that transition semantics and callbacks are inseparable.

Change: Extract a private protocol core with explicit awaiting/admitted/completed phases and a transition result describing next state, ordered stream events and any admission persistence requirement. The runtime shell executes the readiness callback first and publishes/emits only after it succeeds. Keep process spawning, timeout/read-phase execution, stderr redaction and exceptions in runtime_antigravity.ml.

Preserve:

- Readiness persistence succeeds before Turn_started is emitted or admitted state is published.
- Duplicate init/result and post-result steps remain errors; a pre-init provider error retains its provider refusal.
- Reserved cancellation, operator interruption and timeout exceptions retain their current treatment.
- Identical closed-step replays emit nothing; conflicting late content remains a protocol failure.
- Text deltas and Text_completed ordering stay exact; terminal repeated response does not duplicate already streamed content.
- Failed turns still report usage, and active tool steps retain the existing read-phase distinction.

Consumers: [lib/keeper/keeper_antigravity_runtime.ml](../../../lib/keeper/keeper_antigravity_runtime.ml), [lib/fusion/fusion_official_client.ml](../../../lib/fusion/fusion_official_client.ml), [lib/runtime/runtime_verification_antigravity.ml](../../../lib/runtime/runtime_verification_antigravity.ml).

Scenarios: [test/test_runtime_antigravity.ml](../../../test/test_runtime_antigravity.ml), [test/test_keeper_antigravity_runtime.ml](../../../test/test_keeper_antigravity_runtime.ml). **Not executed in this audit.**

Ordering rationale: Existing fixture scenarios verify callback ordering, failed callbacks, step identity and streaming continuity. This is a real type/effect boundary improvement, but callback sequencing makes it riskier than S1/S2 and unsuitable for a mechanical split.

### S4

**Make provider-metrics cache refresh ownership explicit and cancellation-complete**

Source: [lib/server/server_routes_http_routes_provider_runs.ml:7](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/server/server_routes_http_routes_provider_runs.ml#L7-L31), [lib/server/server_routes_http_routes_provider_runs.ml:94](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/server/server_routes_http_routes_provider_runs.ml#L94-L188).

Problem: A cache entry independently mutates value, updated_at, in_flight and last_error. The refresh path re-raises Eio.Cancel.Cancelled before reaching the in_flight reset, while acquisition sets in_flight before starting or forking the worker. Whether cancellation or fork failure leaves a reusable entry permanently marked refreshing needs a concrete scenario; no live failure is claimed.

Change: First reproduce cancellation/fork-failure ownership cleanup through the existing cached_json test surface. Then use a closed idle/refreshing state with an exact worker token and immutable last-good payload/error metadata; centralize acquire/completion/cancellation transitions and keep the mutex, table eviction, executor pool and HTTP serialization at the edge. A stale worker must not clear a replacement owner's refresh.

Preserve:

- Fresh reads do not recompute; stale reads return last-good data while one refresh owns the key.
- Refresh failure preserves payload and its original freshness timestamp.
- Cancellation propagates after releasing only the worker's own ownership.
- sync_first on cold entries keeps its current behavior.
- Configured resource-bounded eviction stays intact; a completed evicted worker cannot resurrect an old cache entry.
- Provider history errors remain redacted at the public response boundary.

Consumers: [lib/server/server_routes_http_routes_provider_runs.ml](../../../lib/server/server_routes_http_routes_provider_runs.ml).

Scenarios: [test/test_model_inference_metrics.ml](../../../test/test_model_inference_metrics.ml). **Not executed in this audit.**

Ordering rationale: test_metrics_cache_retains_last_good already exercises failure/recovery through this exact cache, but does not establish cancellation cleanup. This file is outside active PR 43355's HTTP/TUI transport files; do not use unrelated dashboard cache tests as proof for this implementation.

### S5

**Consolidate full-health refresh bookkeeping into an immutable owned state machine**

Source: [lib/server/server_routes_http_runtime.ml:693](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/server/server_routes_http_runtime.ml#L693-L734), [lib/server/server_routes_http_runtime.ml:974](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/server/server_routes_http_runtime.ml#L974-L1180), [lib/server/server_routes_http_runtime.ml:1310](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/server/server_routes_http_runtime.ml#L1310-L1337).

Problem: The full-health refresher's snapshot, in-flight flag, started time, request flag, invalidation generation, active worker, counters and per-worker failure flag live in separate refs/fields. A mutex serializes access, but readers must assemble an eight-element tuple and each transition manually maintains correlated state.

Change: Introduce a private immutable refresh state and typed Idle/Running ownership with worker identity/generation. Pure transitions take observed time, completion/failure/invalidation events and return state plus explicit wake/metric decisions. Keep Eio promises, stream signaling, fiber creation, locks, logs and metrics execution in the shell.

Preserve:

- One active worker is shared by waiters and survives cancellation of an individual waiter.
- A result computed before an invalidation cannot be published as current; schedule the existing follow-up.
- Last-good payload time and first failure time remain distinct across repeated failures.
- An active worker's timeout is reported once without pretending the worker stopped.
- No lost wake on invalidation and no unbounded invalidation queue.
- Existing monitoring thresholds, timeout policies and serialized public fields remain unchanged in the refactor.

Consumers: [lib/server/server_routes_http_runtime.ml](../../../lib/server/server_routes_http_runtime.ml), [lib/server/server_dashboard_http_execution_surfaces.ml](../../../lib/server/server_dashboard_http_execution_surfaces.ml).

Scenarios: [test/test_server_runtime_bootstrap.ml](../../../test/test_server_runtime_bootstrap.ml). **Not executed in this audit.**

Ordering rationale: The existing tests include worker survival after waiter cancellation, dirty-generation rejection and last-snapshot preservation. Mutation is necessary for publication and resource ownership; the target is correlated state spread, not removal of synchronization.

### S6

**Give connector status a common typed projection before JSON aggregation**

Source: [lib/gate/channel_gate_connector.ml:10](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/gate/channel_gate_connector.ml#L10-L47), [lib/gate/channel_gate_connector.ml:70](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/gate/channel_gate_connector.ml#L70-L94), [lib/gate/channel_gate_slack_state.ml:153](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/gate/channel_gate_slack_state.ml#L153-L278), [lib/tui_decode_connectors.ml:50](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/tui_decode_connectors.ml#L50-L95), [lib/tui_decode_connectors.ml:135](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/tui_decode_connectors.ml#L135-L159).

Problem: The connector module interface returns arbitrary JSON snapshots. connectors_json immediately reads available back out with a false default to count active connectors. Transport implementations already hold typed status internally, but the TUI stores available, connected, raw status and a separately decoded connection variant, repeating a consistency relationship across boundaries.

Change: Define a small common typed descriptor/status projection at the connector boundary and serialize it once for HTTP. Preserve transport-specific details through explicit typed variants or a clearly separate extension payload. Compute active_count from typed availability; have the TUI decoder construct the common connection state once and derive redundant flags/text where consumers permit.

Preserve:

- Transport connected and connector available are independent: connected-but-unavailable remains representable.
- Stale/disconnected/offline meanings and existing wire field names remain unchanged.
- Binding-store failure remains visible and must not appear as an empty successful binding list.
- One malformed connector row is refused with its identity/position while valid rows remain available.
- Preserve the existing absent-flag decode contract during extraction; any strictness change is a separate behavior decision.
- Keep names and durable paths behind the existing authenticated directory boundary.

Consumers: [lib/server/server_routes_http_routes_channel_gate.ml](../../../lib/server/server_routes_http_routes_channel_gate.ml), [lib/tui_decode_connectors.ml](../../../lib/tui_decode_connectors.ml), [bin/masc_tui_loader.ml](../../../bin/masc_tui_loader.ml), [bin/masc_tui_connector_unbind.ml](../../../bin/masc_tui_connector_unbind.ml).

Scenarios: [test/test_channel_gate_connector_routes.ml](../../../test/test_channel_gate_connector_routes.ml), [test/test_tui_decode.ml](../../../test/test_tui_decode.ml), [test/test_tui_connector_unbind.ml](../../../test/test_tui_connector_unbind.ml). **Not executed in this audit.**

Ordering rationale: This follows a concrete typed-data-to-JSON-to-data round trip and duplicated state proof obligation. Start with common availability/connection/binding-read fields rather than inventing a universal connector framework; test requests/decoded decisions, not TUI labels or layouts.

### S7

**Replace connector ingress scheduling flag combinations with explicit lane lifecycle**

Source: [lib/gate/connector_ingress_lane.ml:21](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/gate/connector_ingress_lane.ml#L21-L40), [lib/gate/connector_ingress_lane.ml:91](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/gate/connector_ingress_lane.ml#L91-L161), [lib/gate/connector_ingress_lane.ml:181](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/gate/connector_ingress_lane.ml#L181-L213).

Problem: Each lane stores independent mutable scheduled and active booleans alongside its mutable FIFO. submit, take_ready_lane, take_lane_job and close must preserve the relationship between queue membership and these flags, including combinations the type permits but scheduling does not use.

Change: Replace the flag product with a closed Scheduled/Running lane state (and only an explicit idle state if genuinely required). Factor locked acceptance/dispatch/completion/close decisions so they return explicit notification/start/failure work; keep Queue, Eio condition/fibers, callback execution and the mutex as owned effectful resources. Do not replace a working FIFO merely to eliminate every mutable data structure.

Preserve:

- FIFO is preserved per Keeper lane, while independent lanes may progress concurrently.
- Exactly one worker owns a lane; submitting to an active or already scheduled lane does not schedule another.
- Every accepted event is executed or reported once through on_failure before owner release.
- Owner_unavailable means no callback was enqueued.
- Callback cancellation is reported under cancellation protection and then re-raised.
- Slack/Discord durable acceptance still precedes delivery handoff.

Consumers: [lib/server/server_slack_in_process_gateway.ml](../../../lib/server/server_slack_in_process_gateway.ml), [lib/server/server_discord_in_process_gateway.ml](../../../lib/server/server_discord_in_process_gateway.ml).

Scenarios: [test/test_server_slack_trigger_policy.ml](../../../test/test_server_slack_trigger_policy.ml), [test/test_server_discord_trigger_policy.ml](../../../test/test_server_discord_trigger_policy.ml). **Not executed in this audit.**

Ordering rationale: A narrow closed-state refactor removes invalid combinations without challenging legitimate mutable queue ownership. Existing connector-path tests verify durable accept and exact event identity; add FIFO/owner-release scenarios only where direct behavioral coverage is absent.

### S8

**Separate durable provider-history decoding and daily projection from journal IO**

Source: [lib/server/server_provider_usage_history.ml:68](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/server/server_provider_usage_history.ml#L68-L154), [lib/server/server_provider_usage_history.ml:168](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/server/server_provider_usage_history.ml#L168-L291).

Problem: read nests record decoding, timestamp/window filtering, per-source replacement, daily winner selection, empty-day projection, malformed-row accounting and logging inside one IO callback flow. Four local hash tables and an unreadable counter implement a pure reduction but obscure the distinct source/day and display/day keys.

Change: Create a private history codec and immutable projection state using explicit source-day/window keys. Fold typed records into the state and return final points, empty reports and diagnostics; keep Dated_jsonl traversal, observer-failure checks and logging in the server reader. Preserve the order of source replacement before daily winner selection. Keep this separate from the live table reducer, whose retention semantics are different.

Preserve:

- A complete snapshot removes older omitted windows only from its source and UTC day; prior days remain history.
- Sparse events retain unstated windows.
- Filter revoked source rows before selecting the latest surviving daily point across sources.
- Out-of-order journal appends cannot revive superseded windows.
- Successful empty reports are not numeric zero and cannot mark a day empty when another source still has a window.
- Keep current timestamp/source tie-breaking and final point ordering.
- Malformed records are logged/countable while readable records survive; whole-store failure or a sink failure in the requested window remains an error.
- Do not silently delete or reinterpret current persisted-format compatibility during a structural extraction; any retirement requires a separately reviewed scope.

Consumers: [lib/server/server_routes_http_routes_provider_runs.ml](../../../lib/server/server_routes_http_routes_provider_runs.ml), [lib/tui_decode_usage.ml](../../../lib/tui_decode_usage.ml).

Scenarios: [test/test_provider_usage_history_snapshots.ml](../../../test/test_provider_usage_history_snapshots.ml), [test/test_model_inference_metrics.ml](../../../test/test_model_inference_metrics.ml). **Not executed in this audit.**

Ordering rationale: Existing tests read the real journal and pass the result through Tui_decode_usage, covering source overlap, empty-day recovery and delayed writes. This is an independently reviewable pure-core extraction with meaningful user-visible history invariants.

### R1

**Credential batch ownership projection**

Source: [lib/auth/auth.ml:106](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/auth/auth.ml#L106-L164).

Problem: Batch credential repair keeps mutable token and name indexes alongside a separately threaded ownership list. Success updates three representations; failure rereads authority then clears and reconstructs two tables. The admission-time shared-token set has different semantics from the refreshed ownership snapshot.

Change: Model admitted shared-token evidence and current ownership as distinct immutable values; return an updated token/name projection from one pure operation, while retaining transaction, reread and credential minting effects at the edge.

Preserve:

- Admission-time shared bearers remain rejected after earlier repairs.
- Every failed write rereads authoritative storage before continuing.
- Identity redirects, token hashing and ownership conflicts remain unchanged.
- Never emit credential/token values in diagnostics or evidence.

Consumers: [lib/server/server_runtime_startup_credentials.ml](../../../lib/server/server_runtime_startup_credentials.ml).

Scenarios: [test/test_auth_token_rotation_transaction.ml](../../../test/test_auth_token_rotation_transaction.ml), [test/test_auth_file_backed_transaction.ml](../../../test/test_auth_file_backed_transaction.ml). **Not executed in this audit.**

Ordering rationale: Clear duplicated-state obligation with existing batch-failure scenarios; security-sensitive transaction behavior needs an isolated source review and focused execution before release.

### R2

**Fusion decision event ownership**

Source: [lib/fusion/fusion_decision.ml:58](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/fusion/fusion_decision.ml#L58-L186).

Problem: validate_event returns raw JSON after validating the decision; read, idempotency and consumer paths inspect the same field names again. Domain authority and serialization remain coupled to generic JSON field access.

Change: Introduce a private typed decision event with a strict codec; derive identity/idempotency checks from typed fields and encode only at event-journal/dashboard boundaries. Keep journal traversal, task/goal authority, locks and append effects in the store.

Preserve:

- A decision must refer to the exact requesting Task and owned Fusion evidence.
- Conflicting same-turn writes remain rejected; identical writes remain idempotent.
- Malformed authoritative history prevents a guessed mutation.
- Source visibility and the existing public JSON contract remain unchanged.

Consumers: [lib/verification_collaboration_evidence.ml](../../../lib/verification_collaboration_evidence.ml), [lib/keeper/keeper_tool_runtime.ml](../../../lib/keeper/keeper_tool_runtime.ml), [lib/server/server_routes_http_routes_dashboard.ml](../../../lib/server/server_routes_http_routes_dashboard.ml).

Scenarios: [test/test_fusion_decision.ml](../../../test/test_fusion_decision.ml), [test/test_verification_collaboration_evidence.ml](../../../test/test_verification_collaboration_evidence.ml). **Not executed in this audit.**

Ordering rationale: Repeated JSON reinspection crosses an authority boundary; a typed event would concentrate contract maintenance without changing its security policy.

### A1

**Separate stream error projection from optional refused-frame diagnostic I/O**

Source: [packages/agent_core/lib/llm_provider/complete_stream_error.ml:8](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/packages/agent_core/lib/llm_provider/complete_stream_error.ml#L8-L70), [packages/agent_core/lib/llm_provider/complete_stream_error.ml:221](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/packages/agent_core/lib/llm_provider/complete_stream_error.ml#L221-L356), [packages/agent_core/lib/llm_provider/complete_stream_error.mli:31](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/packages/agent_core/lib/llm_provider/complete_stream_error.mli#L31-L40), [packages/agent_core/lib/llm_provider/complete_stream.ml:1145](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/packages/agent_core/lib/llm_provider/complete_stream.ml#L1145-L1191).

Problem: http_error_of_stream_error appears as a typed conversion in its signature, but the two malformed-frame arms call dump_refused_frame, which reads MASC_WIRE_PARSE_DUMP and opens/appends/closes a file. Reviewing or reusing error policy therefore also requires knowing process environment and diagnostic ownership. Inline projection assertions can reach this effect when the variable is set. This is a maintainability/effect-boundary candidate, not evidence of an observed runtime bug or a security defect.

Change: Make the error projection return its typed HTTP failure together with an optional narrowly typed refused-frame diagnostic description. Keep redaction/formatting shared, and execute the optional dump explicitly at the existing stream finalization effect edge exactly once. Keep the diagnostic carrier private where possible. Update the direct diagnostic test to exercise the explicit sink boundary. Do not add another environment knob, provider-specific retry policy or generic effect abstraction.

Preserve:

- Keep every current HTTP error constructor, wire format, diagnostic message and provider-status distinction: only declared 429/5xx provider conditions become HttpError; unstated errored choices remain Provider_interrupted.
- Keep MASC_WIRE_PARSE_DUMP optional and disabled for absent/empty values; preserve full-frame diagnostic payload rather than truncating it to the log excerpt.
- Redact before writing the full dump and before bounding the 256-byte message excerpt; retain original byte count and verbatim=true/false so offset evidence stays honest.
- Preserve 0600 creation mode, append behavior, escaped row layout and Sys_error noninterference. Preserve the existing exception policy rather than widening swallowed failures.
- The production finalization path emits a missing failure event before projection/dump and publishes its terminal summary afterwards; retain this order and do not duplicate the diagnostic write.
- Do not import coordinator configuration into Agent Core; its diagnostic sink currently reads the environment locally to preserve dependency direction.

Consumers: [packages/agent_core/lib/llm_provider/complete_stream.ml](../../../packages/agent_core/lib/llm_provider/complete_stream.ml), [packages/agent_core/test/test_wire_parse_dump.ml](../../../packages/agent_core/test/test_wire_parse_dump.ml).

Scenarios: [packages/agent_core/test/test_wire_parse_dump.ml](../../../packages/agent_core/test/test_wire_parse_dump.ml), [packages/agent_core/lib/llm_provider/complete_stream_error.ml](../../../packages/agent_core/lib/llm_provider/complete_stream_error.ml). **Not executed in this audit.**

Proposed verification: Through the public streaming path, feed one malformed SSE frame and one malformed NDJSON frame; assert one diagnostic row, unchanged returned typed error and one terminal summary. Exercise an unwritable dump destination to preserve the original error. These are proposed scenarios, not executed evidence.

Ordering rationale: One production caller and an existing diagnostic scenario bound the change. The new boundary makes error policy review independent of file effects while preserving operator evidence; priority is based on the hidden effect, not file length.

Public-package risk: The diagnostic helper is currently exposed through a callable conversion; enumerate external package consumers before changing a public signature.

## Boundaries retained or excluded

These are reasons not to perform a blanket rewrite, not whole-module correctness claims.

- [lib/keeper/keeper_memory_os_current.ml](../../../lib/keeper/keeper_memory_os_current.ml): In-review coverage, not a new candidate: campaign scope identifies open PRs #43347 (snapshot codec), #43348 (journal codec), and #43353 (immutable successor recall). These exact responsibilities were independently reviewed earlier in this session. The campaign baseline still contains their original implementation; refresh integration state before editing nearby code. K7 concerns only the residual receipt reconciliation boundary.
- [lib/keeper/keeper_tool_plan_executor.ml](../../../lib/keeper/keeper_tool_plan_executor.ml): The read/write execution gate at lines 238-301 legitimately owns mutable readers/writer/waiting_writers counters under an Eio mutex and condition. Cancellation rolls back waiting_writers. Removing mutation for style would obscure resource ownership and fairness; extract no generic gate merely because mutable fields exist.
- [lib/keeper/keeper_heartbeat_loop.ml](../../../lib/keeper/keeper_heartbeat_loop.ml): Deferred_lane_slot at lines 207-367 already has a closed Idle/Held/Dispatched state and owns the process-local mirror of a durable runtime suffix. Its callback-owned ref and ordered save/clear effects are intentional. A separate pure scheduling decision module already exists; do not count the large outer loop as proof of an absent functional boundary.
- [lib/keeper/keeper_heartbeat_loop_scheduling.ml](../../../lib/keeper/keeper_heartbeat_loop_scheduling.ml): Already contains an explicit pure keepalive scheduling decision. Reuse the existing boundary before proposing a competing scheduler abstraction.
- [lib/keeper/keeper_tool_descriptor.ml](../../../lib/keeper/keeper_tool_descriptor.ml): Large descriptor and schema inventory with explicit execution/policy variants and a central constructor. File size alone does not justify scattering the capability declaration source of truth; a separate correctness or consumer-dependency problem is needed.
- [packages/agent_core/lib/execution_event_store.ml](../../../packages/agent_core/lib/execution_event_store.ml): The mutable lifecycle, health, committed snapshot and resource hooks at lines 575-640 represent a live resource owner with locks and fencing. Atomic writer-path claims and byte buffers for binary encoding are justified mutation. K6 targets scan data flow only, not wholesale immutability of live storage.
- [lib/keeper/keeper_agent_run.ml](../../../lib/keeper/keeper_agent_run.ml): The request digest memo at lines 1485-1492 is documented as turn-fiber-owned, with workers receiving private snapshots; the shared agent cell is deliberately captured by tools loaded mid-turn. These are ownership boundaries, not automatically refactoring defects. K4 preserves them and distinguishes attempt-local from turn-local evidence.
- [lib/workspace/workspace_backlog.ml](../../../lib/workspace/workspace_backlog.ml): The commit result explicitly preserves committed revision and primary/recovery/post-commit degradation. Its lease fence, protected settlement, cache invalidation and recovery-copy ordering are durability mechanisms, not mutations to remove for style. Preserve them when changing callers.
- [lib/workspace/workspace_task_lifecycle.ml](../../../lib/workspace/workspace_task_lifecycle.ml): The task state/action match already makes ownership, cancellation reasons, verification submission and timestamp preservation explicit. Do not replace exhaustive variants with strings or a generic transition table merely to shorten the file.
- [lib/workspace/workspace_task_transition_executor.ml](../../../lib/workspace/workspace_task_transition_executor.ml): Already a narrow immutable backlog transformation. Entry actions preserve the previous handoff, exit actions author one; the distinction is intentional and must remain visible.
- [lib/task/task_goal_assignment.ml](../../../lib/task/task_goal_assignment.ml): This task-domain integration boundary intentionally acquires Goal/backlog authority and owns typed cross-store failures. Moving it into the Goal leaf domain would reverse the documented dependency direction.
- [lib/goal/goal_phase.mli](../../../lib/goal/goal_phase.mli): Paused/Blocked carry the resumable phase as a closed sum, and public actions exclude verifier authority actions. This is useful type-level contract, not redundant boilerplate.
- [lib/fs_compat/fd_cache.ml](../../../lib/fs_compat/fd_cache.ml): active counts, close_on_release, LRU timestamps and the mutex represent live descriptor ownership. Replacing these with an immutable map alone would not replace resource lifetime synchronization.
- [lib/fs_compat/atomic_write.ml](../../../lib/fs_compat/atomic_write.ml): Explicit publication stages, cleanup failure collection and cancellation/backtrace preservation are real I/O protocol state. The inspected run_stage/capture_cleanup boundaries intentionally distinguish recoverable failure from cancellation/fatal exceptions; no blanket catch-all rewrite is justified.
- [lib/fs_compat/atomic_replace.mli](../../../lib/fs_compat/atomic_replace.mli): Before_rename/After_rename is already a typed publication outcome and the strict versus rename-only APIs state distinct durability contracts. Keep this distinction instead of unifying all writers behind unit/string results.
- [lib/dated_jsonl/dated_jsonl_store.ml](../../../lib/dated_jsonl/dated_jsonl_store.ml): Closed store/retention variants and typed root/location constructors are a useful shared registry. Filesystem enumeration belongs at this edge; fixed retention values are explicit product/resource contracts, not evidence for arbitrary immutable refactoring.
- [bin/masc_tui_runtime_config_edit.ml](../../../bin/masc_tui_runtime_config_edit.ml): Already a small immutable private edit session with explicit observe/adopt/replace actions. Source path/revision are preserved and tests cover draft retention after conflicts. No substantive rewrite justified.
- [bin/masc_tui_runtime_account_form.ml](../../../bin/masc_tui_runtime_account_form.ml): Already uses a nonempty zipper-like ring and closed Filling/Saved phases. UI rendering is colocated, but no audited behavior/invariant problem justifies a size-only split or new visual tests.
- [bin/masc_tui_lane_application.ml](../../../bin/masc_tui_lane_application.ml): Application tracking is typed and immutable. The unit ref inside ticket is an intentional unforgeable physical identity, never mutated; replacing it merely because rg reports ref would not improve ownership.
- [bin/masc_tui_lane_subscriptions.ml](../../../bin/masc_tui_lane_subscriptions.ml): Already has typed requests and phases, immutable edits and revision-bound saves with current keeper/output revalidation. No substantive defect established by this representative audit.
- [lib/gate/channel_gate_connector.ml:registry](../../../lib/gate/channel_gate_connector.ml): Startup registration and lookup are short, mutex-protected operations over an owned table. Registry mutability itself is not a refactor target; S6 concerns the descriptor contract, not synchronization removal.
- [bin/masc_tui.ml](../../../bin/masc_tui.ml), [bin/masc_tui_http.ml](../../../bin/masc_tui_http.ml), `bin/masc_tui_io_domain.ml`, [bin/masc_tui_board_upload.ml](../../../bin/masc_tui_board_upload.ml): Excluded at the initial inventory because PR #43355 then owned HTTP/TUI transport changes. The follow-up REST read confirms it merged on 2026-10-16 at 13:11:50 UTC (reported PR head c736c2325a85231741f41a5f63b82cb6e353b34f). This removes the active-PR exclusion; the merged implementation still needs a fresh semantic audit. Its changed-file list was read, but implementation behavior was not audited here.
- [lib/keeper/keeper_autonomous_turn_source.ml](../../../lib/keeper/keeper_autonomous_turn_source.ml), [lib/keeper/keeper_checkpoint_store.ml](../../../lib/keeper/keeper_checkpoint_store.ml), [lib/keeper/keeper_event_bridge_error_json.ml](../../../lib/keeper/keeper_event_bridge_error_json.ml), [packages/agent_core/lib/base/error.ml](../../../packages/agent_core/lib/base/error.ml), [packages/agent_core/lib/structured.ml](../../../packages/agent_core/lib/structured.ml): Excluded because active PR 43352 owns structured-evidence changes. Exact changed-file list was read from GitHub; no overlap proposed.
- [lib/schedule/schedule_domain.mli](../../../lib/schedule/schedule_domain.mli): Already has a pure typed domain, closed status/recurrence alternatives and explicit time interpretation; no specific defect established by this inspection.
- [lib/backend/backend.ml](../../../lib/backend/backend.ml): Key-index tables and lock-duration refs belong to a concrete concurrent IO owner. Mutation alone is not a reason to replace them; observer-after-unlock and exception cleanup are real lifecycle requirements.

- [packages/agent_core/lib/llm_provider/provider_admission.ml](../../../packages/agent_core/lib/llm_provider/provider_admission.ml): Retain the existing functional transition module and effect owner. Registry state is immutable; a short Stdlib.Mutex section publishes it together with scheduler reconfiguration, while waiting/diagnostics remain outside. Atomically installed observer removal uses installation identity so an old remover cannot erase a replacement. Replacing these owner-local cells solely to eliminate mutation would obscure publication ordering.
- [packages/agent_core/lib/agent/agent_execution_runner.ml](../../../packages/agent_core/lib/agent/agent_execution_runner.ml): Retain this effect owner rather than turning the captured terminal disposition into an unnecessary global/pure state layer. The per-run ref captures at most one disposition until the writer exits; the actual sink is delivered after that boundary under cancellation protection. Caller switch lifetime remains distinct from the protected writer lifetime, and original reserved exceptions/backtraces survive cleanup failures. Fresh/resume branches differ in readiness and resume authority, so their visual duplication alone is insufficient justification to merge them.
- [packages/agent_core/lib/agent/agent_lifecycle.ml](../../../packages/agent_core/lib/agent/agent_lifecycle.ml): Retain the pure lifecycle transition/snapshot helper and separate event publication wrapper. Transition errors are closed variants; build_snapshot takes prior snapshot and explicit observations. The wrapper owns clock, fresh IDs, event publication and exception rethrow. This is an existing functional/effect separation, not an unreviewed blanket endorsement of all lifecycle behavior.

## Coverage still open

[Consulted sources](consulted-sources.json) records 123 files used for named boundaries, callers and scenarios. Agent Core follow-up entries additionally record whether the read covered the whole source or selected spans; symbol-search-only paths are not counted. This is selective semantic inspection of the complete file census.

- TUI orchestration, rendering and broad payload decoding remain a large semantic-review area. HTTP-domain PR #43355 has merged; refresh the integrated source before reviewing that boundary.
- Agent Core coverage now includes committed WAL scanning and selected provider-admission, stream-error, runner and lifecycle boundaries. The full stream assembler, backend codecs, scheduler internals, exact-output admission, standard/advanced run-loop differences and lifecycle consumer integrations remain open.
- Remaining production directories have not been cleared by representative samples. Browser, sandbox, multimedia, process and observation paths need their own consumer/invariant analysis.
- TypeScript/sidecar consumers are included only when tracing an OCaml contract. A full frontend or third-party-code audit is not implied.
- Lexer/parser inputs (`lib/exec/parser/bash_lexer.mll`, `lib/exec/parser/bash_subset.mly`) are outside the `.ml`/`.mli` census and remain an explicit follow-up surface.
- Test/tooling refactoring follows production contract understanding; no broad test rewrite or new style/count gate is planned.

## Round log

- Previous work: Memory OS codecs/successor core published as three Draft PRs; current open heads were refreshed before this round. That is source progress, not merged/runtime completion.
- Round 1: all tracked `.ml`/`.mli` files classified at the pinned baseline; clean-checkout counts independently matched the committed-blob reader; 24 source-backed candidates recorded with boundaries, invariants, callers and suites. S1 implemented with a private immutable observation core, retained lock/observer effects and two additional public-store scenarios; published as [#43367](https://github.com/jeong-sik/masc/pull/43367). OCaml syntax checks passed; behavior suites remain unexecuted.
- Round 2: K1 implemented as a private failure-evidence classifier in [#43370](https://github.com/jeong-sik/masc/pull/43370). Historical range sizing, named input refusal, invalid-output veto, size-independent failure and current CLI capacity remain separate facts. Syntax parsing passed; existing callback/admission scenarios were extended but not executed.
- Round 3: D2 implemented in [#43374](https://github.com/jeong-sik/masc/pull/43374). Focused source review corrected the initial no-op proposal: every accepted existing upsert commits even when fields are unchanged. Rejection and commit results are explicit; current RFC implementation references were updated. Syntax parsing passed and two public-store scenarios were added but not executed.
- Round 4: expanded Agent Core inspection across 17 explicitly scoped source/test reads in [#43377](https://github.com/jeong-sik/masc/pull/43377). Added A1 for the hidden diagnostic file effect in stream-error conversion and retained three existing ownership boundaries. This expands the queue to 25 candidates; it does not complete Agent Core coverage.
- No local Dune build, CI polling, behavior execution, formal GitHub approval, merge or runtime proof is supplied by this inventory.
