# Ask answer submission and reread observations

Source comparison base: `333536e514ae14445536be762917f5d754a5c22d` (#43770).
These are source boundaries, not observed runtime samples or speed measurements.

## As-Is / To-Be

The early POST receipt and final canonical-list reread both called
`observe_ask_answer_receipt`. That function logged only when the receipt was
newly retained. Once early delivery retained it, the terminal call returned no
new receipt and emitted no `reread_complete` log. A fallback log with that label
also described the answer receipt, not whether the canonical reread succeeded.

Receipt retention remains once per original request. Reread admission now has a
separate typed observation using the actual list Result. Its gate checks the
current opaque submission, workspace authority/identity and inflight state. It
does not require a new receipt, settle the action or change feedback.

| Boundary | Before | After |
| --- | --- | --- |
| Early receipt + completed reread, receipt records | 1 | 1 |
| Reread admission record after early receipt | 0 | 1 |
| Failed reread | No independent terminal outcome | Returned_error, original receipt retained |
| Submission intent | No dedicated lifecycle start | Original start timestamp and submitted event |
| Workspace check / answer POST / asks reread | No separate call intervals | Start and return/error/exception/cancellation events |
| Stale/foreign/unverified reread admission | No separate event | Still no admission |
| Missing finish | No stage evidence | Open stage retained; no fabricated completion |
| Answer POST / canonical reread calls | Existing sequence | Same sequence |

The immutable submission carries one process-local monotonic start timestamp
alongside its existing opaque request, workspace owner, Keeper, question and
source Turn_ref. This is observation metadata, not a new request identity or
admission authority. Typed call/event/outcome values control the log projection;
there are no keyword decisions, timeouts, retries or new configuration knobs.

`tui_ask_answer_lifecycle` records submission, actual function observation
boundaries and admitted reread Result. A call's elapsed interval includes start
logging, authentication, executor waiting and response interpretation as
applicable. It is not HTTP entry/RTT, pure CPU, actual paint, first usable input
or useful Keeper work. Returned POST means a Result returned; it does not prove
answer acceptance or a durable wake. Existing canonical feedback provides that
distinction. Cancellation records cancellation and rethrows with the original
backtrace; non-Eio fallback does not enter Eio cancellation protection. Observed
functions do not run under cancellation protection.

Worker observations use the captured original submission without mutable UI
state. Late workers may report their own events but gain no current UI authority.
The UI log follows existing workspace-operation admission; a settled submission
cannot emit another reread-admission record. No raw answer text, labels, snapshot
or exception details are added to the lifecycle projection. Existing receipt
feedback logging remains separate and changes its phase to `receipt_admitted`.

No new HTTP/model calls, Tool effects, request generations, cache, screen rows,
automatic retry, synthetic completion, mutation gate or draft transition. The
early receipt still precedes canonical reread and still launches original Ask
follow-up; actual Task progress remains independently observed.

## Evidence and remaining limits

The existing original-submission ownership scenario extends early receipt plus
failed reread, receipt independence, successful empty reread with unknown answer
write, settled/duplicate/stale/foreign/unverified completion and original source
timing attribution. Existing source-inspector and follow-up fixtures carry the
timestamp without changing their ownership. No standalone helper or screen
wording/layout/row-order/PTY test is added. Scenarios are authored, unexecuted.

Author checks are parsing-only and diff/changelog hygiene. Typing, assertion
execution, call timing/cancellation runtime behavior, CI, native/model runs,
installation/restart, visible UI, speed and independent review are unverified.
