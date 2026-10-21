# Workspace Curator: accepted work and Addon execution

This is the proposed E02 implementation contract under the
[Addon worklist](../../reports/addon-lane-full-worklist-20261021.md).
It specifies the execution boundary. The [Curator worker](../../addons/workspace-curator/README.md)
and [shared host semantic port](workspace-curator-semantic-validation.md) are now
implemented. The original admission consumer now captures actual Runtime
provenance and reads/submits/restores the original worker result; production
scheduler switching, domain commit recovery and wake integration remain.
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

Reuse the existing Curator wake owner and common Addon change/result events.
There is a concrete integration gap: Curator currently subscribes only to memory
commits and exact-lane publication. Addon export On/result changes are not proven
to wake it. `register_tool_change_handler` is a single server notification bridge;
do not replace that bridge with a Curator callback or execute storage/provider
work while a lifecycle lock is held. Provide shared owner-safe event delivery,
with unsubscribe tied to the server switch, before claiming reconnect resumes
pending work without an unrelated memory commit.

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

Next coding boundary: retained host classification/briefing request types and
strict durable recovery, then the shared package request store, host semantic
validation before original-flow acceptance, and consumer.
Keep domain authority on the host throughout these units; do not switch production
to an incomplete transport adapter.

The first [batch and known-request storage foundation](workspace-curator-request-capture.md)
now retains complete request data and validates original classification rows and
briefing partitions. It does not yet implement the trusted host provenance
envelope, restart enumeration, accepted-work/commit lifecycle, semantic port or
production Addon consumer. The follow-up
[typed host capture and original judgment](workspace-curator-host-capture.md)
now defines the caller-supplied provenance envelope, physical-workspace binding
and captured-template/input checks, but production metadata capture and the
remaining lifecycle/semantic/consumer integration are still required above.


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

This adapter does not create another scheduler or model runner. The current
production Curator scheduler has **not yet switched** to it. That switch must
still prioritize accepted-work recovery even while Off, preserve input/output
size refusal and whole-batch successor linkage, perform actual fresh
before/expected-after domain commit recovery, and subscribe to original result
and export events without replacing the existing MCP inventory callback.
`capture_*` publication failure still requires original discovery, not another
fresh request. No extraction, production recovery or Off/On completion follows
from this source alone.
