# Original Keeper continuation for companion operations

Implementation and design for the remaining continuation work in
[#45736](https://github.com/jeong-sik/masc/issues/45736). The version-3 companion now has a private publication channel.
The worker Service drains its durable outbox on a separate owned delivery thread.
Original source capture and first-writer retention are source implementation
in `Lane_addon_companion_origin`, before companion grant issuance. Canonical
publication retention, a durable Keeper queue producer and source-checked
observation intake are now implemented on the host. The original private broker can now call that producer through a
host-injected callback; the worker Service now sends its committed envelopes
through its original Publisher. A preparing
receipt or a private worker's completed fill does not prove the Keeper resumed.

## Ownership before dispatch (source implementation)

The Keeper adapter captures the original invocation from
`Keeper_tool_runtime.context` at the frozen Add-on export route: Keeper name, original `turn_ref`, `tool_use_id`, task
source and continuation channel. Use the source context captured for that call;
the Keeper's subsequently selected task cannot substitute for it. Preserve an
explicit unrouted channel rather than guessing a conversation.

The Add-on owner first revalidates the exact provider connection, export,
principal and declaration. Before supplying a companion capability to the worker,
it commits an original invocation binding containing those coordinates, the
public tool/input digest and the original continuation. Persist no endpoint capability,
OAuth material, approval link, credential reference or private program arguments.

A second call with the same source recovers that original binding and refuses
another grant. It cannot replay a login because the first reply was lost. Changed
input or destination is a conflict. An unconfirmed binding write permits only
reconciliation of that binding, never a replacement login. Keeper calls missing
their original invocation coordinates cannot promise automatic continuation.
Operator and external-agent calls retain their explicit status flow and receive
no fabricated Keeper destination. Origin capture uses the root owner's actual
filesystem capability. Absence of that capability refuses new Keeper companion
authority; it does not create a replacement filesystem or event loop.

The immutable record contains only original ownership and input identity. It
is an intent retained before dispatch, not a receipt that a grant, login request,
fill or wake happened. Private publication and owner-loss records must preserve
that distinction when the delivery path is connected.

## A private publication control (source implementation)

The existing independent companion socket negotiates version 3 for progress
publication with a separate private capability. Do not send asynchronous work through the
worker's serialized public MCP request. The worker supplies only an original
invocation capability, publication ID, typed publication kind and public output.
It cannot supply a Keeper, task, source, conversation or wake destination.

The host captures the export's output schema with its original invocation and
validates every worker publication against it before retention or delivery.
Discard raw worker text, metadata and exception prose at the same boundary as
ordinary companion tool replies. Machine_addon_host injects the Keeper
admission callback; Lane_addon_runtime captures the exact origin and output
schema, and rechecks the original provider, caller and configuration on each
delivery. It never requires Browser authority for publication. For 1Password this output contains only the
operation ID, closed phase, submitted-fill fact and false website-verification
claim. The package remains responsible for its public projection.

Browser command authority and progress delivery have different lifetimes. A
released or withdrawn Browser grant permits no more Browser input. A separate
publication binding may still deliver the final committed result of that same
invocation, then end explicitly. It cannot bind another Browser or adopt another
provider connection. Provider retirement closes and joins publication admission.
After that join, the allocation's existing settlement owner emits a host-only
`owner_lost` notice for an invocation whose successful acceptance was confirmed.
Its fixed output is `{"outcome":"unknown"}`; the worker decoder refuses that
kind. The retained record preserves the original closed worker schema as
provenance without fabricating a worker operation phase or credential result.
No successor may claim the original private authority.
No elapsed-time expiry or replacement operation is introduced.

This settlement uses the captured raw host sink and original origin. It cannot
reenter provider authorization, allocation cleanup or Browser work. Live
invocation acceptance and eligibility are recorded without yielding. A rejected
or unaccepted invocation completes its notification without an owner-loss event.
A worker Terminal that reached confirmed durable admission completes the same
notification before the following fresh authorization read can yield, preventing
a false loss notice if the provider ends during that read. Browser Release and
withdrawal never complete this separate publication notification.

This is source implementation for detected provider retirement while the host
owner is alive. A cancelled root switch or failed storage remains unconfirmed
under the allocation's existing cleanup contract. It does not promise recovery
from whole-host power loss. Source fixtures enter the actual Runtime Attach and
exported invocation paths with an external worker replaced by an exit barrier.
They release that barrier without Detach, require canonical owner-loss admission
and IPC settlement, and check that explicit Detach still owns worker resource
release. Known-terminal and rejected-invocation variants require no false loss
notice. Those new fixtures have only been parsed; native execution and an actual
process-kill scenario remain unverified.

## Commit, deliver and acknowledge

The private Python login journal now commits changed operation state and its
immutable public publication intent in one atomic file write. It emits typed
attention, submitted-fill and terminal transitions; intermediate polling/checking
activity emits no notice. Separate successful fills retain separate publication
IDs even when their public snapshots match. Public envelopes contain only that
ID, kind, operation ID, phase, submitted-fill fact and false website verification.

`Logins.pending_publications` rereads the same unacknowledged envelopes without
binding or executing anything. The private `acknowledge_publication` requires
the exact original caller and complete, type-correct envelope. A duplicate ACK
does not rewrite its record. Its `host_accepted` marker means durable host
admission only; it does not claim queue consumption or Keeper resumption. Neither
method is a public MCP tool, and the Service-owned delivery pump invokes the private transport and commits
ACKs with the original caller after confirmed host admission. The private journal uses version 2 with strict closed decoding.

After an uncertain journal write the original engine fences admission, further
writes and private sockets. It cannot overwrite a possibly committed publication
from its older memory snapshot. Recovery reads the actual journal, preserves
original IDs/host acceptance and records lost nonterminal ownership as a new
unknown terminal notice without rebinding or replay. Private file tests cover
failures before a fill-state write, after that write and after an ACK write.

The Service-owned delivery thread registers the original caller and Publisher
before request admission. It reads committed envelopes without holding the
engine lock during private network IO. After an exact host ACK it commits that
envelope's admission marker with the original caller, even when the actor job
was an operator check. State commits and existing status/host observation
activity notify delivery; uncertain transport remains pending until such
activity reconciles the same IDs. No new polling timer, replacement capability
or request/fill replay is introduced.

Storage uncertainty immediately interrupts this separate Publisher and stops a
cached batch. Service retirement stops publication admission and IO; its worker
joins delivery before closing the engine lease, including background failure.
The private endpoint is never reconstructed from a retained journal. Explicitly
unrouted descriptors continue to use their status flow without fabricated ACKs.
Controlled Service, actual private files and Unix-socket fixtures cover normal
attention/fill/terminal delivery, lost ACK reconciliation, cancel during a blocked
ACK and an ACK write that committed before reporting failure. Their host is a
controlled ACK endpoint. The separate native failure-path probe below exercises
the real OCaml host, worker Publisher and Keeper intake.

The host implementation now retains each notice under the original invocation
and publication ID in a private immutable file. It captures the export's closed
output schema, revalidates the public output and rejects changed same-ID payloads
or damaged/unsafe files without repair. The exported reply and publication paths
share the same closed-schema validator. No raw worker text or private descriptor
is copied into this record.

`Keeper_addon_publication.deliver` commits that record and durably enqueues a
`Addon_operation_changed` stimulus before its optional wake hint or successful
return. The queue carries original source/channel and immutable pointers; output
stays in the canonical host record. Retries consult the existing queue and its
strict reaction-ledger consumption evidence. Source capture and this internal producer are not publisher authentication.
The private broker retains its separate original invocation capability and
provider/caller scope through the callback; no queue path accepts a package
supplied route.

Keeper intake strictly rereads both the origin and publication before rendering
public output into the prompt. A different Task, Keeper or route cannot borrow
the record. The validated event is carried as typed in-memory observation data
and rendered in a lossless `publication` prompt field; shortening the ordinary
display preview must not discard the operation ID or public state. Unavailable/corrupt source reads retain the queued stimulus and do
not advance cycle failure state or manufacture an empty consumed result. The new
type is explicit through queue persistence, reaction/disposition kinds, routing,
paused-source handling, lifecycle selection and waiting inventory projections.
The isolated native failure-path probe has exercised this transport and a
subsequent real Keeper turn. It does not establish a real-account fill or an
original website Task's continuation.
Intake now groups Add-on notices by the exact original invocation, source and
captured channel. The first canonical source actually consumed sets the batch
boundary. Same-invocation notices share that intake; other invocations and
general sources remain durable for their own turns. An unreadable first notice
does not anchor the group or starve a readable independent source. General-first
intake likewise leaves Add-on notices for a separately routed turn. No new count
limit, expiry or wake destination is introduced.

Controlled fixtures call the real durable queue, heartbeat intake and wake
channel projection. They check original-task/conversation grouping, deferred
source retention, ordinary-first order and corrupt-source independence. Their
completed-turn receipts are simulated; they do not prove a model ran, replied on
that channel or continued the original website task. Canonical queue metadata
alone is not task continuation.

Delivery records must distinguish publication accepted, queue entry committed,
original source consumed and resumed turn observed. Queue admission alone does
not establish exactly-once consumption: inspect the existing durable queue's
deduplication and terminal receipts, including a crash between enqueue and the
publication record's delivery update. Recovery must not turn an acknowledged or
consumed publication into permission to repeat the operation.

An original provider's loss is a host-originated unavailable/unknown event, not
a fabricated worker success. The original task remains available for the Keeper
to reconcile. The same rule applies when a private publication cannot finish
during worker shutdown.

## Resume and verify (remaining implementation)

The resumed Keeper receives the original invocation coordinates and the public
state pointer. After a submitted fill it inspects the original Browser tab,
handles an observed next sign-in page with the same grant where necessary,
checks actual website authentication, releases the grant and continues its
original task. A denied or unknown result requires reconciliation rather than
blind replay. Approval URLs remain in the private operator UI throughout.

Required evidence includes an actual Keeper call, the durable original binding,
private approval, a fill in the same physical Browser session, a durable
publication/queue record, and the actual resumed Keeper turn with website and
task evidence. Source review, fabricated provider tests, compiled artifacts,
installation and this end-to-end result remain distinct claims.

The origin fixtures cover real private files, immutable-source conflicts,
corrupt/unsafe records and cross-process first-writer behavior. Five passed in
[native run 40147809672](https://github.com/jeong-sik/masc/actions/runs/40147809672)
at source `6e6491e9cec86347b6664d26821cba95eda080f7`. That run built the server
and all selected suites, but failed overall on two other fixture scenarios.

The host publication fixtures use private files, the durable queue and actual
canonical observation reads, including retry after simulated source consumption.
Five passed in that same native run. At source
`60303e6d5c3334df8a4827448e2a2fc6b84c5071`,
[run 40149926239](https://github.com/jeong-sik/masc/actions/runs/40149926239)
passed all eight publication scenarios, including the three original-source
batching cases, and all seven selected suites (108 tests). The run failed later
on an artifact-copy permission error; its real Chromium probe was skipped.
Simulated completion receipts in fixtures do not prove that a model ran or
continued a real website task. The newer acceptance and owner-loss changes have
not been executed in that run.

## Observed isolated failure continuation

On 2026-10-25, the retained server and frozen 1Password package from source
`6e6491e9cec86347b6664d26821cba95eda080f7` ran in a temporary workspace with
fabricated local OAuth state and a nonexistent Browser selection. No real
1Password account was connected, no OAuth network exchange ran, and no extension
or page input was dispatched. This configuration exercises a pre-effect refusal,
not authentication.

An actual Keeper called `onepassword_login` and received `preparing`. The real
Service then committed `outcome_unknown`; its separate Publisher sent the
terminal envelope through the actual host broker. The immutable publication,
original invocation record, reaction ledger and the next model input retained
the same publication ID, tool-use ID and original turn reference. A second actual
Keeper turn received that canonical event and reported the same operation ID and
phase without another login or status call. With an explicit instruction to use
the existing `keeper_surface_post` tool, a further probe persisted that response
on the original Dashboard surface. Its source was
`trace-1792891739983-00000#1`, the reply tool ran in `#2`, and message
`msg-1792891759701373-4` contains the submitted response. The exact tool execution,
canonical publication and actual reaction-ledger receipt were joined before
recording the result. The initial observer assumed surface-post chat rows carried
`turn_ref`; the actual producer omits it. A separate verification joined the
successful post's payload to its persisted assistant row instead.

That probe's original Task was explicitly null. A subsequent isolated probe of
the same source used the actual `keeper_task_claim` tool to claim and auto-start
`task-001` before requesting login. The real login call in
`trace-1792893853333-00000#2` captured that Task, tool-use ID and original
Dashboard channel. Its canonical terminal event and actual queue
`turn_completed` receipt preserved those coordinates. The next real model turn
in `#3` retained `task-001`, called `keeper_surface_post` and persisted message
`msg-1792893883329673-7`. Both tool-call contexts and the resumed decision record
identify that Task; the authoritative backlog and Keeper metadata still bind it
in progress after the probe. Thirteen tracked package files matched the frozen
source. Original source-file hashes and retained captures preserve the join.

These results establish private worker delivery, durable source consumption,
original non-null Task preservation and a subsequent real Keeper turn for a
controlled failure. They do not establish successful fill, website
authentication, actual process-kill recovery or production installation. Local
receipts are retained under `reports/onepassword-addon-20261024/` in the
development worktree. Earlier failed observer runs remain separate evidence;
they are not relabelled as successful execution.
