# Workspace Curator: accepted work and Addon execution

This is the proposed E02 implementation contract under the
[Addon worklist](../../reports/addon-lane-full-worklist-20261021.md).
It specifies the execution boundary. The [Curator worker](../../addons/workspace-curator/README.md)
and [shared host semantic port](workspace-curator-semantic-validation.md) are now
implemented. The original admission consumer now captures actual Runtime
provenance and reads/submits/restores the original worker result. Its separate
commit consumer now applies and recovers original Ledger/Briefing judgments;
scoped lifecycle/result wake delivery now signals the existing owner. Production
scheduler switching remains.
This is not a claim of completed extraction or an installed replacement.

Source baseline: `3145acf9fc32ab77c25d97ab7e5710194cd270cf`.
The Candle receipt follow-up changes neither Curator nor its domain interfaces.

## Decisions and existing owners

Keep one server-owned Curator for each physical workspace. Its current
[`start_with` owner](../../lib/server/server_workspace_memory_curator.ml)
serializes classification and briefing, listens to memory commits and exact-lane
configuration changes, and parks when idle. Preserve this owner and its
`request` wake; a package must not create a second fact scanner or polling loop.

Extract execution of both classification and briefing, including their accepted
request/result lifetime. A callback that merely invokes a model through another
process does not satisfy E02: the original batch must survive an owner restart,
Off, a disconnected worker and a delayed result.

| Boundary | Authority that remains on the host |
| --- | --- |
| Fact intake | `Workspace_memory_context.collect`, physical workspace identity and exact source-bound fact references |
| Classification input | `Workspace_memory_request.prepare` and its selected/remaining whole facts, rendered prompt and original ledger |
| Classification decision | `Workspace_memory_decision.decode` and the pure `Workspace_memory_ledger.apply` against the captured selected facts |
| Durable effects | The original serialized owner calls `Workspace_memory_ledger.save`; a worker cannot write the ledger or Keeper memory |
| Briefing input | `Workspace_memory_briefing.prepare`, source/contract identity, fixed pass and last complete publication |
| Briefing decision | `decode_output`, `accept` and host-owned `save`; a partial chunk never replaces the published summary |
| Model execution | The existing Addon common Exact runner owns provider admission, credentials, route selection and the original terminal result |
| Resource lifetime | The common Addon installation/instance/incarnation owner owns worker detach, cancellation and cleanup |

The existing host `validate` callback already calls pure `Ledger.apply` during
semantic candidate validation; classification repeats decoding/apply before its
save. The briefing callback similarly validates `decode_output`/`accept` without
saving. Preserve these full domain checks when moving the transport: a package
schema success is not a ledger or briefing commit.

There is another concrete gap before that commit: the current HTTP flow invokes
these pure host checks **before candidate acceptance**, using
`Reject_and_advance` for a schema-valid but domain-invalid answer. CLI candidates
receive the same validation. The common Addon Exact runner originally validated
only package/request schemas. The [trusted semantic port](workspace-curator-semantic-validation.md)
now binds original Curator captures before candidate acceptance and retained delivery;
production owner capture and worker integration are still required.
Checking only after the worker retains a terminal answer would silently lose
this semantic fallback. The extraction must provide a shared host-owned
validation port inside the original admitted flow, before terminal delivery,
without creating a new request or restarting the candidate order.

Bind that validator to the trusted captured classification/briefing request and
its original selected facts/ledger or briefing batch. It is pure validation,
not commit authority. A worker cannot select a privileged validator by naming
one in its arguments, and optional input/output Hooks cannot disable it. Restore
the same binding from strict host state after restart. Missing or conflicting
semantic validation authority must refuse dispatch, rather than accept a
schema-only result as a Curator judgment. The shared validation integration is now implemented as described in the semantic
port document; this document alone does not prove execution or production wiring.

## Two request kinds, one retained execution contract

Classification and briefing use separate declared Exact outputs. They are not
one permissive schema. Keep the current classification output schema and briefing
`{"briefing": <nonblank string>}` schema. No fact IDs, audit context, provider
credentials or installation ownership supplied by a model may become authority.

