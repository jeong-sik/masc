# Received Child snapshot durability

`Keeper_child_content_journal` stores received complete Child observations in a
separate SQLite receiver store. Root chat event allocation and Task metadata
admission remain independent. This store accepts only a sealed
`Keeper_claude_task_binding.child_observation` through the existing
`Keeper_child_content.prepare` redacted publication constructor. A decoded public
view cannot mint a journal publication.

The real turn driver forwards the optional Child callback with the frozen
routing run, runtime and lane attempt. Agent-run carries that sealed decision in
`Keeper_hooks_agent_core.Child_content_observed`. Interactive streaming captures
workspace, Keeper, operation source and redactor once at the turn boundary; the
callback writes directly under cancellation protection, without entering the
worker queue that drops ordinary events after client disconnect. Autonomous
streaming captures the turn reference and writes independently of its closed
root bus and root publication mutex. Neither sink adds root speech, reasoning,
usage, lifecycle, tool progress or Task/run ownership.

Only an already received callback is protected. This does not extend the
one-result provider receiver lifetime or establish receipt of unforwarded
provider frames. Interactive request/disconnect execution and visible TUI
acceptance are not established by source wiring or authored fixtures.

## Disk authority

The captured canonical workspace selects
`.masc/child-content-journals/v1/<keeper>/<generation>/<session>/<client>.sqlite3`.
Every opaque component is whole-byte hexadecimal. Immutable metadata binds the
canonical workspace, Keeper, receiver generation, provider session and actual
client UUID. Every decoded row is checked against that full ticket scope.
There is no live roster, latest-input or Task-ID lookup.

The private SQLite IO helper shares statement finalization, pre-open validation,
blocking offload, exact handle closure and ambiguous commit handling with the
Task journal. Schema, admission, immutable metadata, row audit and sequence
contracts stay in each store. Task APIs and schema remain unchanged. Directory
preparation reuses the existing owned-root durability mechanism; separate leaf
checks and SQLite pathname open do not prove leaf descriptor continuity or
complete protection against pathname replacement races.

A `BEGIN IMMEDIATE` write transaction allocates one disk-owned positive sequence
and inserts one redacted snapshot. The unique key is the exact framed tuple
`(observation_id, original ordinal, channel)`. Equal full scoped payload replays
the original receipt; changed source, attempt, body or attribution conflicts.
Same provider envelope received before and after parent admission has distinct
host observation IDs, so an unknown snapshot is not overwritten by a later
bound one. Blocks sharing a frame ID retain their original ordinal/channel.
Each block commits separately; a block receipt never proves full envelope or
provider coverage.

The recorded timestamp is the local append clock. It is not provider reception
time or an ordering proof against root events. DELETE journaling and EXTRA
synchronization use the existing durable SQLite pattern. On an unconfirmed
commit, reconciliation retries the **same** prepared private publication; it
must not remint the observation or reprepare under another redactor/attempt.
Cleanup warnings retain the primary receipt/failure separately. No automatic
retry or fallback is installed. The actual interactive/autonomous `observe` →
`report` sinks discard the prepared publication and retain typed uncertainty
and collector-local health only; same-publication reconciliation is available
to explicit `prepare` + `append` callers, with no recovery queue or retry handle
installed in these sinks. Busy refusal remains explicit.

## Read and failure boundaries

`open_reader` receives an authenticated caller's captured workspace/Keeper and
exact three-field invocation. `read` opens READONLY and creates nothing. Missing
store, corrupt schema/history, foreign incarnation, cursor ahead, directory/I/O
failure and uncertain write are distinct typed outcomes. A successful read
fully audits schema, immutable scope, JSON codec, row composite key, contiguous
sequence and metadata in one snapshot before returning any suffix. This is
semantic consistency checking, not cryptographic authentication of disk body.
The cursor names the actual store incarnation and audited sequence; replacing a
store does not inherit its previous cursor.

Reads do not claim provider completeness. Health belongs to the in-memory
collector only; after collector loss, historical persistence-failure coverage is
unknown. A valid store and an empty health list do not prove that all observations
were received or persisted. No success registry or unrelated inventory is added.

The full-audit read primitive is deliberately not attached to periodic polling.
A future authenticated receiver/read transport and TUI consumer need a distinct
unchecked change-hint path and explicit audited refresh, preserving the
corruption contract without repeatedly scanning unchanged history. This unit
adds neither endpoint nor TUI row integration nor cross-root/Child ordering.

## Scoped read contract and unchecked discovery hints

