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
