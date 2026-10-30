# Local source caller outcome visibility

| Observed original caller outcome | As-Is | To-Be |
| --- | --- | --- |
| Returned | Awaiting UI application | Same pending category |
| Raised exception | Awaiting UI application | Read failed |
| Interrupted | Awaiting UI application | Read interrupted |
| Not started | Awaiting UI application | Read not started |

The original first-fact record already retains these outcomes. The pending
projection now preserves them through a typed failure payload and unstarted
constructor. Both the composer metadata note and Keeper/Work source notes use
that projection, with exhaustive outcome matches. No exception text is added.
This addresses the failure-label P3 in #44143 review 5585958569; it does not
establish the cause of the reported persistent Loading incident.

The existing source in-flight check still controls whether pending is shown.
Request/source/workspace/revision admission, retained prior metadata/failure,
normal payload return, error application, follow-up reads, input authorization
and physical worker/cancellation cleanup are unchanged. A returned caller does
not prove payload success, and failed/interrupted/unstarted caller facts imply
neither queued error-message delivery nor physical resource release. Earlier
I/O/comparison preparation phases retain their existing projection semantics.

Four observed caller outcomes were collapsed to one category; the source now
distinguishes four. These are static category counts, with no executed cohort,
failure-rate, latency, throughput or paint result. A failed pending projection
adds a small payload allocation per call; the existing atomic facts are still
read once. There is no new state slot, worker, retry, timer, cache or log event.

Four changed OCaml files receive parsing-only checks, interface first. The
request/authority/launch code and observation recording/execution prefix are
compared with the parent source. No wording, layout, row, snapshot, PTY or
helper-count test is added. No type/warning/link/build/test execution, CI,
native/model/controller run, install/restart/live write, independent approval
or merge is established. Actual failure/cancellation rendering remains unobserved.

All six goal axes remain open: original Ask/Task useful work; exact preparation
and frozen discovery; ordinary/nested/dynamic/effectful Composition continuity;
held-job/shared-backend continuation; cold usable input and TUI readability/
visibility; matched actual Before/After retaining failed, cancelled, interrupted,
not-started and unfinished samples. This source presentation correction does
not supply those runtime measurements.
