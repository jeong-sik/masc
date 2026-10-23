# Exact worker terminal records and fresh state

Workspace Curator 0.1.4, Candle Appraiser 0.1.5, Keeper Librarian 0.2.3 and
HITL Auto Judge 0.1.1
use worker record version 2. Pending records retain the original request.
Terminals retain `version`, `request_id`, `digest` and `result`; workers with
multiple exported tools also retain `tool`. Retaining a terminal atomically
replaces the pending body. The worker wire protocol stays the same. A repeated
submit checks the original input digest and returns the retained terminal.

Finished input bytes no longer accumulate. Startup still checks every retained
record, including its result, once; its cost grows with terminal metadata and
result bytes. This change does not delete terminal identities or results.

## Deploy with a stopped writer

Old worker records are refused. Do not convert them or copy old pending records
into a new worker store. This hard cut applies only to the persistent worker
volumes of all four packages above, including operator-admitted HITL worker
requests when its automatic host dispatch is not connected. It preserves host original requests,
Exact records and proofs, domain ledgers, receipts and source queues.

1. Record the actual workspace, installation IDs, selected manifests and image
   IDs. Inspect each worker container and its `/state` mount. Verify the volume's
   `masc.lane.state.owner` label against its workspace, installation and package.
   `Lane_addon_worker_state` derives the volume name from that identity; package
   revision changes alone reuse the same volume.
2. Join both host original and worker inventories before stopping execution;
   the worker listing alone misses lost worker records. For each affected ID,
   record installation/declaration/package/tool, owner scope, request ID/digest,
   host progress phase and last wait observation, worker pending/terminal/absent,
   host Exact absent/open/terminal, and bound proof presence/outcome/attempt
   ordinal. Resolve pending work through its existing serialized host owner.
   Then stop the workspace server through its normal shutdown path and verify
   that no server or worker still writes these volumes. Recount after shutdown.
   Clear state only when the worker has no pending requests and no unresolved
   dispatched host original depends on that worker. Stop the hard cut if either
   inventory has such work, including a host original whose worker record is
   absent. Continue with authoritative recovery, or a separately reviewed
   per-original chain set-aside plan that preserves its evidence and explicitly
   determines how its domain inputs become eligible again. Do not continue from
   an uncertain or contradictory inventory, and do not dispatch an old request
   as new work. Keep these dispositions, counts and byte counts in the receipt.
3. Preserve each complete old volume in a separate, identified archive or backup
   volume, together with its owner label and container/mount inspection. Verify
   the backup by rereading its inventory and checksum before clearing anything.
   This includes pending and finished records, temporary files and every package
   directory inside the volume.
4. Remove the stopped worker container through normal lifecycle cleanup. After
   verifying that the old volume has no users and its backup is complete, replace
   it with empty state under the same installation identity. Let the host create
   and validate its owned volume; do not invent a new installation ID or relabel
   a foreign volume. Perform this for every installed affected package, including
   a detached installation that may later be reattached.
5. Select the new manifests and images, run the candidate's deployment preflight,
   and start the server. Confirm each attached worker's package revision. A
   retained host terminal can still finish its owner without a worker record;
   undispatched work can be admitted normally. A dispatched open original cannot
   recover automatically from empty worker state: `Lane_addon_submit_once` keeps
   it `Missing_after_dispatch`, and the Exact runner only processes worker-listed
   requests. This is why step 2 must resolve or explicitly set aside those
   originals before clearing the volume. Check the known IDs against host proofs
   and owner outcomes, recording delivery and domain commit separately.

The host incarnation/cause change has its own Exact/Curator/Librarian hard cut
in the [unknown outcome RFC](../rfc/RFC-exact-outcome-unknown-names-its-cause.md).
If both changes deploy together, use one stopped-server window and satisfy both
inventories. Browser Add-on fresh-state steps are a separate retained-owner
contract and must use the candidate's actual preflight refusals.

## Roll back

Stop all writers first. Restore the matching old image, manifest and complete
old worker volume together. Reconcile host requests that advanced after the
backup before enabling execution. A stored terminal, an admission ACK, a host
proof and a domain commit prove different stages; backup restoration alone does
not authorize a provider replay.
