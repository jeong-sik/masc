# Retained shutdown acknowledgement for an absent owner

A finalized `operator_stop_retain_meta` record can outlive its Keeper owner,
metadata, and declaration. Normal recovery continues to reject that disagreement:
absence is not evidence that the original retained-metadata cleanup succeeded.

`Keeper_shutdown_reconciliation.acknowledge_absent_owner` records an explicit
operator observation as `operator_absence_acknowledged`. It keeps the complete
original finalization, original revision and update time, and a SHA-256 digest of
the original canonical operation JSON. It also records the actor, reason,
observation time, and authoritative backlog version. It never fabricates metadata
removal, settles work, or deletes the shutdown record. Ordinary replacement and
terminal reclamation cannot alter or erase the acknowledgement.

The operator endpoint is
`/api/v1/keepers/<name>/shutdown-operations/<operation-id>/absence-acknowledgement`.
Both GET and POST require a bearer credential with `CanAdmin`; workspace auth
must be enabled and require tokens. The authenticated credential owner supplies
the actor. A body actor or an identity header cannot change that attribution.

GET returns the exact durable operation and current primary backlog version,
with `expected_revision`, `expected_backlog_version`, and
`eligibility_checked: false`. It is an observation for review, not a reservation
or an assurance that acknowledgement can proceed. It does not modify the record,
and responses are not cached. A changed owner or backlog can make POST fail after
the preview. POST repeats every eligibility check below under the transaction's
locks.

POST accepts exactly these fields (the two revisions come from the preview):

```json
{
  "schema": "masc.keeper_shutdown.absence_acknowledgement.request.v1",
  "expected_revision": 4,
  "expected_backlog_version": 3260,
  "reason": "Confirmed this retained shutdown has no remaining owner or work"
}
```

The example revisions are illustrative, not live instructions. The operation ID
and Keeper name are selected by the URL. Duplicate, missing, or unknown fields,
an actor field, non-integer revisions, and a blank reason are rejected. The HTTP
contract uses exact operation/backlog revisions; it does not accept or claim a
caller-supplied digest precondition. The retained original digest is audit evidence.

The first acknowledgement requires all of the following:

- The exact record is finalized with retained metadata, no in-flight turn, no
  requested completion, and stopped-lane join evidence without a cleanup error.
  Every originally recorded task has original settlement evidence.
- The owner inventory is installed and reports that this owner is absent; the
  lane registry is also empty for the name. Both the canonical metadata and
  resolved declaration paths return physical `ENOENT`. Parse failure, a dangling
  direct symlink, or a missing owner inventory cannot authorize the operation.
- The primary backlog is readable at the requested version. No claimed,
  in-progress, or awaiting-verification task belongs to this Keeper or any
  originally recorded task ID. Recovery snapshots do not authorize the change.
- A read-only inspection of the canonical chat-operation database finds no queued
  or running operation. Missing database, validated terminal-only database, and
  unreadable/corrupt database remain distinct results. The check does not create,
  initialize, settle, or recover a database; orphaned journals are refused.
- The locked shutdown inventory has no corrupt sibling and no other operation
  requiring an admission fence. Any current intake reservation belongs to this
  exact operation.

The lock order is intake, lifecycle key, authoritative backlog, shutdown
inventory, and exact operation. The inventory scan releases each record read lock
before the target write lock is acquired. No owner mailbox command runs inside
these guards. Canonical metadata creation takes intake and the lifecycle key;
ordinary lane registration takes the lifecycle key. The ready owner inventory has
no removable individual owner entry: an absent entry under the creation guards
also excludes the sole chat-operation writer. SQLite inspection runs in a system
thread while the lifecycle guards remain held.

The acknowledgement CAS increments the operation revision once. A retry naming
the old or acknowledged revision returns the same immutable record. It checks
corrupt and unfinished siblings again, and releases only an intake reservation
still belonging to the acknowledged operation. It does not inspect, overwrite,
or release a later owner's state. Boot recovery retains this terminal observation
without retrying old finalization; corrupt siblings still restore their fence.

The domain tests exercise real Eio creation paths and durable SQLite/backlog files,
including queued and running operations, corruption, revision conflicts, a
post-CAS/pre-release retry, and a creator blocked until the acknowledgement
commits. The HTTP tests dispatch through the actual dashboard router with real
credentials, checking authorization, actor attribution, exact body parsing,
post-preview conflicts, durable acknowledgement, and retry behavior. Remote CI is
the execution evidence; source inspection alone does not establish that these
tests pass. No live acknowledgement accompanies this change.
