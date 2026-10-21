# Original Keeper detail request state in the pane

| Source facts | As-Is | To-Be |
| --- | --- | --- |
| No matching value, error or pending request | Generic loading | Not observed; existing server authority decides read/confirmation guidance |
| Matching tab/Keeper request, no value | Generic loading | Same loading with original request interval |
| Matching retained value with pending read | Value only | Refresh pending plus last observation |
| Matching retained value with failed read | Error replaces value | Error plus last observation |
| Failed retry with retained value and request | Error only | Original failure, pending retry and last observation |
| Snapshot stamped for another Keeper | Generic loading when no error | Never use it; only actual current pending request can show loading |

This affects the existing shared projection for Instructions, Sandbox status,
GitHub and Identity. It reads the current tab/Keeper's original `detail_reads`
entry, the existing error and the actual matching stamped value. Container-log
pending is a different source and cannot authorize status progress. A request
entry establishes scheduling, not physical I/O start, executor quiescence,
response admission, paint, usable input or effect permission.

No new requests, retries, timers, thresholds, state slots or caches are added.
Existing launch-time clearing is retained, so the change does not manufacture
a prior snapshot when entry/refresh already cleared it. Only values actually
retained by existing paths can appear as the last observation. Request generations,
workspace withdrawal, current selection and response application stay with the
original caller. The projection never writes those fields or changes login,
configuration, sandbox or token actions. Errors use existing terminal single-line
sanitization. Actual successful empty lines remain an observed value, not unread.

Local Keeper metadata and Work already have distinct jobs, mutexes, source
admission and follow-up reads. Their pending-outcome repair in #44348 remains.
The inspection did not establish a missing local-source settlement or prove
that this four-tab display path caused the reported persistent TUI Loading.
Other loading projections remain separate work, including lanes, Channels,
Items and Automation; this is not a claim to repair every Loading label.

Only the changed renderer receives a parsing-only check. Original request
launch, completion/selection, workspace retirement and action sources are
compared with the parent. No new wording/layout/row/snapshot/PTY test is added.
No typecheck, build, behavior test, CI, TUI/controller/native/model run, install,
restart, live write, independent approval or merge is established. The source
cases above are an unexecuted comparison, not rendered evidence. Actual first
paint/input, retry/withdrawal interaction and matched before/after remain
unmeasured; no latency or throughput percentage is inferred.

All six axes remain open: original Ask/Task useful work, exact preparation and
frozen discovery, ordinary/nested/dynamic/effectful Composition continuity,
held-job/shared-backend continuation, cold usable input/TUI readability and
visibility, and matched actual cohorts retaining failed/cancelled/interrupted/
not-started/unfinished samples. Display honesty is progress within that scope,
not completion of the full goal.
