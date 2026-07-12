---
rfc: "connector-deferred-reply-via-chat-queue"
title: "Durable Keeper chat receipts and connector delivery settlement"
status: Active
created: 2026-06-30
updated: 2026-07-11
author: vincent
supersedes: []
superseded_by: null
related: ["0203", "0217", "0223", "0225", "0226", "0232", "masc#23925"]
implementation_prs: [24139]
---

# RFC: Durable Keeper chat receipts and connector delivery settlement

## 1. Problem

A busy Keeper can accept a Dashboard, Discord, or Slack message after returning
the acknowledgement “your message is queued”. Acceptance used to mean only that
an in-memory or partially persisted payload existed. It did not prove that:

- the individual message had a durable identity;
- a restart would replay the same message;
- an active lease remained observable as work in progress;
- the turn persisted a reply or failure marker;
- the originating connector delivered the terminal response; or
- the Dashboard invalidated and reread the authoritative queue projection.

The old public destructive dequeue and a second consumer watchdog made the gap
worse. A payload could disappear before its terminal outcome was known, and a
watchdog could settle a lease while the underlying turn continued.

## 2. Required invariant

Every accepted message has one stable `Receipt_id` and follows this closed
lifecycle:

```text
Pending -> Inflight -> Delivered
                    \-> Failed
```

`Delivered` means the complete delivery boundary succeeded:

1. the Keeper turn produced a visible terminal result;
2. the transcript write committed; and
3. for Discord or Slack, the connector's primary terminal send committed.

`Failed` is also terminal and carries a typed failure kind plus detail. It is
not silently converted into success. Structured process cancellation is the one
non-terminal exit: it nacks the lease back to `Pending` with the same receipt ID.

Messages from the same source may be coalesced into one Keeper turn, but the
lease retains every constituent receipt and finalizes them atomically.
Connector idempotency follows the same acceptance boundary: a failure before
the queue/user transcript commits releases the external key for retry; a turn
failure after durable inbound acceptance retains the key and emits a distinct
"accepted but failed" notice so retry cannot duplicate the user row.

## 3. Durable queue contract

### 3.1 Snapshot schema

The on-disk SSOT is the workspace/cluster-owned Keeper runtime file resolved by
`Workspace.keepers_runtime_dir`:

```text
default cluster:     <base>/.masc/keepers/<keeper>/chat-queue.json
non-default cluster: <base>/.masc/clusters/<cluster>/keepers/<keeper>/chat-queue.json
```

Snapshots contain pending prompts and attachments, so the atomic replacement
file is created with owner-only mode `0600`. A queue configured for one cluster
never scans, leases, or rewrites another cluster's Keeper directory.
`Workspace.keepers_runtime_dir` is the explicit ownership decision: a
non-default cluster never inspects the default cluster as a migration fallback.
If an operator intentionally migrates a queue, the exact snapshot directories
must be copied into the selected canonical namespace while the server is
stopped; startup does not infer ownership from partial directory contents.

Schema `keeper_chat_queue.v3` contains:

- a monotonic `revision`;
- every receipt ID;
- `Pending` and `Inflight` message payloads;
- typed transcript provenance (`surface`, conversation/external message IDs,
  speaker, structured mentions) plus an explicit `queue_owned` or
  `upstream_recorded` ownership decision;
- lease ID and start time for `Inflight`; and
- terminal completion/failure metadata. Ordinary terminal receipts discard
  message bodies and attachments; `Transcript_persist_failed` retains the
  queued message/provenance in owner-only storage so a failed transcript write
  cannot erase the only durable copy. The Dashboard projection never emits
  that retained body.

The revision domain is capped at JavaScript's exact JSON integer boundary
(`2^53 - 1`) because the same value crosses the Dashboard JSON/SSE boundary.
The next mutation fails explicitly with `Revision_exhausted`; it never wraps a
signed `int64` into a corrupt negative snapshot.

Every mutation is written atomically before the API reports success. A failed
write rolls the in-memory mutation and revision back. Corrupt or unreadable
snapshots remain untouched, make that Keeper queue unavailable, and surface an
explicit load error. They are never interpreted as an empty queue.

### 3.2 Version-1 migration

Production snapshots existed as `keeper_chat_queue.v1` before this contract.
Startup therefore performs one explicit migration transaction:

1. strictly decode the v1 shape;
2. mint one receipt for each legacy inflight/pending payload;
3. replay legacy inflight payloads ahead of pending payloads; and
4. atomically replace the file with strict v2.

After that transaction there is no v1 runtime fallback or dual-write path. A
malformed v1/v2 file is a load error, not a compatibility success.

### 3.3 Restart recovery

