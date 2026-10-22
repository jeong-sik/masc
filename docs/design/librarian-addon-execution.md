# Librarian execution as an Addon

This is the next implementation boundary for worklist E03. It is a design based
on source `db31e62fe17f92aea4919de7765f1ace65914772`, not an implemented package,
passing runtime scenario or replacement for E03's original completion criteria:
preserve checkpoint, absorption, Memory lineage and pending work, and verify
Keeper memory continuity.

## Execution must leave authority on the host

The current boundary is more involved than calling an inference helper in a
worker. [`Keeper_librarian_runtime`](../../lib/keeper/keeper_librarian_runtime.mli)
`infer_memory_step` already calls the real absorption judge. Its private
`memory_step` is a gated host decision, not an untrusted model proposal.
`run_best_effort` also publishes Memory or continuity. Neither function is a
worker entrypoint.

| Boundary | Existing owner and contract |
| --- | --- |
| Scheduling and purge | [`Keeper_memory_lane`](../../lib/keeper/keeper_memory_lane.mli) owns each Keeper's serialized running/pending work and cancel-and-await purge fence. A worker's detachment does not establish that old effects have stopped. |
| Input selection and progress | [`Keeper_librarian_durable_consumer`](../../lib/keeper/keeper_librarian_durable_consumer.mli) preserves original checkpoints, official fragments, range identity, commit receipts and cursor recovery. Missing or unreadable input is not an empty batch. |
| Proposal decoding | [`Keeper_librarian`](../../lib/keeper/keeper_librarian.mli) resolves surrogate memory names against the original ordered input. Re-decoding against today's Memory can retire a different identity. |
| Explicit candidates | [`Keeper_memory_admission_judgment`](../../lib/keeper/keeper_memory_admission_judgment.mli) provides the strict wrapper, full candidate coverage, support and exact claim-reference checks. A successful decode is not candidate consumption. |
| Absorption and duplicate checks | [`Keeper_librarian_absorb_gate`](../../lib/keeper/keeper_librarian_absorb_gate.mli) retains unconfirmed source memories. An enabled but unavailable judge leaves the complete range pending. A worker-supplied gate JSON is not a host judgment. |
| Memory and lineage | [`Keeper_memory_os_current`](../../lib/keeper/keeper_memory_os_current.mli) applies dispositions/programs under the existing lock and checks support, concurrent retirement, original destinations and receipts. Do not replace current Memory with a worker's full snapshot. |
| Continuity | [`Keeper_librarian_continuity`](../../lib/keeper/keeper_librarian_continuity.mli) owns original prefixes, holes, generation and snapshot CAS. Its frontier and Memory's committed frontier can differ. |
| Candidate ACK | [`Keeper_memory_admission_queue`](../../lib/keeper/keeper_memory_admission_queue.mli) checks original generation, request ID, sequence, payload digest and the committed Memory receipt before removing sparse settled rows; deferred gaps and a new tail remain. |

## First implementation unit

Implement the explicit pending-candidate judgment as a real persistent Addon
request with host-owned resume, settlement and ACK. Use the existing
[`Lane_addon_runtime`](../../lib/lane_addon/lane_addon_runtime.mli),
[`Lane_addon_tool_request_owner`](../../lib/lane_addon/lane_addon_tool_request_owner.mli),
[`Lane_addon_exact`](../../lib/lane_addon/lane_addon_exact.mli) and persistent
[`exact_worker.py`](../../addons/exact_worker.py) ports. Do not create a second
model broker, per-domain singleton or parallel Memory scheduler.

The host must retain the physical workspace/Keeper identity, queue generation,
complete candidate rows, original ordered current facts, available/unavailable
retirement evidence, rendered prompt/variables/schema and original
installation/package/tool/revision identities before model dispatch. The
worker receives the granted immutable execution request and proposes output.
Credentials, input selection and Memory mutation remain on the host.

Resume must strictly rediscover original work before capturing a new root.
Read an existing host Exact terminal or the original worker request before any
new submission. Retain a dispatch intention before the send. An unknown sent
outcome does not authorize another model call. Package replacement must not
transfer an old request to different inputs, installation or schema.

Retain the raw proposal, validate it against that original input, run the
existing host absorption gate and apply the existing locked Memory disposition.
Only a matching original Memory receipt establishes commit and permits the
existing candidate ACK. A worker's `already_represented` answer or a request
record's terminal flag is insufficient. After a lost ACK, recover the original
receipt instead of generating another judgment.

Off must refuse fresh root/child admission while allowing already retained
results and confirmed local commit/ACK recovery. This differs from the existing
global Librarian disabled policy. Preserve the purge fence, sparse deferred
gaps, newly appended candidates and concurrent retirement checks. Unchanged
deferred, unknown or refused work must not mint a new root on each wake.

Size refusal must preserve the candidate queue's existing disjoint whole-input
partition semantics and its mixed-failure veto. Parent/child intention,
retention, strict reread and acknowledgement need original identities. A
temporary implementation that only parks size-refused work has not preserved
this behavior and does not complete the unit.

## Shared execution gaps that must be resolved

**Admission policy:** builtin Librarian resolves to `Background` admission,
while `Server_lane_addon_exact.execute_http` starts `Standard` flows in the
inspected source. The host must carry a trusted typed admission policy for the
new consumer. Do not silently change fairness, let worker input select its own
priority or add a duplicate operator knob.

**Failure evidence:** the existing Librarian `inference_failure` distinguishes
whole-walk capacity evidence, invalid-output veto, CLI participation and
`exhausted_input_refusals`. The latter authorizes unread-hole behavior only for
an actually exhausted API-only walk with nonempty named provider causes.
Common Addon aggregate `Input_refused` or diagnostic text cannot reconstruct
that proof. Preserve the actual host flow evidence in a typed original receipt
before migrating those consumers. A worker's exhaustion claim is not authority.

**Absorption recovery:** the gate exposes observation JSON but no authoritative
strict `run_result` restore port. Claiming crash-safe gate continuation requires
original state/questions/destination and trusted typed answers with a strict
re-derived decision. Casting observer JSON into a gate result is insufficient.
Any remaining gate reevaluation must be explicit; preserving a raw Memory
proposal alone does not prove that no model call can repeat after a crash.

**Validation binding:** compose the new original-consumer validator with the
existing Curator namespace checks in `Server_lane_addon_exact.validate_request`.
Direct Exact calls and retained delivery must not bypass an original binding by
relabeling its package. Generic partial schema checks do not verify candidate
coverage, surrogate identity, lineage or commit authority.

## Evidence required before claiming extraction

Use actual Store/Runtime/worker scenarios for publication uncertainty before
submit, lost sent outcomes, worker replacement, Off local recovery, gate failure,
commit/ACK loss, concurrent retirement, sparse gaps/new tail, malformed complete
inventory, purge cancellation/late results and typed size versus quota/invalid
refusal. Observe original requests, durable state and decisions; do not add TUI
wording or layout assertions. Then verify a real provider and both UIs against
the matching executable/package identity and preserved original Memory.

E03 also includes ordinary checkpoints and official ranges, continuity-only and
Memory-plus-continuity passes, ordered message-floor programs, unread-hole
authority, working-context organization/review and maintenance. Keep those
paths on the existing host until each has the same original execution and
recovery guarantees. Remove current builtin settings only after their complete
replacement works; preserve retained Librarian history independently. This
first unit and design do not narrow E03 or declare any of the original 54 tasks
complete.
