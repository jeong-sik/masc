# Preserve a known failure while its explicit retry is pending

Source comparison base: `6d7e353b4cff46d5e0ac17a42ff7db5b0985b53d`
(#43843). This layer changes Task/Goal history retry observations. It does not
measure or diagnose the reported live Loading screen, input, paint, preparation
or useful-work latency.

## As-Is / To-Be

The preceding layer retains a last successful history through failed refresh.
However, explicit refresh of a failure with no successful value still enters
`Loading`. The operator loses the known cause throughout the pending read,
even though a retry has not repaired that source.

The fetched model now has a private no-value retry state containing the new
request and original failure. Its existing public view is `Failed cause`;
`in_flight` independently reports the pending retrieval. No empty history or
successful value is manufactured. Both actual history views display the pending
retry separately from the terminal-safe, wrapped cause.

| Boundary | Before | Implemented behavior |
| --- | --- | --- |
| Explicit retry after first failure | Known cause replaced by Loading | Known cause retained; new request pending |
| Repeated explicit retry | Another new loading owner | New owner; same unrepaired cause retained |
| Late superseded success/failure | Original generation guard | Same guard; cannot settle current retry or erase its cause |
| Current retry fails | Failure without value | New failure replaces prior cause; no value |
| Current retry succeeds | Ready data | Same Ready data; pending/failure cleared |
| Retry suspension | No distinct retry state | Owner retired; original cause remains, no pending read |
| Wrong key / workspace withdrawal | Scope reset | Same reset and retained generation ordering; no borrowed cause |
| Refresh with last good data | Existing value/stale behavior | Unchanged |

Only the explicit `refresh` operation creates this new state. The two production
entry points are Task history and Goal timeline begin functions. Existing
`start` consumers retain their first-failure/loading behavior and same-key
sharing policy. If a sharing read encounters a pending explicit retry, it shares
that owner. Every fetched helper that observes or settles private status handles
the retry: current owner, pending, start/refresh, suspension, completion, current
key/view/request and per-key view. The public view variants and request branding
remain unchanged; this is not an effect/admission or work-progress status.

## Source invariants and evidence

For any number of explicit retries of the same no-value failure, the known cause
stays observable until the current request produces a result or its scope is
cleared/replaced. A suspended retry retains the cause without retaining pending
authority. The current failure can replace its predecessor; a success supplies
the first real value. Superseded or duplicate results cannot supply it.
These are logical state invariants, not measured error frequency, response time,
reduced HTTP calls or throughput. No timer, cap, retry cadence, new configuration
knob or background read is introduced.

Extend the preceding compound scenario in `test_tui_server_identity_refresh`
through real Task/Goal begin/complete state functions and production decoders.
It now starts with no-value failures, supersedes pending retries, rejects old
success and failure, records a newer failure and accepts current recovery. The
Goal initial failure is a typed source-unavailable response delivered through
HTTP success. Existing last-good failure retention, repair and same-ID workspace
withdrawal/replacement continue afterward. The scenario is **unexecuted**;
it does not run the main loop, HTTP, probe or terminal. Suspension behavior is
inspected in source, not isolated by an executed cancellation scenario.

Only OCaml parsing, source-method/call-site inspection, diff and changelog checks
are performed. Typing, executed scenarios, CI, installation and visible UI proof
remain separate. No layout, wording, row-order, snapshot, PTY, helper-mirror or
invocation-count test is added. Matched Before/After should freeze the original
Task/Goal/workspace, failures, retry ordering and decoded events; retain failed,
cancelled, interrupted and unfinished attempts. Observe requested/settled/applied
and visible paint clocks separately from useful task effects. No measured speedup
or verified screen is claimed.