An `Inflight` snapshot means the previous process did not durably settle the
lease. Startup atomically moves those receipts back to `Pending`, preserving
their IDs and FIFO order, and increments the revision. Delivery is therefore
at-least-once; connector and transcript effects must remain idempotent where
their downstream contracts permit it.

Reconfiguring BasePath first clears the in-memory registry and then loads the
new workspace. Receipts from one BasePath must never appear in another.

### 3.4 Mutation surface

The public queue API is intentionally narrow:

- `enqueue` returns the durable receipt, revision, pending count, and inflight
  count only after commit;
- `lease_batch` changes a same-source pending run to `Inflight` atomically;
- `finalize` commits `Delivered` or `Failed` for the exact lease;
- `nack` returns the exact lease to `Pending`; and
- `snapshot` / `lookup_receipt` are read-only diagnostics; exact lookup returns
  the receipt and revision from one locked observation.

There is no public unleased `dequeue`, `clear`, `remove_matching`, or untyped
`ack` path.

## 4. Turn and connector settlement

### 4.1 One timeout owner

The Keeper turn runtime owns timeout and cancellation. The queue consumer does
not race it with a second wall-clock watchdog. The turn returns a typed terminal
outcome, and the consumer persists that exact decision before allowing another
queued turn for the Keeper.

If finalization persistence fails, the consumer retains the decision in memory
and retries the same finalization. It does not rerun the Keeper turn and does
not release the Keeper dispatch gate until settlement succeeds.

### 4.2 Connector join

For Discord and Slack, the consumer starts the outbound adapter before the turn
and joins its terminal callback after the turn finishes. The callback reports
exactly one result for the primary final reply or error reply.

- preview edits and rich side messages do not decide the receipt, but the
  adapter joins their transport work before firing its terminal callback;
- Discord final-text rich projection preserves source order and uses the
  transport's named embed-count limit per turn; omissions above that cap are
  logged and counted;
- an interim stream-protocol diagnostic cannot mask a later final-send failure;
- a typed terminal cancellation emits an explicit connector notice and remains
  `Cancelled` even if that notice itself cannot be delivered;
- a missing connector credential becomes `Connector_unavailable`;
- a terminal HTTP/API failure becomes `Delivery_failed`; and
- empty terminal connector output is a failure, not implicit success.

When both the turn and connector delivery fail, the durable receipt records the
connector delivery failure and retains the typed turn failure in its detail.
The transcript already contains the turn-side failure marker.

Dashboard-originated queued turns have no external adapter. Their event stream
is still drained so backpressure cannot stall the turn, and transcript commit is
their delivery boundary.

### 4.3 Recording ownership

The admission result and persisted queue ownership fix transcript ownership
without string classification:

```ocaml
match admission, transcript_ownership with
| Free_turn, _ -> gate records the user row inside the acquired turn slot
| Busy_queued, Queue_owned -> queue consumer atomically records each receipt's user row and one terminal row
| Busy_queued, Upstream_recorded -> queue consumer records only the terminal row
```

Legacy active connector receipts without an ownership decision fail migration
closed. Operators must reconcile them explicitly; startup never guesses from a
pre-existing transcript row.

This preserves the single connector-inbound recorder defined by RFC-0226.

## 5. Admission and lane isolation

The autonomous lane yields while the Keeper has either pending or inflight chat
receipts. Leasing must not create a race window in which an autonomous turn can
overtake the queued chat turn.

Direct Dashboard and connector turns use non-blocking admission. Route-level
queue observations are only fast paths: after acquiring the Keeper turn slot,
the admission boundary rereads parked waiters and active durable receipts before
running the turn. A receipt committed or leased before that post-lock read wins
FIFO priority; queue read errors fail closed and route the message through the
durable enqueue/error path.

Queue state and finalization state are per Keeper. Different Keepers may drain
concurrently. A corrupt snapshot, connector failure, or stuck finalization for
one Keeper must not block another Keeper lane.

## 6. Dashboard and acknowledgement wiring

### 6.1 Busy acknowledgement

A successful busy acknowledgement includes:

- `receipt_id`;
- committed `queue_revision`;
- pending and inflight counts; and
- a typed queued status source.

If durable enqueue fails, the route returns an explicit error and must not claim
the message is queued.

The Dashboard handles `KEEPER_CHAT_QUEUED` as a server acceptance receipt. It
keeps the chat row in `queued` state after the short acknowledgement stream ends
and preserves the receipt ID, revision, and queue position in message details.
Browser-local unsent drafts are labelled separately as “server not accepted”.

