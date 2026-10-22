# Original observation delivery

Curator retains registration and terminal intentions in its original owner
journal. Preparing an intention is separate from publishing it to the exact
registry and acknowledging its delivery. The serialized workspace owner keeps
the physical workspace lease throughout this operation.

`Exact_lane_run_registry.reconcile_original` validates the full supplied original
before touching storage. Its observation mutex encloses the generic Core mutation
mutex and the existing private JSONL path mutex/exclusive data-descriptor lock.
The transaction strictly parses the complete current log. A malformed unrelated
row, orphan completion, incomplete tail, incomplete startup or unavailable source
refuses confirmation. Startup also records valid-wire orphan completions as
malformed, preventing compaction and payload sweeping from hiding that damage.
Registration membership is independent of projection retention.

Matching registration and producer terminal data are confirmed without appending
or replacing the log. This still performs actual file/parent durability fences.
Payload availability requires the complete owned, no-follow file, digest and
descriptor checks; JSON null is an available value. Different original input or
genuine producer output conflicts instead of resetting the lifecycle. A typed
restart observation alone permits correction by the actual original terminal.
Conflicting failed-completion overlays are preserved and refuse confirmation.

Cold payload directory preparation runs on the caller under the observation
mutex. The blocking log callback requests each needed immutable payload through a
closed preparation result, releases its Core/file locks, then starts a fresh
transaction after preparation. It never performs an Eio wait in a system thread.
Every later transaction rechecks actual log and payload data; an earlier read is
not a capability to append. Confirmation verifies bytes as well as pathname and
descriptor identity before and after the data sync. Append rollback and uncertain
durability remain explicit; publication may have happened before cancellation.

Only after registry locks are released does Curator freshly restore the complete
physical original, ancestry and immutable receipts. It ACKs registration first,
then completion, using their exact digests. Lost ACK retries confirm the same
facts without another execution. Fully acknowledged history skips registry
delivery after eviction. Pending completion may republish that same original if
its registration was evicted. Success confirms historical publication even if
ordinary per-lane retention immediately removes the run from the current page.

Observer failures leave the owner eligible for a wake from the existing server
maintenance tick. The wake resolves its physical workspace and signals only that
existing owner; it performs no journal/provider/domain work. Fresh owner authority
still governs every subsequent action. There is no new timer, retry cap or busy
loop. Unknown provider duration and extended cache/cost usage remain absent; the
full original terminal receipt preserves any reported basic token counts.

The conditional transaction currently uses the existing complete-byte updater,
temporarily retaining the log string and verification copies. It is not a latency
or memory optimization. Raw superseded restart rows remain only until ordinary
compaction; permanent interruption audit, full G03 timelines, real-provider,
Dashboard/TUI and installed-runtime evidence are separate unfinished work.

New tests exercise actual file-backed conditional publication, original Owner
ACKs, typed restart correction, invalid/unavailable sources, same-inode changes,
data-fsync failure, concurrent delivery, immediate retention and Off maintenance
recovery. Parser checks establish syntax only. The earlier successful
[11-case production diagnostic run](https://github.com/jeong-sik/masc/actions/runs/39699404401)
executed source `a650bad6dc7a5133c9d0de516f15a54e42cf3b8b`; it does not execute
this subsequent reconciliation implementation.
