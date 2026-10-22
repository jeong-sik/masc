# Original request store concurrency

The configured Addon host may validate an original request while its serialized
workspace owner records progress or observer receipts. These are distinct
callers of `Lane_addon_store`, often with distinct Store objects. The workspace
lease and the semantic owner's update order do not exclude this host read.

In [run39705408417](https://github.com/jeong-sik/masc/actions/runs/39705408417),
the public Curator fixture stopped before Off: strict original-owner inspection
refused, the retained Exact record was absent and HTTP posts were zero. The host
reported `exact_record_failed` with a single-link check diagnostic. That check
uses `st_nlink <> 1`, so its message also covers an opened old inode unlinked by
atomic replacement. The actual link count and syscall interleaving were not
recorded; concurrent progress replacement is a source-supported mechanism, not
a measured interleaving. Extending the timeout does not address that refusal.

Original-scope publication, known-ID reads and complete inventories now use the
existing `File_lock_eio.with_mutex` cross-context table. The key combines the
existing physical parent, store basename and exact scope digest. Parent aliases
and separate Store objects therefore share the serializer before descendants
exist. A missing parent is an error, not newly created authority. No new lock
file, registry, timer or retry limit is introduced.

The serializer covers only the blocking store transaction: complete strict read,
file/parent sync and final verification, or directory preparation and atomic
publication. Existing no-follow, owner, permission, single-link, descriptor and
path checks remain in force. Cooperative progress replacement cannot invalidate
its own concurrently held strict read; external changes still refuse. Different
scopes remain independent. The cost is additional parent resolution and waiting
behind another same-scope transaction, including a complete inventory's fsyncs.
This is not a latency improvement or cross-process exclusion, and it does not
make the Owner's separate expected-record load and save a filesystem CAS.

The regression holds an actual original descriptor during its real sync,
observes an aliased Store's writer queued on the same existing mutex, publishes
an unrelated scope, then releases the read and checks old inventory bytes and
fresh new progress. Actual waiter state orders the actors; the timeout is only
a hang guard. Existing real replacement, hardlink, symlink and failed-sync tests
remain refusal checks. The public production fixture still drives the configured
Python/MCP worker and common Exact HTTP path without injecting a host terminal.
Parser/source review alone does not establish a successful compiled execution,
real Docker/provider behavior, installed runtime or either UI.

The [executed ten-suite receipt](../evidence/2026-10-22-curator-original-delivery/selected-execution-serialization.json)
records exact `47b9e716607b74d4948e38608f09460b1ccb45b5`,226 actual passing
cases, including discovery8 and production13. The production case that failed
before now reaches its actual retained terminal and Off settlement. The original
namespace obstruction/maintenance recovery and held-descriptor/alias scenarios
also pass. This selected scope is distinct from full regression, a measured
historical syscall race and actual provider/UI/installed runtime behavior.
Native Stack44994 was externally merged into the Candle branch, whose whole
tree equals this executed candidate; main integration is not established.
