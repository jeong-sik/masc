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
