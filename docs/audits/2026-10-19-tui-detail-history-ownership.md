# Keep Task and Goal history bound to the current read

Source comparison base: `830a231e3d4dc9adcb05d08ee67eb7f86b587dce`
(#43841). This layer repairs TUI read ownership and implements visible retrieval
states. It does not establish the cause of the reported live Loading screen or
measure input, paint, preparation or useful-work latency.

## As-Is / To-Be

Task history and Goal timeline completion compared only the item ID currently
selected. A second read of the same item could finish first, then an older
response could replace its newer value or failure. Cached state was an optional
ID/result pair; absence also rendered as loading, and a refresh failure replaced
the previous successful history with an error. Task cancellation follow-up
explicitly discarded the previous history before fetching again.

Both histories now use the existing immutable fetched model with an opaque
key/generation request. Explicit refresh supersedes the pending owner, retaining
the same key's previous value and refresh failure. The existing `start` API keeps
its sharing policy for other consumers. Async messages carry the original
request, and only that source's current owner can settle it. Latest scoped
responses may settle while the pane is hidden; display still selects by item
key. Navigation clears retain generation ordering, and workspace withdrawal
clears both values and pending owners before any same-ID replacement can read.

| Boundary | Before | Implemented behavior |
| --- | --- | --- |
| Same-ID overlapping reads | Any matching ID could publish, including an older late response | Only the latest issued request can publish |
| Refresh with prior rows | No distinct retrieval state | Prior rows remain; pending refresh is visible |
| Refresh failure | Prior history replaced by error | Prior observation plus failure reason |
| Retry after failed refresh with prior value | Failure/value not retained as one reading | Prior value and failure remain until replacement settles |
| No requested value | Absence displayed as loading | Not requested, loading and failed are distinct |
| Source unavailable Goal payload | Unavailable payload replaced history | Typed failure becomes a read failure with its cause; prior successful events remain |
| Workspace replacement with same IDs | Item ID alone was insufficient ownership | Both source caches/owners withdrawn; generations retained |
| Task/Goal work and actions | Original action and source protocols | Unchanged; retrieval completion grants no work/effect/success claim |

This is not a new polling policy, timeout, concurrency cap or global cache.
Superseding a response owner does not cancel that earlier HTTP read or reduce
the number of requested reads. Existing workspace cancellation and envelope
authority remain separate. First-read failure with no prior value is `Failed`;
a retry then loads with no invented history. Only a decoded Goal-ready event
list enters the successful cache. Typed store/linked-task/approval unavailability
is converted at the read boundary to its existing cause, so HTTP success alone
cannot replace good events with an unavailable payload or an invented empty list.
Added diagnostics are terminal-sanitized and wrap through the existing text
layout at the detail width. The planning library declares the sanitizer dependency.

## Source bounds and scenario evidence

For `K` same-ID reads issued before their answers arrive, the old ID check could
accept all `K` matching answers, in arrival order. The new source state accepts
only its current pending request; up to `K-1` superseded completions cannot
replace it. After it settles, duplicate completions cannot settle it again.
These are ownership invariants, not measured error frequency, throughput or
milliseconds. One last successful value is retained per source; failed refresh
retention has a heap cost and does not establish end-to-end performance.

A compound scenario in `test_tui_server_identity_refresh` uses the actual Task
and Goal begin/complete/withdraw state functions and production decoders. It
retains original decoded events through overlapping same-ID reads, latest
failure versus old success, pending retry and repair, including a typed Goal
source-unavailable response carried by HTTP success. It then withdraws both
sources and requests the same IDs under a replacement workspace, rejecting the
retired responses before accepting the replacement owners. This scenario is
authored and **unexecuted**. It covers state/protocol decisions; it does not run
the full main loop, workspace probe, HTTP transport or a terminal.

OCaml parsing, source call-site/dependency inspection, diff and changelog checks
are separate from typing, scenario execution, CI, installation and visible UI
proof. No layout, wording, row-order, snapshot, PTY, helper-mirror or
invocation-count test is added. Matched Before/After must retain the same Task,
Goal, workspace, history payloads, failures and refresh order; keep cancelled,
interrupted and unfinished reads. Record actual issued/settled/applied and
visible paint clocks separately from useful task effects. No runtime speedup
or verified screen is claimed by this source layer.

The subsequent [retry observation layer](2026-10-19-tui-retry-failure-observation.md)
extends the no-value explicit-retry policy above: it retains the known failure
while exposing the new pending owner. This document's source comparison remains
bound to its recorded baseline and layer.
