# Optional Lane Broadcast delivery ledger

This child unit builds on #40233 commit 3da12eba97c42cf756fd71c322588893db8c737b.
The parent already retains exact published evidence under a stable caller key
and lets same-key retries recover a committed receipt while fanout is blocked.
This first response unit adds durable intentions and recipient outcomes.
It does not change the current Broadcast request, message commit, fleet handler,
background recovery or TUI. The parent CR is assessed against its own
implementation; this unit alone does not prove durable Fleet delivery.

The host admits one operation under the authenticated caller and caller-retained
operation ID. The payload contains the exact published artifact SHA-256,
message content and accepted recipient snapshot. The workspace request ID uses the same SHA-256 caller/key pair and 16-byte
hex projection as the parent; retries return its original record. A conflicting
payload, digest or recipient snapshot cannot replace an admitted operation.
The journal initially states Uncommitted, so durable intention acceptance is
not mislabeled as workspace message commit.

After the actual workspace commit, the host records its sequence. Per-recipient
projection remains Pending until append_user_message_once accepts the same
Workspace_message request identity. Failed attempts retain their detail and
obligation. Accepted is monotone. Restart scans retain unfinished commits and
partial recipient delivery. Complete means projection acceptance, not Keeper
reading or use. The ledger never calls a provider or a Keeper.

The journal uses the existing append-only private-file transaction, including
its process lock, fsync, rollback and typed descriptor-settlement outcomes.
Events are strictly decoded. Unknown states and torn tails refuse authoritative
recovery; they are not silently skipped or truncated. Successful durable appends
with descriptor cleanup failures carry that evidence without inviting replay.
A semantic refusal with a cleanup failure preserves both typed primary and
cleanup evidence. Recovery returns completed records with cleanup failures in
settled_with_cleanup, separately from pending delivery obligations.
Recovery opens only an existing uniquely linked regular journal, using the same
exclusive journal lock as admission. A durable pending marker whose journal is
missing is corrupted evidence: recovery retains the marker and refuses the scan
without creating a replacement journal. Only an existing empty journal can be a
pre-admission crash boundary; its marker is retired while that journal is locked.
Pending journal filenames must be exact lowercase SHA-256 identities.

Callers offload blocking ledger operations through the existing host boundary.

## Runtime integration child

The next child activates the journal for optional Lane Evidence Broadcast.
The authenticated Evidence path publishes its immutable artifact, captures the
registered Fleet roster, and durably admits the caller's retained operation key
before the workspace commit. A retry reuses that original audience and artifact.
Workspace publication uses the same request ID. An interrupted publication is
reconciled against the exact authoritative sender, content and sequence.
A journaled committed message that is unavailable is refused, never republished.

The explicit Deferred_fleet mode returns the workspace receipt before recipient
projection. Ordinary Broadcast retains its existing immediate mention and Fleet
behavior. Deferred mode rejects mention-bearing content before admission or
workspace mutation because mention intake must settle before Fleet projection.
The Lane path sends only the host-generated stored-artifact marker; selected
report text, including any mentions, stays inside the immutable artifact.

A server-root Pulse owns recovery under its root switch and the existing
maintenance cadence. Admission nudges it. It reconciles unfinished commits and
projects only pending members of the accepted roster. A beat scans and schedules
work without awaiting recipient completion. Commit jobs own each caller/operation;
projection jobs own each caller/operation/recipient through durable acknowledgement.
A blocked recipient cannot hold a sibling or a separately admitted operation.
Overlapping scans share those owners, and a recipient rereads its durable state
before projection so an older scan cannot replay an already accepted member.
Cancellation releases the in-flight owner while retaining the pending journal
obligation for a later service. The production recipient
adapter uses the existing Workspace_message request key and
append_user_message_once. Cancellation after transcript append but before journal
acknowledgement leaves a pending obligation: retrying the same key observes the
existing transcript rather than appending a second row. Projection acceptance
still does not establish that a Keeper read or used the report.

An admitted intention whose workspace write is rejected reports pending_commit.
A failure with uncertain commit evidence reports outcome_unknown. Both retain
the operation key for retry; only an authoritative committed receipt acknowledges
it in the TUI. Durable descriptor cleanup issues are logged without converting
an accepted write into a replayable rejection.

The child adds source fixtures for receipt return before blocked projection,
partial recipient failure and restart, fixed-audience recovery, interrupted
workspace publication, independent sibling and newly admitted operation progress,
duplicate scans and cancellation retry, and the production adapter's transcript deduplication.
These are proposed native fixtures, not executed native or live delivery proof.
The child has no provider/model execution evidence. Current-caller and strict saved visibility authorization are inherited from
privacy parent #40233 c327e74d4ba9f6f81da237d7938a78992286e9f5 through
#40330 bad4c98f17a5a250d59a3c1e92afddb85281eb75. Cached retries validate
the saved operation before looking up a source binding that may have been removed.
