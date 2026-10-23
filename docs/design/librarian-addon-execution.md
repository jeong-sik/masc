# Librarian execution as an Addon

This records the original E03 extraction contract and its current implementation.
The explicit-candidate caller uses its configured Addon for proposals and the
host for absorption, Memory and ACK. The completed-history production queue now
also uses an immutable Addon owner for checkpoint, official-client and mixed
input. Continuity and other purposes remain on their existing host paths.

[Current execution evidence](../evidence/2026-10-23-librarian-history-owner/README.md)
separates successful Pending-foundation and Python-worker checks from the new
host integration selection. Earlier failures and their repairs remain in the
worklist. E03 stays incomplete until its original memory lineage, failure
semantics, pending-work and actual Keeper-continuity criteria are verified.

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
The Workspace Curator and the Librarian share one submit-once journal
(`Lane_addon_submit_once`). Its pre-send destination check runs before the
intent is written. A submit the host refused before sending declines that
intent, so the next pass reads absence and submits the same request again.

Retain the raw proposal, validate it against that original input, run the
existing host absorption gate and apply the existing locked Memory disposition.
Only a matching original Memory receipt establishes commit and permits the
existing candidate ACK. A worker's `already_represented` answer or a request
record's terminal flag is insufficient. After a lost ACK, recover the original
receipt instead of generating another judgment.

Off must refuse fresh root/child admission while allowing already retained
results and confirmed local commit/ACK recovery. This differs from the existing
global Librarian disabled policy. With no attached keeper-librarian Add-on the
owner reports `Addon_unattached` with the waiting candidate count instead of a
repeated failure; candidates stay queued. Preserve the purge fence, sparse deferred
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

## Shared execution boundaries

**Admission policy:** builtin Librarian resolves to `Background` admission.
The Addon host carries that same trusted typed policy for the original
Librarian consumer. Worker input cannot select priority or add an operator knob.

The shared port returns one host `request_authorization` containing its pure
output validator, typed admission class and execution lifecycle/dispatch guards. The common
broker passes that mandatory class through its runner to the actual HTTP
`Exact.start_flow`. The Curator issuer performs its original-binding checks and
grants Standard; the Librarian issuer grants Background only after strict
original capture, purpose and destination validation. A worker name grants no
priority. Worker wire/digests remain unchanged, and retained delivery does not
run another provider. This does not change one-shot CLI admission.

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

The pure port does not persist or discover records, bind the physical journal
or recover a provider response lost before its after-hook write. The explicit
owner below retains the original input bytes and restores workspace, inputs and
Gate authority before calling it. A raw Memory proposal or this pure port alone
does not establish crash-safe continuation. Later reevaluation needs an explicit
original decision; a restore error does not authorize provider retry.

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
semantic rejections and complete official-client tail. The remaining host Librarian paths also consume the shared classifier/receipt
instead of maintaining a private exhaustion predicate. The explicit-candidate
and completed-history owners now use this same proof through their configured
worker. The host alone retains commit authority.

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

## Explicit-candidate capture and execution contract

The production trigger remains
`Keeper_librarian_queue_refresh.run_explicit_admission` followed by
`Keeper_memory_admission_worker.run`. The candidate implementation below replaces
the latter's execution with original discovery, worker execution, absorption,
locked Memory disposition, verified receipt recovery, candidate ACK and both
children of a whole-input partition. Source integration is not execution proof
or completion of the wider extraction.

The immutable execution capture binds the actual workspace and flat keepers
root path/device/inode, canonical Keeper ID and existing Memory incarnation
epoch. There is no per-Keeper subdirectory inode to invent. Root preparation
uses the existing `Current.capture_program_anchor` before observing that epoch;
observation itself does not create it. An owner-specific original Store scope
and a host-minted tagged request identity make complete discovery independent
of other Keepers and older epochs, without a new index. Incoming Exact requests
can derive only the lookup scope from that identity and must still restore the
full original physical capture and acknowledged part ancestry.