The exact lifecycle and its atomic snapshot revision are queryable at
`GET /api/v1/keepers/<name>/chat/receipts/<receipt_id>`. Queue-change SSE remains
an invalidation rather than lifecycle truth: the Dashboard rereads this endpoint
for every visible busy-ACK receipt and moves that chat row to
`pending`, `inflight`, `delivered`, or `failed`. A receipt-query failure is
operator-visible and never guessed as success. Revision comparison prevents an
older concurrent GET from regressing a newer terminal row. Receipt observation,
reconnect hydration, and a visible-panel safety poll provide catch-up when the
queue invalidation arrives before the stream acknowledgement or is missed during
a disconnect.

A delivered receipt's `outcome_ref` is the exact `turn_ref` persisted on its
assistant transcript row. Terminal transcript convergence is complete only when
the bounded history read contains that identity; an older non-empty history
window is not success. The history and receipt deadlines cover response-body
parsing as well as response headers, and the Dashboard permits only one terminal
convergence read per Keeper at a time. Failed, empty, stale, or timed-out reads
remain pending for the next visible-panel poll.

`Delivered.outcome_ref` is non-optional at the queued-turn boundary. If a
successful-looking provider reply omits or malforms `turn_ref`, the transcript
row is retained for diagnosis but the receipt terminates as typed
`Missing_turn_ref`/`Internal_error`; the server never fabricates a join key or
emits `Delivered` without one. If a legacy or corrupt snapshot still projects a
`Delivered` receipt without a nonblank key, the Dashboard surfaces a correlation
invariant error and stops terminal-convergence retries for that receipt.
The queue consumer repeats this invariant at its final typed boundary:
`Delivered` carries a required canonical `turn_ref` string, and an invalid value
is finalized as `Internal_error`, never as `Delivered` with a missing key. A
`Failed` outcome may omit correlation, but a supplied value must be the same
canonical key; invalid values are omitted with explicit failure detail rather
than sanitized into a different identity.

### 6.2 Authoritative queue projection

`Server_keeper_waiting_inventory` exposes separate
`chat_queue_pending` and `chat_queue_inflight` rows. Each row includes receipt
ID, source, timestamp, and lifecycle detail. Snapshot load failures appear as
explicit `read_error` rows.

Every committed mutation invokes one post-commit transition observer outside
queue locks. The server emits `keeper_chat_queue_changed` with Keeper name and
revision. This event is an invalidation signal: the Dashboard debounces it and
rereads the authoritative waiting inventory instead of reconstructing state
from deltas.

The chat composer renders server pending/inflight/read-error counts independently
from browser-local drafts and from the Keeper's active turn state. The waiting
inventory renders each active receipt ID, lifecycle, lease ID, and inflight start
time so a reloaded Dashboard still has a correlation path. Its chat-specific
projection also exposes read errors and a stable newest-first window of failed
receipts with explicit total, limit, and truncation fields; the UI never treats
that response window as silent archival pruning.

## 7. Verification

Focused regression coverage must prove:

- `Pending -> Inflight -> Delivered|Failed` and exact receipt lookup;
- coalescing preserves all receipt identities;
- nack and restart preserve receipt IDs;
- enqueue, lease, finalize, and nack persistence failures roll back;
- v1 migration happens once and malformed snapshots fail closed;
- BasePath/cluster reconfiguration does not leak the registry;
- every atomic snapshot replacement has exact owner-only `0600` permissions;
- structural Eio switch cancellation nacks the unchanged lease, while an
  explicit operator/provider terminal cancellation remains a `Cancelled`
  failure even when connector notice delivery fails;
- an inbound connector transcript write failure rejects before queue ACK;
- queued failure markers persist as `Transport_failure`, never as an utterance
  that advances the answered watermark;
- failed finalization persistence retries without redelivering the turn;
- different Keeper queues dispatch concurrently;
- a receipt committed after a stale outer peek still blocks direct admission,
  both while Pending and Inflight;
- connector ACK receipt matches the durable snapshot;
- Discord/Slack terminal callback failures remain visible;
- Dashboard busy ACK rows remain `queued` after `RUN_FINISHED`;
- pending/inflight/read-error rows reach the Dashboard projection; and
- missing or malformed queued-turn `turn_ref` never reaches `Delivered`; and
- queue-change SSE triggers an authoritative refresh.

Full Dune remains CI authority. Local validation uses focused repo wrapper
targets plus the relevant Dashboard typecheck and Vitest suites.

## 8. Non-goals

- Generic sidecar connectors without an in-process outbound adapter retain the
  async-poll path.
- This RFC does not redesign the general Keeper event queue.
- Connector-specific rich formatting is a separate transport contract; this
  RFC only requires its terminal delivery result to settle truthfully.
- Terminal receipt retention/archival policy is tracked separately in #24232
  and may move to a crash-safe append-only ledger, but active receipts must
  never be pruned or hidden by that work.
