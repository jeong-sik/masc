# Keeper Single-Owner Inbox Ledger v1

## Contract

The operation ledger is a Keeper's durable inbox and execution history. It is
not a workflow engine.

- Message and Stimulus ingress stores immutable input before accepting an
  operation.
- One Keeper owner is the only writer of that Keeper's ledger and conversation
  state.
- At most one operation per Keeper is Running with conversation-state
  authority.
- A Running operation is never automatically executed again after a crash.
- Terminal operations and terminal delivery attempts are immutable.
- A stale child completion cannot settle a different operation or a replacement
  owner.
- Interrupted operations, failed outcomes, and Ambiguous deliveries remain
  visible context. They do not block later work.
- Keeper-to-Keeper messages are ordinary inbox messages. They create no wait,
  join, callback, dependency, or reply obligation.

The system does not promise exactly-once external effects, fleet-wide resource
isolation, or arbitrary orchestration liveness.

## Authorities

| Concern | Authority |
| --- | --- |
| Keeper existence and profile | resolved active config |
| Acceptance, FIFO, and execution history | per-Keeper operation ledger |
| Conversation | successful `next_state_ref` values and ledger projection |
| Connector attempts | delivery ledger |
| Async jobs | the producer-owned Fusion, HITL, or Gate store |
| Pause | `keeper_control` |
| Routine health reads | immutable owner projection |

## Identity and canonical requests

The Keeper identity is the canonical BasePath and Keeper name. Recreating the
same name at the same BasePath resumes the same ledger. A new identity requires
a new name or BasePath.

Identifiers use positive v1 parsers:

```text
operation_id = kop1:<64 lowercase hexadecimal characters>
delivery_id  = kdel1:<64 lowercase hexadecimal characters>
blob_ref     = sha256:<64 lowercase hexadecimal characters>
```

No other identifier is accepted or reinterpreted.

An ingress-specific constructor uses cryptographic randomness or a
domain-separated deterministic digest. Event and continuation constructors are
deterministic. Operator and connector constructors may be random.

The request digest is the SHA-256 of canonical v1 envelope bytes, not an
unframed concatenation:

```json
{"schema":"masc.keeper_operation.request.v1","kind":...,"source_ref":...,"submitter_ref":...,"input":...}
```

The typed encoder fixes field order, value representation, and UTF-8 bytes.
Duplicate fields, unknown fields, malformed UTF-8, and non-finite numbers are
rejected before encoding. The authenticated submitter is injected by the host.

The same operation ID and digest is a replay. The same ID and a different
digest is an identity conflict.

## Runtime layout

```text
<base>/.masc/keepers/<keeper>/operations.sqlite3
<base>/.masc/keepers/<keeper>/operation-blobs/sha256/<prefix>/<digest>
```

Each owner holds one persistent SQLite connection. Exact operation reads and
all writes use the same serialized store lane. Routine reads use the immutable
owner projection.

SQLite configuration is:

```text
PRAGMA journal_mode=DELETE
PRAGMA synchronous=FULL
PRAGMA foreign_keys=ON
```

The schema activates only when exact `application_id`, `user_version`, and
schema objects match v1.

### operations

```text
queue_seq       INTEGER PRIMARY KEY
operation_id    TEXT UNIQUE NOT NULL
kind            Message | Stimulus | Autonomous
source_ref      canonical typed bytes NOT NULL
submitter_ref   canonical typed bytes NOT NULL
state           Queued | Running | Settled | Cancelled | Interrupted
request_digest  lowercase SHA-256 NOT NULL
input_ref       typed immutable blob ref NOT NULL
base_state_ref  typed immutable blob ref NULL
outcome_ref     typed immutable blob ref NULL
next_state_ref  typed immutable blob ref NULL
created_at      REAL NOT NULL
started_at      REAL NULL
finished_at     REAL NULL
```

SQL checks enforce the legal field shapes for each state. A partial FIFO index
selects Queued rows, and a partial unique index permits at most one Running row.

Legal transitions are:

```text
Queued  -> Running -> Settled
Queued  -> Cancelled
Running -> Interrupted
```

