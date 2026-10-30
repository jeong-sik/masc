---
status: Draft
---

# Keeper asynchronous execution and fleet continuity

Tracking: #36941, #42799; Goal `goal-keeper-async-fleet-20261026`.

This is an implementation and acceptance contract, not a claim that the
following behavior is already available. The initial source baseline is
`74f7647213c1469589b1036be5a268f4c45758fd`. The operator requested safe
asynchronous execution, messaging, waiting and mutual delegation across
mixed sandboxes, from approximately ten to three hundred Keepers. The full
scope remains open until the evidence in section 9 exists.

## 1. Observable behavior

A Keeper submits work A and receives its original operation identity without
waiting for A to finish. It performs independent work B. When A settles, its
complete result is retained and a durable notification reaches the original
owner. The Keeper observes that result and continues the task which requested
A. A restart, lost connection, failed model turn or another Keeper's blocked
work must not silently lose A, run A again, or substitute a different result.

The same contract applies when A is a composition, a delegated request, a
Fusion run or an asynchronous add-on. Each producer retains its own execution
authority; a shared notification contract does not authorize generic replay.

An explicit operator pause remains a pause. Completion is retained until
execution is admitted again. An unavailable backend is a visible typed hold,
not success, absence, permission to relaunch, or an invented timeout failure.

## 2. Two execution domains

These are different user-visible effects and must remain explicit:

* **Isolated job:** immutable verified input artifacts, a private workspace,
  no inherited host/Keeper credentials and the declared network isolation.
  `keeper_job_start` currently implements this for Docker only. Extending it
  to an endpoint must preserve these guarantees or explicitly refuse before
  launch. Merely running its argv in the Keeper workspace violates its contract.
* **Workspace process:** the Keeper's selected checkout, environment, identity
  and declared sandbox/network policy. A long build is this domain. Async
  execution must pass the same typed command, path, Gate and effect admission
  as synchronous Execute. A raw argv control tool cannot bypass that admission.

Both need endpoint-owned lifetimes in microVM and remote SSH. Starting a host
process against an endpoint path, backgrounding the transport, or changing
the Keeper's profile to Docker does not implement either endpoint domain.

The endpoint route freezes its actual backend, endpoint/guest identity,
Keeper identity and workspace identity. Current configuration may authorize
new requests but cannot retarget a previously accepted operation.

## 3. Original-operation authority

The durable binding contains workspace identity, Keeper identity, operation
ID, original invocation identity, effect domain, exact command/input digest,
originating Task/turn and continuation conversation. IDs supplied by a model
are untrusted lookup keys; they never grant access to another owner.

The lifecycle is represented by closed variants, including preparation,
launch intent, accepted/running, exit, cancellation intent, result available,
delivery acknowledged, cleanup and explicit reconciliation holds. Uncertainty
about an effect is separate from the last confirmed lifecycle state.

Before launching, commit the operation binding and launch intent. Before
cancelling or deleting, commit that intent. Every effect settles against the
same operation and backend handle. Repeated admission of the same invocation
reconciles that binding; it does not create a replacement. Changed arguments
for an existing invocation are a conflict.

Endpoint acceptance and starting the child need a recoverable rendezvous:
the child cannot run before its original owner record exists. A lost start
reply is reconciled using that original endpoint record. PID alone is not a
handle: boot/session identity and process identity must distinguish PID reuse.
Cancellation must never signal a replacement process or unrelated process group.

The endpoint owns stdout/stderr and the exit receipt. The SSH/container exec
connection carries control messages only after acceptance; EOF of that control
connection does not cancel an accepted asynchronous job. Explicit cancel,
endpoint teardown and synchronous Execute retain their own declared semantics.

Endpoint reboot or guest replacement is not ordinary disconnect recovery.
If the original process/outputs cannot be recovered, expose that exact typed
outcome and retained evidence. Never infer a successful exit or relaunch.

## 4. Protocol and endpoint storage

Use a closed, strictly decoded control protocol with explicit operations for
start, inspect, read/result, cancel and release. Reject missing, duplicate and
unknown fields. The existing synchronous framed execution protocol remains a
separate operation; do not turn its EOF watchdog off for ordinary Execute.
Advertise asynchronous support through an actual shim capability probe.
An old or incapable shim refuses async admission before any payload effect.