Before the first worker RPC, the host must retain an immutable accepted request:

- An opaque host request identity and kind, physical workspace binding, original
  batch/pass identity and exact selected/remaining fact or source references.
- The captured input, effective prompt, schema/contract and their digests.
- The original classification ledger snapshot or briefing prepared-state and
  expected publication identity needed to validate and recover its commit.
- The admitted installation/package/tool binding, request digest, source and
  configuration revisions. Worker incarnation is an execution reference, not
  the identity of a durable fact or the right to claim another installation's work.

Mint a request identity once and retain it with this capture. The current Curator
mints an observer run ID inside each classification/briefing attempt; that alone
cannot identify accepted work across restart. Do not derive identity solely from
prompt bytes: an explicit later pass may legitimately use equal input.

Use `Lane_addon_runtime.retain_tool_request_owner` before any RPC to preserve the
existing installation fence. Its backing `Lane_addon_tool_request_owner.retain`
now stores the complete canonical request with its digest and destination, and
`load` strictly restores a known key. The batch codecs preserve classification
and briefing input; the trusted provenance envelope above is still required.
Recovery also needs typed enumeration and an accepted-work/commit lifecycle
before the consumer is wired; an execution-history row or known-ID load is not
this authoritative journal.

The package retains opaque requests and their common Exact terminal results in
installation state. It has no workspace ledger path, Keeper memory directory or
provider credential. Reuse the common host-request/result protocol and the
request-schema grant; do not add another provider client, route registry or a
Curator-only background broker. Reusable retained-request storage is now shared
with Candle in `addons/exact_worker.py`, including its MCP control loop and
terminal lifetime. Domain request codecs and host commit logic remain separate.

## Result, uncertainty and commit recovery

The original host owner reads the retained request first. Only an authoritative
absence at its bound installation can admit that same immutable request.
Transport loss is neither absence nor a terminal model decision. A reply for a
different identity or changed request digest is rejected.

| Observed boundary | Required effect |
| --- | --- |
| Not dispatched / worker unavailable | Keep the accepted host capture and pending facts; do not consume or replace them |
| Retained pending result | Keep the same request and owner; a wake/read does not submit another model request |
| Valid answered result | Revalidate the captured schema and full domain decision, retain that judgment, then let the original host owner commit |
| Domain-invalid candidate output | Preserve rejection evidence and the existing original-flow semantic advance before terminal acceptance; no ledger mutation, fresh request or reset of candidate order |
| Exhausted semantic candidates / terminal execution refusal | Preserve the original terminal and typed failure after the existing HTTP/CLI fallback policy; no ledger mutation or synthetic success |
| Unknown provider outcome | Retain uncertainty under the original request; never turn it into `absent` or automatically redispatch it |
| Size refusal | Preserve current classification narrowing for input/output-size refusal and briefing narrowing for input-size refusal only; use whole-row `Request.narrow` / `Briefing.narrow`, retain the child batch and predecessor, and never truncate prose |
| Failed or uncertain ledger/briefing save | Reload authoritative state before deciding whether the original commit happened; never interpret an I/O error as proof of no write |
| Observer receipt failure | Preserve the judgment and domain commit truth separately; retry recording without replaying the model or domain effect |

The current `execution_failure` has only input-size, output-size and generic
execution failures. That type is insufficient for a polling Addon consumer:
`pending`, transport unknown, terminal unknown, rejected input and a commit
failure have different recovery meanings. Introduce and exhaustively consume the
typed boundary before wiring the asynchronous path. Do not feed `pending` into
current generic-failure/narrowing logic and mint a fresh attempt on every wake.

`Ledger.save` explicitly allows an error after replacement. A recovery record
must retain enough original input and expected post-commit identity to recognize
an already applied result, or report a conflict after a fresh read. It cannot
use `Already_disposed`, a stale in-memory ledger, or a matching observer outcome
alone as proof that this exact request committed. Briefing recovery must likewise
preserve the exact pass target and prior publication; additions wait for the next
pass, while removed/modified sources and contract changes follow `prepare`'s
existing reset rules. No partial summary is published as a completed pass.