Original prompt preservation includes the resolved main template and fragment,
the actual advisory Memory limits, ordered variables, substitution JSON byte
strings, full rendered prompt/schema and stable parsing time. Restore uses those
captured values; a later prompt override or advisory environment change cannot
reconstruct an old request. Other Librarian purposes are refused by this explicit
candidate capture rather than replacing their conversation/context with empties.

The common configured tool-call port retains the original logical installation,
package/tool and semantic configuration revision while the existing configuration
and action serializers cover fresh complete declaration confirmation through the
worker RPC. Local original publication is cancellation-protected; the actual RPC
remains cancellable. A source review caught a shield extending across RPC and it
was repaired before this unit's freeze. Cancellation execution tests remain
required. Raw source revision is provenance, not a reason to transfer or rewrite
an existing request after an otherwise equivalent configuration edit.

The absorption journal must replay returned evaluations through the gate's
existing derivation before continuing only the next not-yet-intended question.
An intended request without its returned evidence remains unknown. The actual
captured authority, raw proposal, parent input and before/after transcripts are
joined again before any decision; observer JSON and a worker judgment cannot
replace them. A known unsuccessful complete gate may have a separately retained
successor attempt on an explicit host trigger. Restore errors do not grant that
successor.

A mandatory boundary is terminal-frontier supersession. Suppose an
original candidate is semantically deferred, then new candidates or material
Memory changes arrive. The current worker judges the pending input again; an
immutable root must not permanently lock those deferred candidates out. The new
owner must retain the complete changed input and the qualified original terminal
frontier it supersedes, preserve both histories, and prevent unchanged wakes from
minting another root. Unknown or failed prior work cannot silently become a
retry grant. Recursive parts also need their original left-before-right traversal
and fresh Memory capture at the moment each sibling is actually evaluated.

The Python request worker has a bounded process-level persistence probe: ten
actual MCP frames cover retained submission, full original role/schema listing,
rebound-input refusal, terminal retention and process restart. Its host result is
synthetic, so it proves neither semantic authority nor OCaml host execution,
provider capture, absorption, Memory or ACK. The complete production owner and
actual Runtime/Store/failure execution results remain required before this unit
can advance to end-to-end qualification.


## Actual explicit-candidate owner candidate (2026-10-22)

`Keeper_librarian_queue_refresh.run_explicit_admission` still submits through the
existing `Keeper_memory_lane`; `Keeper_memory_admission_worker.run` now delegates
to `Keeper_librarian_admission_owner.run`. There is no second scheduler. The
owner restores the complete original part/execution/gate inventories before
local recovery, candidate ACK or fresh work. `Queue.read_generation` preserves
the address of an original request even when a persisted queue becomes empty.
Scope identity includes the physical workspace/keepers roots, Keeper and that
original queue generation. The complete capture additionally binds the required
Memory epoch, so epoch loss or replacement cannot hide an old request by moving
its lookup address.

Fresh capture uses the real resolved prompt/fragments, ordered original Memory,
policy values, stable parsing time, complete sparse candidate payloads,
retirement evidence and actual semantic Addon destination. The worker retains
or reads that exact request; the shared host Exact runner invokes the full pure
admission validator. Its execution-only guard checks current configured
semantic authority before actual measurement/generation dispatch, including
waiting for a provider permit, while completed originals remain locally readable
when Off. Lost or uncertain worker admission never grants a resubmit. Worker
terminal JSON and restored host judgments must equal the retained original host
terminal; call finals additionally require its latest completed execution proof.
Absent or open host evidence cannot authorize Memory, ACK or supersession.

New host executions register an inline cancellation scope in the existing
Keeper Memory-lane entry, from the initial guard through result/proof publication
and cleanup. Purge fences new registrations, signals the ordinary drain and all
external scopes before joining any, then waits for their actual exits. Retained
terminal reads do not register execution. This lifecycle is source-integrated;
its actual provider-cancellation scenario still needs compiled execution.

Only actual exclusive host input-capacity proof permits two whole-candidate
children. The existing Owner/Progress journal retains both original children
and acknowledges their exact publication before either runs. The right child
captures Memory at its actual turn after any left-side commit. A terminal
semantic Deferred remains immutable on an unchanged wake. A new tail or
material fact/provenance change can qualify a new full pending batch, including
old gaps, through independently verified original terminal/receipt evidence;
ordinary failure and unknown execution are not supersession grants.

