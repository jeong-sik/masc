# Independent native-task observations in Keeper chat

Keeper chat reads the existing authenticated native-task discovery and records
endpoints separately from root chat journals. Opening chat and the existing
refresh cadence request observations for the selected Keeper. Reading older
chat rows does not stop task reads. Leaving the surface stops new polls;
returning catches up. Root-turn completion does not clear this state.

## Authority and identity

`Masc_tui_native_tasks` consumes `Keeper_native_task_read`, with no second wire
decoder or private runtime capability. Structural decoding and exact request
matching validate Keeper, receiver, store incarnation and complete suffix. Even
a first records read must match the incarnation advertised by discovery. Cache
ownership is bound to the Keeper. Histories are keyed by receiver and store;
task aggregation uses the complete original `Runtime_native_tasks.origin`.

A newly advertised store starts a distinct history from the beginning. It does
not reset a retained cursor. Only a validated successful page advances that
history. Missing receivers do not erase observations or imply completion.
Per-receiver failure retains its cursor/tasks while other receivers can advance.
Discovery/transport failure retains previous state with explicit failure. An
unchanged audited successful boundary skips redundant records HTTP; failed
reads retry on the existing cadence.

The launcher captures workspace authority and identity, checking before and
after every HTTP read. Mailbox delivery uses `Workspace_scoped`; withdrawal
clears caches and inflight marks. Stale results cannot populate a successor
workspace. There is one inflight read per Keeper and sequential receiver reads.
URI query encoding preserves opaque reserved characters. CanAdmin is unchanged.

## Presentation

A separate `NATIVE TASKS` section precedes pending operator input. Existing
Status, Tool and Error presentation has no invented timestamp or root-turn rail
and uses the chat viewport's measurement/scrolling. It creates no authored
speech, changes no input delivery state, contributes no root activity and adds
no root model usage. Registration alone displays `status unreported`; explicit
patches are labeled `reported`, and terminal notices remain separate evidence.
Signed usage and absent/false/true flags retain their meaning. `skip_transcript`
suppresses its inline task entry; ambient observations contribute no activity.
Provider completeness and liveness remain explicitly unknown after root exit.

Ctrl-D Full details expose store, invocation/input, runtime attempt, native-call
envelope/ordinal, run and source identity. Raw identities remain unchanged in
state. Labels, bodies and diagnostics use the existing terminal sanitizer at
the display edge. Failures and process-only persistence/cleanup diagnostics
remain visible. These transient snapshots are not searchable durable chat
messages; scroll-index placeholders preserve projection alignment.

Unchanged audited reads retain the immutable native-state identity. Native
entries and their join with settled history are memoized by actual input and
display-setting identity, preserving existing row-count and scroll-anchor
caches on idle paints. Changed observations, tools visibility or label width
invalidate the relevant projection.

## Evidence limits

Authored fixtures route public HTTP-shaped JSON through the actual shared
codec, suffix reader and chat layout projection. They cover suffix progress,
signed usage, terminal notice, unchanged reads, full-origin separation, new
stores, foreign scope, failure/retry cursors, missing receivers, URI values,
skip/ambient flags, terminal safety and no fabricated root activity. They have
not executed in this session. Parsing is not typecheck or runtime proof.

This creates no events a provider has not emitted, extends no receiver lifetime
and repairs no SQLite pathname leaf races. The earlier local PTY attempt failed
at localhost bind before launching the installed historical binary; it supplies
no frame for this patch. Matching-binary provider and screen checks remain.