Registry directories, manifests and output files are endpoint-owned. Validate
owner, mode, file type, roots and no-follow access before mutation. Prevent
symlink replacement, cross-Keeper name collisions and request-supplied paths
from redirecting control files. Writes use the repository's canonical durable
publication/recovery primitives where available; any endpoint-specific
primitive needs its own explicit crash contract and behavioral verification.

Protect lifecycle control from the payload with an actual supervisor boundary
(for example a distinct UID and protected control storage, or an equivalent
capability boundary). A different directory with mode 0700 under the payload's
own UID is insufficient. The payload must not forge a launch/cancellation/exit
receipt or redirect its process handle. Untrusted endpoint files cannot
authorize relaunch, process signalling or resource removal; reconcile them
against trusted original server/supervisor authority. A backend without this
boundary is not implemented by adding a warning to its result. Payload exit
and Task/Goal verification remain distinct authorities even with that boundary.

Each response binds the original operation, route identity and outcome.
Output supports exact offsets and complete retained artifacts. Bounded previews
identify truncation and cannot stand in for complete logs. Partial reads,
output publication failure and missing streams are explicit states.

## 5. Notification, scheduling and consumption

Persist the canonical result before announcing it. Persist the notification
before acknowledging producer delivery. Live wake is a hint; startup and
existing maintenance recover undelivered obligations from original records.
A callback failure cannot undo delivery or acknowledge an unread result.

Completion priority must not depend on model-written text or Board content.
Use typed producer/event facts. A delegation or Fusion answer must not be
buried behind unrelated ambient Board activity. Preserve urgency and original
arrival ordering within an admission class. Resource bounds protect actual
memory/FD/backend capacity, not cumulative turns/time/tokens or retry counts.

An event-driven turn already processing one source cannot yield to the same
source still retained for its eventual acknowledgement. Compare exact selected
source identities before considering successors. At a persisted tool boundary,
independent newly ready work must be able to obtain service without replaying
an effect or abandoning the original continuation. Model/provider runtimes
must honor the same host yield contract, or expose their limitation explicitly.

Selection, model-input transmission, successful turn settlement, source ACK
and application of the result are separate facts. A wake counter or cleared
queue alone does not prove result use. Preserve conversation routing: unrelated
connector conversations or add-on invocations do not share reply authority.

Before ACKing a completion at a checkpoint, durably bind its original result
reference into the resumable consumer context and confirm that handoff. A
model round having seen transient observation text is insufficient, especially
when the official-client session is later replaced. Until that binding exists,
retain/recover the original notification. Admission must still service new
successors: retaining the original batch at the head of a bounded intake must
not create a checkpoint/reselection loop that starves every later completion.

## 6. Messaging, waiting and delegation

Delegation submission is asynchronous. The asker's owner lane must not remain
locked while the delegate executes. A -> B -> A and A -> B -> C -> A must be
able to accept independent messages and return original results. Nested waits
release execution leases and transport/session slots; durable dependency
records retain the continuation instead of a blocked model/owner call stack.

Differentiate asking for future work from consuming a dependency's result.
For an actual dependency cycle, return an explicit typed cycle with the exact
participants and keep independent work executable. Do not reject every mutual
message merely because two Keepers communicate in both directions. Independent
reciprocal requests are not automatically a dependency cycle.

Wait targets are original operation/result bindings. A result-only lookup
does not create an automatic continuation. A prepared composition may resume
only its sealed original run and completed start nodes are never re-executed.
Missing, cancelled, failed and unavailable dependencies have distinct outcomes.
No wait holds a global discovery lock, model slot, endpoint session or another
Keeper's owner lane while waiting for its dependency to run.

Recovery of one malformed/unavailable owner must leave other ready owners
serviceable. Discovery, admission, worker lifetime and cancellation cleanup
need independent switch ownership; a reserved worker must actually exist.
Caller observation cancellation does not imply the producer has terminated.

## 7. Resource and scale behavior

Exercise 10, 100 and 300 logical Keeper cohorts with mixed producer types,
runtime assignments and sandbox routes. Distinguish logical Keeper count,
real model calls, live sandbox count and host resources. Three hundred
simulated rows are not three hundred live sandboxes or real-model autonomy.

Use configured endpoint concurrency and actual worker/process/FD capacity.
No long-lived waiting job occupies an SSH control session. Batch discovery
shares read-only inventory only when the frozen backend route is equivalent;
per-owner effect authority and journals are never shared. Avoid repeated full
fleet scans per result or quadratic whole-queue scans at every tool boundary.

