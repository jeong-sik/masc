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

The channel carries the existing private extension prepare/invoke/release
commands. Their programs and arguments remain trusted package-owned backend data.
The executor uses the original Browser private wire and its existing page slot;
it must fence/retire uncertain original Browser calls when cancelled. The socket
broker itself does not own or bypass that Browser serializer.

Ending a normal exported invocation withdraws an unused grant. An already
claimed connection remains available to its background login operation.
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

## Python client

`addons/onepassword/companion.py` validates the private endpoint's directory and
socket, finite closed JSON, operation identities and frame bounds. Constructing
`Companion(descriptor)` returns a cancel handle without connecting. Its separate
`bind(browser_instance_id=..., tab_id=...)` registers the original socket before
blocking on connect or the initial response. Cancellation interrupts either an
initial bind or a later receive and permanently prevents reconnect/rebind.

Commands are serialized on that one socket. A partial/lost send or malformed
reply is an unknown outcome, never a retry. Public exceptions contain fixed codes,
and the descriptor's capability is excluded from its representation. A successful
fill result still requires subsequent website-level authentication verification.

## Verification and remaining integration

Nine focused Python tests passed using the real client and actual Unix sockets
against a fabricated host. They cover prepare/invoke/release, immutable operation
binding, peer loss without replay, malformed/duplicate/nonfinite replies, strict
boolean receipts, cancellation during an initial bind and an active receive,
unused-handle cancellation and private endpoint permissions.

Seven OCaml source scenarios exercise one-use grants, unused-grant withdrawal,
reader-buffered pipelining, cancellation-ignoring bind/execute cleanup, peer loss,
explicit invocation cancellation and the separate revocation/join boundary. This
coding session parsed those sources; it did not execute, typecheck or build them.
No installed-host, real Browser or real 1Password result is established.

The runtime must still construct this broker under the original provider owner,
inject grants only into negotiated private host call context, and implement the
fresh provider/caller/Browser authority factory. It must withdraw unused grants,
cancel failed invocations and join broker cleanup during provider retirement.
The Python login lifecycle must then use this transport, private approval controls
and durable safe operation/continuation records. Existing exports continue to
report `browser_login_available = false` until that path is usable.
