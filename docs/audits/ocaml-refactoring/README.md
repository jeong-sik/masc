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
`python3 docs/audits/ocaml-refactoring/inventory.py aea8424926ea79f110315eec5ab429ac51043598`.
Production
also has 2,427 interfaces; tests, tooling and documentation/experiment files are
counted separately. These measurements are reading aids, not quality scores,
file-size targets or CI gates. Missing `.mli` alone is not a defect.

The earlier `lib/` + `bin/` inventory did not include the 233 Agent Core
implementations. This inventory includes them. The file census is complete for
its stated baseline and production scope; semantic review is selective and
continues. Consulted files below do not imply complete audits of those files.

The [earlier Godfile audit](../godfiles-20261008/README.md) remains historical
evidence. Its counts and open/closed claims must not be carried forward as live
state. At the initial inventory observation, Memory OS PRs #43347, #43348
and #43353 were open Draft members of stack #43349 with source review only.
Round8's separate REST/ancestry observation confirms all three merged on
2026-10-16 (UTC): [#43347](https://github.com/jeong-sik/masc/pull/43347) at
[11c2f3c0](https://github.com/jeong-sik/masc/commit/11c2f3c08d7e20fd9338197188b8a39cab3368b0),
[#43348](https://github.com/jeong-sik/masc/pull/43348) at
[8ff0aa5d](https://github.com/jeong-sik/masc/commit/8ff0aa5d695df60d72132a06863f3bd6c4e2f547),
[#43353](https://github.com/jeong-sik/masc/pull/43353) at
[c5337092](https://github.com/jeong-sik/masc/commit/c5337092c70bc5cf6a615f481684810db40a7116).
Root verified their merge commits are ancestors of
observed main `776383528786929d01f8103e27823041c3cee755`. This integration metadata does
not claim that the
historical campaign checkout `c12ccd6d4348c31e62b1d1cfdda313b318094c53`
already contains the new Memory OS source, or supply new semantic/runtime evidence.

## Reference basis

- [OCaml Programming Guidelines](https://ocaml.org/docs/guidelines): coherent
  modules, explicit interfaces, readable small functions and exhaustive matching.
- [OCaml Error Handling](https://ocaml.org/docs/error-handling): represent
  expected failure explicitly and retain distinctions callers need.
- [OCaml 5.5 module examples](https://ocaml.org/manual/5.5/moduleexamples.html):
  use signatures to control exported representations and `include` to reuse a
  coherent module's components while preserving type equality internally.
- [Jane Street Effective ML](https://blog.janestreet.com/effective-ml/): optimize
  for readers, make states precise, avoid elaborate type tricks, and keep
  mutation where it serves the problem.
- [Real World OCaml: Modules](https://dev.realworldocaml.org/files-modules-and-programs.html)
  and [Maps and Hash Tables](https://dev.realworldocaml.org/maps-and-hashtables.html):
  hide representation behind signatures; use immutable maps when retained
  values and explicit transformations simplify reasoning.
- [Real World OCaml: Imperative Programming](https://dev.realworldocaml.org/imperative-programming.html):
  keep external effects explicit while using local mutation where it serves an
  algorithm. Applied to D3, we retain the decoder's fresh, non-escaping
  duplicate-ID table.

- [OCaml lexer entrypoints](https://ocaml.org/manual/5.5/lexyacc.html): explicit
  arguments can carry invocation state before the final lexbuf argument, while
  preserving longest-match and source-order tie behavior. The grammar here uses Menhir;
  ocamlyacc-specific concurrency claims are not applied to it.

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

The queue now contains **30 concrete candidates**: 24 from the first semantic pass, A1
from the Agent Core follow-up, T1 from the integrated TUI investigation, E1/E2 from
Exec, M1 from multimodal/media, and J1 from the Schedule investigation. Fifteen are
implemented as PRs; their source-review evidence is recorded on each PR: `S1` in
[#43367](https://github.com/jeong-sik/masc/pull/43367) isolates provider usage
acceptance; `K1` in [#43370](https://github.com/jeong-sik/masc/pull/43370) preserves
separate Librarian failure-policy axes; `D2` in
[#43374](https://github.com/jeong-sik/masc/pull/43374) returns an explicit Goal commit
result; `A1` in [#43386](https://github.com/jeong-sik/masc/pull/43386) separates stream
error projection from diagnostic file I/O; `D1` in
[#43399](https://github.com/jeong-sik/masc/pull/43399) returns the committed Task
verification obligation together with its public result. `K2` in
[#43411](https://github.com/jeong-sik/masc/pull/43411) isolates canonical child export
selection. `S2` in [#43469](https://github.com/jeong-sik/masc/pull/43469) isolates
declared lane edit planning while retaining its locked commit shell. `K3` in
[#43479](https://github.com/jeong-sik/masc/pull/43479) makes contention ticket ownership
an exclusive immutable phase. `S8` in
[#43489](https://github.com/jeong-sik/masc/pull/43489) separates durable history
decoding and immutable daily projection from journal effects. `J1` in
[#43510](https://github.com/jeong-sik/masc/pull/43510) puts note append under the
existing ledger lock and preserves typed storage failures at the tool boundary. `M1` in
[#43526](https://github.com/jeong-sik/masc/pull/43526) isolates immutable durable-media
state while retaining ordered diagnostics and persistence in the accumulator. `E2` in
[#43532](https://github.com/jeong-sik/masc/pull/43532) preserves the original timeout
budget and epoch through recursive dispatch after reproducing premature child refusal.
`E1` in [#43534](https://github.com/jeong-sik/masc/pull/43534) gives each public Bash
parse its own counter while preserving shared nested accounting. `D7` combines the
whole-envelope repair in [#43544](https://github.com/jeong-sik/masc/pull/43544) with
canonical snapshot codec/projection ownership in
[#43553](https://github.com/jeong-sik/masc/pull/43553). `D3` in
[#43556](https://github.com/jeong-sik/masc/pull/43556) gives Goal document data and
codecs one private owner while retaining source and transaction effects. Fifteen
candidates remain queued; this ordering does not waive their coverage.

| ID | Priority | Status | Refactoring point |
| --- | --- | --- | --- |
| [K1](#k1) | next | in review | Compute librarian failure evidence once with explicit independent policy axes |
| [K2](#k2) | next | in review | Give canonical child export selection a typed pure boundary |
| [K3](#k3) | next | in review | Represent Board contention rearm tickets with one explicit phase |
| [K4](#k4) | later | candidate | Make request-evidence reset and projection ownership explicit per attempt |
| [K5](#k5) | later | candidate | Separate approval restart replay decisions from recovery effects |
| [K6](#k6) | investigate | candidate | Make Agent Core committed-batch scanning an explicit returned state |
| [K7](#k7) | later | candidate | Separate Memory receipt reconciliation selection from its durable plan |
| [D1](#d1) | next | in review | Return an explicit task commit receipt instead of a cross-scope notification ref |
| [D2](#d2) | next | in review | Make Goal upsert a typed immutable transaction decision |
| [D3](#d3) | later | in review | Isolate the Goal document codec and schema rejection contract |
| [D4](#d4) | investigate | candidate | Audit and retain typed Goal publication outcomes across the backend adapter |
| [D5](#d5) | later | candidate | Extract the Board vote decision from post/comment mutation shells |
| [D6](#d6) | later | candidate | Represent Board snapshot flush work and retry obligations explicitly |
| [D7](#d7) | next | in review | Preserve evidence transport decisions in the complete review request, then isolate snapshot projections |
| [S1](#s1) | next | in review | Extract the provider usage acceptance/revocation reducer from the shared observation store |
| [S2](#s2) | next | in review | Move lane edit decisions into a pure declared-configuration planner |
| [S3](#s3) | later | candidate | Separate Antigravity protocol transitions from persistence and stream callbacks |
| [S4](#s4) | investigate | candidate | Make provider-metrics cache refresh ownership explicit and cancellation-complete |
| [S5](#s5) | later | candidate | Consolidate full-health refresh bookkeeping into an immutable owned state machine |
| [S6](#s6) | later | candidate | Give connector status a common typed projection before JSON aggregation |
| [S7](#s7) | later | candidate | Replace connector ingress scheduling flag combinations with explicit lane lifecycle |
| [S8](#s8) | next | in review | Separate durable provider-history decoding and daily projection from journal IO |
| [R1](#r1) | later | candidate | Credential batch ownership projection |
| [R2](#r2) | later | candidate | Fusion decision event ownership |
| [A1](#a1) | next | in review | Separate stream error projection from optional diagnostic file I/O |
| [T1](#t1) | investigate | candidate | Preserve dispatch and commit knowledge in Board post completion |
| [E1](#e1) | next | in review | Make token-budget state belong to one top-level parse while sharing it with nested substitutions |
| [E2](#e2) | next | in review | Keep one typed original timeout budget and epoch through recursive substitution dispatch |
| [M1](#m1) | later | in review | Separate durable stream-media transitions from diagnostic output and final media persistence |
| [J1](#j1) | next | in review | Give schedule-note append the ledger transaction and typed failure boundary |

## Candidate evidence

Source coordinates pin the revision inspected; the initial inventory uses its baseline
and later candidates name their inspection revision. Consumer/test links are navigation
aids; refresh them before implementation.

### K1

**Compute librarian failure evidence once with explicit independent policy axes**

Source:
[lib/keeper/keeper_librarian_runtime.ml:460](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/keeper/keeper_librarian_runtime.ml#L460-L896).

Problem: The same Exact_output failure tree is traversed independently by
flow_input_capacity_evidence, flow_has_invalid_output,
flow_has_size_independent_failure, and walk_shows_size_flow;
extraction_has_invalid_output, extraction_shows_size, extraction_meets_same_failure, and
extraction_observed_input_capacity repeat the work over nested CLI fallback history.
Constructor additions must be classified consistently in several places. These are
deliberately different policies, so merging their booleans would be incorrect, but the
repeated traversal obscures their common evidence and veto rules.

Change: Introduce a small pure failure-evidence record with separate fields for
historical range-size evidence, named input-capacity refusal, invalid output, and
size-independent execution failure. Classify each typed provider/CLI cause exhaustively
and fold the exact-flow advances and final cause once. Derive existing public decisions
from the record, retaining their current signatures. Keep prompt rendering, dispatch,
and persistence in the runtime.

Preserve:

- A failure before generation dispatch is not provider size evidence.
- Historical range-window policy and admission input-capacity policy remain distinct; a
  timeout is not by itself an admission split permit.
- Invalid output vetoes capacity/size adaptation in either slot order as current callers require.
- Candidate rejection is not a dispatched size-independent execution failure.
- A later quota failure does not erase an earlier measured CLI capacity; equal
  capacities preserve walk order.
- Do not introduce accumulated turn, time, token, or cost gates.

Consumers:
[lib/keeper/keeper_librarian_runtime.ml](../../../lib/keeper/keeper_librarian_runtime.ml),
[lib/keeper/keeper_librarian_durable_consumer.ml](../../../lib/keeper/keeper_librarian_durable_consumer.ml),
[lib/keeper/keeper_librarian_queue_refresh.ml](../../../lib/keeper/keeper_librarian_queue_refresh.ml),
[lib/keeper/keeper_memory_admission_worker.ml](../../../lib/keeper/keeper_memory_admission_worker.ml).

Scenarios:
[test/test_keeper_librarian_capacity_callback.ml](../../../test/test_keeper_librarian_capacity_callback.ml),
[test/test_keeper_librarian_cli_lane.ml](../../../test/test_keeper_librarian_cli_lane.ml),
[test/test_keeper_librarian_range.ml](../../../test/test_keeper_librarian_range.ml).
**Not executed in this audit.**

Ordering rationale: Bounded pure policy work with existing end-to-end callback and
admission-worker scenarios, including slot-order independence and invalid-output veto.
It reduces constructor drift without changing dispatch/storage or duplicating the Memory
OS codec boundaries (in review during the initial investigation; Round8 integration is
recorded separately).

Implementation: [#43370](https://github.com/jeong-sik/masc/pull/43370) adds a private
immutable failure-evidence module. Runtime computes one summary for terminal callbacks;
the public interface, dispatch evidence and callback order remain unchanged. Added
equal-capacity slot-order cases and strengthened the admission-worker scenario to
distinguish native input refusal from measured range-size evidence. Five changed OCaml
files passed syntax parsing; scenarios are unexecuted. Review details and exact heads
are recorded on the PR.

### K2

**Give canonical child export selection a typed pure boundary**

Implemented in [#43411](https://github.com/jeong-sik/masc/pull/43411) with private
`Keeper_composition_child_exports`: ordered values or a closed selection error.
Canonical authority, disposition, publication and retained-artifact effects stay in
their existing owners.

Source:
[lib/keeper/keeper_tool_composition_surface.ml:1445](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/keeper/keeper_tool_composition_surface.ml#L1445-L1498),
[lib/keeper/keeper_composition_dependency_result.ml:91](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/keeper/keeper_composition_dependency_result.ml#L91-L126).

Problem: The async worker dispatches a child-result read, preserves typed
Deferred/Failed/Completed status, then decodes the canonical
result/exports/available/value JSON envelope inline inside the effectful dispatch
closure. Changes to export schema or selection must be reviewed alongside original
activation authority, artifact publication, unavailable-result tracking, and sibling
execution in a 3,026-line surface module. The storage reader exposes a generic execution
result, so the canonical envelope contract is reconstructed at the consumer.

Change: Create a private pure selected-export decoder near the canonical
dependency-result contract, accepting the declared Plan.export list and observed JSON
and returning ordered export values or a closed selection error. Keep ownership
validation, result-artifact publication, dispatch, and conversion to Tool_result in
their current owners. Use direct calls to the new boundary rather than another surface
facade.

Preserve:

- Only successful canonical named-composition results grant composable exports.
- No requested exports permits an absent exports object; declared exports must each be
  available and carry a value.
- Declared export order remains the output association order.
- Authoritative failed-child observations remain distinct from unavailable
  observations/publication failures.
- Deferred dependencies, retained artifacts, failure effect disposition, and original
  child activation authority remain intact.
- Reading a result never grants child submission or replay authority.

Consumers:
[lib/keeper/keeper_tool_composition_surface.ml](../../../lib/keeper/keeper_tool_composition_surface.ml),
[lib/keeper/keeper_composition_continuation_wake.ml](../../../lib/keeper/keeper_composition_continuation_wake.ml),
[lib/keeper/keeper_tools_agent_core_bundle.ml](../../../lib/keeper/keeper_tools_agent_core_bundle.ml).

Scenarios: [test/test_keeper_owned_jobs.ml](../../../test/test_keeper_owned_jobs.ml)
exercises the actual native async child-result branch, original child/parent
continuations, whole-child failure and publication recovery. Added cases preserve
ordered escaped export names and typed values through a dependent artifact read, and
release a dependency after a child with no exports completes.
[test/test_keeper_composition_nested.ml](../../../test/test_keeper_composition_nested.ml),
[test/test_keeper_composition_async_broker.ml](../../../test/test_keeper_composition_async_broker.ml)
and
[test/test_keeper_tool_plan_executor.ml](../../../test/test_keeper_tool_plan_executor.ml)
remain related suites. **Not executed in this audit.**

Ordering rationale: A narrow protocol boundary in a large effect owner; it improves
reviewability without replacing the already typed execution and authority machinery.
Implementation tracing identified `test_keeper_owned_jobs` as the real native barrier
scenario; the general nested-composition suite also contains inline-only child cases.

### K3

**Represent Board contention rearm tickets with one explicit phase**

Design inspection revision: `d3e01a8d75986ef32807d10d81c50dfa6d31bebf`. Implementation
is recorded below; the source coordinates here retain their historical design baseline.

Source:
[lib/keeper/keeper_board_attention_worker.ml:63](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/keeper/keeper_board_attention_worker.ml#L63-L106),
[lib/keeper/keeper_board_attention_worker.ml:175](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/keeper/keeper_board_attention_worker.ml#L175-L387),
[lib/keeper/keeper_board_attention_worker.ml:502](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/keeper/keeper_board_attention_worker.ml#L502-L509),
[lib/keeper/keeper_board_attention_worker.ml:2161](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/keeper/keeper_board_attention_worker.ml#L2161-L2215).
The
[public testing interface](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/keeper/keeper_board_attention_worker.mli#L320-L365)
already hides the scheduler representation.

Problem: Mutually exclusive `pending` and `inflight` options allow a both-present shape.
Short mutex-protected transitions reconstruct their priority across allocation,
cancellation, delivery completion and reset. The concrete ownership question is whether
a callback still owns the current key and ticket after an outside-lock request, not how
many mutable fields the worker has.

Implemented change: Private `Keeper_board_attention_rearm_state` owns an immutable
`Idle | Pending of ticket | Inflight of ticket` phase and retained next-delay history.
Closed decisions describe reservation/deduplication and delivered/retry/suppressed
completion. The worker retains the entry list/state cell, shared ticket counter, mutex,
exact-key lookup, callbacks and logs, publishing state/counter together under its
existing mutex. The pure module is independent of worker/Wake resource types; public
worker signatures remain unchanged.

Preserve:

- Exact key equality uses Keeper name, partition ID and canonical generation identity.
  One worker-run scheduler separately owns the workspace closure; do not hoist it
  globally.
- `Idle` retains delay history. New tickets use the current delay then advance it under
  the existing policy; dedup and stale callbacks do not allocate or advance. Reset
  removes entry history but never rewinds the scheduler ticket counter.
- Publish `Pending` before fork and `Inflight` before request. Fork, sleep, request and
  logs stay outside the mutex; an eager injected fork may execute before the scheduled
  log.
- After request, re-find the current key and ticket under lock. A reset or same-key
  replacement suppresses the old completion without cancelling a newer reservation or
  undoing an already sent hint.
- Every returned `Ok`, including `Coalesced` and `Not_registered`, completes without
  automatic retry. Only returned `Error` allocates the existing next retry; retain
  error-log, launch, retry-log order.
- Sleep/fork exceptions release only their matching `Pending` reservation and propagate,
  retaining advanced delay history. Existing request exceptions are different: they skip
  completion and leave `Inflight` until reset or scheduler lifetime ends. Do not add
  finalization, cancellation-to-retry conversion or arbitrary-exception retry in this
  representation change.
- Reset and schedule in `apply_drain_rearm` remain separate lock acquisitions. Keep the
  deferred scheduler, Wake registry, timer switch/clock and durable candidate/partition
  authority separate; scheduler cleanup never consumes or expires Board work.

Consumers:
[exact generation claim](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/keeper/keeper_board_attention_worker.ml#L1661-L1677),
[drain result routing](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/keeper/keeper_board_attention_worker.ml#L1965-L1991),
[worker registration](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/keeper/keeper_board_attention_worker.ml#L2099-L2117),
[Wake.request](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/keeper/keeper_board_attention_worker_wake.ml#L73-L91),
and
[keepalive installation](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/keeper/keeper_keepalive.ml#L410-L443)/[lane switch and stop wiring](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/keeper/keeper_keepalive.ml#L1411-L1453).
Returning from the worker alone is not proof that every timer has already been cancelled
before its supplied switch closes.

Existing scenarios:
[delayed deduplication and reset](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/test/test_keeper_board_attention_worker.ml#L987-L1088),
[rescan routing](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/test/test_keeper_board_attention_worker.ml#L1090-L1145),
[returned delivery error](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/test/test_keeper_board_attention_worker.ml#L1147-L1186),
[reentrant callback outside lock](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/test/test_keeper_board_attention_worker.ml#L1188-L1237),
[reset during failed wake](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/test/test_keeper_board_attention_worker.ml#L1239-L1281).
**Inspected, not executed.** The returned-error case calls schedule only after the
failed request task returns; actual request-callback reentrancy is covered by the
separate outside-lock case. The existing reset case does not recreate the same key
during delivery; the callback test is not a multi-domain stress test, and candidate
fixture setup is not a final durability assertion.

Added scenario source: Reset and recreate the same key inside the request, then return
either the old error or success; the new ticket survives both. Fork/sleep exceptions
preserve advanced delay and propagate, while an old callback replayed after reset cannot
cancel the replacement. `Coalesced`/`Not_registered` complete without automatic retry.
An eager fork with a raised request keeps the existing Inflight behavior until reset.
All five cases use the existing public scheduler seam and are registered in
`test_keeper_board_attention_worker`; they are unexecuted. The injected `Cancelled`
exception is not native cancellation evidence.

Implemented in [#43479](https://github.com/jeong-sik/masc/pull/43479), code head
`186295c6f25a2c9d64a2c0b6c87f0c478450f289` against
`c12ccd6d4348c31e62b1d1cfdda313b318094c53`. Independent review read the complete
five-file diff and real worker/Wake/keepalive consumers, with no findings. The public
worker interface and the worker suffix from deferred scheduling through production
wiring/testing exports are byte-identical. Four changed OCaml files passed syntax
parsing. No typecheck, build, scenario execution, formal GitHub approval, merge or
runtime proof is supplied.

Ordering rationale: A bounded exclusive-state change with real worker/wake integration
and existing deterministic callback scenarios. Full partition persistence, lifecycle
recovery and deployed scheduling are outside this design review. A request-exception
repair would require its own explicit contract.

### K4

**Make request-evidence reset and projection ownership explicit per attempt**

Source:
[lib/keeper/keeper_agent_run.ml:1475](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/keeper/keeper_agent_run.ml#L1475-L1547),
[lib/keeper/keeper_agent_run.ml:1910](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/keeper/keeper_agent_run.ml#L1910-L2065),
[lib/keeper/keeper_agent_run.ml:2545](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/keeper/keeper_agent_run.ml#L2545-L2701).

Problem: Request attribution, wire evidence, projected provider content, and projected
messages occupy four independently reset refs; the source comment explicitly documents
that clearing only the final record cells lets a failed lane attempt leak its inputs
into the next lane. Their updates and final projections are hundreds of lines apart.
Turn-local model-input windows and last-response observations intentionally have
different lifetimes, so a broad single optional evidence cell would also be wrong.

Change: Encapsulate attempt-local request evidence in a private state record with an
explicit unprojected/projected projection variant and named
begin_attempt/observe_projection/observe_wire/observe_native_input operations. Each
operation returns the new state; one callback-owned cell may publish it. Keep turn-local
window/response evidence and digest memo ownership separate. Expose immutable snapshots
to receipt generation.

Preserve:

- Every materialized runtime attempt resets all attempt-local evidence together.
- Turn-local window cuts and last-response input observations survive a later runtime selection.
- A native client holding input is an explicit attribution gap, not zero bytes or an
  absent dispatch.
- A wire observation can exist without a serializable body or successful provenance and
  must retain that distinction.
- A turn-local digest memo is mutated only by its owning fiber after the awaited CPU
  job; cancellation does not hand shared mutable state to a worker.
- Persisted input snapshots and receipt runtime attribution use the actual observed attempt.

Consumers: [lib/keeper/keeper_agent_run.ml](../../../lib/keeper/keeper_agent_run.ml),
[lib/keeper/keeper_turn.ml](../../../lib/keeper/keeper_turn.ml),
[lib/keeper/keeper_turn_record_writer.ml](../../../lib/keeper/keeper_turn_record_writer.ml),
[lib/keeper/keeper_provider_input_snapshot.ml](../../../lib/keeper/keeper_provider_input_snapshot.ml).

Scenarios:
[test/test_keeper_prompt_metrics.ml](../../../test/test_keeper_prompt_metrics.ml),
[test/test_keeper_model_input_ledger.ml](../../../test/test_keeper_model_input_ledger.ml),
[test/test_keeper_projection_change.ml](../../../test/test_keeper_projection_change.ml),
[test/test_keeper_model_input_demotion.ml](../../../test/test_keeper_model_input_demotion.ml),
[test/test_keeper_official_client_host.ml](../../../test/test_keeper_official_client_host.ml).
**Not executed in this audit.**

Ordering rationale: Causal historical risk is documented directly beside the reset code.
High impact on observability integrity, but callback lifetime and mixed native/Agent
Core paths make this less isolated than K1-K3. Existing helper tests do not by
themselves prove a complete multi-attempt run_turn scenario.

### K5

**Separate approval restart replay decisions from recovery effects**

Source:
[lib/keeper/keeper_approval_queue.ml:519](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/keeper/keeper_approval_queue.ml#L519-L787).

Problem: read_pending_log_unlocked combines durable-tail recovery, raw JSON line
parsing, generation validation, pure log-row application, sequence calculation, and
observation of settlement errors. load_snapshot_unlocked then combines decoded-state
classification with cache publication, conditional compaction, error reporting, and a
five-element result tuple. It is difficult to review which facts authorize a restart
rewrite without following filesystem effects through both functions.

Change: Extract pure log replay over complete decoded rows into an explicit replay-state
record, then a pure restart-plan result describing readable entry errors, classified
pending/delivery maps, and whether durable rewrite is necessary. Keep tail recovery,
fsync/compaction, locking, and cache publication in the store shell. Reuse existing
codec and classify_restarted functions; do not invent a generic event-store framework.

Preserve:

- Older log generations are already represented by the snapshot; a future generation fails closed.
- Only an incomplete final append is recoverable as a tail; malformed complete rows
  preserve the store and fail.
- Monotonic next_sequence uses the maximum accepted row sequence.
- A missing snapshot is a reset store and does not authorize replaying orphan log rows.
- Readable entries and their explicit errors survive a partial snapshot; entry errors
  prevent restart rewrite.
- Durable snapshot/log compaction and published caches cannot describe different generations.
- Cancellation is re-raised; shared cache mutation remains under the existing store lock.

Consumers:
[lib/keeper/keeper_approval_queue.ml](../../../lib/keeper/keeper_approval_queue.ml),
[lib/keeper/keeper_gate.ml](../../../lib/keeper/keeper_gate.ml),
[lib/keeper/keeper_gate_replay.ml](../../../lib/keeper/keeper_gate_replay.ml),
[lib/server/server_runtime_bootstrap.ml](../../../lib/server/server_runtime_bootstrap.ml),
[lib/keeper/keeper_shutdown_finalize.ml](../../../lib/keeper/keeper_shutdown_finalize.ml).

Scenarios:
[test/test_keeper_approval_queue.ml](../../../test/test_keeper_approval_queue.ml),
[test/test_keeper_hitl_replay_delivery.ml](../../../test/test_keeper_hitl_replay_delivery.ml).
**Not executed in this audit.**

Ordering rationale: Direct restart scenarios already cover sequence persistence,
generation serialization, partial snapshots, row replay, and incomplete-tail recovery.
The change reduces audit complexity at an authority boundary, but must preserve the
current recovery/write ordering exactly.

### K6

**Make Agent Core committed-batch scanning an explicit returned state**

Source:
[packages/agent_core/lib/execution_event_store.ml:1240](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/packages/agent_core/lib/execution_event_store.ml#L1240-L1444).

Problem: scan_committed_batches nests a batch/event grammar inside file-frame reads,
codec calls, cooperative yields, digest accumulation, and two outer refs that publish
locations and replay events only after a valid footer. The commit visibility rule exists
in control-flow placement rather than a named typed scan state, so a change to streaming
or indexing can accidentally move partial-batch state across the commit boundary.

Change: First replace the two outer refs with explicit immutable scan accumulators
passed through tail recursion. If that clarifies the boundary, isolate pure
batch-header/footer/event-sequence validation over already decoded frames using a closed
batch phase and a validated committed-batch value. Retain streaming file reads,
incremental digest work, Eio cancellation checks and cooperative yields in the driver;
do not preload the whole WAL or change its format.

Preserve:

- No event index entry or replay event is committed before matching batch identity,
  range, count, and digest checks.
- Event sequence and correlation identity remain exact and canonical bytes remain validated.
- Committed corruption is refused rather than truncated as an uncommitted tail.
- Read_only_events and Rebuild_durable_index return identical committed event order
  while differing only in index construction.
- Cancellation checkpoints and cooperative yielding remain present for large WALs.
- Writer claims, lifecycle hooks, fsync authority, and fencing stay in their existing effect owner.

Consumers:
[packages/agent_core/lib/execution_event_store.ml](../../../packages/agent_core/lib/execution_event_store.ml),
[packages/agent_core/lib/execution_journal.ml](../../../packages/agent_core/lib/execution_journal.ml).

Scenarios:
[packages/agent_core/test/test_execution_event_store.ml](../../../packages/agent_core/test/test_execution_event_store.ml),
[packages/agent_core/test/test_execution_journal.ml](../../../packages/agent_core/test/test_execution_journal.ml),
[packages/agent_core/test/test_execution_lane_writer.ml](../../../packages/agent_core/test/test_execution_lane_writer.ml).
**Not executed in this audit.**

Ordering rationale: Useful separation at a durable authority boundary with extensive
corruption/recovery/cancellation scenarios. The current private mutable store and byte
buffers are justified; no performance improvement is claimed, and a small
accumulator-only slice should precede any larger grammar extraction.

### K7

**Separate Memory receipt reconciliation selection from its durable plan**

Source:
[lib/keeper/keeper_memory_os_current.ml:705](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/keeper/keeper_memory_os_current.ml#L705-L788).

Problem: Receipt reconciliation interleaves cached fixed-point checks, lazy snapshot
hashing, prepared-snapshot durability confirmation, pure eligibility filtering,
first-occurrence deduplication in a local hash table, quarantine, cache marking, file
removal, and rewriting. The receipt selection policy is therefore read together with its
effect order even though it can be calculated from observed receipt/snapshot values.

Change: After the existing Memory stack integrates, extract a pure receipt selection
result carrying ordered reconciled receipts and a typed unchanged/remove/rewrite
decision. Use an immutable set for exact receipt-key deduplication or retain a private
local hash table if measured cardinality justifies it; the substantive boundary is the
returned decision. Leave snapshot sync, quarantine-before-rewrite, atomic I/O, and cache
identity checks in the store.

Preserve:

- Prepared receipts become committed only for the exact snapshot revision and digest and
  after durability confirmation.
- Committed receipts remain valid at a higher authoritative snapshot revision.
- Duplicate keys retain their first input occurrence and existing order.
- Skipped receipt bytes are quarantined before any rewrite or removal forgets them.
- The fixed-point shortcut requires unchanged or newer authoritative snapshot evidence;
  missing/lower/different same-revision snapshots require reconciliation.
- Candidate consumption receipts survive unrelated snapshot commits and fact retirement.
- Coordinate after PRs 43347, 43348, and 43353; this candidate excludes their codec and
  successor-projection scope.

Consumers:
[lib/keeper/keeper_memory_os_current.ml](../../../lib/keeper/keeper_memory_os_current.ml),
[lib/keeper/keeper_librarian_durable_consumer.ml](../../../lib/keeper/keeper_librarian_durable_consumer.ml),
[lib/keeper/keeper_memory_admission_worker.ml](../../../lib/keeper/keeper_memory_admission_worker.ml).

Scenarios:
[test/test_keeper_memory_os_current.ml](../../../test/test_keeper_memory_os_current.ml),
[test/test_keeper_librarian_durable_consumer.ml](../../../test/test_keeper_librarian_durable_consumer.ml),
[test/test_keeper_memory_admission_queue.ml](../../../test/test_keeper_memory_admission_queue.ml).
**Not executed in this audit.**

Ordering rationale: Distinct residual responsibility from the in-review Memory
codec/successor slices. Existing tests include first-order receipt reconciliation,
prepared exact-snapshot recovery, cache invalidation, no-change consumption, and
retirement replay rejection. Defer until that stack lands to avoid overlapping
ownership.

### D1

**Return an explicit task commit receipt instead of a cross-scope notification ref**

Source:
[lib/workspace/workspace_task_transitions.ml:156](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/workspace/workspace_task_transitions.ml#L156-L162),
[lib/workspace/workspace_task_transitions.ml:405](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/workspace/workspace_task_transitions.ml#L405-L447),
[lib/workspace/workspace_task_transitions.ml:684](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/workspace/workspace_task_transitions.ml#L684-L731).

Problem: transition_task_outcome_r carries the public result and
committed_verification_submission through separate channels. The latter ref is set after
write_backlog, then inspected after the lock callback and its exception-to-IoError
handler. Correct notification behavior therefore depends on an assignment happening at
exactly the commit boundary, even when later projections fail. This is a real
responsibility boundary, not a complaint about a local ref in isolation.

Change: Introduce a private closed transaction outcome describing no-op versus committed
transition, carrying the verified submission obligation and response together. Separate
pre-commit failure/compensation from post-commit projections and submission
finalization. Replace the ref only after preserving the cases where a projection fails
after the backlog has committed; do not simply map the successful public Result to a
notification.

Preserve:

- Read and mutate the authoritative backlog under the existing lease/lock.
- Create the verification request before committing AwaitingVerification.
- Compensate only a failed pre-commit request; never undo a committed task.
- Delete a superseded verification request before announcing the new request.
- No-op/rejected transitions remain silent. Preserve Eio cancellation and existing
  post-commit scheduling semantics.

Consumers: [lib/workspace/workspace_task.ml](../../../lib/workspace/workspace_task.ml),
[lib/task/tool_task.ml](../../../lib/task/tool_task.ml),
[lib/verification_protocol.ml](../../../lib/verification_protocol.ml).

Scenarios:
[test/test_task_transition_broadcast.ml](../../../test/test_task_transition_broadcast.ml),
[test/test_verification.ml](../../../test/test_verification.ml),
[test/test_workspace.ml](../../../test/test_workspace.ml). The verification suite
executed in the later D7 check below; the other two suites remain unexecuted in this
audit.

Ordering rationale: The current code explicitly documents commit-sensitive projection
failures, and test_submit_schedules_review_after_log_failure plus
test_raw_workspace_submission_notifies_once exercise the user-visible continuity. A
typed receipt makes the commit/notification relation reviewable without moving I/O or
changing task policy.

Implementation: [#43399](https://github.com/jeong-sik/masc/pull/43399) replaces the
cross-scope ref with a function-local `Noop | Committed { submission; result }` receipt.
A committed late projection error remains a public error while retaining the existing
outside-lock supersede deletion and notification. Cancellation still escapes without
that finalization; this is not a durable replay guarantee. Three real-request-store
scenarios cover late observer failure, precommit revision exhaustion and an explicitly
raised cancellation exception. Two changed OCaml files passed syntax parsing. Later
[run 39004452904](https://github.com/jeong-sik/masc/actions/runs/39004452904) at
combined head `3c8ed8b0f44101d346efa6c008b1a0d10dafd2c7` passed these three
`workspace_boundary` cases (1–3) within all 100 verification cases. This execution does
not cover the other two named suites or actual fiber cancellation scheduling.

### D2

**Make Goal upsert a typed immutable transaction decision**

Source:
[lib/goal/goal_store.ml:681](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/goal/goal_store.ml#L681-L700),
[lib/goal/goal_store.ml:1018](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/goal/goal_store.ml#L1018-L1168).

Problem: upsert_goal_internal communicates created/updated action, refusal, and pending
audit events through three refs. update_state uses physical identity (next_state ==
state) to mean do not write, including a rejected first creation. A future record-copy
refactor can accidentally turn refusal into an empty-store write, and the three
independent refs permit combinations that are impossible in the domain but require
fallback failed-to-save handling.

Change: Compute an explicit result containing either a write error or an accepted
immutable commit with the next state and returned value. Have a private lock-owning
transaction persist only accepted commits and return the value directly. Keep row
transformation separate from clock, identity and storage effects, and preserve the
public upsert wrappers. The focused source audit found that every accepted existing
upsert writes even when supplied fields are unchanged; there is no upsert no-op decision
to add. `transact_goal` has its own equality-based no-op contract and remains separate.

Preserve:

- A refused first upsert writes no goals.json and leaves the source Uninitialized.
- Creation/update is decided inside the write lock from authoritative state.
- Criterion edits invalidate proof progress using Goal_phase.criterion_changed and keep
  suspension semantics.
- Returned updated action contains the previous goal, and the revision witness belongs
  to that exact commit.
- Audit intents remain in the same state write as the goal change; refusal must not mint
  events. An accepted unchanged-field upsert still advances the store revision and, with
  an actor, emits `Updated`.

Consumers: [lib/workspace_goals.ml](../../../lib/workspace_goals.ml),
[lib/goal/goal_measurement.ml](../../../lib/goal/goal_measurement.ml),
[lib/goal/goal_verification.ml](../../../lib/goal/goal_verification.ml).

Scenarios: [test/test_goal_store.ml](../../../test/test_goal_store.ml),
[test/test_goal_upsert_fsm_bypass_10247.ml](../../../test/test_goal_upsert_fsm_bypass_10247.ml),
[test/test_goal_suspension.ml](../../../test/test_goal_suspension.ml),
[test/test_goal_tools.ml](../../../test/test_goal_tools.ml). **Not executed in this
audit.**

Ordering rationale: This removes implicit control encoded by object identity and three
mutable side channels. Existing tests explicitly cover refused first write, previous-row
return, revision witnesses, criterion edits, and durable audit outbox behavior.

Implementation: [#43374](https://github.com/jeong-sik/masc/pull/43374) replaces the
three refs and physical-identity signal with a private typed commit result, keeping pure
row transformations apart from identity, clock and persistence effects. The unused
public `update_state` helper is removed after repository caller/alias inspection; the
three upsert interfaces remain unchanged. External package consumers were not verified.
Added actual-store scenarios for audited refusal and accepted identical-field writes.
Four changed OCaml files passed syntax parsing. Round 16's first D3 check exposed a
compile error in the identical-audited-upsert fixture, which earlier source review had
missed; the tuple type annotation and subsequent execution status are recorded under D3.
No D2 behavior execution was established by that failed build.

### D3

**Isolate the Goal document codec and schema rejection contract**

Source:
[lib/goal/goal_store.ml:16](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/goal/goal_store.ml#L16-L165),
[lib/goal/goal_store.ml:168](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/goal/goal_store.ml#L168-L393).

Problem: Goal state, pending events and pending notifications share a persistence module
with filesystem source classification, locking, writes and transactions. The codecs
encode different deliberate contracts: unknown Goal fields are refused, suspended phases
require restore state, event/notification objects have exact fields, missing optional
outboxes are accepted, and duplicate pending event/notification identities are rejected.
Readers changing source availability or transactions must currently retain all these
wire-level details in context. The existing codec region is already pure; this candidate
makes its representation ownership explicit rather than repairing a demonstrated
behavior defect.

Change: Put the canonical Goal document data and existing encode/decode/validate
functions in one private `Goal_document` module, included by Store under its unchanged
public signature. Keep load_source, errno handling, mirror observation and transaction
effects in Goal_store. Preserve the existing acceptance behavior; do not tighten
duplicate-field rules, change optional defaults, remove priority clamping or redesign
wire formats in the extraction.

Preserve:

- Preserve every currently accepted/rejected JSON shape, field order and
  schema_rejection field/detail.
- Unknown status/phase shapes remain refused; suspended Goal restore targets are preserved.
- Mirror data stays observation-only and is never served as authoritative Goal state.
- Pending event/notification order and their distinct identity checks remain unchanged.
- Public Goal_store type identity and API remain compatible.

Acceptance is intentionally nonuniform: the document does not reject duplicate Goal IDs,
all duplicate Goal/root keys, or unknown root keys. Goal rows reject unknown fields and
require exactly one nonblank criterion revision; criterion/event/notification objects
have their own exact-field rules. Optional Goal strings retain their current projection,
and integer priorities retain clamping. Event revision uses `Json_util.get_int`,
including parseable `Intlit`, whereas document version and Goal priority match `Int`.
The event seen-table is fresh to one decode and stays local. No generic strict-record or
numeric decoder replaces these policies.

Consumers:
[lib/keeper/keeper_store_boot_reconcile.ml](../../../lib/keeper/keeper_store_boot_reconcile.ml),
[lib/workspace_goals.ml](../../../lib/workspace_goals.ml),
[lib/task/task_goal_assignment.ml](../../../lib/task/task_goal_assignment.ml).

Scenarios: [test/test_goal_store.ml](../../../test/test_goal_store.ml),
[test/test_goal_notification_contract.ml](../../../test/test_goal_notification_contract.ml),
[test/test_goal_suspension.ml](../../../test/test_goal_suspension.ml),
[test/test_keeper_store_boot_reconcile.ml](../../../test/test_keeper_store_boot_reconcile.ml).
The initial focused run stopped while compiling an inherited fixture; the corrected
request below has no observed result yet.

Ordering rationale: The candidate is a trust-boundary split: exact persisted state
validation can be reviewed independently of read-source policy and mutation. It is not a
request to split by line count or to replace all parsers with a generic framework.

Implementation: [#43556](https://github.com/jeong-sik/masc/pull/43556), code head
`6237238cfbdce158d0d192c97f01e4bd5871862f` against
`a850f8ab8b37972b1b233a6e803e8fbfbedf9995`, creates private `Goal_document` with the
seven existing canonical public data types, private schema rejection, criterion helpers,
codecs and shared priority clamp. Store includes it under its byte-identical public
`.mli`. The owning `masc_goal` stanza auto-discovers modules and only adds
`private_modules`. The eleven-value private signature keeps row/outbox helpers hidden;
Store retains transition effects, rollup, source/byte decoding, clocks/IDs, locks, D2
upsert and D4 publication. Both modules retain their own Result binding. Exact
comparisons find unchanged function/type bodies and retained Store code; only the moved
decoder-owner comment and a final blank line differ.

One added actual-file scenario writes a valid suspended Goal and two distinct ordered
pending events to primary and mirror, then introduces an invalid restore target and
malformed outbox in primary. Public `validate_state_json` and `load_source` retain the
same first canonical field/detail through their different wrappers. A valid mirror stays
observation-only; `transact_goal` refuses before callback entry, preserving both files.
Repairing only the restore target exposes the later outbox error. Restoring valid
primary bytes preserves the complete suspended Goal, restore target, event
payloads/order and revision. This exercises the validator used by setup without
executing the setup CLI. It introduces no production hook or new schema rule.

Independent author-free source review passed `6237238cfbdce158d0d192c97f01e4bd5871862f`,
full-index diff SHA-256
`80a72ae5248728be4ff0a6848d23cbeb74473188cdec503ba0dbabaa07785b5a`. Four changed OCaml
files passed syntax-only parsing.
[Initial run 39006043087](https://github.com/jeong-sik/masc/actions/runs/39006043087) at
that code head failed while compiling `test_goal_store.ml:1298`: the inherited D2
audited-upsert fixture accessed `goal.criterion_revision` before the callback return
type was known. No test executable ran. Exact source comparison confirms this fixture
and the public Store interface are unchanged from D2 and the extraction parent; this is
not an observed execution of those earlier heads. Earlier source reviews did not
identify the fixture defect. Commit `d01061b7cdb99a749f346d14cbf5dad55acafe1b` annotates
the returned tuple as `Goal_store.goal * Goal_store.pending_event list`, preserving
every assertion and all production code.
[Corrected run 39006426800](https://github.com/jeong-sik/masc/actions/runs/39006426800)
requests that head with `minimal=true` and the same
`test_goal_store,test_goal_notification_contract,test_goal_suspension,test_keeper_store_boot_reconcile`;
its result is not yet observed. No local build/typecheck/test, full CI, formal approval,
merge, setup subprocess, deployed runtime or visible UI proof is claimed.

Round 16 context: main `069564c47eec30155c2a8058d67e30aa4607053d` retains the same
original document-codec prefix. Textual merge-tree with the parent succeeds. The fully
paginated 86-open-PR census and all 25 prior stack head/base identities were refreshed:
only inherited D2 #43374 intersects the 32-path selected target/consumer scope,
including the planned new module pair. The upstream setup child-environment fix leaves
Goal validation unchanged and must survive a future restack. Wider Goal
textual-reference overlaps and all transitive behavior are not cleared by this bounded
review. The historical file-census and consulted-source counts are unchanged.

### D4

**Audit and retain typed Goal publication outcomes across the backend adapter**

Source:
[lib/goal/goal_store.ml:514](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/goal/goal_store.ml#L514-L576),
[lib/goal/goal_store.ml:592](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/goal/goal_store.ml#L592-L604),
[lib/workspace/workspace_utils_ops.ml:257](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/workspace/workspace_utils_ops.ml#L257-L300),
[lib/workspace/workspace_backlog.ml:215](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/workspace/workspace_backlog.ml#L215-L220).

Problem: Workspace_utils_ops already distinguishes a committed backend mutation with
local mirror failure as Ok {mirror_error=Some _}. Its write_json_result compatibility
adapter converts that outcome back to Error. Goal_store.write_state_result uses that
adapter and returns Persist_failed to callers before advancing the projection
generation, while Goal reads are direct local-file reads. Whether this is correct
depends on which store is authoritative for each backend; the code exposes a semantic
question rather than proof of a reproduced production bug.

Change: First trace Goal backend authority and add a focused fault scenario for backend
success/local mirror failure. Then carry an explicit publication outcome if the backend
commit is authoritative, or use a clearly local-authoritative writer if local goals.json
is the authority. Reuse the existing typed write_json_commit capability instead of
inventing string matching. Keep this separate from the pure upsert extraction.

Preserve:

- Never report a definitive pre-effect failure for a mutation that the chosen authority
  has committed.
- A recovery mirror failure remains a committed primary write, as the current test already requires.
- Unavailable or corrupt primary state must not authorize mutation through a fallback mirror.
- Projection generation and event delivery must be tied to the actual authoritative commit.
- Do not change backend authority without an explicit documented decision.

Consumers: [lib/workspace_goals.ml](../../../lib/workspace_goals.ml),
[lib/goal/goal_measurement.ml](../../../lib/goal/goal_measurement.ml),
[lib/goal/goal_verification.ml](../../../lib/goal/goal_verification.ml).

Scenarios: [test/test_goal_store.ml](../../../test/test_goal_store.ml),
[test/test_workspace.ml](../../../test/test_workspace.ml),
[test/test_goal_tools.ml](../../../test/test_goal_tools.ml). **Not executed in this
audit.**

Ordering rationale: The exact flattening exists in current source, but the authority
choice needs clarification from implementation and fault evidence. This is not a blanket
change of every Result-returning writer; Workspace_backlog is a useful existing example
of a committed-outcome boundary.

### D5

**Extract the Board vote decision from post/comment mutation shells**

Source:
[lib/board/board_votes.ml:164](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/board/board_votes.ml#L164-L235),
[lib/board/board_votes.ml:257](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/board/board_votes.ml#L257-L316).

Problem: Post and comment voting duplicate the previous-direction state machine and
counter adjustments inside separate validate/append/re-read/mutate pipelines. A
correction to same-direction rejection or flip arithmetic must be applied in both places
and at both admission/commit stages. The effect ordering is intentional: a vote row is
appended before in-memory mutation and the final decision uses a fresh read.

Change: Introduce a small private pure vote decision that maps previous vote and
requested direction to Already_voted or a typed first-vote/flip delta. Apply that
decision under each existing state lock, with separate post/comment record updates so
post updated_at semantics remain explicit. Keep durable append and the fresh
commit-stage recheck in the two effect shells.

Preserve:

- Validation or append failure leaves all vote counts and vote_log entries unchanged.
- Recheck after append; do not reuse stale staged post/comment records.
- Same-direction concurrent attempts remain Already_voted.
- Post updated_at and vote timestamp follow the current cast/flip time; comments do not
  acquire an invented timestamp field.
- Dirty flags, caches and restart replay remain consistent; do not change karma scoring
  or ledger ordering.

Consumers: [lib/board/board_dispatch.ml](../../../lib/board/board_dispatch.ml),
[lib/board/board.ml](../../../lib/board/board.ml).

Scenarios:
[test/test_board_vote_persistence.ml](../../../test/test_board_vote_persistence.ml),
[test/test_board_dispatch.ml](../../../test/test_board_dispatch.ml),
[test/test_board_karma_ledger.ml](../../../test/test_board_karma_ledger.ml). **Not
executed in this audit.**

Ordering rationale: This isolates one closed domain decision without abstracting away
legitimate Eio locks or forcing generic record lenses. Persistence-failure, flip,
comment-vote and restart tests already provide meaningful consumer evidence.

### D6

**Represent Board snapshot flush work and retry obligations explicitly**

Source:
[lib/board/board_votes.ml:789](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/board/board_votes.ml#L789-L920),
[lib/board/board_votes.ml:966](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/board/board_votes.ml#L966-L1045).

Problem: delete_post and flush_dirty both snapshot several stores, clear dirty state
under the state lock, persist outside it under the persistence lock, then re-mark
affected stores on failure. They carry the work as positional tuples and independently
encode which failed snapshot re-queues posts versus comments. Adding a snapshot kind or
changing retry policy can produce a missing durable obligation even when the in-memory
deletion succeeded.

Change: Use a private closed snapshot-kind batch and an explicit persistence result per
kind. Extract the pure retry classification and batch selection while leaving snapshot
capture/dirty clearing under store.mutex and all writes serialized by persist_mutex.
Reuse the typed batch in deletion and ordinary flush; retain their distinct public
result contracts.

Preserve:

- Keep persistence lock ordering: persist_mutex outside short state-lock sections.
- Never rewrite a partially loaded or unreadable snapshot.
- Concurrent edits after snapshot capture must remain dirty and must not be cleared by
  write completion.
- A failed posts/votes/reactions write re-queues the current post retry obligation; a
  failed comment write re-queues comments.
- Empty final snapshots still persist and retry, so deleted rows cannot resurrect after restart.
- Deletion_persistence_pending remains a post-effect result, not a pre-effect rejection.

Consumers: [lib/board/board_dispatch.ml](../../../lib/board/board_dispatch.ml),
[lib/board/board_core_persist.ml](../../../lib/board/board_core_persist.ml).

Scenarios:
[test/test_board_delete_rewrite_requeue.ml](../../../test/test_board_delete_rewrite_requeue.ml),
[test/test_board_vote_persistence.ml](../../../test/test_board_vote_persistence.ml),
[test/test_board_persistence_load_contract.ml](../../../test/test_board_persistence_load_contract.ml).
**Not executed in this audit.**

Ordering rationale: The important duplication is the durable retry protocol and
dirty-state coupling, not the tuple syntax alone. Existing tests inject each snapshot
failure, cancellation during flush, unreadable sources and competing edits.

### D7

**Preserve evidence transport decisions in the complete review request, then isolate
snapshot projections**

Round 13 refinement in [#43538](https://github.com/jeong-sik/masc/pull/43538): source
inspection at `0bef45a0ae2179fb1ea2036dbab05c1ca208b948`, independently checked at
`7f4a2fb602a0f4bad140eb0673324f2b4844d5ad`. These D7 sources are unchanged by the
intervening E1 parser work. That initial finding was source-derived; no reproduction,
provider request or deployed incident was observed in Round 13. The Round 14 repair
addressed the complete envelope; Round 15 separately implements the canonical
codec/projection boundary below.

Source:
[lib/workspace/workspace_verification_store.ml:3](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/workspace/workspace_verification_store.ml#L3-L78),
[lib/workspace/workspace_verification_store.ml:81](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/workspace/workspace_verification_store.ml#L81-L627),
[lib/workspace/workspace_verification_store.ml:811](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/workspace/workspace_verification_store.ml#L811-L829).

Problem: One module owns evidence variants, persisted JSON, judge transport,
metadata-only redaction, aggregate content selection, artifact reads and binary-body
storage. Its three serializers already have distinct names and policies. Splitting their
files alone would leave a concrete consumer problem:
[submit-time capture](https://github.com/jeong-sik/masc/blob/0bef45a0ae2179fb1ea2036dbab05c1ca208b948/lib/verification_protocol.ml#L178-L200)
stores the rich snapshot in `output.submitted_evidence`, and
[request serialization](https://github.com/jeong-sik/masc/blob/0bef45a0ae2179fb1ea2036dbab05c1ca208b948/lib/verification.ml#L65-L73)
retains that output.
[Review preparation](https://github.com/jeong-sik/masc/blob/0bef45a0ae2179fb1ea2036dbab05c1ca208b948/lib/completion_authority_agent.ml#L503-L510)
includes this raw request beside the transport projection in the same `completion_notes`
value.

The
[prompt builder](https://github.com/jeong-sik/masc/blob/0bef45a0ae2179fb1ea2036dbab05c1ca208b948/lib/task/anti_rationalization.ml#L327-L363),
[default template](https://github.com/jeong-sik/masc/blob/0bef45a0ae2179fb1ea2036dbab05c1ca208b948/config/prompts/verification.md#L23)
and
[reviewer invocation](https://github.com/jeong-sik/masc/blob/0bef45a0ae2179fb1ea2036dbab05c1ca208b948/lib/task/anti_rationalization.ml#L607-L655)
retain those bytes. Consequently, stored truncated prefixes, aggregate-withheld artifact
bodies and captured collaboration content can reappear through the raw request. The
projection's omission/size contract does not cover the complete prompt. Truncation does
not recover unread source bytes, and binary payload bytes remain in their separate
body/attachment path. Collaboration capture still checks authorization; this finding
does not establish unauthorized disclosure. Live prompt overrides and actual provider
transmission were not inspected.

Round 14 repair in [#43544](https://github.com/jeong-sik/masc/pull/43544), code head
`3c8ed8b0f44101d346efa6c008b1a0d10dafd2c7` against
`e5ee7070d7e768039f2da78d2721891b511dc552`: a private pure
`completion_notes_of_evidence` in the existing completion authority projects an
immutable request copy and assembles the whole envelope. It removes every top-level
`output.submitted_evidence` occurrence from that copy and retains all other output
fields, order, identity and criteria. Evidence reaches the prompt through the existing
typed transport projection. The original rich request, snapshot lookup, validation order
and subsequent binary-image reads are unchanged. No public API, Dune declaration, new
module/type, cap or recursive redactor is introduced.

Round 15 extraction in [#43553](https://github.com/jeong-sik/masc/pull/43553), code head
`bf306c55180d4fe63173090322d9744722721782` against
`cb7410b761d1abb3b0ee6d41c600fc07998136b3`: private `Workspace_verification_snapshot`
owns the six existing snapshot/header/access types, canonical decoders and distinct
persistence, judge and metadata projections. Store includes that module under its
byte-identical public signature. The owning `masc_workspace` Dune stanza registers the
private module. Acquisition, request loading, authorization, UTF-8/reference admission
and binary-body I/O stay in Store. Moved function/type bodies and retained Store bodies
are unchanged; two comments clarify ownership and the aggregate cap's actual
text-artifact scope. No new cap, format, public type path or forwarding facade is
introduced.

The private interface exposes the existing pure Store API plus only the request-snapshot
decoder and shared note prefix needed by Store. Request decoding still stops at the
first malformed item. Identity projection retains its first error while evaluating later
decoders; warning selection still skips malformed items. Header-before-snapshot
validation, collaboration digest checks, binary decoder permissiveness, smallest-first
transport selection and submission-order output are preserved. These are distinct
contracts, not interchangeable folds.

Preserve:

- Invalid-reference items remain payload-free and must not echo rejected paths; this
  does not claim that the existing separately rendered raw reference list hides every
  input reference.
- Stored evidence preserves submission-time bytes/digests; metadata and judge
  projections do not substitute for the stored snapshot.
- Truncated/aggregate-withheld content remains visibly unavailable with the existing
  tools/read instructions.
- Binary body bytes stay outside JSON. Preserve the actual existing checks:
  collaboration decoding verifies its content digest; binary decoding accepts a digest
  string, while body reading checks the filed path shape and actual delivery size
  without recomputing that digest. Do not claim a binary hash-validation guarantee or
  silently add one in this extraction.
- Preserve evidence order, byte ceilings and collaboration-source metadata; this
  extraction does not redesign resource limits.
- No filesystem or clock effects are introduced into codecs.

Consumers: [lib/verification_protocol.ml](../../../lib/verification_protocol.ml),
[lib/completion_authority_agent.ml](../../../lib/completion_authority_agent.ml),
[lib/verification_authority_tools.ml](../../../lib/verification_authority_tools.ml),
[lib/goal_verification_agent.ml](../../../lib/goal_verification_agent.ml),
[lib/dashboard/dashboard_verification.ml](../../../lib/dashboard/dashboard_verification.ml),
[lib/tui_decode.ml](../../../lib/tui_decode.ml).

Scenarios: [test/test_verification.ml](../../../test/test_verification.ml),
[test/test_verification_collaboration_evidence.ml](../../../test/test_verification_collaboration_evidence.ml),
[test/test_verification_operator_evidence.ml](../../../test/test_verification_operator_evidence.ml).
Existing transport tests assert the projection in isolation. The metadata-only
review-notes test checks post-verdict task notes, a different surface. Round 14 extends
the existing persisted-contract scenario through real submission, persistence/reload,
`Completion_authority_agent.start` and the final `run_llm_reviewer_fn` callback.

Added scenario: real files produce a truncated prefix, a complete artifact withheld by
aggregate selection, and an admitted small artifact; a Board post supplies captured
collaboration. After submission, the fixture changes the files, Board body/author and
live contract. The actual reviewer callback captures its initial prompt and dispatches
its supplied frozen Board lookup. Assertions outside the callback check persisted
criteria/content/references, original lookup data, unchanged stored request, settled
registry and completed Task, then the three intended body omissions. Environment and
hooks are restored after switch cleanup; Board singletons/backends are reset, with setup
inside the protected thunk. No new production hook or provider call is involved.
Duplicate-key removal and unchanged image assembly have source inspection, not new
integration scenario coverage.

Initial execution found a fixture defect:
[run 39003932711](https://github.com/jeong-sik/masc/actions/runs/39003932711) at
original checkpoint `2c53e607e254759fd52418f1c38fcba36912fb9e` and
[run 39003976629](https://github.com/jeong-sik/masc/actions/runs/39003976629) at
repaired checkpoint `c96d08cd515101b32c7aa01c40ee6b0621748041` each compiled and ran 100
verification cases with one failure at frozen-lookup equality; the separate seven-case
collaboration suite passed. The reviewer lookup adds a success-observation object around
a string containing the Board JSON. The fixture compared that outer object with the raw
source, so neither run reached the intended omission assertions. These failures are not
D7 reproduction evidence. Initial source review missed that wrapper mismatch. The
corrected test checks the success flag, decodes `lookup_result`, and still compares the
complete frozen source object.

Corrected focused execution, observed in Round 15:
[original run 39004398611](https://github.com/jeong-sik/masc/actions/runs/39004398611)
at `2d1069337ba85577b39332e185edb74946dcdfd2`, with the baseline production blob
restored, reaches and fails the final-prompt truncated-prefix omission assertion after
capture, frozen lookup and persisted-request checks succeed. It has one failure among
100 verification cases; all seven collaboration cases pass.
[Repaired run 39004452904](https://github.com/jeong-sik/masc/actions/runs/39004452904)
at `3c8ed8b0f44101d346efa6c008b1a0d10dafd2c7` passes all 100 verification and seven
collaboration cases, including all three omission assertions. The corrected test blob is
identical across checkpoints. Actual checkout identities and logs were read. Both run
only `test_verification,test_verification_collaboration_evidence` with `minimal=true`.
Independent source review passed final envelope head
`cb7410b761d1abb3b0ee6d41c600fc07998136b3`; later documentation preserves the tested
OCaml blobs.

Round 15 adds one public persisted-request scenario in
[test/test_dashboard_verification.ml](../../../test/test_dashboard_verification.ml):
authority inspection and dashboard listing read the same snapshot with a valid leading
item and two different malformed items. Both refuse partial evidence and report the same
first canonical error through their existing outer types. Rewriting only the first
malformed item under the same request ID exposes the next error through both consumers,
including cached listing invalidation. It does not use or expose the private module.
Independent author-free source review passed code head
`bf306c55180d4fe63173090322d9744722721782`, full-index diff SHA-256
`928239916fd92d39cdcbb54ceb3c03adef9de1fa2ddc3bbf865ca399ee50a028`. Four changed OCaml
files passed syntax-only parsing and whitespace checks.
[Focused run 39005181417](https://github.com/jeong-sik/masc/actions/runs/39005181417)
passed at `bf306c55180d4fe63173090322d9744722721782`: 100 verification, seven
collaboration-evidence, ten operator-evidence and 29 dashboard-verification cases (146
total), `minimal=true`. Actual checkout identity, selected suites and logs were read,
including both phases of the new consumer scenario, the inherited final-prompt omission
assertions and operator JSON-to-TUI decoding. Later documentation-only commits preserve
the tested code/test/Dune blobs. No local build/typecheck/test, full CI, formal
approval, merge, provider transmission or deployed-runtime proof is supplied.

Ordering rationale: The actual producer-to-consumer path exposes the missing boundary;
file size does not justify the work. The Round 13 74-open-PR census found no direct
store/interface/workspace-Dune overlap, but `test_verification.ml` was touched by our
lower #43399 and TUI decoding by external #43518/#43504. Round 14 refreshed 77 open PRs
with every changed-file page and the 23 prior stack heads: no head changed, and direct
D7 overlap is only inherited #43399. Four external Keeper-prompt-adjacent diffs were
read separately; they do not edit this Task-review envelope. Main
`8afa88fb1ce52b5842b572cb4a4e22c57bbeca60` has no direct D7 production change or textual
conflict with the campaign base. These observations are not a whole-stack integration
verdict.

Round 15 context refresh: main `86402bfaff605bc6c27270697d6fc4bd1ef5e651` has no changed
path in the bounded 42-path Store/direct-consumer scope since the common ancestor;
`merge-tree` reports no textual conflict with the extraction parent. All 24 existing
stack heads/bases are unchanged. The 83-open-PR census, including all changed-file
pages, has no direct extraction/test overlap. Exact external TUI hunks at #43518
(`18c8f25b7103a8ae17cb69d8b3b2561c087666a4`) and #43504
(`5652cbe9f13fec8b58aa4f2499e7cc4ee78e138f`) change keeper preparation/execution-scope
fields; their Store collaboration decoder blocks remain byte-identical. This is bounded
source/context evidence, not clearance of all transitive changes or either complete
external PR.

### S1

**Extract the provider usage acceptance/revocation reducer from the shared observation store**

Source:
[lib/runtime/runtime_provider_usage_window.ml:858](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/runtime/runtime_provider_usage_window.ml#L858-L1008).

Problem: record intertwines complete-versus-sparse report policy, per-source snapshot
watermarks, per-window freshness, accepted-report filtering, nested mutable hash tables
and the durable observer callback. The public values are immutable, but the
authoritative transition remains an in-place algorithm inside the mutex, so policy
cannot be reviewed independently of publication and callback behavior.

Change: Introduce a private immutable per-scope state with ordered maps keyed by
(limit_id, window_kind) and source. A pure reduce ~observed_at report state returns the
next state and the exact accepted report option. Keep the scope table/mutex, clock
initialization, observer invocation, cancellation propagation and sink diagnostics in
the effect boundary. Do not combine this first slice with provider wire decoder
rewrites.

Preserve:

- Empty sparse reports change nothing and do not notify the sink.
- A complete report revokes only older omitted windows owned by that same source.
- Equal/older window timestamps cannot replace a held observation, and a source snapshot
  watermark prevents old omitted windows returning.
- An empty complete report remains a reported_no_windows observation with its source and timestamp.
- The observer receives only the accepted report and runs after the lock is released;
  observer failure does not roll back the live observation.
- state ordering remains limit_id then the existing kind comparator; recorded scopes
  include complete empty reports.

Consumers:
[lib/runtime/runtime_provider_usage_read.ml](../../../lib/runtime/runtime_provider_usage_read.ml),
[lib/keeper/keeper_claude_code_runtime.ml](../../../lib/keeper/keeper_claude_code_runtime.ml),
[lib/keeper/keeper_codex_runtime.ml](../../../lib/keeper/keeper_codex_runtime.ml),
[lib/server/server_dashboard_runtime_resolved_json.ml](../../../lib/server/server_dashboard_runtime_resolved_json.ml),
[lib/server/server_provider_usage_history.ml](../../../lib/server/server_provider_usage_history.ml).

Scenarios:
[test/test_provider_usage_snapshots.ml](../../../test/test_provider_usage_snapshots.ml),
[test/test_provider_usage_windows.ml](../../../test/test_provider_usage_windows.ml),
[test/test_provider_usage_history_snapshots.ml](../../../test/test_provider_usage_history_snapshots.ml).
The live-window suites remain unexecuted; the history suite passed its seven cases at
the combined head recorded in [S8](#s8). This does not establish execution of the added
S1 live-store scenarios.

Ordering rationale: A bounded immutable functional-core extraction with existing
account-lifecycle scenarios: removed cap, complete empty report, disabled bucket and
sparse Codex update. The durable sink and source watermark rules make it substantive;
replacing every process-wide table is unnecessary.

### S2

**Move lane edit decisions into a pure declared-configuration planner**

Source:
[lib/runtime/runtime.ml:3267](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/runtime/runtime.ml#L3267-L3729),
[lib/runtime/runtime_config_text.ml:408](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/runtime/runtime_config_text.ml#L408-L437).

Problem: The lock/read/parse/commit wrapper is already identifiable, but
conversation-lane create/rename/remove and exact-lane append/drop/move/replace decisions
still occupy runtime.ml alongside persistence. Declaration validation, reference
rewriting and slot placement are nested in effectful entrypoints, increasing the context
needed to verify a single edit.

Change: Extract private planning functions over the freshly loaded source text and
Runtime_schema.config. Return edited text or a closed lane-edit error; retain public API
wrappers, CAS source-revision checks, lock warnings, whole-file validation and durable
commit in runtime.ml. Treat conversation-lane reference edits and exact-output slot
edits as separate work units if needed.

Preserve:

- Read declarations under the writer lock; never reconstruct edit inputs from the
  filtered/admitted runtime catalog.
- Rename the lane table, keeper assignments, runtime default and Fusion seat references
  together in one validated write.
- Preserve rejected-but-declared slots, declaration order and slots written by another
  writer before lock acquisition.
- Keep HTTP/catalog slots separate from CLI slots, prevent duplicate membership, and
  refuse removing the final exact-lane slot.
- Preserve inline/dotted-table refusal semantics and every existing source-revision
  conflict/lock-warning distinction.
- Do not move parse or reads outside the write transaction merely to make the planner appear pure.

Design refresh at `01168475d83c920242df72fa0bd549f6c798cf2a`: retain malformed-input and
same-name-rename refusal before path resolution or lock acquisition. Every
declaration-dependent plan still runs on the just-read content/config pair under the
existing lock. A private prepared edit can encode validated inputs; do not duplicate raw
and prepared operation variants or add a generic transaction framework.

Keep `set_runtime_lane_candidates` as its separate typed CAS transaction. The exact-slot
format classifier must remain one definition shared by planning, first-run setup and the
public resolved projection. Existing public `Runtime_config_text` helpers and
route-reference types remain stable. Replacement currently classifies
current/replacement groups before editable-table and duplicate checks; preserve that
refusal precedence. The public move documentation should clarify that already-first
promotion is refused without changing order, matching current implementation and
scenario source.

Implemented in [#43469](https://github.com/jeong-sik/masc/pull/43469), code head
`d75ced3b0b74dc0cf4badbbf559b853bb778e3e5`, against adopted remote parent
`c07048b5af0641bcc53d2c7b9b93da17bef506c6`. Private `Runtime_lane_edit` owns validated
abstract edits, pure plans and closed errors. Runtime keeps path resolution, the writer
lock, fresh reads, whole-file validation and commit; its separate typed CAS writer is
byte-identical. The shared slot classifier remains one definition, and public
declarations remain stable.

The new scenario source combines dotted Keeper assignment, default and all Fusion seat
kinds in one real-file rename; waits on the real config lock before an intervening
writer changes declarations; and checks CLI replacement plus
duplicate/cross-group/no-schema refusal. The intervening fixture performs a direct
closed file write under that lock, not the complete durable commit protocol. These
scenarios are registered but unexecuted.

Independent source review passed for all seven changed files and the relevant consumers.
After adopting the externally restacked parent, the full implementation diff and result
blobs remained identical; the reviewer checked changed adjacent dependencies and carried
the source verdict. Six changed OCaml files passed syntax parsing before adoption. No
typecheck, build, test execution, formal GitHub approval, merge or runtime proof is
claimed.

Consumers:
[lib/server/server_routes_http_routes_dashboard.ml](../../../lib/server/server_routes_http_routes_dashboard.ml),
[lib/runtime/runtime_config_text.ml](../../../lib/runtime/runtime_config_text.ml),
[lib/runtime/runtime.mli](../../../lib/runtime/runtime.mli).

Scenarios: [test/test_fusion_config_edit.ml](../../../test/test_fusion_config_edit.ml),
[test/test_runtime_per_keeper_routing.ml](../../../test/test_runtime_per_keeper_routing.ml),
[test/test_exact_output_catalog_precedence.ml](../../../test/test_exact_output_catalog_precedence.ml).
**Not executed in this audit.**

Ordering rationale: The source explicitly documents previous lost-slot and
partial-rename failures, and tests exercise real persisted TOML plus resolution. This
refresh confirms the boundary remains at this baseline; existing edit_runtime_lanes
should be retained as the effect shell.

### S3

**Separate Antigravity protocol transitions from persistence and stream callbacks**

Source:
[lib/runtime/runtime_antigravity.ml:679](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/runtime/runtime_antigravity.ml#L679-L923),
[lib/runtime/runtime_antigravity.ml:1000](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/runtime/runtime_antigravity.ml#L1000-L1060).

Problem: protocol_state combines optional init/result products, while apply_event
validates protocol order, computes immutable next state, persists conversation readiness
and emits stream events in one function. The mutable driver ref is an appropriate
effect-boundary holder; the difficult part is that transition semantics and callbacks
are inseparable.

Change: Extract a private protocol core with explicit awaiting/admitted/completed phases
and a transition result describing next state, ordered stream events and any admission
persistence requirement. The runtime shell executes the readiness callback first and
publishes/emits only after it succeeds. Keep process spawning, timeout/read-phase
execution, stderr redaction and exceptions in runtime_antigravity.ml.

Preserve:

- Readiness persistence succeeds before Turn_started is emitted or admitted state is published.
- Duplicate init/result and post-result steps remain errors; a pre-init provider error
  retains its provider refusal.
- Reserved cancellation, operator interruption and timeout exceptions retain their
  current treatment.
- Identical closed-step replays emit nothing; conflicting late content remains a protocol failure.
- Text deltas and Text_completed ordering stay exact; terminal repeated response does
  not duplicate already streamed content.
- Failed turns still report usage, and active tool steps retain the existing read-phase distinction.

Consumers:
[lib/keeper/keeper_antigravity_runtime.ml](../../../lib/keeper/keeper_antigravity_runtime.ml),
[lib/fusion/fusion_official_client.ml](../../../lib/fusion/fusion_official_client.ml),
[lib/runtime/runtime_verification_antigravity.ml](../../../lib/runtime/runtime_verification_antigravity.ml).

Scenarios:
[test/test_runtime_antigravity.ml](../../../test/test_runtime_antigravity.ml),
[test/test_keeper_antigravity_runtime.ml](../../../test/test_keeper_antigravity_runtime.ml).
**Not executed in this audit.**

Ordering rationale: Existing fixture scenarios verify callback ordering, failed
callbacks, step identity and streaming continuity. This is a real type/effect boundary
improvement, but callback sequencing makes it riskier than S1/S2 and unsuitable for a
mechanical split.

### S4

**Make provider-metrics cache refresh ownership explicit and cancellation-complete**

Source:
[lib/server/server_routes_http_routes_provider_runs.ml:7](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/server/server_routes_http_routes_provider_runs.ml#L7-L31),
[lib/server/server_routes_http_routes_provider_runs.ml:94](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/server/server_routes_http_routes_provider_runs.ml#L94-L188).

Problem: A cache entry independently mutates value, updated_at, in_flight and
last_error. The refresh path re-raises Eio.Cancel.Cancelled before reaching the
in_flight reset, while acquisition sets in_flight before starting or forking the worker.
Whether cancellation or fork failure leaves a reusable entry permanently marked
refreshing needs a concrete scenario; no live failure is claimed.

Change: First reproduce cancellation/fork-failure ownership cleanup through the existing
cached_json test surface. Then use a closed idle/refreshing state with an exact worker
token and immutable last-good payload/error metadata; centralize
acquire/completion/cancellation transitions and keep the mutex, table eviction, executor
pool and HTTP serialization at the edge. A stale worker must not clear a replacement
owner's refresh.

Preserve:

- Fresh reads do not recompute; stale reads return last-good data while one refresh owns the key.
- Refresh failure preserves payload and its original freshness timestamp.
- Cancellation propagates after releasing only the worker's own ownership.
- sync_first on cold entries keeps its current behavior.
- Configured resource-bounded eviction stays intact; a completed evicted worker cannot
  resurrect an old cache entry.
- Provider history errors remain redacted at the public response boundary.

Consumers:
[lib/server/server_routes_http_routes_provider_runs.ml](../../../lib/server/server_routes_http_routes_provider_runs.ml).

Scenarios:
[test/test_model_inference_metrics.ml](../../../test/test_model_inference_metrics.ml).
**Not executed in this audit.**

Ordering rationale: test_metrics_cache_retains_last_good already exercises
failure/recovery through this exact cache, but does not establish cancellation cleanup.
This file is outside active PR 43355's HTTP/TUI transport files; do not use unrelated
dashboard cache tests as proof for this implementation.

### S5

**Consolidate full-health refresh bookkeeping into an immutable owned state machine**

Source:
[lib/server/server_routes_http_runtime.ml:693](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/server/server_routes_http_runtime.ml#L693-L734),
[lib/server/server_routes_http_runtime.ml:974](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/server/server_routes_http_runtime.ml#L974-L1180),
[lib/server/server_routes_http_runtime.ml:1310](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/server/server_routes_http_runtime.ml#L1310-L1337).

Problem: The full-health refresher's snapshot, in-flight flag, started time, request
flag, invalidation generation, active worker, counters and per-worker failure flag live
in separate refs/fields. A mutex serializes access, but readers must assemble an
eight-element tuple and each transition manually maintains correlated state.

Change: Introduce a private immutable refresh state and typed Idle/Running ownership
with worker identity/generation. Pure transitions take observed time,
completion/failure/invalidation events and return state plus explicit wake/metric
decisions. Keep Eio promises, stream signaling, fiber creation, locks, logs and metrics
execution in the shell.

Preserve:

- One active worker is shared by waiters and survives cancellation of an individual waiter.
- A result computed before an invalidation cannot be published as current; schedule the
  existing follow-up.
- Last-good payload time and first failure time remain distinct across repeated failures.
- An active worker's timeout is reported once without pretending the worker stopped.
- No lost wake on invalidation and no unbounded invalidation queue.
- Existing monitoring thresholds, timeout policies and serialized public fields remain
  unchanged in the refactor.

Consumers:
[lib/server/server_routes_http_runtime.ml](../../../lib/server/server_routes_http_runtime.ml),
[lib/server/server_dashboard_http_execution_surfaces.ml](../../../lib/server/server_dashboard_http_execution_surfaces.ml).

Scenarios:
[test/test_server_runtime_bootstrap.ml](../../../test/test_server_runtime_bootstrap.ml).
**Not executed in this audit.**

Ordering rationale: The existing tests include worker survival after waiter
cancellation, dirty-generation rejection and last-snapshot preservation. Mutation is
necessary for publication and resource ownership; the target is correlated state spread,
not removal of synchronization.

### S6

**Give connector status a common typed projection before JSON aggregation**

Source:
[lib/gate/channel_gate_connector.ml:10](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/gate/channel_gate_connector.ml#L10-L47),
[lib/gate/channel_gate_connector.ml:70](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/gate/channel_gate_connector.ml#L70-L94),
[lib/gate/channel_gate_slack_state.ml:153](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/gate/channel_gate_slack_state.ml#L153-L278),
[lib/tui_decode_connectors.ml:50](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/tui_decode_connectors.ml#L50-L95),
[lib/tui_decode_connectors.ml:135](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/tui_decode_connectors.ml#L135-L159).

Problem: The connector module interface returns arbitrary JSON snapshots.
connectors_json immediately reads available back out with a false default to count
active connectors. Transport implementations already hold typed status internally, but
the TUI stores available, connected, raw status and a separately decoded connection
variant, repeating a consistency relationship across boundaries.

Change: Define a small common typed descriptor/status projection at the connector
boundary and serialize it once for HTTP. Preserve transport-specific details through
explicit typed variants or a clearly separate extension payload. Compute active_count
from typed availability; have the TUI decoder construct the common connection state once
and derive redundant flags/text where consumers permit.

Preserve:

- Transport connected and connector available are independent: connected-but-unavailable
  remains representable.
- Stale/disconnected/offline meanings and existing wire field names remain unchanged.
- Binding-store failure remains visible and must not appear as an empty successful binding list.
- One malformed connector row is refused with its identity/position while valid rows
  remain available.
- Preserve the existing absent-flag decode contract during extraction; any strictness
  change is a separate behavior decision.
- Keep names and durable paths behind the existing authenticated directory boundary.

Consumers:
[lib/server/server_routes_http_routes_channel_gate.ml](../../../lib/server/server_routes_http_routes_channel_gate.ml),
[lib/tui_decode_connectors.ml](../../../lib/tui_decode_connectors.ml),
[bin/masc_tui_loader.ml](../../../bin/masc_tui_loader.ml),
[bin/masc_tui_connector_unbind.ml](../../../bin/masc_tui_connector_unbind.ml).

Scenarios:
[test/test_channel_gate_connector_routes.ml](../../../test/test_channel_gate_connector_routes.ml),
[test/test_tui_decode.ml](../../../test/test_tui_decode.ml),
[test/test_tui_connector_unbind.ml](../../../test/test_tui_connector_unbind.ml). **Not
executed in this audit.**

Ordering rationale: This follows a concrete typed-data-to-JSON-to-data round trip and
duplicated state proof obligation. Start with common
availability/connection/binding-read fields rather than inventing a universal connector
framework; test requests/decoded decisions, not TUI labels or layouts.

### S7

**Replace connector ingress scheduling flag combinations with explicit lane lifecycle**

Source:
[lib/gate/connector_ingress_lane.ml:21](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/gate/connector_ingress_lane.ml#L21-L40),
[lib/gate/connector_ingress_lane.ml:91](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/gate/connector_ingress_lane.ml#L91-L161),
[lib/gate/connector_ingress_lane.ml:181](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/gate/connector_ingress_lane.ml#L181-L213).

Problem: Each lane stores independent mutable scheduled and active booleans alongside
its mutable FIFO. submit, take_ready_lane, take_lane_job and close must preserve the
relationship between queue membership and these flags, including combinations the type
permits but scheduling does not use.

Change: Replace the flag product with a closed Scheduled/Running lane state (and only an
explicit idle state if genuinely required). Factor locked
acceptance/dispatch/completion/close decisions so they return explicit
notification/start/failure work; keep Queue, Eio condition/fibers, callback execution
and the mutex as owned effectful resources. Do not replace a working FIFO merely to
eliminate every mutable data structure.

Preserve:

- FIFO is preserved per Keeper lane, while independent lanes may progress concurrently.
- Exactly one worker owns a lane; submitting to an active or already scheduled lane does
  not schedule another.
- Every accepted event is executed or reported once through on_failure before owner release.
- Owner_unavailable means no callback was enqueued.
- Callback cancellation is reported under cancellation protection and then re-raised.
- Slack/Discord durable acceptance still precedes delivery handoff.

Consumers:
[lib/server/server_slack_in_process_gateway.ml](../../../lib/server/server_slack_in_process_gateway.ml),
[lib/server/server_discord_in_process_gateway.ml](../../../lib/server/server_discord_in_process_gateway.ml).

Scenarios:
[test/test_server_slack_trigger_policy.ml](../../../test/test_server_slack_trigger_policy.ml),
[test/test_server_discord_trigger_policy.ml](../../../test/test_server_discord_trigger_policy.ml).
**Not executed in this audit.**

Ordering rationale: A narrow closed-state refactor removes invalid combinations without
challenging legitimate mutable queue ownership. Existing connector-path tests verify
durable accept and exact event identity; add FIFO/owner-release scenarios only where
direct behavioral coverage is absent.

### S8

**Separate durable provider-history decoding and daily projection from journal IO**

Design inspection revision: `c5337092c70bc5cf6a615f481684810db40a7116`. Implemented in
[#43489](https://github.com/jeong-sik/masc/pull/43489), code head
`07ceeeb4719cfe44d39cf9af5ed0e72acf2b5000` against
`733b2f86675e9dc09a898dd3e20d2cee2f4617ec`. Independent source review passed the
complete five-file implementation and its consumers; four changed OCaml files passed
syntax parsing. The later focused CI result below applies to the combined head
containing the S1 declaration repair; formal GitHub approval, merge and runtime/UI proof
remain separate.

Source:
[accepted-report encoding](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/server/server_provider_usage_history.ml#L13-L47),
[durable item codec](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/server/server_provider_usage_history.ml#L68-L154),
[journal/diagnostic shell](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/server/server_provider_usage_history.ml#L156-L238),
[daily projection](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/server/server_provider_usage_history.ml#L240-L291).
Keep the
[public API](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/server/server_provider_usage_history.mli#L1-L34)
stable.

Problem: The reader interleaves item decoding, source/day replacement, cross-source
display selection, empty-day reporting and diagnostics inside the journal callback. Four
local tables and a counter obscure the two different key spaces. The live observation
reducer has a different revocation horizon and must remain separate.

Implemented boundary: Private `Server_provider_usage_history_projection` owns the codec
and daily projection. It owns closed point/complete-snapshot items and an abstract
immutable accumulator, with operations to consume one item, record an unreadable item
and produce the final response. A source/day key contains scope, source and UTC
observation day; its window map uses kind and optional limit ID. Final display keys omit
source but retain scope, kind, limit ID and day. Derive display winners only after
source revocation. Reuse the existing UTC helper and canonical scope digest; do not add
a second calendar, date identity or provider schema. Keep one local accumulator ref
adapting the unit-returning journal callback rather than changing the shared storage API
to eliminate it.

Preserve:

- Physical file selection follows append-time UTC dates; filtering and daily identity
  follow each item's observation time. Fully decode selected items before filtering to
  the inclusive observation window, so malformed old/future items still count while
  valid out-of-window items do not.
- A complete snapshot revokes strictly older rows only within its source and UTC day.
  Sparse rows retain omitted windows. Equal timestamps within a source keep the first
  encountered item; display ties across sources choose the lexicographically greatest
  source. Preserve final point and empty-report ordering.
- Successful empty reports differ from numeric zero and missing days. An empty marker
  produces no empty-day claim while any source has a surviving display point. Preserve
  optional historical marker state, source-specific aliases, accepted unknown nonempty
  source/kind strings and current numeric/error precedence; no clamping is bundled. This
  bounded extraction preserves existing alias and absent-marker-state decoding; changing
  those stored-history semantics is outside it. No compatibility policy or exception to
  the constitution is introduced.
- Encode only the accepted report: complete marker first, then windows in accepted
  order; sparse reports have no marker. Do not reread the live table or restore rejected
  windows.
- Keep immediate diagnostic order: warn before incrementing unreadable count, process
  list items in order, retain valid neighbors, and continue after malformed rows. Do not
  defer warnings until finalization or discard a complete line because one item is
  invalid. Whole-store failure still logs and returns Error rather than partial history.
- Check the latest observer failure once at read entry, retain its observation timestamp
  semantics, and preserve cancellation escape. Dated_jsonl keeps append locks, channels,
  path clocks and retention; observer/live-state and route-cache ownership are
  unchanged. A successful later append does not by itself clear the recorded observer
  failure.

Producers:
[observer installation](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/server/server_bootstrap_maintenance.ml#L423-L441),
[provider read publication](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/runtime/runtime_provider_usage_read.ml#L73-L91),
[Muse report publication](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/runtime/runtime_muse_usage.ml#L1-L68),
and the
[accepted-report observer boundary](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/runtime/runtime_provider_usage_window.ml#L1011-L1077).
The implementation rechecked this boundary at its campaign parent: S1 captures the
accepted report and immutable next observations together under the mutex, derives
source-owned quota rest after unlock, then invokes the observer. S8 does not change that
owner.

Consumers and cache limits: the
[HTTP cache owner](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/server/server_routes_http_routes_provider_runs.ml#L53-L198)
and
[history route](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/server/server_routes_http_routes_provider_runs.ml#L325-L372)
retain their existing policy. Cold requests return loading while refresh is scheduled. A
History.read Error is converted into an unavailable JSON payload and cached as a
successful computation, replacing prior history; this is different from a generic
compute Error retaining a prior value. The
[TUI loader](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/bin/masc_tui_loader.ml#L979-L1001)
checks cache error/loading/unavailable before
[typed decoding](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/tui_decode_usage.ml#L172-L235).
Existing generic cache cancellation can escape before in-flight cleanup; that belongs to
S4 and is not repaired or certified by S8. No HTTP/cache/UI behavior is established by
direct decoder scenarios.

Existing scenarios:
[test/test_provider_usage_history_snapshots.ml:1](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/test/test_provider_usage_history_snapshots.ml#L1-L173)
covers the real observer → JSONL → History.read → typed decoder path, source overlap,
empty-day recovery and delayed rows. **Executed at the combined head recorded below.**
Correction:
[test/test_model_inference_metrics.ml:1728](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/test/test_model_inference_metrics.ml#L1728-L1760)
concerns runtime decision/cost history and is removed as direct S8 scenario evidence.
Static overview payloads and store-retention tests are adjacent context, not substitutes
for this journal consumer.

Added scenario: The seventh actual-file case in
`test_provider_usage_history_snapshots.ml` writes valid items on both sides of a
schema-invalid out-of-window item, malformed physical JSON, a parsed non-list row and a
later real complete report. It checks three unreadable records through the typed
decoder, four surviving observations across distinct UTC days, exact neighbor
percentages and later uncapped USD, with no invented empty day. Valid old/future items
are filtered. The scenario passed in the focused run below; it adds no production
injection hook or screen/layout assertion.

Ordering rationale: A small private module exposes the existing streamed reduction while
retaining one adapter ref and every I/O owner. The six existing scenarios all expect
zero unreadable records; the added case targets the changed decoder/reducer through the
real journal. Concurrent append snapshot consistency, full provider codecs, cache
cancellation and visible UI remain outside this scope.

Focused execution observed in Round 11:
[run 38986241160](https://github.com/jeong-sik/masc/actions/runs/38986241160), exact
head `0190a7bea54f85aee77107c89092e6a4adcc1fb1`,
`suite=test_provider_usage_history_snapshots`, `minimal=true`, completed successfully.
The actual log records all seven cases passing, including damaged-journal case 0. This
is focused suite evidence for that combined head, not full CI or a build result for the
unchanged lower S8/S1 commits.

### R1

**Credential batch ownership projection**

Source:
[lib/auth/auth.ml:106](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/auth/auth.ml#L106-L164).

Problem: Batch credential repair keeps mutable token and name indexes alongside a
separately threaded ownership list. Success updates three representations; failure
rereads authority then clears and reconstructs two tables. The admission-time
shared-token set has different semantics from the refreshed ownership snapshot.

Change: Model admitted shared-token evidence and current ownership as distinct immutable
values; return an updated token/name projection from one pure operation, while retaining
transaction, reread and credential minting effects at the edge.

Preserve:

- Admission-time shared bearers remain rejected after earlier repairs.
- Every failed write rereads authoritative storage before continuing.
- Identity redirects, token hashing and ownership conflicts remain unchanged.
- Never emit credential/token values in diagnostics or evidence.

Consumers:
[lib/server/server_runtime_startup_credentials.ml](../../../lib/server/server_runtime_startup_credentials.ml).

Scenarios:
[test/test_auth_token_rotation_transaction.ml](../../../test/test_auth_token_rotation_transaction.ml),
[test/test_auth_file_backed_transaction.ml](../../../test/test_auth_file_backed_transaction.ml).
**Not executed in this audit.**

Ordering rationale: Clear duplicated-state obligation with existing batch-failure
scenarios; security-sensitive transaction behavior needs an isolated source review and
focused execution before release.

### R2

**Fusion decision event ownership**

Source:
[lib/fusion/fusion_decision.ml:58](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/lib/fusion/fusion_decision.ml#L58-L186).

Problem: validate_event returns raw JSON after validating the decision; read,
idempotency and consumer paths inspect the same field names again. Domain authority and
serialization remain coupled to generic JSON field access.

Change: Introduce a private typed decision event with a strict codec; derive
identity/idempotency checks from typed fields and encode only at event-journal/dashboard
boundaries. Keep journal traversal, task/goal authority, locks and append effects in the
store.

Preserve:

- A decision must refer to the exact requesting Task and owned Fusion evidence.
- Conflicting same-turn writes remain rejected; identical writes remain idempotent.
- Malformed authoritative history prevents a guessed mutation.
- Source visibility and the existing public JSON contract remain unchanged.

Consumers:
[lib/verification_collaboration_evidence.ml](../../../lib/verification_collaboration_evidence.ml),
[lib/keeper/keeper_tool_runtime.ml](../../../lib/keeper/keeper_tool_runtime.ml),
[lib/server/server_routes_http_routes_dashboard.ml](../../../lib/server/server_routes_http_routes_dashboard.ml).

Scenarios: [test/test_fusion_decision.ml](../../../test/test_fusion_decision.ml),
[test/test_verification_collaboration_evidence.ml](../../../test/test_verification_collaboration_evidence.ml).
**Not executed in this audit.**

Ordering rationale: Repeated JSON reinspection crosses an authority boundary; a typed
event would concentrate contract maintenance without changing its security policy.

### A1

**Separate stream error projection from optional refused-frame diagnostic I/O**

Source:
[packages/agent_core/lib/llm_provider/complete_stream_error.ml:8](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/packages/agent_core/lib/llm_provider/complete_stream_error.ml#L8-L70),
[packages/agent_core/lib/llm_provider/complete_stream_error.ml:221](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/packages/agent_core/lib/llm_provider/complete_stream_error.ml#L221-L356),
[packages/agent_core/lib/llm_provider/complete_stream_error.mli:31](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/packages/agent_core/lib/llm_provider/complete_stream_error.mli#L31-L40),
[packages/agent_core/lib/llm_provider/complete_stream.ml:1145](https://github.com/jeong-sik/masc/blob/aea8424926ea79f110315eec5ab429ac51043598/packages/agent_core/lib/llm_provider/complete_stream.ml#L1145-L1191).

Problem: http_error_of_stream_error appears as a typed conversion in its signature, but
the two malformed-frame arms call dump_refused_frame, which reads MASC_WIRE_PARSE_DUMP
and opens/appends/closes a file. Reviewing or reusing error policy therefore also
requires knowing process environment and diagnostic ownership. Inline projection
assertions can reach this effect when the variable is set. This is a
maintainability/effect-boundary candidate, not evidence of an observed runtime bug or a
security defect.

Change: Make the error projection return its typed HTTP failure together with an
optional narrowly typed refused-frame diagnostic description. Keep redaction/formatting
shared, and execute the optional dump explicitly at the existing stream finalization
effect edge exactly once. Keep the diagnostic carrier private where possible. Update the
direct diagnostic test to exercise the explicit sink boundary. Do not add another
environment knob, provider-specific retry policy or generic effect abstraction.

Preserve:

- Keep every current HTTP error constructor, wire format, diagnostic message and
  provider-status distinction: only declared 429/5xx provider conditions become
  HttpError; unstated errored choices remain Provider_interrupted.
- Keep MASC_WIRE_PARSE_DUMP optional and disabled for absent/empty values; preserve
  full-frame diagnostic payload rather than truncating it to the log excerpt.
- Redact before writing the full dump and before bounding the 256-byte message excerpt;
  retain original byte count and verbatim=true/false so offset evidence stays honest.
- Preserve 0600 creation mode, append behavior, escaped row layout and Sys_error
  noninterference. Preserve the existing exception policy rather than widening swallowed
  failures.
- The production finalization path emits a missing failure event before projection/dump
  and publishes its terminal summary afterwards; retain this order and do not duplicate
  the diagnostic write.
- Do not import coordinator configuration into Agent Core; its diagnostic sink currently
  reads the environment locally to preserve dependency direction.

Consumers:
[packages/agent_core/lib/llm_provider/complete_stream.ml](../../../packages/agent_core/lib/llm_provider/complete_stream.ml),
[packages/agent_core/test/test_complete_http.ml](../../../packages/agent_core/test/test_complete_http.ml).

Scenarios:
[packages/agent_core/test/test_complete_http.ml](../../../packages/agent_core/test/test_complete_http.ml),
[packages/agent_core/lib/llm_provider/complete_stream_error.ml](../../../packages/agent_core/lib/llm_provider/complete_stream_error.ml).
**Not executed in this audit.**

Implementation: [#43386](https://github.com/jeong-sik/masc/pull/43386) adds a pure typed
projection and a separate private diagnostic sink. The existing HTTP streaming suite now
covers malformed SSE/NDJSON with absent/empty settings, full-frame append, redaction,
restrictive creation permissions and directory destination failure. It asserts the typed
result and failure-event/append/terminal-summary order. The obsolete direct-converter
diagnostic suite is removed. Six changed OCaml files passed syntax parsing; scenarios
remain unexecuted.

Ordering rationale: One production caller and an existing diagnostic scenario bound the
change. The new boundary makes error policy review independent of file effects while
preserving operator evidence; priority is based on the hidden effect, not file length.

Implementation-scope correction: `complete_stream_error` was already listed in Dune
`private_modules`; it has no public facade alias. The actual production caller is the
stream finalizer. Its inline assertions keep a pure error-only wrapper; the old
standalone diagnostic suite moves to the public HTTP streaming scenario suite. Public
`Complete` interfaces remain unchanged.

### T1

**Give Board post completion an explicit dispatch and commit outcome**

Inspection revision: `857c8647ce7cc7305d6aa081d1aa24ac5b93f05e`. This follows the merged
TUI I/O work; it is not a regression attribution to #43355.

Source:
[bin/masc_tui_board_requests.ml:27](https://github.com/jeong-sik/masc/blob/857c8647ce7cc7305d6aa081d1aa24ac5b93f05e/bin/masc_tui_board_requests.ml#L27-L67),
[bin/masc_tui_http.ml:2506](https://github.com/jeong-sik/masc/blob/857c8647ce7cc7305d6aa081d1aa24ac5b93f05e/bin/masc_tui_http.ml#L2506-L2541),
[bin/masc_tui_board_updates.ml:94](https://github.com/jeong-sik/masc/blob/857c8647ce7cc7305d6aa081d1aa24ac5b93f05e/bin/masc_tui_board_updates.ml#L94-L137),
[bin/masc_tui_async_protocol.ml:476](https://github.com/jeong-sik/masc/blob/857c8647ce7cc7305d6aa081d1aa24ac5b93f05e/bin/masc_tui_async_protocol.ml#L476-L481),
[lib/server/server_routes_http_routes_activity.ml:1293](https://github.com/jeong-sik/masc/blob/857c8647ce7cc7305d6aa081d1aa24ac5b93f05e/lib/server/server_routes_http_routes_activity.ml#L1293-L1331),
[lib/board/board_core_persist.ml:685](https://github.com/jeong-sik/masc/blob/857c8647ce7cc7305d6aa081d1aa24ac5b93f05e/lib/board/board_core_persist.ml#L685-L738).

Problem: A file-read/upload failure before masc_board_post is definitely not dispatched,
while a lost connection or unreadable response after the POST may follow a committed
post. Both reach new_post_done as Error string. The completion clears
board_post_inflight and the composer allows a new send. Because ordinary create_post
generates a fresh ID, manually resending a committed-but-unanswered post can create
another post. Source establishes the information loss and resend path; this audit did
not reproduce a live duplicate.

Change: First establish the Board route commit receipt contract, then introduce a small
closed Board-write outcome carried through the existing request, async protocol and
update owners: not dispatched, acknowledged, refused where proven, and outcome unknown.
Keep the existing IO-domain transport and attachment sequencer. Preserve effect
knowledge at the HTTP/tool-envelope boundary and use a pure completion decision for
draft/attachment retention plus reconciliation intent. This is a behavior
correction/design investigation, not a mechanically behavior-preserving extraction.

Preserve:

- A failure reading or uploading a staged file must prevent the Board POST; earlier
  content-addressed uploads do not establish that a post was sent.
- Uploads remain ordered; the first upload failure stops subsequent attachments and the post.
- Workspace authority is captured at dispatch; cancellation and Workspace_scoped
  admission continue to reject replies for withdrawn authority, including A to B to A.
- Cancellation after dispatch does not prove server rollback or authorize replay.
- A confirmed success clears only the exact sent draft when it remains unchanged and
  removes only the sent staged attachment objects; later edits and newly staged files
  survive.
- Unknown outcome must preserve the draft and sent payload identity; do not add an
  automatic retry, arbitrary timeout or heuristic title/body matching as commit proof.
- Do not classify every Board 4xx as definitely uncommitted until the route commit
  boundary proves that contract.
- Payload field order, auth refresh-on-401, expected_workspace binding, IO-domain
  ownership and upload byte limits remain intact.

Consumers:
[bin/masc_tui.ml](https://github.com/jeong-sik/masc/blob/857c8647ce7cc7305d6aa081d1aa24ac5b93f05e/bin/masc_tui.ml),
[lib/board_tool_adapter/board_tool_post.ml](https://github.com/jeong-sik/masc/blob/857c8647ce7cc7305d6aa081d1aa24ac5b93f05e/lib/board_tool_adapter/board_tool_post.ml),
[lib/board/board_dispatch.ml](https://github.com/jeong-sik/masc/blob/857c8647ce7cc7305d6aa081d1aa24ac5b93f05e/lib/board/board_dispatch.ml),
[lib/tui_decode.ml](https://github.com/jeong-sik/masc/blob/857c8647ce7cc7305d6aa081d1aa24ac5b93f05e/lib/tui_decode.ml),
[bin/masc_tui_http.ml](https://github.com/jeong-sik/masc/blob/857c8647ce7cc7305d6aa081d1aa24ac5b93f05e/bin/masc_tui_http.ml).

Scenarios:
[test/test_tui_board_attachments.ml](https://github.com/jeong-sik/masc/blob/857c8647ce7cc7305d6aa081d1aa24ac5b93f05e/test/test_tui_board_attachments.ml),
[test/test_tui_io_domain.ml](https://github.com/jeong-sik/masc/blob/857c8647ce7cc7305d6aa081d1aa24ac5b93f05e/test/test_tui_io_domain.ml).
**Not executed in this audit.** Existing attachment and cancellation scenarios do not
establish a Board commit receipt. Discovery only:
[test/test_tui_board_composer.ml](https://github.com/jeong-sik/masc/blob/857c8647ce7cc7305d6aa081d1aa24ac5b93f05e/test/test_tui_board_composer.ml)
was searched for test names and draft-related lines; its test bodies were not reviewed.

Proposed verification:

- The second staged file fails to upload: Only the preceding upload requests exist; no
  Board POST is sent; the draft and staged list remain.
- The server commits a new post, then the connection closes before the completion is
  decoded: A typed unknown outcome is retained with the original payload; no automatic
  second POST and no assertion that the first did not land.
- An exception occurs after Board_dispatch.create_post has committed: A route-level 400
  cannot silently turn that execution into a proven refusal; resolve the server receipt
  boundary before implementing the classifier.
- A successful acknowledgement arrives after the operator edited the draft or staged
  another file: Only sent attachment identities are removed and the changed draft
  remains.
- Workspace authority is withdrawn while the request is queued, in flight, or its
  completion is queued: Queued work remains cancellable; stale replies cannot mutate a
  successor workspace; a dispatched effect is not treated as undone.

Ordering rationale: The causal issue is lost commit knowledge at a real request-to-state
boundary, not the size of masc_tui.ml or the number of refs. Existing generic
post_outcome demonstrates the vocabulary but cannot safely be adopted unchanged: its
universal 4xx-to-refused rule is stronger than this Board route, whose catch-all 400 can
occur after tool execution.

Open contract questions: The current route exposes ok/message rather than a structured
post identifier. Complete post-commit failure behavior and reconciliation need
investigation. Comments and votes require their own persistence trace before expanding
this scope.

### E1

**Make token-budget state belong to one top-level parse while sharing it with nested substitutions**

Implemented in [#43534](https://github.com/jeong-sik/masc/pull/43534), code head
`c97931d1772d1af19cb9f6d251011284e5acc970` against
`0bef45a0ae2179fb1ea2036dbab05c1ca208b948`. Round 13 refreshed the complete lexer,
parser adapter, grammar and public parser tests. Their production source was unchanged
from observed main `fce61a52528dfced7b41d5f9f84cafcb8fd6ce3a`; the 74-open-PR census
found no overlap with the parser, its Dune declaration or the affected test. Source
links below retain the initial inspection revision.

Source:
[lib/exec/parser/bash_lexer.mll:13](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/exec/parser/bash_lexer.mll#L13-L50),
[lib/exec/parser/bash_lexer.mll:374](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/exec/parser/bash_lexer.mll#L374-L381),
[lib/exec/parser/bash.ml:203](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/exec/parser/bash.ml#L203-L230).

Problem: The public parse_string entry resets a module-global token counter; recursive
child parsing intentionally shares it. Ownership is encoded in a reset-and-call
convention instead of a value scoped to the invocation. A second concurrent top-level
parse would share/reset that mutable budget, but no real multi-domain production overlap
or observed refusal bypass is established by this audit. The hook is different: module
initialization creates an unset ref, each top-level parse installs the same parse_source
closure, and child calls parse_source directly without reinstall/reset. This is stable
recursive wiring, not demonstrated request-dependent hook swapping.

Implemented boundary: `Bash.parse_string` owns one local integer ref and a recursive
source parser that captures it. OCamllex entrypoints receive the counter and child
parser explicitly; heredoc readers receive only the counter, and balanced source-copying
scanners remain unchanged. Remove the global counter, reset/get helpers, mutable hook
and unset-hook sentinel. Keep useful local mutation and the unchanged Menhir grammar
rather than adding another context module or lock.

The canonical `Bash.parse_string` signature is unchanged. Generated lexer helper
arguments change; those modules remain exposed by the existing library configuration.
The repository caller census finds only `Bash.ml` using them, but external raw-module
consumers were not surveyed. The public interface comment now describes supported
command substitutions/quoted literal heredocs, variable refusal and the actual handled
failures; it no longer promises an uncaught-exception/depth guarantee absent from the
implementation.

Preserve:

- The existing 50,000 token/piece threshold and exact increment sites stay unchanged.
- Nested substitutions spend the same top-level token budget; only a fresh top-level
  call gets a fresh counter.
- Longest-match/source-order tie behavior, quote metadata, argv concatenation, heredoc
  source bytes and refusal precedence stay unchanged.
- Child refusal is returned unchanged; no broad exception defaulting.
- No implicit new size/depth/deadline limit and no new Eio yield point.
- Same-domain synchronous parsing currently has no Eio yield; do not claim a proven race
  from ref presence alone.

Consumers:
[lib/exec/command_gate/shell_command_gate.ml:308](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/exec/command_gate/shell_command_gate.ml#L308-L317),
[lib/keeper_tooling/shell_costume.ml:69](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/keeper_tooling/shell_costume.ml#L69-L74),
[lib/keeper/keeper_gate_readonly.ml:495](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/keeper/keeper_gate_readonly.ml#L495-L504),
[lib/exec_policy/exec_policy.ml:154](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/exec_policy/exec_policy.ml#L154-L165),
[lib/exec_policy/execute_script_paths.ml:207](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/exec_policy/execute_script_paths.ml#L207-L258),
[lib/keeper/keeper_sandbox_docker.ml:388](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/keeper/keeper_sandbox_docker.ml#L388-L427).

Consumer refinement: the three direct production callers are
`Shell_command_gate.decide_raw`, `Exec_policy.parse_string_to_ir`, and
`Execute_script_paths.script_destinations`; Shell_costume, readonly classification and
Docker validation wrap those boundaries. Some calls classify text rather than select its
execution model. No production concurrent overlap or bypass was reproduced.

Strengthened scenario:
[test_bash_parser.ml](https://github.com/jeong-sik/masc/blob/c97931d1772d1af19cb9f6d251011284e5acc970/lib/exec/test/test_bash_parser.ml)
replaces the old child-only overflow case, which could not distinguish shared
accounting. Parent 20,000 words and child 29,999 words each parse independently;
together with the substitution piece they reach 50,000 and must retain the complete
parent argv and exact nested child AST. One extra child word must return
`Parse_aborted Token_limit_50k` although that child still parses alone. A fresh nested
parse immediately afterward verifies recovery without depending on test-runner order.
This preserves existing behavior; it is not a reproduced defect or a concurrent-domain
test.

Validation: the two changed `.ml` files and `bash.mli` passed syntax parsing; local
lexer generation, typechecking, builds and tests were not run. Independent source review
passed the complete four-file change. Focused
[run 39002500571](https://github.com/jeong-sik/masc/actions/runs/39002500571), exact
code head `c97931d1772d1af19cb9f6d251011284e5acc970`, compiled and passed all four
targets with `minimal=true`: the complete parser suite (including the strengthened
shared-budget case), parser-to-dispatch substitutions, 19 gate/policy suite cases
(including typed-boundary cases) and 42 script-path cases. The gate suite reaches both
gate and policy parse adapters; the script-path suite reaches the third direct consumer.
Later documentation commits leave all four code/test blobs unchanged. The fixture-only
oracle and typed cwd validator are not substituted for these actual parser paths. This
is neither full regression nor production-concurrency evidence.

Ordering rationale: The
[OCamllex entrypoint contract](https://ocaml.org/manual/5.5/lexyacc.html) supports
additional arguments before the lexing buffer, including recursive entrypoint calls.
Keeping the counter local follows
[Jane Street's practical approach to purity and simple interfaces](https://blog.janestreet.com/effective-ml/).
The benefit is explicit invocation ownership, not a file-size reduction or an unproved
concurrency claim.

### E2

**Keep one typed original timeout budget and epoch through recursive substitution dispatch**

Implemented in [#43532](https://github.com/jeong-sik/masc/pull/43532), code head
`1bada8c2ac6c030d450cd2a2abd2f88117e4d91d` against
`65c68b5d02800cf14ab0c7195c18b62c36cf0718`. Round 12 refreshed the dispatcher and direct
process/adapter boundaries against observed main
`fce61a52528dfced7b41d5f9f84cafcb8fd6ce3a`: the relevant production source was identical
before this repair. The 70-open-PR census found no overlap with the dispatcher, its
interface, the substitution test or their Dune declarations. Historical source links
below retain the initial inspection revision.

Source:
[lib/exec/exec_dispatch.ml:393](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/exec/exec_dispatch.ml#L393-L396),
[lib/exec/exec_dispatch.ml:479](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/exec/exec_dispatch.ml#L479-L507),
[lib/exec/exec_dispatch.ml:706](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/exec/exec_dispatch.ml#L706-L746),
[lib/exec/exec_dispatch.ml:799](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/exec/exec_dispatch.ml#L799-L804),
[lib/exec/exec_dispatch.ml:1010](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/exec/exec_dispatch.ml#L1010-L1015),
[lib/exec/exec_dispatch.mli:34](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/exec/exec_dispatch.mli#L34-L47),
[lib/exec/exec_dispatch.mli:58](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/exec/exec_dispatch.mli#L58-L72).

Problem: The API promises one caller-owned timeout epoch across stages/substitutions. At
eval_substitutions:719, remaining_timeout computes original budget minus elapsed time;
:740-746 passes that reduced value plus unchanged started to child dispatch; a Simple
child at :497 subtracts elapsed from the same epoch again. With budget 10 and 3 seconds
already spent, the source arithmetic hands child 7 then computes about 4 at its Host
Process_eio call boundary. Pipeline fallback explicitly keeps the original budget with
started to avoid this double debit. The public typed-dispatch contract failure was
reproduced before applying the repair; no deployed incident is claimed.

Implemented boundary: An inline sealed `Invocation_timeout` module owns the immutable
original budget and epoch. Five mutually recursive workers carry its abstract value
unchanged; only existing remainder checks and Host process calls derive relative
seconds. The three public entrypoints retain their optional arguments and original
default-clock/variable-refusal order. `None` avoids remainder clock reads. Keep
`budget -. (now -. started)` exactly, including the existing non-finite/refusal
behavior; do not replace it with deadline addition, a new clock basis or a new timeout
policy. Injected Docker/MicroVM/SSH/Delegated runners retain their existing interfaces
without timeout arguments. No dependency or Dune change is needed for the private inline
boundary.

Preserve:

- None remains unlimited; this work concerns existing explicit caller-supplied timeouts only.
- Existing finite-positive process timeout validation, exhausted-budget status and
  diagnostic precedence stay stable.
- Child and parent share one original deadline; neither fresh budgets per stage nor
  repeated debit of already elapsed time.
- Env substitutions execute before argv substitutions in original order; stdout
  trimming/single argument and child exit semantics unchanged.
- Keep current wall-clock basis unless a separate intentional API change is approved; do
  not silently add monotonic or depth policies.
- Native pipelines keep live pipes/backpressure and callback ordering; cancellation
  continues to escape with resource cleanup.

Consumers:
[lib/exec/exec_dispatch.ml:1041](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/exec/exec_dispatch.ml#L1041-L1071),
[lib/keeper_tooling/execute_shell_ir.ml:73](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/keeper_tooling/execute_shell_ir.ml#L73-L102),
[lib/process/process_eio.ml:97](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/process/process_eio.ml#L97-L125),
[lib/process/process_eio.ml:1149](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/process/process_eio.ml#L1149-L1179).

Existing scenarios:
[lib/exec/test/test_shell_ir_subst_exec.ml](https://github.com/jeong-sik/masc/blob/1bada8c2ac6c030d450cd2a2abd2f88117e4d91d/lib/exec/test/test_shell_ir_subst_exec.ml)
retains the unlimited, exhausted-child, sequence deadline, native streaming, callback,
stdin and scope cases. The existing sequence observer only rejects a second timeout
above 0.15s, so it did not detect premature debit at an already elapsed entry. The
focused post-repair request additionally covers native Host pipeline, Host stdin,
delegated execution and injected Docker/native-fallback callback/redirect suites.
Injected runner tests do not prove a live Docker deployment.

Executed before repair:
[run 39001537440](https://github.com/jeong-sik/masc/actions/runs/39001537440), exact
test-only head `4d65016432b0b86902a6dac97bd1a77ab41fff5f`, compiled and ran the
substitution executable. With original budget 1024s and an epoch 768s earlier, its log
recorded 256.000000s remaining at entry and 255.998030s after dispatch. The parent
exited successfully but returned `<>` instead of `<argv-value>`, with the
exhausted-substitution diagnostic. This first argv assertion stopped the executable; the
environment/nested/successive vectors and later existing cases were not reached in that
run. The fixture observes actual Host output and clock values without sleeps, an
injected clock or a new observer.

Executed after repair:
[run 39001763188](https://github.com/jeong-sik/masc/actions/runs/39001763188), code head
`1bada8c2ac6c030d450cd2a2abd2f88117e4d91d`, compiled and passed all five explicitly
named suites with `minimal=true`. The identical substitution test blob passed argv,
environment and nested/successive output assertions with 255.996069s, 255.990105s and
255.995290s respectively still available after dispatch, then completed all existing
cases. Native Host pipeline, delegated, injected Docker/fallback and Host stdin suites
also reported OK. All three changed OCaml files passed syntax parsing; independent
source review found no actionable issue. Later documentation commits do not change
code/test blobs. This focused result does not establish full CI, formal approval, merge
or deployed behavior.

Reachability limit: Current Keeper Command/Argv lowering read here produces literal
Simple invoking shell/program. Parser-produced Subst is concretely executed by the
dedicated test and exported dispatcher supports it, but no in-repository production
entry that currently constructs and dispatches parsed Subst was established. Do not
generalize to all Keeper shell commands or claim deployed impact.

Ordering rationale: The reproduced failure came from mixing original budget and
already-reduced duration in identically typed float options. A private abstract type
makes that distinction explicit throughout recursion. This follows the
[OCaml module abstraction mechanism](https://ocaml.org/manual/5.5/moduleexamples.html)
and
[Jane Street's guidance on precise states and practical purity](https://blog.janestreet.com/effective-ml/),
while retaining the existing effectful process owner.

### M1

**Separate durable stream-media transitions from diagnostic output and final media persistence**

Inspection revision: `d3e01a8d75986ef32807d10d81c50dfa6d31bebf`. Priority: `later`; this
is a maintainability candidate, not an observed media-loss, concurrency or performance
defect.

Round 10 refinement in [#43517](https://github.com/jeong-sik/masc/pull/43517):
`0190a7bea54f85aee77107c89092e6a4adcc1fb1`; the accumulator and HTTP consumer are
unchanged from the inspection revision. The design below was implemented in
[#43526](https://github.com/jeong-sik/masc/pull/43526), code head
`4c4bbe042c428760f5d68537d7903f399d292198` against
`1985c5c662c3c85a46edad289ef3b53733d5b45e`. Independent source review passed the
complete seven-file change; five changed OCaml files passed syntax parsing. Focused run
[39000671109](https://github.com/jeong-sik/masc/actions/runs/39000671109) was requested
at final head `85c7f3714774d89f5e296c5568a21d5585329f08` with
`suite=test_keeper_stream_media_accum` and `minimal=true`. Round 12 inspection confirmed
the target compiled/linked and all 12 cases passed, including actual A/C files, absent
B, strict failed-request reload and exact delivery provenance. This is focused execution
at that head; full HTTP/provider/UI and logger-fault behavior remain unverified.

Source:
[lib/server/keeper_stream_media_accum.ml:13](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/server/keeper_stream_media_accum.ml#L13-L263),
[lib/server/keeper_stream_media_accum.ml:285](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/server/keeper_stream_media_accum.ml#L285-L378),
[lib/server/keeper_stream_media_accum.mli:14](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/server/keeper_stream_media_accum.mli#L14-L40).

Problem: One event updates scope, block occupancy, completed evidence and terminal phase
through several mutable helpers; overflow and metadata drift log inside those
transitions. Reviewing which completed media survive a failed or superseded attempt
requires following these coupled updates. A pure transition would expose that lifecycle
independently of diagnostic and storage effects while retaining the legitimate
turn-local owner.

Implemented boundary: The private `Keeper_stream_media_state` in the owning
`lib/server/dune` replaces five correlated mutable fields with one turn-local owner of
abstract immutable state. The public accumulator API remains unchanged. Keep ordered
completed values and closed wire-refusal/metadata-drift decisions; configuration lookup,
state publication, warnings and `to_chat_blocks` decode/store/chat projection remain in
the shell. Use only the domain stages needed below, without a generic effects framework
or new public API. The live SSE bridge retains its separate quarantine, scope-poisoning
and immediate-persistence policies.

Preserve:

- Completed media survive later failure, exact scope changes and runtime attempts; the
  current boundaries discard only unfinished occupancy. Preserve the special
  first-attempt behavior and exact supplied `stream_scope` identity.
- Keep block-stop completion order and ascending index order when terminal events
  finalize several open blocks, including in-order dropped placeholders.
  [Finalize and publish each block before the next](https://github.com/jeong-sik/masc/blob/0190a7bea54f85aee77107c89092e6a4adcc1fb1/lib/server/keeper_stream_media_accum.ml#L128-L155),
  [then publish the terminal phase](https://github.com/jeong-sik/masc/blob/0190a7bea54f85aee77107c89092e6a4adcc1fb1/lib/server/keeper_stream_media_accum.ml#L219-L235);
  do not replace that sequence with eager whole-terminal publication. Duplicate
  terminals cannot duplicate completion.
- Retain the first metadata, ignore drift with its diagnostic, and suppress media for
  tool-owned/invalid/closed indexes. Preserve the collector's distinct
  `StreamIncomplete`/`StreamRepeating` behavior rather than importing the live bridge
  policy.
- Freeze the wire cap once at creation and retain decision-time byte count/cap in the
  placeholder. Keep current MIME/token, Base64 decoding, typed persistence refusal and
  byte-unit labels; add no cap, timeout or retry policy.
- [Publish scope entry before evaluating the event](https://github.com/jeong-sik/masc/blob/0190a7bea54f85aee77107c89092e6a4adcc1fb1/lib/server/keeper_stream_media_accum.ml#L164-L195).
  A warning-only metadata-drift result must not overwrite the owner with a captured
  snapshot after logging.
- [Warn before recording a wire drop](https://github.com/jeong-sik/masc/blob/0190a7bea54f85aee77107c89092e6a4adcc1fb1/lib/server/keeper_stream_media_accum.ml#L97-L106),
  then apply the drop/occupancy change to the current snapshot. Preserve propagated
  exceptions and earlier completed blocks; add no exception shielding or cancellation
  conversion. Allocation-failure equivalence still needs implementation review.
- [Canonical success materializes media files before delivery selection](https://github.com/jeong-sik/masc/blob/0190a7bea54f85aee77107c89092e6a4adcc1fb1/lib/server/server_routes_http_keeper_stream.ml#L2370-L2438);
  selected assistant/failure rows attach the blocks, while direct-continuation and
  tool-only paths make separate transcript decisions.
- Keep failed-reply persistence and repeated `to_chat_blocks` behavior:
  content-addressed file reuse does not make materialization exactly once, and a later
  failure path may invoke it again.

Producers:
[synthetic response events](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/packages/agent_core/lib/llm_provider/streaming.ml#L270-L316)
and
[Gemini inlineData events](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/packages/agent_core/lib/llm_provider/streaming.ml#L3221-L3260).
Consumers:
[HTTP raw-event/attempt feed](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/server/server_routes_http_keeper_stream.ml#L2024-L2088),
[failed-reply media persistence](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/server/server_routes_http_keeper_stream.ml#L2174-L2220),
[media-block construction and assistant append helper](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/server/server_routes_http_keeper_stream.ml#L2370-L2414),
[selected control/media-only branch calls](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/server/server_routes_http_keeper_stream.ml#L2434-L2488),
and
[visible spoken reply append](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/server/server_routes_http_keeper_stream.ml#L2514-L2516).
The
[live bridge terminal policy](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/keeper/keeper_chat_agent_core_stream_bridge.ml#L920-L1035)
and
[live media/failure effects](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/keeper/keeper_chat_agent_core_stream_bridge.ml#L1480-L1545)
remain separate owners. The assistant helper is called by `Assistant_row`,
`Visible_blocks`, and visible spoken-reply branches; pending direct continuation and
`Tool_calls_only` choose other persistence paths.

Existing scenarios:
[test/test_keeper_stream_media_accum.ml:1](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/test/test_keeper_stream_media_accum.ml#L1-L431)
reads public accumulator output through a real temporary store: native media references,
attempt reset, timeout discard, terminal order/freeze, tool ownership, metadata drift,
frozen cap and malformed-payload placeholders. Selected
[live bridge scenarios](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/test/test_gate_keeper_backend.ml#L2564-L2735)
cover a different delivery consumer. **The 11 existing accumulator cases passed with the
added scenario in run 39000671109; the separate live bridge cases remain unexecuted
here. No complete HTTP or UI observation is supplied.**

Added verification: The twelfth public scenario feeds media/tool collectors in HTTP
callback order, using the tool collector's exact scope. Complete one media block, leave
another open, fail the attempt, then reuse an index in a new attempt and complete it
with replayed terminal events. Only the earlier and newly completed media should
survive, once and in order.
Call `to_chat_blocks`, resolve the actual stored media files and compare decoded bytes;
the unfinished payload must have no stored file. Pass the blocks to
[the public transcript helper with `Request_failed`](https://github.com/jeong-sik/masc/blob/0190a7bea54f85aee77107c89092e6a4adcc1fb1/lib/server/server_keeper_operation_transcript.ml#L32-L52),
then
[strictly reload the durable JSONL](https://github.com/jeong-sik/masc/blob/0190a7bea54f85aee77107c89092e6a4adcc1fb1/lib/keeper/keeper_chat_store.ml#L2466-L2493)
and verify the typed failure row retains the ordered blocks and delivery identity.
**Executed in run 39000671109:** this crosses the public collector, media store and
HTTP-used transcript persistence helper; it does not execute the full HTTP handler,
provider failover or UI.

Ordering rationale: Actual synthetic/Gemini producers, file materialization and
selective transcript attachment bound the change. Independent review checked scope
publication, warning-before-drop, current-state updates after observers and per-block
completion before terminal phase publication. Logger-fault/reentry execution and
allocation-failure equivalence remain unproved. The fixture restores its environment and
filesystem capability; its explicit library dependencies match the actual module owners.

Integration observation: The Round 11 census inspected 64 open PRs and five open native
stacks. Main `fce61a52528dfced7b41d5f9f84cafcb8fd6ce3a` does not change the media
accumulator or its direct consumer APIs. External draft
[#43521](https://github.com/jeong-sik/masc/pull/43521) at
`008a2f4902ab2f062a8202cf2bd8226ec00ccb0f` adds an ignored `ResponsesOutputItems` case
to the old accumulator. That constructor is absent from this base; a later integration
must carry its case into the new state match. It is not copied into this stack or
treated as merged.

### J1

**Give schedule-note append the ledger transaction and typed failure boundary**

Initial inspection revision: `c5337092c70bc5cf6a615f481684810db40a7116`. Implemented in
[#43510](https://github.com/jeong-sik/masc/pull/43510), code head
`79284756371ab29aa46da36773f3f1cc16177fde` against
`0190a7bea54f85aee77107c89092e6a4adcc1fb1`. Independent source review passed the
complete five-file implementation and actual store/tool consumers. Five changed OCaml
files passed syntax parsing; focused before/after execution is recorded below. No local
build, formal approval, merge or production-runtime proof is supplied. The controlled
test reproduces the lost append; no production incident is claimed.

Source:
[note identity and append](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/schedule/schedule_store.ml#L647-L693),
[ledger load/write owner](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/schedule/schedule_store.ml#L438-L478),
[existing locked mutation](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/schedule/schedule_store.ml#L807-L830),
[encoded write boundary](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/workspace/workspace_utils_ops.ml#L258-L299),
[explicit file-lock boundary](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/workspace/workspace_utils_ops.ml#L671-L688).

Original problem: `append_note` reads a whole ledger snapshot, allocates the note ID
from `version + 1`, and writes a replacement snapshot without the schedule-file lock
used by other mutations. Its direct tool/route consumers add no such transaction. Two
appends can therefore derive the same ID from version v and publish competing v+1
snapshots, or a note can overwrite a schedule/wake change. The inspected write API
receives content, not an expected revision. Separately, every read error becomes
`Schedule_not_found` and the tool reports it as a workflow refusal, losing the existing
corruption distinction. These are source-derived ownership/error concerns, not an
executed production incident.

Implemented boundary: The existing schedule-file lock now encloses load, existence
decision, ID/count derivation, immutable next-state construction and publication.
`load_for_mutation` preserves typed `Corrupt_ledger`. After argument/actor validation,
the note tool matches the existing store-error variant: corruption and persistence
failure become `Runtime_failure`; a genuine absent schedule and the other workflow
errors remain `Workflow_rejection`. `make_note` and the existing next-state calculation
remain in place; no new module, error taxonomy or transaction framework is added. This
intentionally changes interleaving/error behavior.

Preserve:

- Resolve author identity at the caller boundary; retain unnamed/spoofed-author refusal.
- Allocate IDs/version from the state owned by the publication transaction. Accepted
  concurrent notes and already committed schedule/wake changes must survive together.
- Preserve supplied timestamps, append order, per-schedule count and stable schedule-ID
  history. Notes survive definition replacement and terminal pruning.
- Note append deliberately bypasses `bump_state` wake pruning; do not introduce it
  indirectly while reusing the transaction owner.
- Keep missing schedule distinct from unreadable/corrupt ledger, preserve surviving
  bytes, and retain current primary/recovery, lock cleanup and cancellation behavior. Do
  not redesign recovery authority, retention, recurrence, overflow or mirror-error
  semantics in this change.
- Add no numeric gate, deadline, retry policy, singleton, queue abstraction or thread-model change.

Consumers:
[note tool](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/tool_schedule.ml#L1312-L1345),
[failure classification](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/tool_schedule.ml#L533-L578),
[action dispatch](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/tool_schedule.ml#L1377-L1400),
and actual
[MCP](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/mcp_server_eio_execute.ml#L420-L442)/[Keeper tag](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/keeper/keeper_tag_dispatch.ml#L117-L130)/[Keeper in-process](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/keeper/keeper_tool_in_process_runtime.ml#L2033-L2053)
routes. This traces immediate consumers, not every possible outer dispatcher or
deployment configuration.

Existing scenarios:
[sequential note/retention](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/test/test_schedule_store.ml#L1740-L1810),
[typed insert-corruption refusal](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/test/test_schedule_store.ml#L1163-L1183),
[busy-domain-pool store fixture](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/test/test_schedule_store.ml#L1530-L1599),
and
[unnamed author](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/test/test_schedule_tool_wiring.ml#L1530-L1577)/[spoofed author](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/test/test_schedule_tool_wiring.ml#L1715-L1775)
cases. **Executed as part of the focused suites below.** The pre-existing sequential
cases alone do not establish concurrent note atomicity or the corrupt-note result.

Added scenarios: Four cases extend the existing store/tool suites: two controlled
real-file appends must retain both accepted notes with distinct IDs and committed
counts; corrupt store reads retain typed failure and both byte strings; the actual note
dispatcher distinguishes absence from corruption; and an actual primary
staging-directory write failure is classified as runtime failure without changing
primary/mirror bytes. The overlap uses the existing warmed cache, a short filesystem
fallback bracket and an occupied single-worker CPU pool. No random sleep or production
injection hook is added. The scenarios were not executed locally; all four were executed
before and after the repair in the focused CI runs below. Mixed note/cancel/update
coexistence remains a proposed follow-up scenario; mirror-recovery branches, lease
expiry/fencing, full transport and deployed concurrency are not established by these
four cases.

Focused validation observed in Round 11: Test-only head
`e6689c054256ae9da5efa83a8ac75bca8d71d4ce` preserves original production code.
[Run 38997963952](https://github.com/jeong-sik/masc/actions/runs/38997963952),
`suite=test_schedule_store,test_schedule_tool_wiring`, `minimal=true`, compiled and ran
both suites. Only the four added cases failed: two of 58 store cases and two of 51 tool
cases. The concurrent append expected `[seed; first; second]` but reloaded
`[seed; second]`; corruption became schedule absence, and the tool rejected
corruption/write failure as workflow errors instead of runtime failures.

[Run 38998302085](https://github.com/jeong-sik/masc/actions/runs/38998302085) ran the
same suites/settings at exact repaired head `28aca42a2de44b642f0603f182a2738dc46fddd3`:
all 58 store and 51 tool cases passed, including the four new cases. These are observed
assertion failures followed by successful focused execution, not setup failures or
dispatch-only evidence. No CI watch/wait loop, full regression, deployed concurrency or
cross-process correctness claim is made.

Ordering rationale: A concrete whole-ledger ownership inconsistency and discarded error
type, separate from K3 timer tickets, K4 attempt evidence and S7 connector lane state.
The pre-implementation open-PR file census found no external overlap for the five
changed files. The existing lock owner and recovery-mirror policy remain unchanged; this
repair does not claim an atomic two-file commit or complete cross-process correctness.

## Boundaries retained or excluded

These are reasons not to perform a blanket rewrite, not whole-module correctness claims.

- [lib/keeper/keeper_memory_os_current.ml](../../../lib/keeper/keeper_memory_os_current.ml):
  Existing snapshot codec (#43347), journal codec (#43348) and immutable successor
  recall (#43353) coverage is not a new candidate. They were in review at the initial
  observation and are now confirmed merged into the separately observed main recorded
  above. Original campaign coordinates remain historical; this metadata refresh adds no
  Memory OS source-reading coverage and does not impute integration to campaign c12.
  Refresh actual implementation before editing nearby code. K7 still concerns the
  residual receipt-reconciliation boundary.
- [lib/keeper/keeper_tool_plan_executor.ml](../../../lib/keeper/keeper_tool_plan_executor.ml):
  The read/write execution gate at lines 238-301 legitimately owns mutable
  readers/writer/waiting_writers counters under an Eio mutex and condition. Cancellation
  rolls back waiting_writers. Removing mutation for style would obscure resource
  ownership and fairness; extract no generic gate merely because mutable fields exist.
- [lib/keeper/keeper_heartbeat_loop.ml](../../../lib/keeper/keeper_heartbeat_loop.ml):
  Deferred_lane_slot at lines 207-367 already has a closed Idle/Held/Dispatched state
  and owns the process-local mirror of a durable runtime suffix. Its callback-owned ref
  and ordered save/clear effects are intentional. A separate pure scheduling decision
  module already exists; do not count the large outer loop as proof of an absent
  functional boundary.
- [lib/keeper/keeper_heartbeat_loop_scheduling.ml](../../../lib/keeper/keeper_heartbeat_loop_scheduling.ml):
  Already contains an explicit pure keepalive scheduling decision. Reuse the existing
  boundary before proposing a competing scheduler abstraction.
- [lib/keeper/keeper_tool_descriptor.ml](../../../lib/keeper/keeper_tool_descriptor.ml):
  Large descriptor and schema inventory with explicit execution/policy variants and a
  central constructor. File size alone does not justify scattering the capability
  declaration source of truth; a separate correctness or consumer-dependency problem is
  needed.
- [packages/agent_core/lib/execution_event_store.ml](../../../packages/agent_core/lib/execution_event_store.ml):
  The mutable lifecycle, health, committed snapshot and resource hooks at lines 575-640
  represent a live resource owner with locks and fencing. Atomic writer-path claims and
  byte buffers for binary encoding are justified mutation. K6 targets scan data flow
  only, not wholesale immutability of live storage.
- [lib/keeper/keeper_agent_run.ml](../../../lib/keeper/keeper_agent_run.ml): The request
  digest memo at lines 1485-1492 is documented as turn-fiber-owned, with workers
  receiving private snapshots; the shared agent cell is deliberately captured by tools
  loaded mid-turn. These are ownership boundaries, not automatically refactoring
  defects. K4 preserves them and distinguishes attempt-local from turn-local evidence.
- [lib/workspace/workspace_backlog.ml](../../../lib/workspace/workspace_backlog.ml): The
  commit result explicitly preserves committed revision and primary/recovery/post-commit
  degradation. Its lease fence, protected settlement, cache invalidation and
  recovery-copy ordering are durability mechanisms, not mutations to remove for style.
  Preserve them when changing callers.
- [lib/workspace/workspace_task_lifecycle.ml](../../../lib/workspace/workspace_task_lifecycle.ml):
  The task state/action match already makes ownership, cancellation reasons,
  verification submission and timestamp preservation explicit. Do not replace exhaustive
  variants with strings or a generic transition table merely to shorten the file.
- [lib/workspace/workspace_task_transition_executor.ml](../../../lib/workspace/workspace_task_transition_executor.ml):
  Already a narrow immutable backlog transformation. Entry actions preserve the previous
  handoff, exit actions author one; the distinction is intentional and must remain
  visible.
- [lib/task/task_goal_assignment.ml](../../../lib/task/task_goal_assignment.ml): This
  task-domain integration boundary intentionally acquires Goal/backlog authority and
  owns typed cross-store failures. Moving it into the Goal leaf domain would reverse the
  documented dependency direction.
- [lib/goal/goal_phase.mli](../../../lib/goal/goal_phase.mli): Paused/Blocked carry the
  resumable phase as a closed sum, and public actions exclude verifier authority
  actions. This is useful type-level contract, not redundant boilerplate.
- [lib/fs_compat/fd_cache.ml](../../../lib/fs_compat/fd_cache.ml): active counts,
  close_on_release, LRU timestamps and the mutex represent live descriptor ownership.
  Replacing these with an immutable map alone would not replace resource lifetime
  synchronization.
- [lib/fs_compat/atomic_write.ml](../../../lib/fs_compat/atomic_write.ml): Explicit
  publication stages, cleanup failure collection and cancellation/backtrace preservation
  are real I/O protocol state. The inspected run_stage/capture_cleanup boundaries
  intentionally distinguish recoverable failure from cancellation/fatal exceptions; no
  blanket catch-all rewrite is justified.
- [lib/fs_compat/atomic_replace.mli](../../../lib/fs_compat/atomic_replace.mli):
  Before_rename/After_rename is already a typed publication outcome and the strict
  versus rename-only APIs state distinct durability contracts. Keep this distinction
  instead of unifying all writers behind unit/string results.
- [lib/dated_jsonl/dated_jsonl_store.ml](../../../lib/dated_jsonl/dated_jsonl_store.ml):
  Closed store/retention variants and typed root/location constructors are a useful
  shared registry. Filesystem enumeration belongs at this edge; fixed retention values
  are explicit product/resource contracts, not evidence for arbitrary immutable
  refactoring.
- [bin/masc_tui_runtime_config_edit.ml](../../../bin/masc_tui_runtime_config_edit.ml):
  Already a small immutable private edit session with explicit observe/adopt/replace
  actions. Source path/revision are preserved and tests cover draft retention after
  conflicts. No substantive rewrite justified.
- [bin/masc_tui_runtime_account_form.ml](../../../bin/masc_tui_runtime_account_form.ml):
  Already uses a nonempty zipper-like ring and closed Filling/Saved phases. UI rendering
  is colocated, but no audited behavior/invariant problem justifies a size-only split or
  new visual tests.
- [bin/masc_tui_lane_application.ml](../../../bin/masc_tui_lane_application.ml):
  Application tracking is typed and immutable. The unit ref inside ticket is an
  intentional unforgeable physical identity, never mutated; replacing it merely because
  rg reports ref would not improve ownership.
- [bin/masc_tui_lane_subscriptions.ml](../../../bin/masc_tui_lane_subscriptions.ml):
  Already has typed requests and phases, immutable edits and revision-bound saves with
  current keeper/output revalidation. No substantive defect established by this
  representative audit.
- [lib/gate/channel_gate_connector.ml:registry](../../../lib/gate/channel_gate_connector.ml):
  Startup registration and lookup are short, mutex-protected operations over an owned
  table. Registry mutability itself is not a refactor target; S6 concerns the descriptor
  contract, not synchronization removal.
- [bin/masc_tui.ml](../../../bin/masc_tui.ml),
  [bin/masc_tui_http.ml](../../../bin/masc_tui_http.ml), `bin/masc_tui_io_domain.ml`,
  [bin/masc_tui_board_upload.ml](../../../bin/masc_tui_board_upload.ml): Excluded at the
  initial inventory because PR #43355 then owned HTTP/TUI transport changes. The
  follow-up REST read confirms it merged on 2026-10-16 at 13:11:50 UTC (reported PR head
  c736c2325a85231741f41a5f63b82cb6e353b34f). This removes the active-PR exclusion. Round
  5 inspected the new I/O domain and selected transport/Board completion boundaries at
  main `857c8647ce7cc7305d6aa081d1aa24ac5b93f05e`; the broader TUI implementation
  remains open.
- [lib/keeper/keeper_autonomous_turn_source.ml](../../../lib/keeper/keeper_autonomous_turn_source.ml),
  [lib/keeper/keeper_checkpoint_store.ml](../../../lib/keeper/keeper_checkpoint_store.ml),
  [lib/keeper/keeper_event_bridge_error_json.ml](../../../lib/keeper/keeper_event_bridge_error_json.ml),
  [packages/agent_core/lib/base/error.ml](../../../packages/agent_core/lib/base/error.ml),
  [packages/agent_core/lib/structured.ml](../../../packages/agent_core/lib/structured.ml):
  Excluded because active PR 43352 owns structured-evidence changes. Exact changed-file
  list was read from GitHub; no overlap proposed.
- [lib/schedule/schedule_domain.mli](../../../lib/schedule/schedule_domain.mli): Already
  has a pure typed domain, closed status/recurrence alternatives and explicit time
  interpretation; no specific defect established by this inspection.
- [lib/backend/backend.ml](../../../lib/backend/backend.ml): Key-index tables and
  lock-duration refs belong to a concrete concurrent IO owner. Mutation alone is not a
  reason to replace them; observer-after-unlock and exception cleanup are real lifecycle
  requirements.

- [packages/agent_core/lib/llm_provider/provider_admission.ml](../../../packages/agent_core/lib/llm_provider/provider_admission.ml):
  Retain the existing functional transition module and effect owner. Registry state is
  immutable; a short Stdlib.Mutex section publishes it together with scheduler
  reconfiguration, while waiting/diagnostics remain outside. Atomically installed
  observer removal uses installation identity so an old remover cannot erase a
  replacement. Replacing these owner-local cells solely to eliminate mutation would
  obscure publication ordering.
- [packages/agent_core/lib/agent/agent_execution_runner.ml](../../../packages/agent_core/lib/agent/agent_execution_runner.ml):
  Retain this effect owner rather than turning the captured terminal disposition into an
  unnecessary global/pure state layer. The per-run ref captures at most one disposition
  until the writer exits; the actual sink is delivered after that boundary under
  cancellation protection. Caller switch lifetime remains distinct from the protected
  writer lifetime, and original reserved exceptions/backtraces survive cleanup failures.
  Fresh/resume branches differ in readiness and resume authority, so their visual
  duplication alone is insufficient justification to merge them.
- [packages/agent_core/lib/agent/agent_lifecycle.ml](../../../packages/agent_core/lib/agent/agent_lifecycle.ml):
  Retain the pure lifecycle transition/snapshot helper and separate event publication
  wrapper. Transition errors are closed variants; build_snapshot takes prior snapshot
  and explicit observations. The wrapper owns clock, fresh IDs, event publication and
  exception rethrow. This is an existing functional/effect separation, not an unreviewed
  blanket endorsement of all lifecycle behavior.

- [bin/masc_tui_io_domain.ml](https://github.com/jeong-sik/masc/blob/857c8647ce7cc7305d6aa081d1aa24ac5b93f05e/bin/masc_tui_io_domain.ml):
  The small resource owner already has the required responsibility: a request-domain job
  queue, domain-local connection pool, nested job switch, result/backtrace relay, and
  caller cancellation/abandonment. Replacing its Eio effects with an immutable reducer
  or another facade would not improve this boundary.
- [bin/masc_tui_http.ml](https://github.com/jeong-sik/masc/blob/857c8647ce7cc7305d6aa081d1aa24ac5b93f05e/bin/masc_tui_http.ml):
  The explicit local HTTP signature names execution domain per operation. Request
  URL/body/header values are built before handoff; credential retry and kept-read cache
  application remain in the calling flow. Streams are intentionally retained there
  because callbacks own TUI state. A second transport abstraction has no demonstrated
  need.
- [bin/masc_tui_kept_reads.ml](https://github.com/jeong-sik/masc/blob/857c8647ce7cc7305d6aa081d1aa24ac5b93f05e/bin/masc_tui_kept_reads.ml):
  Short mutex sections protect generation tables without holding the lock over
  send/decode. A 304 answers with the value whose tag was sent; reaffirm does not
  overwrite a different newer tag. These are legitimate state/cache effects, not
  refactoring candidates solely because the tables are mutable.
- [bin/masc_tui_render_schedule.ml](https://github.com/jeong-sik/masc/blob/857c8647ce7cc7305d6aa081d1aa24ac5b93f05e/bin/masc_tui_render_schedule.ml):
  Input/Background/Force and Idle/Wait_until/Render already make the scheduling decision
  explicit. Terminal presentation and mailbox effects remain in masc_tui.ml. No causal
  reason was found to replace this small stateful scheduler.
- [bin/masc_tui_machine_live.ml](https://github.com/jeong-sik/masc/blob/857c8647ce7cc7305d6aa081d1aa24ac5b93f05e/bin/masc_tui_machine_live.ml):
  Live payload decode, mark identity, activity feed validation and view advance are
  already closed types with an explicit boundary. The consumers retain exact
  request/view/port admission before state mutation. Splitting these small typed forms
  further is unwarranted.
- [bin/masc_tui_board_upload.ml](https://github.com/jeong-sik/masc/blob/857c8647ce7cc7305d6aa081d1aa24ac5b93f05e/bin/masc_tui_board_upload.ml):
  File inspection/read effects have explicit resource ownership and identity/size
  checks; upload_staged injects read/upload, preserves order, and stops on the first
  failure. Keep this real IO boundary; T1 concerns the later post commit receipt, not
  the content-address upload sequencer.
- [lib/browser_lane/browser_upload_lease.ml](https://github.com/jeong-sik/masc/blob/857c8647ce7cc7305d6aa081d1aa24ac5b93f05e/lib/browser_lane/browser_upload_lease.ml):
  Retain the Pending/Owned/Released lease and owner-local mutable registry. Claims
  transfer only exact registered snapshot batches before WebDriver mutation; claimed
  bytes survive callback failure/cancellation until confirmed session teardown or
  invalid-session evidence. The short non-yielding mutex protects that ownership
  transfer, and cleanup runs after it. Removing refs or physical lease identity alone
  would obscure the lifetime protocol. This does not certify every cleanup-exception
  path.
- [lib/browser_lane/browser_lane.ml](https://github.com/jeong-sik/masc/blob/857c8647ce7cc7305d6aa081d1aa24ac5b93f05e/lib/browser_lane/browser_lane.ml):
  Retain live client queues, per-client waiters, retired identity set and last delivered
  result as effect-owner state. Disconnect settles waiters and drains work; switch
  release removes pending request ownership; retry of the most recently delivered
  ID/payload is acknowledged while a changed payload for that ID is refused.
  Watched_work retains an answer/command that arrived as the time window closed. An
  immutable map alone would not replace those resource and delivery obligations.

Exec inspection at `684336274720034611073beab836159fd4ee3b94` retains these boundaries:

- [lib/exec/parser/bash_lexer.mll:20](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/exec/parser/bash_lexer.mll#L20-L38),
  [lib/exec/parser/bash.ml:203](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/exec/parser/bash.ml#L203-L220):
  Lexer-owned refusal variants and parser boundary translation already preserve
  construct identity and child failure. Keep exhaustive closed outcomes; do not
  reintroduce post-hoc substring refusal guesses.
- [lib/exec/shell_ir.mli:42](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/exec/shell_ir.mli#L42-L77),
  [lib/keeper_tooling/execute_shell_ir.ml:73](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/keeper_tooling/execute_shell_ir.ml#L73-L102):
  Closed recursive IR, nonempty sequence head, typed target/path ownership and
  gate-before-dispatch are coherent boundaries. No blanket Result/default rewrites
  warranted.
- [lib/exec/exec_dispatch.ml:403](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/exec/exec_dispatch.ml#L403-L477),
  [lib/exec/exec_dispatch.ml:766](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/exec/exec_dispatch.ml#L766-L1004),
  [lib/exec/test/test_exec_dispatch_pipeline_streaming.ml:21](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/exec/test/test_exec_dispatch_pipeline_streaming.ml#L21-L63):
  Native pipeline selection exists to retain real pipe backpressure and live callback
  semantics. Same-target physical identity identifies a resource runner owner; do not
  replace it with structural comparison or purify execution into a buffered
  whole-pipeline fold.
- [lib/process/process_eio.ml:1149](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/process/process_eio.ml#L1149-L1248),
  [lib/process/process_eio.ml:1444](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/process/process_eio.ml#L1444-L1601):
  Local phase/open-handle refs, output buffers, Eio switches and concurrent await/drain
  implement resource lifetime and cleanup. Their mutation is legitimate per-call I/O
  state, distinct from parser process-global accounting.
- [lib/exec/parser/bash_subset.mly:112](https://github.com/jeong-sik/masc/blob/684336274720034611073beab836159fd4ee3b94/lib/exec/parser/bash_subset.mly#L112-L114):
  The left-recursive pipeline action appends one stage and can repeatedly copy its
  prefix. No latency/allocation measurements or harmful production input distribution
  were established; do not promote to an extra broad performance candidate merely to
  enlarge the list.

Multimodal/media inspection at `d3e01a8d75986ef32807d10d81c50dfa6d31bebf` retains these
five boundaries:

- [Immutable workspace](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/multimodal/workspace.ml#L1-L89)
  and
  [CAS publication](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/multimodal/workspace_holder.ml#L1-L18):
  the
  [post-turn caller](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/keeper/keeper_post_turn.ml#L52-L132)
  hydrates identity before the retried pure update. Keep the holder and short emitter
  mutex as effect owners. The
  [cross-domain scenario](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/test/multimodal/test_workspace_holder.ml#L93-L123)
  was read, not executed; it is not contention or serialization proof.
- [Frame/kept store](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/multimodal/vision_artifact_store.ml#L1-L262)
  and
  [kept-root maintenance](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/multimodal/vision_kept_maintenance.ml#L1-L299):
  frames auto-prune, kept artifacts do not. Pruning protects a new handle and accounts
  for unlink outcomes; kept cleanup completes reference scans and records candidates
  before deleting the intersection with the prior pass.
  [Store effects](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/keeper/keeper_vision_tool.ml#L93-L118)
  and the
  [maintenance command](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/bin/deployment_preflight_helper.ml#L475-L525)
  retain those policies.
  [Two-pass/reappearing-reference scenarios](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/test/test_vision_kept_maintenance.ml#L35-L153)
  and
  [frame retention/fallback scenarios](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/test/multimodal/test_vision_artifact_store.ml#L245-L332)
  are source evidence only. Reference-scanner internals and all concurrent
  publication/deletion races remain open; the permission-based unlink fixture is not
  portable proof under privileged runners.
- [Per-walk media readings](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/keeper/keeper_media_reading.ml#L1-L366):
  memo identity includes kind, MIME and source hash; successful durable readings need no
  new deadline, while failed readings are reused only within the walk. The
  [driver](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/keeper/keeper_turn_driver.ml#L2256-L2285)
  owns one projector per walk and retains canonical input for later capable candidates.
  [Real-store projection scenarios](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/test/test_keeper_turn_driver_failover.ml#L1070-L1185)
  and
  [cache/deadline/retry scenarios](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/test/test_keeper_turn_driver_failover.ml#L1230-L1415)
  inject the reader; they do not invoke STT/PDF providers. The separate
  [H5 observation harness](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/test/test_h5_media_failover_continuity.ml#L1-L406)
  prints most equality outcomes and is not an end-to-end failover assertion.
- [Typed input carriers](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/keeper/keeper_multimodal_input.ml#L214-L297)
  and
  [MIME/data-URL validation](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/keeper/keeper_multimodal_input.ml#L489-L563):
  attached bytes, URL and file ID are distinct alternatives.
  [Ingest/fallback projection](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/keeper/keeper_vision_ingest.ml#L1-L363)
  preserves native references when applicable and emits explicit unread references for
  text-only fallback without fetching them. Retain these distinctions; only the listed
  parser spans, not every attachment or provider serializer, were inspected.
- [Generated-media persistence](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/keeper/keeper_chat_media_store.ml#L1-L271)
  has one MIME/category/extension table and typed decode/size/source/write failures. The
  [pure vision core](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/multimodal/vision_analyze.ml#L1-L27)
  and
  [latest structured outcome classifier](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/keeper/keeper_vision_tool.ml#L392-L468)/[candidate outcome handling](https://github.com/jeong-sik/masc/blob/d3e01a8d75986ef32807d10d81c50dfa6d31bebf/lib/keeper/keeper_vision_tool.ml#L791-L849)
  preserve refusal/non-ready states separately from invalid finished JSON and
  token-limit continuation. Full native-client failure traversal, transport execution
  and generated-media cleanup races remain outside this slice.

Schedule inspection at `c5337092c70bc5cf6a615f481684810db40a7116` retains these four boundaries:

- [Typed domain interface](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/schedule/schedule_domain.mli#L1-L222)
  and
  [opaque acceptance proof](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/schedule/schedule_runner.mli#L67-L111):
  consumer queue/fence/activation effects stay outside the schedule leaf. The
  [consumer](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/server/server_schedule_consumers.ml#L1015-L1190)
  obtains proof through the runner commit callback after durable acceptance.
  `Work_accepted` does not establish final Keeper work or connector delivery.
  [Acceptance/repair scenarios](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/test/test_schedule_consumer_dispatch.ml#L3120-L3286)
  were read, not executed; the domain implementation and complete downstream delivery
  remain open.
- [Exact occurrence identity](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/schedule/schedule_occurrence_id.ml#L1-L19)
  and
  [dispatch failure policies](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/schedule/schedule_runner.ml#L446-L571):
  retry retains the same instance/schedule/due/payload identity, while occurrence
  rejection and declaration rejection remain different. The
  [store](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/schedule/schedule_store.ml#L1243-L1334)
  preserves those transitions; tick time anchors recurrence and the caller clock stamps
  attempts.
  [Failure-scope/retry scenarios](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/test/test_schedule_runner.ml#L830-L938)
  do not justify collapsing this into a Boolean retry or global scheduler state.
- [Durable queue reconciliation](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/server/server_schedule_consumers.ml#L900-L1012),
  [intake fence and self-clock holds](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/server/server_schedule_consumers.ml#L1255-L1373)
  and the
  [production maintenance loop](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/server/server_bootstrap_maintenance.ml#L604-L651):
  exact-current-occurrence retry stays eligible while prior unconsumed work/fences can
  hold new intake. Startup recovery precedes sequential ticks; the supplied switch/fiber
  owns sleep and cancellation. Preserve those effect/resource owners and existing
  policy.
  [Held-wake](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/test/test_schedule_runner.ml#L1182-L1230)
  and
  [offline-owner/acceptance repair](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/test/test_schedule_consumer_dispatch.ml#L3182-L3286)
  cases are source evidence only, not proof of all transfer/lease or multi-process
  behavior.
- [Seen-key progress/cache](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/schedule/schedule_runner.ml#L238-L443),
  [decoded ledger cache](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/schedule/schedule_store.ml#L320-L478)
  and
  [immutable status projection](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/lib/schedule/schedule_runner_status.ml#L1-L170):
  cached values are retained by version/identity, and the private occurrence table is
  published only after population. Append progress advances after each actual append
  succeeds; moving that work into a precomputed pure plan would change partial-failure
  handling.
  [Seen-key failure/recovery](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/test/test_schedule_runner.ml#L362-L430)
  and
  [pool/cache](https://github.com/jeong-sik/masc/blob/c5337092c70bc5cf6a615f481684810db40a7116/test/test_schedule_store.ml#L1530-L1693)
  scenarios have separate execution evidence: the seen-key failure/recovery cases remain
  unexecuted; the pool/cache store cases passed as part of the 58-case store suite at
  `28aca42a2de44b642f0603f182a2738dc46fddd3` (see [J1](#j1)). There is no blanket
  exactly-once guarantee when both append progress and seen-key persistence fail, nor a
  full status/cache audit.

## Coverage still open

[Consulted sources](consulted-sources.json) records 280 unique files used for named
boundaries, callers and scenarios. Focused reading records distinguish full-source and
selected-span reads and pin later inspection revisions; symbol-search-only paths are not
counted. Historical test paths remain tied to the revision at which they were inspected.
This is selective semantic inspection of the complete file census. The original Round 5
TUI log retains all 29 records: 26 direct readings and three discovery-only searches.
Their original scopes and baseline remain in the JSON; discovery-only records are
excluded from the 202 focused reading records and the unique-file total. Round 7 adds 53
focused records and 50 unique paths at `d3e01a8d75986ef32807d10d81c50dfa6d31bebf`: 44
multimodal/media records and 9 Board rearm design records, including two build
declarations. Governance and audit-context reads remain excluded from these additions;
interface-only reads are not implementation audits. Round8 adds 51 focused records (22
Schedule, 29 S8 design) and 37 unique paths at
`c5337092c70bc5cf6a615f481684810db40a7116`. Six governance and two README-context
records are excluded. Two scoped records can refer to the same file; they do not count
as two unique files. Memory OS integration metadata adds no semantic reading.

- TUI inspection now covers the integrated I/O domain, selected HTTP/cancellation/cache
  owners, typed scheduling/machine payloads and Board post completion. The full
  orchestrator, all asynchronous admission classifiers, stream replay/acknowledgement
  and underlying HTTP pool/TLS/socket internals remain open. T1 requires server receipt
  and reconciliation design before implementation.
- Agent Core coverage now includes committed WAL scanning and selected
  provider-admission, stream-error, runner and lifecycle boundaries. The full stream
  assembler, backend codecs, scheduler internals, exact-output admission,
  standard/advanced run-loop differences and lifecycle consumer integrations remain
  open.
- Remaining production directories have not been cleared by representative samples.
  Browser upload leases and selected live-command ownership were inspected; cleanup
  failure settlement, full native/BiDi host lifecycle, WebDriver/DOM protocols, sandbox,
  multimedia, process and observation paths remain open.
- TypeScript/sidecar consumers are included only when tracing an OCaml contract. A full
  frontend or third-party-code audit is not implied.
- The two tracked lexer/parser generator inputs at
  `684336274720034611073beab836159fd4ee3b94`, `lib/exec/parser/bash_lexer.mll` and
  `lib/exec/parser/bash_subset.mly`, have now been read with their generator
  declaration. They remain a separate input inventory, outside the historical
  `.ml`/`.mli` census denominator. Generated output, Menhir conflicts and parser
  behavior were not checked by execution.
- Exec coverage remains selective: full process/spawn/detached lifecycle, remote runner
  cleanup, complete command/path policy and real concurrent parser scheduling remain
  open. E2 is a source-derived timeout concern requiring reproduction, not a reported
  Keeper shell incident.
- Multimodal/media inspection now traces selected artifact storage/retention, typed
  input carriers, per-walk readings, stream producers and success/failure persistence
  consumers at `d3e01a8d75986ef32807d10d81c50dfa6d31bebf`. Full
  Payload/Artifact/Hydrator implementations, reference-scanner internals, all
  serializers/native-client vision paths, media serving/UI behavior and concurrent
  filesystem settlement remain open. K3 refines contention ticket ownership only;
  deferred scheduling, partition durability and full keepalive/recovery remain outside
  its scope.
- Schedule coverage now traces selected ledger/note, occurrence dispatch and immediate
  MCP/Keeper consumers. J1 now has a source-reviewed transaction/error repair, four
  observed original-source failures and successful repaired execution of the two focused
  suites (109 cases); full cron/calendar, Keepalive, queue/transfer and final connector
  work remain open. S8 now traces durable accepted reports through journal reduction and
  selected HTTP/TUI data consumers; full provider codecs, cache cancellation and UI
  behavior remain open. S8 also has seven passing focused journal/decoder cases at the
  combined ownership-repair head. These executions do not establish full transport,
  deployed-runtime or visible UI behavior.
- Test/tooling refactoring follows production contract understanding; no broad test
  rewrite or new style/count gate is planned.

## Round log

- Previous work (initial observation): Memory OS codecs/successor core were published as
  three Draft PRs and their then-open heads were refreshed. That observation supplied
  source progress only; the later merged-main metadata is recorded in Round8 and does
  not establish runtime completion.
- Round 1: all tracked `.ml`/`.mli` files classified at the pinned baseline;
  clean-checkout counts independently matched the committed-blob reader; 24
  source-backed candidates recorded with boundaries, invariants, callers and suites. S1
  implemented with a private immutable observation core, retained lock/observer effects
  and two additional public-store scenarios; published as
  [#43367](https://github.com/jeong-sik/masc/pull/43367). OCaml syntax checks passed;
  behavior suites remain unexecuted.
- Round 2: K1 implemented as a private failure-evidence classifier in
  [#43370](https://github.com/jeong-sik/masc/pull/43370). Historical range sizing, named
  input refusal, invalid-output veto, size-independent failure and current CLI capacity
  remain separate facts. Syntax parsing passed; existing callback/admission scenarios
  were extended but not executed.
- Round 3: D2 implemented in [#43374](https://github.com/jeong-sik/masc/pull/43374).
  Focused source review corrected the initial no-op proposal: every accepted existing
  upsert commits even when fields are unchanged. Rejection and commit results are
  explicit; current RFC implementation references were updated. Syntax parsing passed
  and two public-store scenarios were added but not executed.
- Round 4: expanded Agent Core inspection across 17 explicitly scoped source/test reads
  in [#43377](https://github.com/jeong-sik/masc/pull/43377). Added A1 for the hidden
  diagnostic file effect in stream-error conversion and retained three existing
  ownership boundaries. This expands the queue to 25 candidates; it does not complete
  Agent Core coverage.
- Round 5 implementation: A1 was rechecked against main
  `857c8647ce7cc7305d6aa081d1aa24ac5b93f05e`, implemented and independently
  source-reviewed in [#43386](https://github.com/jeong-sik/masc/pull/43386). The focused
  read corrected a tentative public-API concern: the projection owner was already
  private.
- Round 5 implementation continued: D1 implemented in
  [#43399](https://github.com/jeong-sik/masc/pull/43399), preserving committed
  verification obligations across ordinary projection errors without changing
  cancellation or lock ownership. The existing compensation comment was corrected to
  distinguish returned cleanup errors from raised exceptions.
- Round 5 coverage: 39 scoped reading records across TUI and Browser added 34 unique
  paths in [#43400](https://github.com/jeong-sik/masc/pull/43400), bringing the
  consulted-source set to 157. Added T1 as investigate and retained eight existing
  ownership boundaries. The queue has 26 candidates; the complete initial file census
  remains pinned and semantic coverage remains selective.
- Round 6 implementation: K2 implemented in
  [#43411](https://github.com/jeong-sik/masc/pull/43411), preserving native child
  authority and publication while extracting the pure selected-export contract. The
  whole stack was rebased onto main `da50197434e17182ca30348afd92a541eea3b155`; S1 now
  retains the upstream quota-rest effect using the same accepted immutable snapshot,
  before the observer. Empty complete reports revoke usage observations but do not clear
  an existing quota rest. Independent source reviews checked the changed S1 integration
  and the other layers' rebased context.
- Round 6 coverage: [#43414](https://github.com/jeong-sik/masc/pull/43414) adds 42
  scoped source-reading records across Exec and lane planning and 36 unique paths,
  bringing the set to 193 files and 98 focused records. Added E1 as later and E2 as
  investigate, retained five Exec/resource boundaries, and refined S2 with its real
  Fusion consumers and transaction/error ordering. The queue has 28 candidates, six
  implemented PRs and 22 remaining candidates.
- Round 7 implementation: S2 implemented in
  [#43469](https://github.com/jeong-sik/masc/pull/43469), moving eight lane edit
  decisions into a private pure planner and preserving the public locked commit path.
  Independent source review passed on the adopted remote parent; syntax parsing passed,
  while added real-file scenarios remain unexecuted. The queue at this implementation
  step has 28 candidates, seven implementation PRs and 21 remaining candidates. Existing
  remote stack heads were adopted unchanged in an isolated checkout; this does not renew
  the older layers' review claims.
- Round 7 coverage: [#43471](https://github.com/jeong-sik/masc/pull/43471) added M1 as
  later and five retained multimodal/media boundaries; refined K3 with scheduler-owned
  ticket IDs, immutable per-entry phase, same-key replacement and exact exception/effect
  ordering. 53 focused reading records (50 new paths) bring the set to 243 files and 151
  focused records at `d3e01a8d75986ef32807d10d81c50dfa6d31bebf`. The queue has 29
  candidates, seven implementation PRs and 22 remaining candidates. Three governance
  reads and one README context read are excluded; initial-baseline carry and
  final-object rereads are explicit. Existing scenarios were inspected but unexecuted;
  proposed scenarios are future validation. Broad semantic coverage remains open.
- Round 8 implementation: K3 implemented in
  [#43479](https://github.com/jeong-sik/masc/pull/43479), replacing independent
  pending/inflight options with a private immutable phase while retaining scheduler
  effects and ticket identity. Independent source review and four-file syntax parsing
  passed; five added scheduler scenarios remain unexecuted. At this step the queue has
  29 candidates, eight implementation PRs and 21 remaining candidates.
- Round 8 coverage in [#43482](https://github.com/jeong-sik/masc/pull/43482): J1 added
  as investigate, four Schedule boundaries retained, and S8 refined to one private
  codec/day projection with immediate diagnostics, existing cache semantics and an
  actual-file damaged-history scenario. Removed the unrelated model-inference-metrics
  suite as direct S8 evidence. 51 focused records (37 new paths) bring the set to 280
  files and 202 focused records; the queue has 30 candidates, eight implementation PRs
  and 22 remaining candidates. Main-source evidence remains pinned to
  `c5337092c70bc5cf6a615f481684810db40a7116`. Memory OS merged-state/ancestry was
  separately refreshed against `776383528786929d01f8103e27823041c3cee755` without new
  semantic coverage. Artifact reviews and implementation evidence remain separate.
- No local Dune build, CI polling, behavior execution, formal GitHub approval or runtime
  proof is supplied by this inventory. The Memory OS merged-state statement is
  separately supplied integration metadata, not new behavioral validation.

- Round 9 implementation: S8 implemented in
  [#43489](https://github.com/jeong-sik/masc/pull/43489) with one private immutable
  history projection and its journal adapter. Independent source review and four-file
  syntax parsing passed; the added damaged-journal consumer scenario remains unexecuted.
  The queue has 30 candidates, nine implemented candidates and 21 remaining.
- Round 10 implementation: J1 implemented in
  [#43510](https://github.com/jeong-sik/masc/pull/43510), reusing the existing ledger
  lock and carrying typed storage failures to the note tool. Four real store/tool
  scenarios were committed before the repair for a separate original-source CI request;
  the expected original failures and repaired success remain unobserved. Independent
  source review and five-file syntax parsing passed. Candidate totals are 30 / ten
  implemented / 20 remaining; the earlier S1 declaration repair is not an additional
  candidate.
- Round 10 context correction: [#43517](https://github.com/jeong-sik/masc/pull/43517)
  distinguishes generated-media file creation before delivery selection from selective
  transcript attachment, and refines M1 state/diagnostic sequencing and the proposed
  durable reload scenario. Independent source/design review and seven added pinned-link
  checks passed. M1 remains unimplemented and the scenario unexecuted; queue and
  historical audit-reading totals are unchanged.

- Round 11 implementation: [#43526](https://github.com/jeong-sik/masc/pull/43526)
  implements M1 with one private immutable state and the existing effect owner.
  Independent source review passed code head `4c4bbe042c428760f5d68537d7903f399d292198`;
  five OCaml files parsed. One real-file/transcript-reload scenario is added but
  unexecuted. Queue: 30 candidates / eleven implemented / 19 remaining. Historical
  consulted-source totals remain unchanged.
- Round 11 evidence refresh: Actual S8 and J1 logs confirm seven S8 cases passing at
  combined head `0190a7b`, four expected J1 failures at `e6689c0`, and all 109 J1 cases
  passing at repaired head `28aca42`. Exact run/head bindings and limits are recorded in
  their entries above; earlier dispatch-only notes remain historical.
- Round 11 context follow-up: [#43528](https://github.com/jeong-sik/masc/pull/43528)
  separates observed history/store execution from adjacent unexecuted live-window/runner
  cases and records the M1 request without a result claim. No implementation,
  queue-count or historical reading-total change.
- Round 12 execution observation: M1
  [run 39000671109](https://github.com/jeong-sik/masc/actions/runs/39000671109) passed
  all 12 cases at `85c7f3714774d89f5e296c5568a21d5585329f08`, including the durable
  failed-turn media reload scenario. Earlier request-only notes remain historical; no
  full HTTP, provider failover, live SSE/UI or logger-exception result is implied.

- Round 14 partial implementation:
  [#43544](https://github.com/jeong-sik/masc/pull/43544) repairs D7's complete
  Task-review envelope and extends the real persisted-request integration scenario. The
  first original/repaired runs exposed a fixture wrapper mismatch, not the product
  failure; corrected checks are requested at the separate heads above and their results
  are not yet observed. The canonical snapshot codec/projection extraction remains
  outstanding, so the queue stays 30 candidates / 13 fully implemented as PRs / 17
  remaining, with D7 partially implemented.

- Round 15 implementation: [#43553](https://github.com/jeong-sik/masc/pull/43553)
  completes D7's private snapshot codec/projection extraction while preserving the
  public Store interface and all retained acquisition effects. Independent source review
  passed the five-file code delta at `bf306c55180d4fe63173090322d9744722721782`; four
  files passed syntax-only parsing. The new persisted-request scenario checks consistent
  first errors and no partial evidence through authority/dashboard consumers, including
  same-ID replacement. The focused four-suite run above passes all 146 cases at that
  same code head, including the new scenario; subsequent documentation changes preserve
  its source blobs. Queue: 30 candidates / 14 implemented as PRs / 16 remaining.
  Historical file-census and consulted-source totals are unchanged.
- Round 15 evidence/context: corrected original D7 execution now reproduces the intended
  final-prompt failure; repaired execution passes 100 verification plus seven
  collaboration cases. This also supplies scoped D1 verification-case evidence, leaving
  its other named suites unexecuted. Refreshed main and the 83-open-PR census show no
  direct extraction conflict. Six inherited changelog format errors were found by the
  existing validator and repaired in the new layer; all 29 fragments pass. Earlier
  source reviews did not catch those documentation defects. No lower PR head was
  rewritten.

- Round 16 implementation: [#43556](https://github.com/jeong-sik/masc/pull/43556)
  implements D3 with one private Goal document/type/codec owner and unchanged public
  Store interface, lifecycle owner and acquisition/transaction effects. Independent
  source review and four-file syntax parsing pass at code head
  `6237238cfbdce158d0d192c97f01e4bd5871862f`. The added real-file scenario checks
  ordered schema errors, mirror non-authority, mutation refusal and exact restoration
  through public consumers. The initial four-suite request stopped at an inherited D2
  fixture compile error before any test executed. A one-line tuple type annotation
  repairs that fixture without changing production; the corrected four-suite request
  above remains unobserved. Queue: 30 candidates / 15 implemented as PRs / 15 remaining.
  This does not settle D4 publication authority or complete broad semantic coverage.
