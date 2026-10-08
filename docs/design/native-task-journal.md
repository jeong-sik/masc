# Native task observations: receiver authority and authenticated reads

This unit stores observations already admitted by the runtime and privately
bound to their original input, native Agent call and dispatch. The receiver
still ends at its first root result. Persistence does not extend provider
lifetime; missing terminal observations do not prove task completion. No TUI or
Dashboard task projection is added.

## Authority and representation

`Keeper_native_task_journal.prepare` alone constructs an abstract publication
from a private `Keeper_claude_task_binding.bound` and captured typed attempt.
Neither a public decoded DTO nor a stored row grants write authority. The
collector supplies its authenticated workspace, Keeper and typed operation or
autonomous turn source. Redaction changes the permitted metadata leaves only.
Authored content, model usage and root outcome remain unchanged.

One SQLite database is the sole authority for each exact receiver at
`<base>/.masc/native-task-journals/v2/<hex keeper>/<hex generation>/<hex session>.sqlite3`.
Whole-byte lower-case hex has one inverse; opaque IDs are not trimmed or
classified by prefixes. All branch writers, readers and fixtures use v2.
The unpublished v1 JSONL representation is replaced, not migrated or silently
read as a fallback. Development files are not deleted. There is no dual writer,
sidecar sequence authority, compaction or retention policy.

The immutable metadata scope includes canonical workspace, Keeper, generation
and session, a newly minted store ID and next sequence. The observations table
has unique event UUIDs and ordered positive JSON-safe sequences. Every payload
is the complete typed task observation. UPDATE/DELETE triggers protect ordinary
observation mutation; schema identity is checked against the expected tables
and triggers. Files copied from a different scope are rejected.

## Append contract and changed corruption detection

The former JSONL implementation decoded every historical row on every append.
Across n observations this repeated O(n²) bytes and semantic work. SQLite
transactions now determine sequence and replay/conflict from the authoritative
tables. A collector's first transaction for a store incarnation performs a full
semantic audit. Later transactions validate schema, scope, sequence-tail
boundary, the incoming observation and any row addressed by its UUID.

This deliberately changes detection timing. An external equal-length rewrite
of an unrelated historical payload can remain undetected by a warm append.
A full public read or a new collector's first audit detects it. Replaying that
row's UUID detects it when the addressed row is decoded. Missing middle rows
are detected by the full audit; tail/metadata disagreement blocks append.
SQLite structural corruption is detected when affected pages are inspected,
not by an asserted perpetual byte-proof. No size/mtime/inode comparison is
used to declare a historical prefix unchanged.

Collector state records only which store incarnation received its initial
audit. It owns no database handle, sequence value or UUID decision cache.
Its short mutex protects that marker; independent collectors remain valid
concurrent writers. Audits can repeat on reopening collectors. Ordinary appends
avoid a full semantic history scan, but no measured speedup is claimed.
Concurrent external replacement of an active database is not a supported
writer operation, as with the previous file contract.

## Transaction, durability and cleanup

Directory preparation uses the existing durable directory helper. Database
open/configuration, reads, transactions and close run in a worker. Every handle
is scoped to its operation. DELETE journaling with synchronous=EXTRA follows the
existing authoritative Keeper operation store: EXTRA also synchronizes rollback
journal directory removal. SQLite busy is an immediate typed refusal; no new
wait timeout, retry loop or backoff is introduced.

BEGIN IMMEDIATE serializes metadata initialization, sequence allocation, UUID
comparison and insertion. Exact replay returns the original sequence and time;
a conflicting payload with the same UUID cannot append. The initial audit
marker is published only after a successful transaction. SQLite rollback
recovery replaces JSONL torn-suffix truncation.

A COMMIT error is `Commit_unconfirmed`, not proof nothing committed. Reconcile
using the same UUID. A successful COMMIT remains `Appended` even if a subsequent
statement-finalize or database-close diagnostic occurs; cleanup warnings never
replace the primary result. Rollback warnings accompany the primary failure.
The production append implementation has narrow COMMIT/close injection points
for deterministic fixtures; it does not substitute fabricated whole outcomes.

Task observations preserve cancellation protection through persistence,
health and reporting without holding the autonomous root-stream mutex. Other
observations retain the original stream locking and closed guards. Task
persistence never mutates the root accumulator or publishes root lifecycle.

## Descriptor-owned directory discovery

Writer reader construction and receiver discovery use one Keeper directory
function for the existing v2 storage layout. Discovery enumerates through
`Fs_compat.read_owned_directory_if_present` using the actual effective UID.
The captured workspace root and every bound ancestor/directory must have that
UID and lack group/other write permission, even when the Keeper or generation
has no files. Checks cover both actual descriptors and corresponding paths;
final validation uses fresh stats. Existing required-directory callers opt into
these checks via `owner_uid`; omitted `owner_uid` preserves prior behavior.

