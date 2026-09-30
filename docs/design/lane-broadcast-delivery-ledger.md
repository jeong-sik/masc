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
Callers offload blocking ledger operations through the existing host boundary.

## Required following units

1. Extend the parent authenticated Evidence admission and status lookup. Publish and verify
   the durable artifact first (already done by the parent), then admit its operation with the actual
   fleet recipient snapshot. Preserve the caller key across an unanswered HTTP
   request; reject contradictory reuse. Existing mutation authorization remains
   authoritative.
2. Give Workspace Broadcast an explicit durable deferred Fleet option. Commit
   using the ledger request ID and sequence, reconcile an interrupted commit by
   that ID, then return its committed receipt before synchronous fleet fanout.
   Preserve other callers' existing semantics and the Fleet audience.
3. Connect a server-root drain/recovery to the recipient journal. Use the existing
   idempotent transcript append with the same request ID; persist each accepted
   recipient and each failure. Do not replace Fleet with System_record or rely
   on a detached fiber. Reading remains a separately observed state.
4. Connect TUI status reconciliation and add actual end-to-end interrupted-POST,
   partial-fanout restart and same-key retry fixtures. The ledger fixtures alone
   do not prove Broadcast receipt latency, delivery or deduplicated transcripts.

No runtime activation, live delivery, native test execution or P1 closure is
claimed by this first unit.
