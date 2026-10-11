# Child observation read lifetime

The TUI loads retained Child observations independently of Root completion and
chat history scrolling. A confirmed server observation identity permits a read;
local attachment/message submission eligibility and roster membership do not.
The server's authenticated operator read contract remains the storage boundary.

Each load captures the existing workspace authority, server identity and original
read epoch. Every HTTP fetch checks that captured epoch and workspace before and
after the request. The result is delivered through `Workspace_scoped` and is
classified as an observation: a retired completion is rejected before it can
replace cache data or release a successor slot for the same Keeper.

Inflight ownership retains the actual `Poll`/`Audit` mode. On read suspension,
running Audits return to pending intent before slots are cleared. Queued and
running Audits coalesce; Poll is never promoted to Audit without explicit intent.
An explicit Audit while server reading is unconfirmed records intent without
issuing HTTP. A confirmed subsequent read consumes it. Repeated suspension keeps
snapshots and intent; withdrawal of the workspace clears cache, slots and intent.

Normal refresh ticks request unchecked-hint Poll reads, including while the user
is reading older chat rows. Forced history refresh requests a full Audit. A
pending Audit behind another read starts after its admitted completion. Current
storage errors retain the consumer's earlier snapshot history and diagnostics.
No input consumption, Task state, Root saying/thinking or liveness is inferred.

The functional retirement fixture covers the actual state suspension and
workspace admission API, including a running Audit with no remaining queued
intent. It does not execute the main TUI launcher, HTTP, mailbox dispatch or
terminal. Rendering, matching installed binaries and visible/provider scenarios
remain separate verification work.


## Chat projection

Received complete Child text uses the external sender style, with `CHILD` sender
metadata visible in the default bare view. Thinking keeps its dim reasoning style;
bare reasoning rows now retain sender metadata too. Metadata is separate from the
original body. The existing hidden/folded/full reasoning decision applies to Child
thinking. No Child row acquires Root request rails, reply aliases, input delivery
state, liveness, or completion merely because a complete snapshot was received.

Search and scroll both use a typed Child anchor containing the full receiver
triple, store incarnation, accepted observation identity, ordinal and channel.
Provider envelope UUIDs are correlations rather than deduplication keys. Complete
bodies use stable Markdown caching; cache identities include the receiver triple,
store incarnation and accepted observation plus durable record sequence. Public
Audit redaction can replace human text without replacing its durable anchor.

Child history is a separate observed lane after Root history, before live/pending
input. Cross-store clocks do not establish a total causal order. Retained stores
remain visible after discovery disappearance; their current completeness and
redaction coverage remain unknown. Read failures remain separate error notices.
Projection and concatenation caches preserve list identity on unchanged snapshots,
including for search and scroll measurements.

These are source contracts. Parser-only checks and independent source review do
not prove type checking, execution, installation, or visible terminal behavior.