Before the first absorption evaluation, the Judged execution retains a full
preparation intent containing the immutable Gate root request and authority.
Local recovery publishes and confirms only that same child, then acknowledges
publication in the parent. Gate execution and Memory commit cannot precede this
acknowledgement; a missing acknowledged child is an error. The Memory disposition
intent is recorded after the Gate completes. Gate requests and returned
transcripts are host-owned. Known-failed retries retain their exact successor
before child publication and acknowledge it before execution. Pending successor
publication can recover only that same child locally; missing acknowledged
history refuses. Restoring completed gate evidence calls no provider.

`Keeper_librarian_admission_commit` validates the original answer and gate chain,
then passes the original disposition/support/required destinations and recall
revision to `Current.apply_disposition`. It merges under the existing Memory
locks instead of replacing a captured full snapshot. Actual matching committed
candidate receipts alone authorize a Finished observation and sparse queue ACK.
Unknown local disposition is reconciled against those same receipts before a
local retry, without another model or gate evaluation.

`Server_librarian_addon_wake` only subscribes to existing Runtime owner events.
A switch-owned child restores the original owner after yielding, then signals
the existing per-Keeper queue wake. Configuration/export hints scan actual
pending queue names. The callback performs no filesystem or Runtime reentry;
shutdown fences copied callbacks and removes this exact subscription.

An unresolved original returns Pending without scheduling itself merely because
a later queue tail exists. Immediate tail recheck requires a completed frontier
walk. Invalid execution evidence remains Unavailable rather than becoming a
normal wait or a partial-success result. In the shared worker, request-local
Exact/ask/delivery errors remain diagnostic and are attempted only once per
cycle, while other requests can continue. Listing/protocol/global-runner failures
still stop the cycle. Purged originals are not rewritten as successful results.