Success, failure, tool failure, input required, and continuation-unrepresentable
are typed outcome variants inside `outcome_ref`; they are not operation states.

### deliveries

```text
delivery_seq          INTEGER PRIMARY KEY
delivery_id           TEXT UNIQUE NOT NULL
operation_id          TEXT NOT NULL REFERENCES operations(operation_id)
destination_ref       canonical typed bytes NOT NULL
state                 Pending | Attempting | Delivered | Failed | Ambiguous
payload_ref           typed immutable blob ref NOT NULL
connector_message_id  TEXT NULL
evidence_ref           typed immutable blob ref NULL
created_at             REAL NOT NULL
started_at             REAL NULL
finished_at            REAL NULL
```

One row is one connector attempt. A partial FIFO index selects Pending rows.
There is no attempt sub-record and no retry mutation. A new explicit request may
create a new delivery row.

### keeper_control

```text
singleton  INTEGER PRIMARY KEY CHECK (singleton = 1)
paused     INTEGER NOT NULL CHECK (paused IN (0, 1))
```

Pause blocks new computation and autonomous generation. It does not block
message acceptance or delivery.

## Immutable blobs

The operation blob store is independent from tool blobs. The wire reference is
only the SHA-256 content address. Distinct OCaml ref types and the canonical
blob envelope carry the expected kind; read-back verifies the descriptor byte
length, exact bytes, envelope kind, and digest. Input, outcome, state, delivery
payload, and delivery evidence cannot be mixed without an explicit parse.

Publication order is:

1. produce canonical redacted bytes;
2. write a temporary file;
3. fsync the file;
4. atomically rename it;
5. fsync the parent directory;
6. read it back and verify exact bytes and digest;
7. only then commit a SQLite reference.

An orphan blob is harmless. A committed reference to an absent or mismatched
blob is a store integrity failure. v1 never deletes operation blobs.

Raw authorization, secrets, and inline attachment bytes are removed before
admission. Attachments become immutable media references.

## Owner

The directory maps `(canonical BasePath, Keeper name)` to a stable owner object.
The object enters the map with `accepting = false`, performs its strict startup
audit outside the directory mutex, and remains mapped while stopping. It is
removed only after its child switches have ended and pointer identity still
matches the map entry.

The owner has:

- a bounded 128-command external mailbox;
- a serialized store lane;
- one computation completion slot;
- one delivery completion slot;
- coalesced shutdown and wake slots;
- at most one computation child and one delivery child;
- an immutable Atomic read projection.

Mailbox capacity is not acceptance. `202 Accepted` is returned only after the
input blob and Queued transaction are durable. A full mailbox rejects before
blob or row creation. The durable FIFO has no artificial row-count limit.

The actor never joins a child while draining commands. Provider, tool, connector,
filesystem, and SQLite work runs outside the actor fiber. The store lane returns
typed completions in request order. Child exceptions and cancellation become
typed completions and never escape to the server root switch.

A computation completion settles only when both are true:

```text
completion.owner == owner
completion.operation_id == owner.running_operation_id
```

An Admin interrupt requests child cancellation without joining it. The operation
becomes Interrupted only after the matching child reports typed cancellation, or
during startup audit after a process crash. The interrupt request has no durable
journal of its own.

## Scheduling and settlement

When unpaused and no operation is Running, the owner starts the smallest
`queue_seq` Queued row. The Running transaction captures the latest successful
`next_state_ref` as `base_state_ref`. The executor receives an already-Running,
immutable operation and does not repeat admission or lifecycle checks.

The child creates immutable outcome, next-state, and delivery-payload blobs.
One terminal SQLite transaction performs all of the following that apply:

- Running to Settled;
- outcome and next-state refs;
- the complete deterministic Pending delivery set;
- one deterministic FIFO-tail successor for cooperative continuation.

If a commit response is uncertain, success requires an exact read-back of the
prior state, target terminal payload, and complete delivery/successor set.
Anything else stops acceptance and scheduling for that owner until restart and
strict audit.