A cold subtree is absent only when an initial descriptor-relative child open
returns ENOENT and the already bound root/ancestors pass fresh validation.
The captured root must exist and be bound. Missing root authority, failures
after binding/enumeration, changed identity or final permission drift are typed
errors. An already enumerated generation disappearing is an outer discovery
failure, so a partial inventory cannot become empty successful discovery.
No pathname preflight or callback flag is promoted into authoritative absence.
The existing unknown-filename skip policy and process-only issue join remain.

Directory enumeration and the later SQLite pathname open are separate operations.
This repair strengthens directory discovery only: it does not bind SQLite's
leaf open to a prior directory descriptor, validate its ownership by this new
helper, or resolve leaf replacement/symlink TOCTOU. Database/cursor/audit/COMMIT /
cleanup semantics are unchanged. Discovery is not an atomic multi-file snapshot,
receiver liveness, historical completeness or a provider lifetime guarantee.
There is no new durable inventory, ordering selector, retry or retention policy.

## Authenticated consumer and exact validation scope

Production GET routes discover receivers and read records for the authenticated
server workspace and requested Keeper. They require the event-journal admin
permission. Discovery understands only canonical managed v2 filenames and
reports invalid managed receivers explicitly. Unknown foreign files are ignored,
never deleted. Reads are READONLY and do not create a missing database.

A read transaction validates every row: scope, typed payload, UUID key,
contiguous sequence, timestamp and metadata boundary. It then returns selected
rows and a typed full-audit snapshot `{store_id, through_sequence}` from that
same transaction. Cursors carry store incarnation and last sequence; a foreign
incarnation or a position beyond the snapshot is rejected. The store ID is
checked only after validating the exact requested scope. This is evidence for
that snapshot, not for later mutations. Public reads remain O(n) audits even
when the cursor selects only a suffix.

Failure/cleanup snapshots are also retained in a process-only issue registry,
keyed by canonical workspace and Keeper with an optional exact receiver. It
holds no collector or DB references, never records ordinary successes and never
clears an old issue because a later write succeeds. Its short mutex protects
in-memory copies only. A failed first append remains discoverable even if it
left no database. Preparation failures that cannot establish receiver identity
remain Keeper-level issues rather than inventing an identity. The process epoch
and known issues are exposed by the reader; historical coverage remains unknown.
There is no expiry/cap or durable failure-store claim. A disk cannot reliably
record its own failed write, and no sequence gap proves event completeness.

## Evidence and outstanding boundaries

Fixtures retain actual private bindings obtained through fake-CLI/runtime/
adapter/driver callbacks. They cover scope/redaction, root-answer preservation,
concurrent UUID replay/conflict, SQLite rollback, sequence boundary corruption,
incarnation cursors, full-read detection and the intentionally delayed unrelated
old-row corruption case. COMMIT-after-success error and post-commit close failure
are distinguished. Process health covers failed-first-append discovery and
later success retaining the issue. Actual authenticated reader fixtures cover
permission, request validation, missing/corrupt state and stored observations.
These newly authored cases have not been run natively in this coding session.

The previous closed-root fixture captures observations before the result and
injects them later; it proves storage capability, not live post-result receipt.
The lock-separation fixture holds actual cold directory preparation, requires
root closure before releasing it, and releases the gate before joining protected
callbacks even on failure. It also remains unexecuted here.

Owner comment 6064649051 reports 68 passing cases on an unpublished temporary
merge of original head 9764a00ac5 with parent fixture b5c8aa1a81. That is not an
execution result for this replacement. Upstream optional `awaited` repair
be7cc1110a6361a355e62b0301d6a253ad1bd52f and parent fixture repair
b5c8aa1a81ecaaaec020f49c9a3d9c8aed7d392c still require owner integration.
No provider lifetime, UI, deployed behavior or full-stack test PASS is claimed.

This discovery hardening adds two registered real-callback store cases: empty
Keeper/generation permissions, a cold missing subtree beneath an unsafe ancestor,
valid empty inventories, an ENOENT after actual binding and an already enumerated
generation removed through the actual after-read hook. Two Fs cases cover owned
cold absence versus an unbound missing root, UID mismatch, preserved non-opt-in
behavior, empty permissions, final directory/root permission drift, bound ENOENT,
post-enumeration directory deletion and captured-root rename. The cases are
authored, **not executed**. Local parse and fragment checks are source checks;
no runtime, HTTP, screen, installation or full-stack success is inferred.
