# Librarian working context and queue progress

Incoming events and chat requests are durable evidence. They are not all
independent commands to run again. The Librarian now organizes outstanding
inputs into source-bound context and next-step suggestions alongside ordinary
long-term memory. Keeper still owns action selection and Owner still owns the
single execution slot.

## Input and refresh

Committed event-queue changes and direct-chat admission/edit signal the existing
detached Librarian lane. Producers only submit work; they do not await a model.
The lane retains one active pass and one latest replacement. A replacement
reads current inputs when it executes, so repeated notifications accumulate in
the durable source stores rather than a list of model calls.

Queued and running chat inputs are read through one read-only SQLite transaction,
without Owner mailbox calls, growing pagination, terminal-history scanning, or
whole-database integrity scans. Event identity includes its exact admission
revision; chat identity includes operation ID and execution digest. Read failures
remain explicit and do not mean that a request disappeared.

Completed-turn evidence has a separate Pending/Attempted state. Queue refresh
cannot coalesce away an unattempted completed turn even when the input IDs are
unchanged. Completing an older attempt cannot clear newer remembered evidence;
cancellation preserves pending state. Attempted means the extraction function
returned, not that the model or storage succeeded.

## Model contract

The existing Librarian response adds `working_contexts`. Each pocket contains
`sources`, `context`, and `next_steps`. The host maps short prompt-local source
IDs back to exact references and requires every selected source exactly once.
Unknown, duplicated, or omitted IDs reject the organization. Suggestions have
no ACK, cancellation, approval, delivery, or execution authority.

For repeated campaign notifications plus a user's progress question, a pocket
may describe one campaign continuation and a distinct unanswered question.
The original IDs and original output destinations remain intact. Source text
is untrusted data; the Librarian cannot grant authority or publish across
conversation boundaries.

## Progress under queue growth

Provider request projections determine which source subset fits. An oversized
first source is skipped for this pass, allowing later smaller sources to be
organized. Skipped sources remain durable. If no source fits, ordinary memory
selection can still fit without queue material. Official-client-only lanes have
no equivalent catalog request-body projection and may reject a large request;
the failure does not gate Keeper intake.

A successful partial pass schedules another only when source coverage by complete
pockets advanced and unorganized inputs remain. Constrained passes select new or
Needs_reconsideration sources, preserving complete pockets instead of repeatedly
splitting them to fill the request. Partially regrouping a pocket preserves
its unselected members as `Needs_reconsideration`, with no actionable next-step
suggestions. This prevents alternating partial selections from repeatedly
losing and rediscovering sources. Snapshot writes use revision CAS and preserve
unobserved source contexts. Verified absent sources can prune derived history.

Keeper recall reads the latest context without waiting for Librarian. It checks
current event/chat references; stale or partially regrouped pockets are marked
for reconsideration and carry no next-step suggestions. Original intake and
current user input remain authoritative when context is absent, stale, disabled,
unfit, or unavailable.

## Evidence and limits

Scenario tests cover 20 repeated events with a direct question, producers
continuing while a fake Librarian is blocked, latest-pass coalescing, omitted
and duplicate references, changed chat input, read-only running/queued input
snapshots, partial observation, stale CAS, monotonic partial-group coverage,
oversized-source skipping, and completed-turn evidence surviving queue refresh.

This change does not make original source count equal to context count, silently
complete user questions, or replace the existing all-ready event intake. It
adds semantic context and next-step proposals to Keeper execution. The ready-only
yield change is tracked separately in PR #36130. These mechanisms do not prove
that every provider, tool, delivery path, or scheduling workload terminates.
CI execution and deployed sustained-load observation remain separate evidence.