The journal exposes descriptor-owned discovery of actual Keeper/generation/
session/client-UUID directories. The same canonical path derivation serves
writers and discovery. The existing filesystem primitive checks bound root,
ancestor and final directory UID/permissions/identity, including empty paths.
Only validated initial descendant absence is a cold empty inventory; an
already enumerated generation/session disappearing is failure. A captured leaf
that subsequently disappears retains its receiver identity with `Missing_store`.
Unknown names follow the existing managed-directory skip policy. Enumeration
and subsequent SQLite pathname opening remain separate observations, not a leaf
TOCTOU security proof or atomic inventory.

`read_hint`/`discover_hints` return a private `change_hint`, never `validation`.
They read immutable schema/full-ticket metadata and tail agreement in a READONLY
snapshot, without quick-check or historical payload/sequence audit. A tampered
prefix with the same tail can leave a hint unchanged while full `read` or audited
`discover` refuses it. Hints cannot clear an audited failure or certify silence,
liveness or completeness. No stat trust cache, automatic retry or extra receiver
registry is added.

`Keeper_child_content_read` is a closed public codec for records, audited receiver
inventories, unchecked hints and typed failures. It reuses the Child observation
codec and re-redacts only human body/model leaves during authoritative read
projection. Scope retains Keeper plus all three invocation fields. The journal
snapshot carries the opened store's own scope, and the projection refuses a
different requested scope with `invalid_scope` even when the suffix is empty,
since an empty page has no row whose origin could expose the label. Records have
unique `(observation_id, ordinal, channel)` keys and contiguous positive sequences;
provider envelope UUID alone is deliberately not unique across received snapshots.
The mandatory request matcher rechecks projected or decoded rows against actual
scope, cursor and complete requested suffix, including an empty caught-up page.
Unknown/duplicate/null/schema/unsafe numeric/scope/cursor/gap mismatches refuse.
Public decoded views cannot mint runtime, binding or journal publication authority.

Every read response explicitly reports persistence-failure history `unavailable`,
provider completeness `unknown` and liveness `unknown`. Collector-local health is
not represented as an empty surviving process history. Cleanup operations and
closed failure codes expose no raw filesystem paths or exception details.
These codecs/discovery primitives are not yet an authenticated HTTP endpoint or
TUI consumer. The subsequent transport must use captured authenticated workspace
scope, strict URI queries and both H1/H2 auth gates; the UI must poll unchecked
hints and fully read changed stores or an explicit audit rather than repeatedly
auditing unchanged full history.

## Immutable TUI snapshot reader

`Masc_tui_child_content` consumes the public records/receivers/hints API through a
caller-supplied guarded fetch boundary. Its immutable cache keeps every complete
snapshot, including refusals, keyed by Keeper, full ticket3 receiver and store
incarnation. Provider envelope UUID is a correlation, not a deduplication key;
there is no Task fold, Root speech/lifecycle mutation or inferred input consumption.
Workspace ownership, read-epoch checks and mailbox admission belong to the actual
launcher; this pure consumer cannot authenticate a workspace from DTO or Keeper
name. The caller must retire the cache with its workspace lifetime.

Poll reads unchecked hints and requests exact suffixes only for changed stores.
It preserves prior bodies/cursor on failure, retains disappeared/older
incarnations, keeps audited errors through an unchecked Poll and avoids repeated
failed full reads at the same attempted hint. A healthy receiver may still advance.
Composite observation identity is checked against retained earlier pages as well
as within a decoded page. An unchanged Poll retains physical state/records
identity rather than rebuilding the retained history.

Explicit Audit always requests full current-incarnation records. It may replace
only the cached human text/model leaves as supplied by that full response;
previous sequence/timestamp/origin/observation/provider/parent/message/evidence
facts must match exactly, and the same incarnation cannot regress its tail.
A valid-looking rollback or identity rewrite is a typed cache refusal that retains
known history. This is consistency with prior observed public facts, not a
cryptographic certification of disk provenance. Full successful reads clear
current audited failure; hints alone cannot clear it.

Audit refreshes current store leaves only as supplied by that response's captured
redactor. Older/disappeared incarnation leaves remain last observed, with current
redaction unknown. An empty caught-up suffix cannot re-redact cached human leaves,
and no policy-version/global/latest-redaction guarantee is inferred. Persistence
failure history remains unavailable and provider completeness/liveness unknown.
This unit adds the standalone public-API consumer and authored transport fixtures;
actual launcher/async read-epoch wiring, distinct safe terminal projection and
visible PTY/screenshot acceptance remain separate subsequent work.