## Off, reconnect and wake delivery

Off refuses new work. Already accepted work keeps its original identity and
explicit outcome: current in-process execution can finish; external execution
may finish or be cancelled by its common owner, whose terminal/unknown result is
then retained. Do not claim that selecting Off proves the provider stopped.
Pending facts and the last complete briefing survive throughout.

A new incarnation on the same installation can read retained work. Another
installation cannot claim authoritative absence and repeat it. An explicit
replacement must preserve the original terminal/conflict/unknown state and admit
any successor as a distinct host decision, not silently change the destination.

`Lane_addon_runtime.subscribe_owner_events` now signals the existing Curator
owner for the actual served Store root and `workspace-curator` package. It keeps
`register_tool_change_handler`, the single MCP inventory bridge, intact. Typed
hints distinguish export inventory changes, matching configuration publication
and accepted original Exact-result delivery. These are hints to reload state,
not worker readiness, provider completion, or domain commit authority.

A worker can become ready before `configuration_status` contains its declaration.
Configuration notification follows that metadata assignment and mutex release.
Its change identity includes the directory, completeness and the package's actual
declaration id/path/source revision/desired revision/enabled values. An unchanged
maintenance pulse does not publish another configuration hint. Removing or
changing a declaration can wake the previously associated package as well.

Exact-result hints require a strictly decoded `accepted=true` response and the
same live original authority after the worker RPC returns. Fresh and restored
terminal deliveries share this edge; a restored hint does not rerun the model.
An unaccepted, malformed, failed or non-Exact delivery cannot invent this fact.
Raw exported-tool `on_result` callbacks do not publish accepted host-result hints.

Subscribers synchronously signal only: no I/O, yielding, or reentry into Runtime
and worker locks. They run outside the subscription mutex; lifecycle publishers
can still hold their own locks. A failing or separately cancelled subscriber is
isolated, while cancellation of the publishing fiber propagates. Unsubscribe
removes only its original registration and is idempotent. The Curator fences its
stopped owner before switch cleanup unsubscribes; copied callback snapshots
therefore cannot revive it. Registration neither replays state nor starts a
worker, so the original initial drain remains necessary.

The server passes its actual `Workspace.config` to Curator startup. The real
host-cycle fixture includes the ready-before-metadata race, workspace/package
isolation, MCP coexistence, accepted/restored Exact replies, observer failure and
negative receipts. A separate case parks the real Curator with an existing fact,
changes its controlled admission predicate without signalling, then changes an
actual Addon declaration. The resulting metadata hint must cause the original
owner to classify that fact without another memory commit. Only the predicate
and model answers are injected. This does not prove the production Addon
admission/settlement loop or an installed browser/UI.

Activation, availability of a worker and selection of a model route remain
independent observations. Curator stays Optional, while the Required contracts
for HITL and Board Attention are unaffected.

## Evidence needed to close E02

1. Strict captured-request round trips and changed request/destination refusal;
   saved capture precedes the first real worker RPC.
2. Real worker restart retains a pending and a terminal classification request
   and briefing request. Original IDs, batches and route/slot joins survive.
3. The actual serialized host owner applies classification exactly to its
   selected facts, publishes briefing only after the complete original pass,
   and preserves unrelated/deleted/source-bound facts under the existing rules.
   A schema-valid but domain-invalid first candidate must still advance to the
   next admitted HTTP/CLI candidate before terminal delivery, with the same
   request identity, complete validation and rejection evidence.
4. Off with accepted work, reconnect without a new memory commit, delayed/unknown
   result, malformed output and save failure leave explicit recoverable state.
   Reading an already committed result does not repeat its domain effect.
5. Matching-source host/worker artifacts, real model calls, actual Dashboard/TUI
   request/result/cleanup observations and preserved before/after ledger and
   briefing bytes. Package-only fixtures, parser success and source review are
   recorded separately from that end-to-end proof.

Next coding boundary: switch the existing serialized production owner to the
original admission and domain commit consumers, preserve typed size refusal and
whole-batch successors, and consume the scoped result/export wakes in that recovery path.
Keep domain authority on the host throughout; the current scheduler has not
switched to the incomplete extraction.

