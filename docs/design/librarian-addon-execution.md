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

The queue now exposes `batch_to_json` / `batch_of_json` for that immutable input
boundary. The closed envelope preserves the original generation and full
ordered candidate rows. Restore must match an independently retained host
list of `explicit_candidate_id` values, including every full-payload digest;
it cannot substitute today's pending batch or accept a worker's identity list.
Sparse sequences and disjoint whole-candidate partitions stay unchanged. This
pure port does not persist or discover the original execution by itself and
does not establish workspace/Keeper/installation authority. The eventual host
capture must bind those owners and Memory inputs separately. Receipt-backed
locked disposition and queue ACK remain the sole consumption path.

## Shared execution gaps that must be resolved

**Admission policy:** builtin Librarian resolves to `Background` admission,
while `Server_lane_addon_exact.execute_http` starts `Standard` flows in the
inspected source. The host must carry a trusted typed admission policy for the
new consumer. Do not silently change fairness, let worker input select its own
priority or add a duplicate operator knob.

The next shared-port implementation returns one host `request_authorization`
containing its pure output validator and typed admission class. The common
broker passes that mandatory class through its runner to the actual HTTP
`Exact.start_flow`. The current issuer first performs the existing Curator
original-binding checks and then grants Standard; a Librarian-looking worker
name does not grant Background. Worker wire/digests and original retained
records remain unchanged, and retained delivery obtains fresh authority without
running another provider. This conduit alone does not implement the Librarian
original consumer, persist a per-attempt class audit, or change one-shot CLI
admission. The eventual Background issuer still needs its strict original host
capture and purpose/destination validation.

**Failure evidence:** the existing Librarian `inference_failure` distinguishes
whole-walk capacity evidence, invalid-output veto, CLI participation and
`exhausted_input_refusals`. The latter authorizes unread-hole behavior only for
an actually exhausted API-only walk with nonempty named provider causes.
Common Addon aggregate `Input_refused` or diagnostic text cannot reconstruct
that proof. Preserve the actual host flow evidence in a typed original receipt
before migrating those consumers. A worker's exhaustion claim is not authority.

**Absorption recovery:** the gate now exposes a separate canonical
`evaluation_evidence_to_yojson` encoder for the existing after-evaluate hook and
a pure `restore` port. The host must retain the original pre-dispatch request,
returned typed response/refusal, original source/proposal inputs and captured
availability with ordered destination identities. Restore rederives each exact
request and the ordinary forward/reverse decisions, checking destination walks
and successful outbound body digests. Live execution and restore share that
decision code. Missing, pending, aborted, changed or extra evaluation evidence
refuses without any provider/configuration fallback; observer JSON is not an
authority format. Original partial failures and judgment-invalid typed answers
remain unsuccessful rather than becoming permission to commit.

The port does not persist or discover the original records itself, bind the
physical journal or recover a provider response lost before its after-hook
write. The eventual owner must retain original input bytes needed to reproduce
the outbound request digest and strictly restore workspace, inputs and gate
authority before calling it. Production Librarian still needs that integration;
a raw Memory proposal or this pure port alone does not establish crash-safe
gate continuation. Any later reevaluation needs an explicit original decision,
not an automatic provider retry on a restore error.

**Validation binding:** compose the new original-consumer validator with the
existing Curator namespace checks in `Server_lane_addon_exact.authorize_request`.
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

## Original host execution evidence through the common runner

The common Exact call now returns a host-only `execution_result` with its actual
outcome and an opaque `Keeper_exact_walk_receipt.t`. The worker's request,
outcome, schema permission and digest format do not gain an evidence or priority
field. The real server captures the original ordered HTTP declaration, catalog
and target fingerprints, visits, generation and measurement evidence, advances,
semantic rejections and complete official-client tail. The current builtin
Librarian also consumes the shared classifier/receipt instead of maintaining a
private exhaustion predicate. This is a production execution boundary; it does
not yet dispatch a Librarian worker or give one commit authority.

A receipt retains typed source observations and rederives policy after strict
restore. Input-only recursive admission partitioning and exhausted API-only
unread authority remain separate decisions. A mixed named capacity plus
size-independent quota/outage failure vetoes recursive splitting. Under the
existing unread contract, that same fully visited, actually dispatched API-only
walk may retain its nonempty named causes. Preflight exclusion, declared CLI,
semantic/invalid output, missing/duplicate visits and local stop cannot grant
that exhaustion authority. Measurement, actual HTTP generation and official
client dispatch are separate observations.

Under the existing original request claim and workspace lease, the broker saves
its started marker, runs the call, then retains and strictly rereads a host result
link before publishing the attempt outcome. One canonical host-built Store link binds declaration and original request
digest, retaining the sparse ordered completed attempts. Every attempt envelope
binds its actual ordinal, original Store root, complete request, schema and
outcome. An Exact record lost after a later ordinal cannot hide its earlier
execution proof or authorize a second dispatch. A worker cannot choose this address. An existing different proof, failed
write or failed read confirmation prevents outcome exposure. No extra queue,
scheduler, registry, lockfile or retry timer is added.

A confirmed proof with its original started marker recovers only that attempt's
local outcome publication. The broker does not resolve a runner or call a
provider again, and a recovered not-final attempt is returned before any later
retry. Missing proof retains the existing unknown outcome; malformed or
unreadable proof refuses rather than becoming absence. The complete original
attempt history is shape-validated before recovery. Delivery still requires
fresh package/request/consumer authority and validation against the current
allowed output; bookkeeping recovery itself grants none of those effects.

`read_original_execution` lets a trusted original consumer read a specifically
bound request/schema/attempt, including while the package is Off. It reads and
validates one original record and the matching durable host link without
claiming, writing, delivering or executing. Generic old finals without proof
remain explicitly unproven. This observation is not Memory lineage, a locked
commit, an absorption transcript, queue ACK or permission to retry a provider.
The consumer must still authenticate its original physical capture and current
Memory/purge/retirement boundary before its separate effects.

The new Store failure/recovery and actual runner/classifier scenarios require
selected compiled verification on their own frozen source. Parser checks and
synthetic broker publication fixtures do not prove real provider capture, UI,
operator installation or completion of E03 or the original54 work items.
