---
rfc: "connector-deferred-reply-via-chat-queue"
title: "Durable Keeper chat receipts and connector delivery settlement"
status: Active
created: 2026-06-30
updated: 2026-07-30
author: vincent
supersedes: []
superseded_by: null
related: ["0203", "0217", "0223", "0225", "0226", "0232", "masc#23925"]
implementation_prs: [24139, 26367]
---

# RFC: Durable Keeper chat receipts and connector delivery settlement

## 1. Decision

Every accepted Dashboard, Discord, or Slack message has one durable
`Receipt_id`. That receipt is the producer identity, queue identity, delivery
correlation identity, and completion identity. The queue does not create a
second lease, claim, attempt, or settlement ID.

The closed lifecycle is:

```text
Pending -> Inflight -> Delivered
                    \-> Failed
```

`Delivered` means the Keeper turn, transcript write, and connector terminal send
all succeeded. `Failed` is terminal and carries a typed failure kind and
operator-visible detail. A process stop, cancellation after claim, or unknown
external effect terminates as `Failed Interrupted`; it is never replayed.

## 2. Fresh durable authority

The BasePath-owned SSOT is:

```text
<base>/.masc/keepers/<keeper>/chat-queue-v3.sqlite3
```

Its schema identity is `keeper_chat_queue.sqlite.v3`. SQLite stores the
monotonic revision, FIFO sequence, terminal count, canonical receipt state, and
message body only while the receipt is active. Terminal rows retain correlation
metadata but discard message bodies and attachments.

This is a fresh-state contract. The runtime does not read, decode, import, or
migrate an older chat-queue file or schema. An unexpected schema, noncanonical
row, ownership change, unreadable store, or metadata divergence makes that lane
explicitly unavailable; it is never interpreted as an empty queue.

## 3. Mutation contract

The public queue surface is intentionally small:

- `enqueue` and `enqueue_with_receipt` durably publish one `Pending` receipt;
- `claim_next` changes the FIFO receipt to `Inflight`;
- `complete_claim` changes that exact receipt to `Delivered` or `Failed`;
- `cancel_pending` terminalizes an exact receipt only before delivery starts;
- `snapshot`, `lookup_receipt`, and `lane_status` are read-only observations;
- `reconcile_persistence` resolves an exact retained SQLite transaction plan.

There is no public requeue operation. Once `claim_next` returns a claim, the
receipt cannot become `Pending` again.

An exact repeated `complete_claim` is idempotent only when the stored terminal
decision is identical. A conflicting decision returns a typed terminal-state
error. A missing or non-inflight receipt returns a typed state error; the
consumer never guesses that completion probably happened.

## 4. Commit uncertainty

The queue distinguishes a transition that was not published from one whose
commit result is indeterminate. Reconciliation compares the durable database
with the exact before/target plan:

- a matching before state applies the retained target;
- a matching published target confirms it;
- any third state is a typed reconciliation conflict.

Claim publication has one additional internal compensation. If commit became
indeterminate before `claim_next` returned anything to a worker, a published
`Inflight` target is moved back to `Pending`. No external effect can exist in
that path, so the same receipt remains authoritative without a second execution
identity. This compensation is not a public requeue and cannot run after a
claim was delivered to a worker.

## 5. Admission and execution ownership

The queued consumer acquires the Keeper lane's serialized chat admission token
before calling `claim_next`. Claim, turn dispatch, connector delivery, and
terminal persistence therefore run inside one admitted lane turn.

The already-admitted token is passed to the direct turn operation. The queued
path does not call a public facade that tries to acquire admission again.
Autonomous and direct chat entrypoints observe the same lane authority, so
there is no nested admission gate or facade-from-facade path.

Every fiber created for a queued turn belongs to the claim-scoped Eio switch.
If that switch is cancelled, the consumer records `Interrupted` under
`Eio.Cancel.protect` before releasing the lane. A terminal persistence failure
retains the exact receipt and outcome for retry; a later receipt cannot claim
the lane first.

Cancellation while merely waiting for admission does not claim or mutate the
receipt. It remains `Pending`.

## 6. Connector and transcript settlement

The source variant fixes transcript ownership without string classification:

```ocaml
match source with
| Dashboard _ -> turn records user and assistant rows
| Discord _ | Slack _ -> gate records the user row; turn records assistant only
```

Discord and Slack settlement waits for the primary terminal send. Preview
updates and side messages cannot settle the receipt. Missing credentials,
terminal transport failure, empty terminal output, missing visible reply, and
transcript persistence failure remain typed failures.

`Delivered.outcome_ref` is the canonical `turn_ref` persisted on the assistant
transcript row. The server never fabricates a join key or converts a missing key
to success.

## 7. API and dashboard projection

A successful busy acknowledgement includes the committed receipt ID, queue
revision, and active counts. Failure to enqueue is returned explicitly.

`GET /api/v1/keepers/<name>/chat/receipts/<receipt_id>` returns schema
`keeper_chat_queue.receipt.v3`. An inflight state exposes its start time and the
same receipt ID; it has no secondary attempt identity.

Queue-change SSE is only an invalidation signal. The Dashboard rereads the
authoritative receipt and waiting-inventory projections. Read failures remain
visible and are never guessed as delivered.

The waiting inventory exposes separate pending, inflight, persistence-blocked,
and read-error rows. Active rows carry the receipt ID, source, FIFO position,
and lifecycle timestamps. A blocked completion carries the same receipt ID.

## 8. Required verification

Focused regression coverage must prove:

- the exact `Pending -> Inflight -> Delivered|Failed` lifecycle;
- FIFO and receipt identity across enqueue, claim, completion, and lookup;
- exact repeated completion is idempotent and conflicting completion is typed;
- pre-admission cancellation leaves the receipt `Pending`;
- post-claim cancellation and process restart terminalize as `Interrupted`;
- uncertain claim publication is never returned to a worker and compensates
  only through exact plan reconciliation;
- completion persistence retries the same receipt and decision without
  redispatch;
- a receipt committed after a stale outer observation cannot be overtaken;
- connector and transcript failures remain visible terminal failures;
- receipt API and waiting inventory expose no secondary execution identity; and
- unknown fields, an unexpected schema, and corrupt rows fail closed.

Full Dune build and tests remain CI authority. Local checks are limited to
formatting, parsing, TypeScript typechecking, and focused non-Dune validation.

## 9. Non-goals

- This RFC does not redesign the general Keeper event queue.
- Connector-specific rich formatting is outside terminal delivery settlement.
- Terminal retention policy may move to a separate ledger, but active receipts
  must never be pruned or hidden.
