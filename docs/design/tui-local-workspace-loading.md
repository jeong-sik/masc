# Local workspace loading without blocking UI admission

## Source finding

The cadence read already used the shared I/O pool, but the transition to a
confirmed matching workspace called `load_from_masc_dir` on the UI thread.
That reads agents, active tasks/history/goal links, goal confirmations and Keeper
metadata before the initial-probe acknowledgement releases parallel HTTP reads.
A slow filesystem/store can therefore delay both key handling and unrelated
HTTP collection. This is a source dependency finding, not a measured incident
latency or a claim that it explains every Loading report.

## Changed ownership and dependencies

Cold/reconfirmed identity schedules two independent local sources and returns
to the initial-probe acknowledgement. `Local_keepers` reads persisted/declared
Keeper metadata. `Local_work` reads agents, tasks/archive/goal links and goal
confirmations. These are independent observations, not an atomic snapshot of
the whole directory. The production TUI installs the shared pool before entering
the loop; missing Eio context yields an explicit failed observation.

Each source owns its pending ticket, immutable payload, failure state and cache
mutex. Work no longer carries Keeper rows and cannot overwrite them on delivery.
Its archive-cache lock cannot delay a Keeper reader by holding the metadata
cache lock. They still share actual I/O-pool resources; no latency or scheduling
priority is inferred from the independent application ownership. A fresh pass
now dispatches two local jobs/observations rather than one combined job; that
adds dispatch/mailbox work and does not establish a total-latency improvement.

A request retains source, poll/refresh intent, workspace authority, exact base
path, source ticket and monotonic dispatch time. Cadence shares a pending request
for that source. Explicit refresh starts a new ticket and requests cancellation
of the previous source worker. Cancellation slots have unique worker tokens so
late cleanup cannot clear a successor slot.
Suspension cancels both observation jobs through the existing workspace owner
and invalidates both tickets. Source is checked along with identity and ticket:
local counters can legitimately coincide, so the number alone is not an owner.
A late same-path result after withdrawal/reconfirmation cannot settle a newer
request. Local clearing retires both source tickets and cancellation slots.
Post-action reloads use the same independent worker path: creation requests only
Keeper metadata; lifecycle results, chat completion and explicit refresh request
Keeper and Work independently. Last observed rows and draft/queue identities
remain during same-workspace revalidation. A new Keeper still waits until its
own metadata appears. Metadata admission owns continuation; Work cannot replay it.

Workers return an immutable reading or failure; the UI applies each source.
An owned outer failure releases only its source request and records
`Local_workspace_failed` for that source, distinct from unread and successfully
empty data. Dataset-specific errors still retain their explicit fields. A stale
failure cannot change current failure state or release a successor request.

Input availability, saved chat opening and retained Task handoff require an
observed local Keeper source with no Keeper-list error, independently of Work
state. Required-source admission restores detail selection, revisits Task
followups, resolves saved opening and drains eligible queued input through
existing FIFO, composer, recall, control-token and explicit-stop rules. Work
admission cannot replay this wake. Actual server acceptance and Task progress
remain separate. Selected live-context config/store I/O is a separate owned job,
keyed by workspace read scope, base path, Keeper, trace and generation; chat uses
its explicit target. Metadata/input handlers do not wait for it. Same-owner
context revalidation retains the previous observation and failure evidence.

Local cache entries are replaced individually. The write-lock callback captures
read exceptions solely to unlock before re-raising their original backtraces,
including cancellation. A cancelled/failed read cannot poison that source's Eio
mutex and thereby refuse every later refresh. This does not claim actual runtime
recovery was executed.

## Before and after

