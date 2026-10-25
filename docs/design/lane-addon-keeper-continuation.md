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
provider connection. Provider retirement closes and joins publication admission. A separate durable
host owner-loss notice remains to be implemented; no successor may claim the
original private authority.
No elapsed-time expiry or replacement operation is introduced.

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
controlled ACK endpoint; an actual OCaml host/Keeper turn remains unexecuted.

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
There is still no executed original Keeper turn or private worker delivery proof.
The existing ready-batch policy can mix notices from different conversations;
its wake channel then becomes `None`. Connecting the private publisher must also
preserve the original source/conversation boundary through actual turn admission.
Canonical queue metadata alone does not prove that routing or task continuation.

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

The new origin fixtures cover real private files, immutable-source conflicts,
corrupt/unsafe records and cross-process first-writer behavior. They have only
been parsed in this external coding session; no local Dune build or execution
has verified them. They do not exercise progress publication or Keeper resumption.

The new host publication fixtures use private files, the durable queue and actual
canonical observation reads, including retry after simulated source consumption.
They are source fixtures only: this coding session has parsed them without a local
Dune build or execution. They do not simulate a resumed Keeper turn as proof of
real continuation.
