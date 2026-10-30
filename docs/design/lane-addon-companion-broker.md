# Private Add-on companion broker

The [1Password docking goal](https://github.com/jeong-sik/masc/issues/45736)
needs an independent transport between its Python worker and the host. A nested
request over the worker's ordinary MCP connection would wait behind its own
exported invocation. Model request/result queues retain payloads and cannot carry
OAuth access tokens, integration keys, approval links or credential references.

`Lane_addon_companion_broker` supplies a private Unix socket in a caller-owned
canonical 0700 directory. It stores no payload, creates no model request, logs no
frame and imposes no operation deadline. Its frame limit comes from the worker's
declared transport bound. Error replies contain only closed fixed dispositions.
This is an OS-user private channel, not isolation against the same OS UID.

## Invocation and Browser ownership

An already admitted exported invocation issues one in-memory grant. Its private
descriptor contains a cryptographic capability, socket path and frame bound.
The first connection presents that capability plus the explicit Browser worker
incarnation and MASC tab. It consumes the grant before the host binding factory
can yield while reading current declarations. No second socket can adopt it.

The host factory must check the original provider owner, caller and exact Browser
owner. It returns an executor that freshly checks that authority before each
command. The grant's host-generated operation UUID and selected tab are immutable;
commands with a different operation/tab are refused before dispatch. A new owner,
new socket or new browser session cannot inherit the old operation.

A credentialless withdrawal frame removes the exact invocation nonce without
selecting a Browser or calling its factory. Its strict acknowledgement means
admission removed, independently of Browser settlement. An absent nonce has the
same acknowledgement, so an explicit reconciliation after a lost control reply
cannot create another operation. This also withdraws accepted, not-yet-bound
grants when their queued login is cancelled.

The channel carries the existing private extension prepare/invoke/release
commands. Their programs and arguments remain trusted package-owned backend data.
The executor uses the original Browser private wire and its existing page slot;
it must fence/retire uncertain original Browser calls when cancelled. The socket
broker itself does not own or bypass that Browser serializer.

Ending an unaccepted exported invocation withdraws an unused grant. A validated
successful invocation accepts its original grant before returning; its worker
may bind in the background after the reply. Accepted grants belong to the
original provider until claimed, cancelled or that owner ends. Acceptance never
resurrects a cancelled or consumed grant. An already claimed connection remains
available to its background login operation.
Cancelling the invocation also cancels a claimed connection. Peer EOF or
additional pipelined input cancels and joins both the initial binding factory and
an active extension call. The same framing reader observes buffered bytes, so
read-ahead cannot hide pipelining. A callback that returns while handling
cancellation cannot emit a late binding/success response. An abandoned binding
receives a nonblocking `finish Abandoned` notification exactly once.

An exact successful release ends the binding with `finish Released`. Revocation
signals cancellation and removes new admission immediately. `await_stopped`
separately joins the broker's listener and connections; it does not prove external
Browser/process cleanup. The caller removes its private directory after that join.

## Host connection and call context

An optional reserved MCP `lane_companion` handshake requires a version-3 request
and declares version 3 plus the
exact exported tools that need this channel. It requires host-context invocation;
the reserved handshake cannot be exported or used as an action. Negotiation,
schemas and exports become visible together at Ready. Companion exports require
input validation and closed public output schemas even when other hooks are disabled.
An unsupported host cannot silently negotiate deferred binding.

The native MCP connection lazily owns one private allocation. Only a negotiated
export receives a fresh capability in its private `lane_call` envelope. The
model's original arguments stay separate. Admission is checked again under the
original worker RPC mutex. Raw worker text, metadata and error detail never reach
the companion export's public callbacks; validated structured output is projected
to its public reply. Container workers and Browser-service providers do not
receive this host companion transport.

At bind and before each new extension effect, the runtime checks the original
provider and Browser entries, generative connection identities and caller
visibility. One fresh declaration snapshot checks both configured owners,
including enabled state, revision and execution package. Both identities are
checked again after that read. The original Browser client repeats admission
after socket connect and before writing.

Retirement withdraws new admission and revokes the broker immediately. Worker
cleanup joins both its original process and private allocation. Allocation cleanup
joins the broker and registered Browser settlements, then removes only its
original empty temporary directory. Only the broker owns socket removal, guarded
by captured directory/socket inode identities. Replacement paths are retained as
unconfirmed. Abandoned bindings release only the original Browser operation and
accept only the exact successful release receipt.

## Python client

`addons/onepassword/companion.py` validates the private endpoint's directory and
socket, finite closed JSON, operation identities and frame bounds. Constructing
`Companion(descriptor)` returns a cancel handle without connecting. Its separate
`bind(browser_instance_id=..., tab_id=...)` registers the original socket before
blocking on connect or the initial response. Cancellation interrupts either an
initial bind or a later receive and permanently prevents reconnect/rebind.
`withdraw()` uses an independent cancellation socket for only the original
nonce, caches a strict acknowledgement and permits an explicit unknown-outcome
reconciliation. `close()` seals the handle before closing both sockets; no new
bind or withdrawal socket can be created after that owner boundary.
Business `interrupt()` stops only the original operation socket, preserving an
already running withdrawal. The service authenticates and deduplicates repeated
cancel requests before interrupting; repeated receipts cannot sabotage disposal.

Browser commands are serialized on their one original socket. A partial/lost send or malformed
reply is an unknown outcome, never a retry. Public exceptions contain fixed codes,
and the descriptor's capability is excluded from its representation. A successful
fill result still requires subsequent website-level authentication verification.

## Verification and remaining integration

Focused Python tests use the real client and actual Unix sockets against a
fabricated host. They cover prepare/invoke/release, immutable operation
binding, peer loss without replay, malformed/duplicate/nonfinite replies, strict
boolean receipts, cancellation during an initial bind and an active receive,
unused-handle cancellation, explicit nonce withdrawal, disposal/close races and
private endpoint permissions. The service fixtures also hold an actual initial
socket handshake while reading state/cancelling, and withdraw a queued NEW
handle before any bind; a descriptor replay is refused by the fabricated host.

OCaml source scenarios exercise one-use grants, accepted background binding,
cancelled/consumed acceptance without resurrection, unused-grant withdrawal,
reader-buffered pipelining, cancellation-ignoring bind/execute cleanup, peer loss,
explicit invocation cancellation and the separate revocation/join boundary. This
coding session parsed those sources; it did not execute, typecheck or build them.
No installed-host, real Browser or real 1Password result is established.

The host connection, private call context and authority factory are source
implementation. Their OCaml fixtures have not been executed or typechecked in
this coding session. The 1Password package negotiates an empty tool list until
its login lifecycle can use this transport, private approval controls
and durable safe operation/continuation records. Existing exports continue to
report `browser_login_available = false` until that path is usable.

## Private publication authority

Version 3 adds `publication_id` to the private descriptor. It is a separate
unguessable capability, or explicit `null` for a caller without a captured
Keeper continuation. The host seals the original source, export output schema
and durable delivery callback before issuing it. Publication frames contain
only that capability and the public event; they cannot name a route.

Invocation acceptance is independent of Browser phase. A publication waits for
a validated successful exported reply, even if its Browser was already released
or withdrawn. Failed invocation cancels both authorities. Browser release,
withdrawal and peer loss close Browser admission only; original provider revoke
ends and joins both. Publication admission freshly checks that original
provider, caller and configuration, without requiring Browser authority again.
The original host callback validates canonical public output, commits it and
admits the original Keeper queue before acknowledging. Repeated delivery may
reconcile the same immutable event; this port never sends Browser commands.

Python `Publisher` owns separate sockets, pins its original socket/directory
identities and can be closed independently of `Companion`. It sends one event
per connection and does not retry automatically. Its controlled socket tests
exercise terminal delivery after Browser close, a lost ACK, shutdown interruption
and replacement refusal. The Service-owned outbox pump calls it from a separate joined thread. State
commits and existing status/host observation activity notify that pump; no new
retry clock or Browser effect retry is introduced. General transport failure
leaves the same envelope unacknowledged. Storage uncertainty fences the pump
and all its sockets, including a cached next event. Service retirement closes
publication IO before joining it and releasing the engine lease. Controlled
Service/journal/socket fixtures do not prove actual Keeper continuation.