Record queue-to-admission and result-to-use latency, throughput, pending age,
FD/process/memory use and backend session occupancy for each fixed cohort.
A stalled owner must not prevent a ready independent owner from completing.
No arbitrary retry cap, TTL, automatic park or cost budget substitutes for a
missing lifecycle transition.

## 8. Implementation units and review boundaries

Maintain native stacked PRs with one reviewable outcome per layer:

1. This contract, fixed acceptance cases and source-backed gap inventory.
2. Completion admission and continuation fairness, including original-source
   exclusion and exact settlement/ACK behavior across runtime adapters.
3. Endpoint protocol and protected durable operation/output registry.
4. microVM and remote-SSH producer adapters plus existing Docker semantics;
   workspace-process and isolated-job effects remain explicit.
5. Wait/delegation dependency lifecycle, independent owner recovery and
   operator-visible blocked/waiting/result/cleanup states.
6. Candidate builds, behavioral and scale evidence, real-model A/B/wake/result
   execution and installation/integration evidence for the selected candidate.

Changes may reveal additional necessary layers; preserve the full acceptance
scope. Independent adversarial review follows each completed work unit.
External coding sessions do not run local Dune builds or watch CI. Request
focused candidate verification when the changed consumer is concrete. Actual
results, independent review, integration, installed identity and live behavior
remain separate evidence layers.

## 9. Fixed acceptance inventory

The canonical host measurement is
`.masc/playground/codex-mcp-client/keeper-async-fleet-20261026/acceptance.json`.
Each ID below must occur exactly once. Every required subcondition needs raw,
candidate-bound evidence before that case is marked passed.

| ID | Required behavior |
| --- | --- |
| A01 | Docker isolated job preserves current isolation, input and durable-result contract. |
| A02 | microVM endpoint-owned workspace process starts without retaining the turn/transport; read/result/cancel use the original handle. |
| A03 | remote-SSH endpoint-owned workspace process has the same lifecycle and survives control disconnect. |
| A04 | Endpoint isolated-job support preserves its separate isolation contract; supported declared routes actually execute it. |
| A05 | Real Keeper submits A, performs independently observable B before A settles, wakes and uses A's exact result in its original task. |
| A06 | Async named/prepared/nested compositions resume the original run, exports and dependencies without rerunning completed effects. |
| A07 | Delegation and Fusion answers reach their original callers despite ambient Board load; failure and cancellation are delivered too. |
| A08 | One running event-driven turn yields safely to a new independent completion without self-preemption or duplicate source ACK. |
| A09 | Direct/ambient messages preserve per-conversation routing while jobs and waits are active. |
| A10 | Reciprocal and three-way delegation progress; genuine dependency cycles are explicit and independent work remains serviceable. |
| A11 | Server/model-session restart, paused owner and failed model turn retain original results until admitted consumption. |
| A12 | Lost start/cancel reply, duplicate submission/delivery, PID reuse and replaced endpoint never launch or signal a replacement. |
| A13 | Cancel before/during/after launch, endpoint teardown and cleanup interruption reconcile the same operation and preserve logs. |
| A14 | Missing/corrupt/truncated output, unavailable producer/store and malformed owner records remain explicit without blocking healthy owners. |
| A15 | 10-Keeper mixed cohort completes the fixed workload with original identities and measured resources/latencies. |
| A16 | 100-Keeper mixed cohort completes the same workload definition with independent owner progress. |
| A17 | 300-Keeper mixed cohort completes the same workload definition without global head-of-line blocking or lost results. |
| A18 | Selected reviewed candidate is built and integrated; installed identity and real-model mixed-sandbox continuation match the recorded evidence scope. |

Each cohort includes completion bursts, slow and unavailable producers,
reciprocal messaging, nested waits, explicit cancellation and restart recovery.
Report unavailable infrastructure as not measured. Source-only reviews,
fixtures, partial CI and self-reported summaries cannot satisfy live execution.

The fixed backend inventory is Docker, Apple Container microVM, Microsandbox
microVM, Nerdctl/Kata microVM and remote SSH. The fixed runtime inventory is
Agent Core, Codex app-server, Claude Code, Antigravity CLI and Muse Serve. Test
each backend's synchronously supported `none`, `inherit` and `policy` network
configurations against asynchronous admission; preserve their existing network
contracts. Record pre-existing unsupported combinations with their source-backed
reason in the matrix, rather than inventing new network support in this change.
No currently supported execution combination may be dropped merely because
the async adapter is missing. All named backends and runtime adapters remain
required even when infrastructure is unavailable: those rows stay not measured.
