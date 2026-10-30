# Keeper Runtime assignment: original intent and owned receipts

Source baseline: `efc66bfba82a912311547137e1d5d7287b2ee84a` (#43697).

## As-Is / To-Be / Before and After

| Assignment boundary | Baseline | This layer |
| --- | --- | --- |
| Key-handler HTTP waits | Zero; already asynchronous | Zero |
| Logical save requests | Config GET then assignment POST: two | Same two |
| Pending intent | Worker closures and final result tuple | Original Keeper/workspace/read owner, explicit Runtime or clear-to-default choice, start clock and owned atomic receipt |
| Prepared provenance | Snapshot and assignment revision leave scope after POST | Immutable snapshot and exact expected revision retained with posting/terminal outcome |
| Concurrent same-Keeper writes | Assignment bypasses Settings/Sandbox pending ownership | Shared same-Keeper pending exclusion; different Keepers independent |
| Interrupted or withdrawn result | Scoped mailbox result; cancellation rethrows before enqueue | Not-sent before possible dispatch, unconfirmed after possible dispatch; terminal receipt survives in session state |
| Refusal evidence | Generic string error | Auth refusal, strict known revision conflict, committed, unchanged with warnings, or outcome unconfirmed |
| Success wording | Says Keeper now runs on chosen Runtime | Reports configured assignment and receipt application/durability; no current-turn execution assertion |

These counts describe source control flow, not measured latency. Existing auth
refresh policy may add physical requests. The final catalog refresh is additional
and excluded from the two-request save chain. No new health request is added.

The baseline operation tuple is admitted after read-token withdrawal **within the
same workspace authority**. It is inaccurate to say every read withdrawal loses
that result. The repaired gaps are cancellation before enqueue, scoped authority
admission, bounded-mailbox dependence, missing per-operation provenance and
missing persistent progress/recovery notice.

## Ownership and write boundary

`begin_runtime_assignment_save` admits only the original verified picker owner.
Settings editor, Sandbox shortcut and assignment pending share exclusion for the
same canonical base path, MASC root and Keeper. A different key cannot rewrite a
pending operation; rejected admission keeps the picker open. Another Keeper may
own an independent operation. Existing server revision conflicts still arbitrate
overlapping changes to the shared runtime configuration.

The worker checks its captured local workspace/read authority before reading and
again immediately before POST. It obtains the current config snapshot and exact
assignment revision, then sends the original concrete Runtime or removes the
explicit assignment for a default choice. No cached pane revision or automatic
redispatch is introduced. An explicit later choice owns a fresh read and request.
This is a local authority recheck plus the existing server assignment CAS, **not**
a new atomic expected-workspace condition on the server. An endpoint replacement
between local checks and server execution is not newly solved by this layer.

Monotonic request observations retain worker phase, original start time and worker
observation time. The event loop admits owned receipts after queued messages and
logs admission time/current-origin status. A terminal receipt cannot return to
posting or finish a successor. A late foreign receipt remains available as its
original operation but cannot authorize the current workspace's catalog refresh.
Retention lasts for the TUI session; no new disk journal is claimed.

## Response evidence

The HTTP adapter preserves status/body instead of flattening them into a string.
401/403 are the existing route's before-callback authorization refusals. A 409 is
known conflict only with the exact error envelope, code and valid expected/observed
assignment revisions. Malformed success, malformed conflict, transport failure and
other HTTP errors are unconfirmed. In particular, the server routes both parse
failure and `Assignment_io_error` to HTTP 400; atomic replace failure can reach that
same IO error path. HTTP 400 alone cannot prove no write.

Committed answers use the existing typed Runtime commit receipt. Unchanged answers
retain the original reply, exact assignment revision and typed lock warnings. The
operation joins this evidence to the original choice. Configuration/application
evidence does not establish which Runtime an already running Keeper turn uses.

## Verification and matched observation follow-up

Three new feature/protocol scenarios are authored, unexecuted: response evidence
classification; original assignment receipt through navigation and authority
withdrawal; and per-Keeper exclusion across assignment/editor/Sandbox with
independent Keepers and fresh successors. The existing unchanged-answer scenario
is adapted to check retained revision, warning and raw receipt. No wording, layout,
row-order, snapshot-output or PTY tests are added.

Ten changed OCaml files passed parsing-only checks; diff hygiene also passed.
Changelog metadata is checked when the draft receives its PR number. These checks
do not establish typing, executable behavior, independent review, merge,
installation, runtime continuity or paint. No local Dune/typecheck/tests, CI,
native/model runs, install/restart or live config writes are part of this unit.

Future matched comparisons must pin baseline/candidate source and installed binary,
use the same Keeper/workspace/revision conditions, and retain failure, cancellation,
interruption and unfinished samples. Record start, worker phase observation, UI
admission, actual paint, input response and effective next-turn Runtime separately.
The existing full goal still includes preparation attribution/discovery reuse,
cold-start first usable input, Ask-to-original-Task/useful-work continuity,
resource-owned Composition, held-job/shared-batch reuse and matched Before/After.
