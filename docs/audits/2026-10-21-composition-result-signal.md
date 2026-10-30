# Original Composition result signals reach the prepared supervisor

Source As-Is/To-Be; no latency, native UI or executed resource evidence.
The prior typed demand path only had a production owned-job emitter. A Named
Composition's own terminal result did not directly signal its dependent parent.

| Boundary | Before | After |
| --- | --- | --- |
| Direct Named durable completion | Queue/wake/ACK, parent waits for maintenance | Same delivery; original typed hint before ACK |
| Completion outbox recovery | Same original delivery, no prepared signal | Same completion observation passed to delivery and hint |
| Successor physical request | Original public result binding needs re-read | First admitted binding from original journal state; never successor ID |
| Completion-disposition observation | Returns classification only | Same reads/guards, also retains that attempt's immutable source snapshot |
| Result observer lifetime | No typed Composition subscriber | Callback registrations owned by server switch and physical workspace |
| Parent resource validation | Complete maintenance and fresh intake | Same authority, with direct typed demand also available |

`observe_completion` performs the original source/membership/current-or-prior
owner and stable-owner read. `completion_disposition`/`completion_pending` keep
their previous classification API and reads. An abstract immutable observation
retains only that delivery attempt's journal/state. `completion_result_notification`
projects the existing `original_named_binding`, including its canonical original
request and Named membership validation. Prepared/no-journal, unadmitted and
recoverable physical attempts have no Named hint. Still-waiting attempts do not
enter the production delivery callback. Current result readiness/admission is
always read later by the prepared controller; this snapshot is no permission.

Both direct settlement and outbox recovery derive the hint after durable queue
delivery succeeds, before the original ACK. Outbox passes the already acquired
completion observation to the production callback, avoiding a repeated whole
disposition read. Volatile/projection-conflicted settlement and existing
recovery/waiting guards remain. A binding-projection failure is logged and does
not undo delivery or block its ACK; complete maintenance remains the recovery
source. No claim that a failed hint itself is durable or that a hint is progress.

`observe_results` resolves the supplied physical workspace once in the common
host executor and registers a typed callback until its supplied switch releases.
Its immutable Atomic list is only live registrations, never candidates/results.
Removal uses the exact physical registration and preserves other lifetimes.
The server installs its prepared callback before initial recovery pulses.
Callbacks run outside CAS and check their own lifetime. If another observer
throws cancellation, check the current publisher's cancellation before isolating
that observer error; the publisher's own cancellation still propagates. A
captured callback can outlive removal briefly but cannot admit work on a closed
switch. Already admitted work and physical I/O are not rolled back or forcibly
stopped. Production registration/publication use the single Eio owner domain.

The existing actual two-job/original child-parent scenario now uses the real
observer and no manual parent result hint or maintenance pulse. Three authored
variants cover direct completion, actual corrupted durable queue plus recovery,
and a distinct observer cancelling its own lifetime during publication. They
check usable original stdout/child result, original Task, unrelated job owner
bytes and independent queue work. Registration uses a real filesystem alias.
The queue-repair variant permits a racing direct callback and recovery; it does
not prove an exclusively outbox-emitted hint. Existing outbox fault/ACK-gap
resource cases retain their original effects with the new observation argument.
All scenarios remain unexecuted. No helper-count, log wording, UI layout/snapshot,
PTY, sleep, arbitrary stress or timing-cap tests added. The Docker protocol peer
is synthetic; these are not real Docker isolation or physical-exit proofs.

New costs: one host realpath per registration; immutable registration list/CAS
allocation and linear publish/removal scans; per-observation source-state
retention, wrapper/record allocation; first Named binding/request validation
when any observer is installed; callback scheduling and error logging. With no
observer, hint projection performs no extra binding read. Field matching does
not scan or cache historical results. The actual benefit is an event path in
place of awaiting another maintenance pulse, not measured seconds or speedup.
Complete scans, selected readiness, lazy declarations, worker and host waits,
failed/cancelled/interrupted/unfinished samples remain preparation costs.

A source review follow-up suggested failed pending entries were not included
in inspected. They already incremented inspected at the exact prior head;
the interface now states the full returned-report equation including failures.
This is a documentation clarification, not a counter behavior change. A separate
review's startup wrapper has no local Registry_closed catch; no blanket catch
was added to hide a real invalidated restoration. Details are in local source
fact-check evidence. COMMENT reviews are not current-head approvals; non-main
stack children still require independent review under the repository contract.

Nine changed OCaml files passed parsing: three interfaces first, then journal,
outbox, completion wake, bootstrap and two resource scenario files. No types,
warnings, link/build, tests, CI/native/controller/model/PTY/TUI paint/input or
runtime timing executed. Current-head independent source review and whole-stack
integration are separate. All six original goal axes and matched actual
Before/After cohorts remain incomplete.