| Scenario | Before | Source change |
|---|---|---|
| First matching identity or reconfirmation | UI-thread directory scan before identity acknowledgement | Schedule owned I/O worker and release acknowledgement |
| Cadence while local read is pending | One process-global boolean | One request owned by the state and source ticket |
| Old result after workspace withdrawal and return to the same path | Base path alone could admit it | Authority, path and source ticket required |
| Worker exception | Worker log; no explicit result to the UI | Failed observation settles its slot and can be retried |
| Saved chat and Task followup before local result | Synchronous scan happened to supply their metadata | Explicit dependency on completed local observation; revisit on admission |
| Retained queued input when local metadata returns | Drain only for keepers classified unavailable before this read | Revisit eligible input on each newly admitted successful Keeper result |
| Required Keeper metadata in the prior asynchronous snapshot | Agents, task/archive and goals read before metadata | Metadata job contains no optional work read |
| Pending and failed Work observation | One local state gated input | Separate metadata state gates input; Work failure remains local to Work |
| Cache lock while archive work runs | One directory-read mutex | Metadata and work caches have separate cooperative owners |
| Equal numeric source tickets or late optional result | One source | Source tag checked; optional payload cannot carry Keeper rows |
| Creation, lifecycle result, chat completion and explicit refresh | Synchronous local directory reload | Source-owned I/O jobs; creation requests metadata only |
| Explicit refresh while an earlier source read is pending | Synchronous reload retired the old ticket | Fresh ticket plus cancellation request; late cleanup cannot clear a successor |
| Cancelled/failed cached read | Exception poisons Eio write mutex | Unlock, then re-raise original exception; later readers may proceed |
| Selected live context on metadata admission or navigation | Synchronous context store/config work | Separate owned I/O read; same-owner refresh retains its observation |

The original source-level UI-thread directory scan count on identity transition
changed from one to zero. This layer removes task/archive/goal reads from the
required metadata job (those calls in that job are now zero). Optional work still
runs in its own job. Neither change says disk work disappeared, every input is
immediately sendable, or pool contention is absent. Metadata remains a required
observation for sends.

## Observations and validation limits

`tui_local_workspace_started` records `source=keepers|work`, `intent=poll|refresh`,
source request and dispatch time. `tui_local_workspace_settled` joins that source/request pair to
observation time, outcome
(`received`, `failed`, `discarded`) and whether a full HTTP refresh remains in
flight. The interval includes pool queueing, cache-lock waiting, disk/store
work and mailbox delay. It is neither worker CPU time nor visible-frame latency.
`tui_local_workspace_superseded` records cancellation requested, not worker exit.
Unobserved starts remain unfinished; do not drop them from comparison. Source
receipts without `intent` do not establish whether a read was a poll or refresh.
`received` means an immutable worker observation returned, not that all datasets
were healthy or input was accepted. Per-dataset errors and Keeper-list errors
remain in their fields. Older whole-directory receipts lack `source`; keep them
as whole-directory observations rather than joining by numeric ticket alone.

The preceding three authored, unexecuted local/HTTP protocol cases now explicitly
target optional work. Three more authored, unexecuted scenarios cover input
availability before Work settles, independent failures, and equal-number
cross-source tickets plus suspension/successors. They use production admission
and state-application functions and assert stored state, not TUI text/layout.
Existing composer, detail-focus and metrics fixtures identify observed metadata.
Four further authored, unexecuted cases cover explicit source supersession and
worker cleanup, creation availability before Work, confirmed deletion without
retargeting detail, and cancellation/exception propagation followed by another
reader using the same cache resource.
No typing, scenario execution, worker cancellation, router, runtime, installed
binary, visible UI or latency proof is established.

## Remaining work and matched comparison

Required Keeper metadata and optional Work now have separate source ownership.
Explicit post-action directory reloads and selected-live-context reads now use
owned observations. Other synchronous paths, including creation HTTP and detail
logs, remain. Continue source cache base/path identity and coalescing frequent
post-action refresh demand without losing freshness; sustained-load fairness is
not proven by the source split. Reduce unneeded preparation/discovery work
without weakening identity,
request ownership, original Task/Ask continuity or retained input control.

Compare matched starts/reconnections and the same datasets before/after: first
usable input and first visible panel p50/p95, repeated preparation/discovery
reads, resource-conflict waiting, and answer-to-original-Task progress. Keep
failed, interrupted and unfinished samples and separate client observation,
painted UI, server acceptance, model start and useful task progress.
