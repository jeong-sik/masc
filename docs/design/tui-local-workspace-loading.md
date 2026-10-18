# Local workspace loading without blocking initial admission

## Source finding

The cadence read already used the shared I/O pool, but the transition to a
confirmed matching workspace called `load_from_masc_dir` on the UI thread.
That reads agents, active tasks/history/goal links, goal confirmations and Keeper
metadata before the initial-probe acknowledgement releases parallel HTTP reads.
A slow filesystem/store can therefore delay both key handling and unrelated
HTTP collection. This is a source dependency finding, not a measured incident
latency or a claim that it explains every Loading report.

## Changed ownership and dependencies

Cold/reconfirmed identity now schedules the same worker as cadence and returns
to the initial-probe acknowledgement. A local request retains workspace
authority, exact base path, source ticket and monotonic dispatch time. Cadence
shares a pending request. Suspension cancels its observation job through the
existing workspace cancellation owner and invalidates its source ticket.
Completion checks the workspace, path and ticket, then settles once. A late
same-path result after withdrawal/reconfirmation cannot settle a newer request.
Explicit post-action synchronous reloads and presentation clearing invalidate
older asynchronous observations as well.

The I/O worker returns an immutable reading or a failure; the UI applies data.
An owned failure releases its request and records `Local_workspace_failed`,
distinct from unread and a successful empty directory. A stale failure cannot
change the current failure state or release the successor request. The metadata
cache is mutable and shared by worker and post-action reads, so a cooperative
mutex owns the directory-read transaction. The production TUI installs its
shared pool before entering the main loop. Missing Eio context is an explicit
failed observation; this launcher has no synchronous directory-read fallback.

An unread/failed local observation does not authorize chat submission. Saved
chat opening and Task handoff wait for local metadata. After an admitted result,
restore the selected detail, revisit retained Task followups, resolve saved chat
opening and drain eligible queued input through existing FIFO, composer,
recall, control-token and explicit-stop rules. A sibling HTTP collector does
not own this wakeup. Actual server acceptance and task progress remain separate.

## Before and after

| Scenario | Before | Source change |
|---|---|---|
| First matching identity or reconfirmation | UI-thread directory scan before identity acknowledgement | Schedule owned I/O worker and release acknowledgement |
| Cadence while local read is pending | One process-global boolean | One request owned by the state and source ticket |
| Old result after workspace withdrawal and return to the same path | Base path alone could admit it | Authority, path and source ticket required |
| Worker exception | Worker log; no explicit result to the UI | Failed observation settles its slot and can be retried |
| Saved chat and Task followup before local result | Synchronous scan happened to supply their metadata | Explicit dependency on completed local observation; revisit on admission |
| Retained queued input when local metadata returns | Drain only for keepers classified unavailable before this read | Revisit eligible input on each newly admitted successful local result |

The source-level UI-thread directory scan count on identity transition changes
from one to zero. The directory work still happens once in the worker; this is
not a claim that disk work disappeared or that every input is immediately
sendable. Metadata remains a prerequisite for sends.

## Observations and validation limits

`tui_local_workspace_started` records source request and dispatch time.
`tui_local_workspace_settled` joins that request to observation time, outcome
(`received`, `failed`, `discarded`) and whether a full HTTP refresh remains in
flight. The interval includes pool queueing, cache-lock waiting, disk/store
work and mailbox delay. It is neither worker CPU time nor visible-frame latency.
Cancelled/unobserved starts remain unfinished; do not drop them from comparison.

Three authored, unexecuted protocol/state scenarios cover independent local/HTTP
admission, duplicate delivery, retired same-path epochs and foreign paths,
owned failure, stale failure and retry. They assert admission and stored state,
not TUI text/layout. Existing composer fixtures now explicitly describe an
observed local directory. No typing, scenario execution, worker cancellation,
router, runtime, installed binary, visible UI or latency proof is established.

## Remaining work and matched comparison

The local snapshot still reads tasks/history before Keeper metadata. Split the
required Keeper observation from optional task/history sources with independent
ownership. Explicit post-action reloads and selected-live-context application
still have synchronous I/O paths. Complete those without weakening identity,
request ownership, original Task/Ask continuity or retained input control.

Compare matched starts/reconnections and the same datasets before/after: first
usable input and first visible panel p50/p95, repeated preparation/discovery
reads, resource-conflict waiting, and answer-to-original-Task progress. Keep
failed, interrupted and unfinished samples and separate client observation,
painted UI, server acceptance, model start and useful task progress.