The first [batch and known-request storage foundation](workspace-curator-request-capture.md)
retains complete request data and validates original classification rows and
briefing partitions. Its original scope did not include host provenance or
lifecycle integration. Subsequent [host capture](workspace-curator-host-capture.md),
[progress](addon-original-request-progress.md),
[discovery](addon-original-request-discovery.md) and
[semantic port](workspace-curator-semantic-validation.md) provide those distinct
foundations. The admission consumer below now captures actual Runtime metadata
and restores original worker results. None of these individual foundations
establishes the remaining production scheduler integration.


## Original admission consumer implementation

`Server_workspace_memory_addon` uses the original Runtime action serializer to
capture the live configured installation, actual declaration source revision and
admitted configuration revision. Its pure capture factory retains the complete
original capture before any RPC. The same configured destination is rechecked
for resumed calls, while original captured revisions remain immutable audit
facts rather than being replaced by today's values.

Every pass strictly reloads the original host record and restores its physical
workspace. New work reads before admission and submits only after a newly stored
intent. An explicit capacity non-admission permits another read/admission of the
same original ID. Pending, unknown, missing-after-dispatch, uncertain journal
publication and Already_stored cannot send another submit. A complete late
answer is fully domain-validated before retaining a judgment. Terminal unknown
and other execution refusals retain their original final as an Execution refusal;
they need no worker on replay. Domain judgments also restore without a live
worker; commit states are returned to the original owner without applying them.

Consecutive equal pending, missing-after-dispatch or transport-unknown
observations return the original record without appending or replacing it.
Changed kind/evidence and nonconsecutive recurrence remain distinct facts.
Explicit capacity non-admission and terminal refusal retain their separate
lifecycles. Equal commit-read uncertainty also reuses its original evidence.
Strict fresh journal/workspace/worker reads and their durability verification
still run; deduplication is not a freshness cache or a new admission permission.

This adapter does not create another scheduler or model runner. The current
production Curator scheduler has **not yet switched** to it. That switch must
still prioritize accepted-work recovery even while Off, preserve input/output
size refusal and whole-batch successor linkage, call the original domain commit
consumer under its existing workspace lease. Scoped original result/export
hints are now subscribed alongside the existing MCP inventory callback.
`capture_*` publication failure still requires original discovery, not another
fresh request. No extraction, production recovery or Off/On completion follows
from this source alone.

## Original domain commit consumer

`Server_workspace_memory_addon.settle` strictly reloads the original record and
physical capture. It decodes the original Answered final and repeats full domain
validation. Recorded commit before/after values must equal those derived from
that capture; journal payloads cannot supply arbitrary replacement domain states.

The owner retains the same workspace lease and serialization from this read
through actual save, fresh confirmation and progress recording. The short Runtime
capture mutex does not replace that owner boundary. The commit consumer uses no
worker, provider or model route, so already accepted judgments remain recoverable
while the installation is Off.

| Fresh domain observation | Commit action |
| --- | --- |
| Exact expected after | Record confirmation without another save, including no-op results |
| Exact original before with newly Stored intent | Recheck source eligibility, call existing domain save, then freshly confirm after |
| Recovered intent and exact before | Record unknown, freshly read again, retain a new retry observation, recheck again before saving |
| Unknown and exact before | Only a newly Stored retry observation can permit saving |
| Other readable state | Record conflict and preserve the entire current domain state |
| Unreadable or malformed state | Preserve original commit uncertainty; never interpret it as before, after or absence |
| Already_stored or unconfirmed intent/retry | Recheck the original journal on a later owner pass; do not save |

Save errors do not identify a filesystem stage. Errors or cancellation can
follow publication. A returned save success also needs a fresh domain read;
confirmation receipt failure does not undo or repeat the domain effect. Exceptions
from the save edge retain uncertainty under cancellation protection and propagate
the original exception/backtrace. An interrupted intent is not permission to
write until recovery establishes a new retry fact.