The explicit-candidate production fixture uses actual Runtime, persistent Python worker,
loopback HTTP/common Exact, serialized Memory lane, original journals, Current
receipts and queue ACK. Its resource-launch edge is substituted; it does not
prove Docker, paid-provider execution, installed native binaries, either visible
UI, other Librarian purposes or the original E03 continuity requirement. The
server wake case substitutes only the final queue-refresh scheduling callback
with the same Memory-lane/public-worker consumer. Earlier selected runs failed
on declaration, lifecycle or typing defects. After those repairs, the explicit
owner suite passed 22 cases on exact `3fdc42ef7e33e70f555ac10e40112875a45fff34`
in [run39886511979](https://github.com/jeong-sik/masc/actions/runs/39886511979).
That result does not certify the later completed-history owner.

## Complete original input data

`Keeper_librarian_input_capture` is the common pure data codec used by the
explicit-candidate capture. It retains all ten `Keeper_librarian.input` fields,
including ordered current facts, original Goal read failures, historical source
spans, counterpart provenance and the complete working-context input. Previous
pocket identity, merge references, completeness and execution basis remain data;
they do not become current execution authority merely by being restored.

A provider/checkpoint message projection is insufficient here. The current
Agent Core checkpoint codec omits `ToolResult.json`, and its provider content
encoder sanitizes some text and projects reasoning details through their raw
provider value. This capture instead retains every typed message/content field,
recursive tool-result blocks, parsed JSON presence separately from a JSON null,
and both raw and typed reasoning detail text. Metadata is an ordered entry list,
so repeated speaker entries remain repeated and retain their original position.
Restoration does not reinterpret malformed/duplicate attribution as a single
trusted speaker. Embedded JSON and speaker content remain untrusted data.

The actual explicit-candidate capture uses this codec but continues to refuse
nonempty conversation, historical spans, tool/counterpart observations and
working-context input. A shared data representation does not permit relabeling a
durable-history pass as an admission pass, and it does not give the worker any
Memory, source, cursor or host gate authority.

The completed-history owner below retains the actual checkpoint prefix and
selected official fragments, both progress positions, source generation,
counterpart/external cursor witnesses, immutable prompt and exact request. The
codec remains a data port: source freshness, execution and publication authority
come from the host owner and its locks rather than from restored input alone.


## Typed suspension and completed-history owner

The durable commit port now distinguishes `Memory_pending` from a committed
snapshot and a refused pass. It returns `Pending` without message-floor inference,
a new Memory mutation, external acknowledgement or atom/official cursor advance
by the consumer. The original owner may already have a real Memory receipt while
its external ACK or position settlement remains unfinished. That state stays
Pending until the original owner completes settlement.
A successful receipt recovery still runs before a new commit callback. Suspension
preserves the failed-range marker that existed before the pass: it neither turns
a previously wide selection into a narrow retry nor clears an earlier failure.

The actual queue drain returns its typed `pass_end`. Both queue signals and boot
catch-up stop the same wake's continuity, context and cleanup phases when that
result is `Pending`; they do not consult an observation snapshot to decide what
to run. Exceptions and cancellation retain their original propagation, and no
new timer, polling loop or immediate retry is introduced. Later external wakes
continue through the existing serialized Memory lane.

Memory health carries `pending` separately from stopped, failed and drained.
The server, strict Dashboard decoder and typed TUI decoder preserve it without
adding a stopped alert or changing the unread count. This is observation of the
real drain result, not permission to dispatch, consume input or commit Memory.

The production `run_durable` queue calls
[`Keeper_librarian_durable_execution`](../../lib/keeper/keeper_librarian_durable_execution.mli).
It strictly inventories retained originals before fresh selection, resolves the
configured `keeper-librarian` / `derive_memory` export, and retains the original
under the Runtime destination serializer before submitting it once. The worker
shares the existing Exact runner; credentials and background admission remain
on the host. An original host proof must confirm the worker answer before raw
proposal decoding or publication.

[`Keeper_librarian_durable_commit`](../../lib/keeper/keeper_librarian_durable_commit.mli)
uses the original captured gate journal, holds actual source locks, and passes
the original revision and full current facts to `Current.apply_disposition_guarded`.
The latter compares both inside its actual Memory write locks. Only matching
atom/official range receipts permit external ACK and original position
settlement, followed by Finished. A post-Memory ACK failure recovers locally
without a second inference or disposition. Changed checkpoint prefixes,
same-trace restarts, physical owners and Memory epochs refuse old authority.

A concurrent explicit Memory write can make a completed model answer stale.
Only a typed basis mismatch observed inside the actual Current write locks,
followed by absence of the original range receipts, closes that original as
`Conflicted`. Storage failures and unknown effects retain their original
uncertainty. An already proved Memory receipt takes precedence over the typed
mismatch; earlier journal recovery may already have published that effect.

For a known basis conflict, a successor preserves the complete original source,
external frontier and captured positions and changes only its current Memory
input/preparation. The parent durably records the full immutable successor
before child retention, then acknowledges that exact retained child before any
RPC. Both links and full payloads are authenticated before resume. An unfinished
intent recovers that same child locally; a confirmed child that disappears
refuses rather than minting another request. The old conflict history remains
available after its successful successor uses the same source range receipts.
Fresh successor capture/inference requires current configured Addon authority.

Addon Off prevents a new original, new gate intent and new gate evaluation.
An existing gate intent/transcript and receipt-backed settlement may recover
locally; an old original cannot
become a new request merely because the package is replaced. This differs from
the existing global Librarian disabled policy, which skips the entire durable
queue. With no configured history export, source input stays unread. A blocked
original retains its journal/error evidence. An unfinished-publication error
suspends the same wake's following Memory phases; ordinary Pending does not
carry a separate live detail string. Neither unknown work nor a malformed
inventory is absence.

The [execution receipt](../evidence/2026-10-23-librarian-history-owner/README.md)
separates passing foundation/worker checks, the actual first host integration
failures and later repairs. The integration fixture uses real Runtime, Python
worker, host Exact HTTP/server authorization, Memory lane and files; resource
launch/cleanup and provider HTTP are substituted. Absorption-model policy is
disabled in that fixture. History capacity/failure descent, remaining Librarian
purposes and actual Keeper continuity still require implementation/verification.
E03 and the original54 acceptance criteria remain incomplete.