Startup changes every remaining Running row to Interrupted and continues with
later Queued rows. It never recreates or reruns the interrupted computation.

## Context and continuation

The current conversation state is the newest Settled operation with a non-null
`next_state_ref`. The next execution combines that state with the deterministic
ledger tail and current immutable input. The tail includes later Settled,
Interrupted, and Cancelled facts plus terminal delivery facts.

Cooperative yield creates a provider-neutral continuation delta. The parent
terminal transaction inserts one ordinary Stimulus successor at the FIFO tail.
Its deterministic identity is derived from the parent operation ID and exact
delta ref. The successor sees the latest conversation state at execution time
and the delta as additional typed context. It has no priority, dependency edge,
or hidden callback. If executor state cannot be represented as that delta, the
parent settles with `Continuation_unrepresentable` and creates no successor.

Autonomous wake is a coalesced hint. An Autonomous operation is created only
when unpaused, with no Running row, no Queued row, and no existing autonomous
candidate. Once accepted it is ordinary FIFO work.

## Keeper messaging

`masc_keeper_send` submits each requested message independently and immediately
returns an operation ID or typed rejection for each item. There is no batch
transaction or target-wide preflight. A busy target may accept while it is
Running if its mailbox has capacity. A self-message is queued behind the current
operation.

`masc_keeper_read` returns exact state and a typed outcome summary only when the
authenticated calling Keeper is the recorded submitter. Admin REST reads use a
separate permission boundary.

Peer content is provenance-bearing user-role data, never target system
instruction. Replies are independent messages.

## Event, async, and Gate handoff

Event Queue remains a durable transport buffer:

```text
durable Event -> Accepted or Replayed operation -> Event ACK
```

An Event is not acknowledged on mailbox, blob, or ledger failure.

Each async producer owns its job and terminal handoff in its existing durable
store. Its terminal transaction records a self-contained completion input,
deterministic Event/operation identity, and whether handoff is pending. Its
reconciler retries the same Event identity until the Event transport accepts or
replays it.

Gate is one such producer. Approval makes the exact immutable effect payload
eligible for one automatic attempt:

```text
Pending -> Approved -> Attempting -> Applied | Failed | Ambiguous
```

The Gate-owned executor durably enters Attempting before dispatching the exact
bytes. A crash, timeout, or lost response from Attempting becomes Ambiguous and
is not dispatched again. This is at-most-one automatic attempt, not exactly-once
external effect. Gate terminal state and its pending completion handoff are
committed together.

## Storage failure and backup

There is no percentage-based capacity formula, reservation ledger, or automatic
blob deletion. A concrete pre-acceptance storage exhaustion maps to a typed 507
response; other store unavailability maps to 503. A failure after acceptance is
settled when possible, otherwise startup turns a remaining Running row into
Interrupted. Storage health is observable but does not become a fleet scheduler
gate.

Backup is quiesced maintenance: stop owner intake and children, close the sole
SQLite connection, copy the database and referenced immutable blobs, then verify
hashes and run the same strict startup audit against the restore.

## Hard cut

Production has one call graph:

```text
Ingress -> Keeper_owner -> Operation_store -> Operation_executor
```

OAS never imports MASC types; a MASC adapter converts OAS results to typed
outcome and continuation delta values. Every production ingress reaches the
single call graph above directly.

Cutover is offline. It verifies no active old work, stops the process, archives
old mutable state outside runtime discovery, creates fresh ledger/control/blob
stores from resolved config, and runs verify-and-exit. Old data is never decoded
or converted. Archive rollback is permitted only before the first v1 operation
is accepted.

## Acceptance invariants

- No execution before durable Queued acceptance.
- At most one state-authorized Running operation per Keeper.
- Terminal operation and delivery rows never reopen.
- A stale completion never settles current work.
- A Running crash never causes automatic computation replay.
- An Ambiguous delivery or Gate attempt never causes automatic resend.
- Failed, Interrupted, and Ambiguous facts do not fence unrelated future work.
- Keeper messaging creates no wait graph.
- Every production ingress has one direct owner admission path.