Classification checks selected source readability, exact current selected facts
and reconciliation of existing captured ledger members. An unreadable selected
store is unavailable, not an empty store. Other newly arrived facts can wait for
the next batch; another owner's ledger update is never merged into the original
answer or overwritten. Briefing checks the current ledger's source identities
and effective prompt contract using the same pass-preservation rule as `prepare`.
Added sources wait; removed/changed targets and changed contracts conflict.
Partial `accept` changes only building progress and preserves the last complete
publication. Only the final original chunk replaces it.

`capture_briefing` requires a fresh complete match with `prepared_state` before
retaining model work. The production owner must preserve its existing initial
prepared-state save and confirmation before capture/submission. This adapter
does not invent a pre-prepare state or create the prepared pass after inference.
Initial-save/capture crash recovery, restart drain priority, observer receipts
and successor linkage must still be connected by that owner. Result/export
hints now wake it; a wake does not itself recover accepted work.

`test_workspace_curator_addon_commit` uses actual Keeper snapshots, host record
reopening, Ledger/Briefing writes and fresh domain reads. Save-edge refusal/lost
receipt cases inject a boundary outcome around actual storage; they do not prove
an actual pre/post-rename filesystem failure. These scenarios, source parsing,
independent review and CI execution are separate evidence layers. They do not
establish production scheduler, installed UI or real provider completion.


## Actual selected-execution failure and repair

The seven-suite selected run
[39671034185](https://github.com/jeong-sik/masc/actions/runs/39671034185)
on `ea9f86ff1f5b5b46cd5375f39885dbb71e5b212a` completed with failure before tests:
`observe original.progress` lacked an `Owner.retained` parameter annotation.
The annotation belongs to the original admission layer, PR #44944. The equivalent
first use in commit `uncertain` is annotated in PR #44948 as well. The prior
consecutive-observation fix and its real file identity/bytes fixture were moved
into #44944 itself, rather than relying on an upper layer to make it safe.
Its intermediate `e3d28089451b475ae5c475ae017528ab9e84a591` received formal source
approval; that approval is not certification of the subsequent compiler repair.
A selected execution on the new published head is separate evidence.


## Typed size refusal before production owner switching

The common Exact final now preserves `Output_limit_reached {detail}` as the
strict wire object `{"status":"output_limit_reached","detail":<nonblank text>}`.
Only Agent Core's typed `Output_limit_reached` maps to the new shared
`Exact_lane_failure.Output_limit`. Invalid JSON, schema/domain rejection,
incomplete/missing output and an oversized transport response stay separate.
The common worker codec, retained host replay, original Curator refusal journal,
Candle appraisal and Browser/Stagehand consumers all explicitly consume it.
Operator Quiz maps it to its existing failed-author / waiting-grade policy;
it does not reduce input or create another request for this output result.

The original candidate walk still tries its admitted HTTP and official-client
tail. A later valid answer wins. Otherwise transient, configuration and auth
failures outrank a terminal; input refusal keeps its existing priority, then
output-limit evidence, then ordinary invalid output. No new size cap is imposed.

Before dispatch, actual context overflow and measured input rejection preserve
`Input_refused Input_capacity`. Missing token measurement or expired,
not-yet-valid or ambiguous capacity evidence is `Transient`: none proves that
smaller input is required. Old retained terminals are read as originally stored,
without inference from detail text and without redispatch.

The production Curator switch must consume these typed facts with its original
policy: classification can narrow whole rows on actual input or output-size
refusal; briefing narrows only on input-size refusal. Invalid_request, generic
invalid output, pending and unknown never grant that narrowing. A successor
needs its own retained child capture and durable predecessor link. Those owner
and successor changes remain pending; this layer does not create a second
scheduler or claim production extraction.

Verification maps changed interfaces to their direct consumers:

| Changed boundary | Consumer and focused verification |
| --- | --- |
| Shared failure classification and Exact final codec | `test_exact_lane_failure`, `test_lane_addon_exact`, real HTTP/CLI-edge and capacity-evidence cases in `test_lane_addon_exact_runner` |
| Original Curator terminal/refused restoration | `test_workspace_curator_addon_contract`: actual journal reopen, original refusal, no worker replay, no replacement write |
| Candle and browser final translation | `test_candle_appraiser_transport`, `test_browser_addon_models`, `test_browser_addon_locate`, `test_browser_addon_stagehand_model` |
| Actual shared-worker persistence and separate Quiz consumer | Python Curator 7, Candle 14, Quiz Flow 68 cases passed on hashed working-tree Python source; actual worker subprocess restarts, controlled model answers |

The earlier [eight-suite run39674624863](../evidence/2026-10-22-curator-owner-wakes/selected-execution.json)
is completed/success at exact `af9e1eeefe9b8b17fe82c643e9344aa3df87416a`, 147 cases,
including seven new owner-wake cases. It verifies the prior admission/commit/wake
candidate, not this newer size-refusal layer, a live provider, browser or UI.
A selected compiled execution for this layer is separate evidence.


## Durable size successor, before production scheduling

The original owner now retains one `Successor_intended` fact containing the
child ID and its entire canonical capture, then retains and strictly reloads
that child, then records `Successor_observed`. Subdividing/Subdivided keep the
original execution refusal. This is recoverable publication across two records,
under the existing serialized workspace lease; it is not a cross-file transaction.
The link operation makes no worker call, model call, domain save or observer ACK.

Capture format `workspace.memory.execution-capture.v2` requires an explicit
nullable predecessor. Root constructors emit null; a child records its immediate
original parent. The decoder is strict: missing predecessor and old-format
records are errors, not inferred roots. This branch has no production scheduler
cutover or installed-data migration. Before any child resume, commit or direct
Exact authorization, strict restoration reads every ancestor and requires the
matching acknowledged child, original size refusal and complete deterministic
whole-batch reduction. Missing/unreadable parents, cycles and mismatches refuse.
A child retained before parent acknowledgement cannot execute.

Classification permits whole-row bisection on typed input capacity, context
overflow, request-body refusal or output limit. Briefing permits the three input
refusals only. Invalid_request, ordinary invalid output, unknown, pending and
pre-dispatch refusal do not authorize a successor. One indivisible source
returns Indivisible without truncation or another request. The captured template,
workspace, ledger, destination revisions and complete prefix/remainder survive;
neighbors are not recollected. Briefing.narrow preserves the identical prepared
state and previous publication, so linking performs no extra domain write.

A recovered Subdividing intent reuses its existing child ID and input. An
unreadable/conflicting child is never absence. After Subdivided, absent child
history is an explicit error: it may have dispatched before its record was lost,
so the parent must not recreate it as Captured. Repeated or nested narrowing
preserves existing child progress and never creates a sibling from the root.
An uncertain publication requires fresh original reads; errors never mint a
replacement ID. The production owner, original Off recovery and initial briefing
prepared-state save still require integration with these boundaries.

Focused verification follows the changed interfaces: Progress -> strict owner
history (`test_lane_addon_request_progress`/discovery); Capture.restore -> root
capture, original admission/commit and direct Exact authority (capture/commit/
contract/common runner suites). Fifteen new commit-suite scenarios exercise real
parent/child storage, reopen at intent/child boundaries, pre-ack refusal, missing
acknowledged child, conflicting child, missing/cyclic ancestry, nested narrowing,
whole-prefix domain commit and Briefing input-only policy. RPC answers in the
child-commit scenario are controlled; this is not a live provider result.

The prior selected run39676761394 on80525774 completed with failure: the code
compiled, but two capacity fixtures incorrectly expected measurement HTTP for
expired/future evidence, and a Candle fixture read a payload from the summary
projection instead of `Runs.get`. Those assertions are corrected in the owning
size layer at c18a1f8c5ab; the failed run is preserved separately and does not
prove the correction or this successor layer. Parser checks are not typing or
execution. A new selected compiled run remains separate evidence.


Selected successor run39679636091 at062bea30 compiled and ran the selected
suites, then failed three interrupted-link fixtures. A newly constructed capture
kept noncanonical internal row key order, while a strict persisted restore read
canonical rows. Narrowing re-rendered a different child's input_text/prompt from
those equivalent rows. Capture.make now canonicalizes its internal whole-work
snapshot while retaining the parent's original substitution bytes separately.
This repairs deterministic fresh/restored narrowing rather than relaxing the
exact child comparison. The failed run and earlier pre-MCP-dependency compile
failure39679243670 remain historical; a new-head run is separate evidence.


## Read an original host terminal while its worker is unavailable

Off retires a worker and removes its live exports. Calling the active export's
read operation therefore cannot recover every already completed host result.
`Lane_addon_exact.observe_retained` provides a host-only read of the original
Exact record. It checks canonical envelope/declaration/request identity, exact
captured request and digest, all actual attempt envelopes and the terminal
against the original schema. Missing, open and terminal are distinct; malformed
or conflicting storage is an error. Started without a final stays open because
a read cannot establish that its provider stopped. No result, claim or request
is written and no route/provider/worker is invoked.

The read accepts the real writer's exception evidence on Outcome_unknown and
later Not_allowed audit attempts that preserve an earlier terminal. A null
started attempt need not be last after interrupted-run recovery and a later
selection denial. This host observation grants no current package delivery or
new execution. It does not call Exact.run with a disabled route.

Curator Dispatch_pending now restores the physical capture and full acknowledged
ancestry, strictly decodes its original configured installation, reconstructs the
same Exact request/schema and checks that original host record first. A retained
terminal goes through the existing complete domain validator and original
judgment/refusal journal. Missing/open still use the normal worker read, and an
invalid record refuses before that fallback. Captured/Admission_wait keep their
existing live export checks and original dispatch rules. Domain settlement keeps
its separate current-state/source/contract guards.

Five new common-reader scenarios exercise real producer records, active started
reads, exception and selection-denial history, interrupted started evidence and
strict identity/schema corruption. Four additional original-consumer scenarios
exercise the public resume/settle path without an initialized live Runtime,
corrupt-host fallback refusal, full domain rejection and canonical installation
kind separation. Controlled provider callbacks are not live provider/actual Off
lifecycle evidence. Production owner scheduling, original observer receipts,
initial prepared-state/capture reconciliation and installed UI remain pending.


## Complete original discovery before production cutover

`Server_workspace_memory_addon.discover` provides the local recovery boundary
for the future production scheduler. It first strictly discovers all original
owners, observes the actual physical workspace and validates the entire capture
forest. This includes the full immutable intent/whole-prefix derivation of each
successor, all predecessor links and each acknowledged child. It never treats a
malformed unrelated record as an empty or partial successful inventory.

A legitimate interrupted publication has a Subdividing parent and either no
child yet or its exact initial Captured child before the parent ACK. Ordinary
`Capture.restore` still refuses that child for execution. The pure inventory
check can validate this exact window without returning an executable capture;
it returns only IDs of parents whose successor intention is already durable.
The host then freshly loads those parents and completes only their existing
retain/read/ACK sequence using the original child ID. It never narrows a merely
Rejected original or mints another ID. An acknowledged missing child is an error
and is never recreated.

After recovery, the host repeats complete discovery/physical forest validation
and ordinary strict restore before returning any original captures. Recovery
errors or uncertainty return no partial successful inventory. The caller must
hold the workspace process lease and serialize the whole operation; a returned
observation does not replace fresh authority at any later effect edge. This is
not a cross-process transaction, a worker admission or a new-work grant. The map
exists only for one pure inventory check; record order is not execution priority.
Complete scans, domain decoding and repeated ancestry/strict reads remain costs.

The port uses local original journals and can recover an already stored intent
without a live worker or model route. New root/new successor admission still
needs the actual current configured Runtime authority, separately linearized
with its action serializer. Do not infer that authority from this inventory or
an old enabled boolean. Production still uses the old direct provider owner at
this layer: switching its scheduler/frontier, new-child authority, registry
receipt delivery, real worker/provider lifecycle, Dashboard/TUI and installation
verification remain required. The new real-Store scenario definitions and
parser checks are not compiled execution or those integration proofs.
