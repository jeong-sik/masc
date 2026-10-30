# Typed original Ask follow-up outcomes and boundaries

Parent: `7639b2778b3ce41e5580b09d7102815d53b895f8` (#44628).
The full six-axis Keeper/TUI goal remains incomplete. No actual Before/After,
runtime speed, useful-work, visible screen or production completion is claimed.

## As-Is / To-Be

| Boundary | Parent source | This source |
| --- | --- | --- |
| Logical terminal result | All errors are strings; UI terminal trace says unconfirmed | Closed failed/cancelled/not-started/withdrawn causes, or strict-stream success |
| Unfinished | Current read phase not projected as a completion value | `followup_completion = None`; source JSON completion null, not a success/empty reading |
| Later retirement | `finish_followup(Error ...)` can replace an already finished result | First terminal result is immutable; later retirement preserves it |
| New read | Retains prior source facts | Same facts retained, new unfinished lifecycle; no inherited completion |
| Missing switch | Generic boundary error | Explicit not-started cause from known no-entry boundary |
| Ordinary dispatch exception | Generic error | Failed, with entry unproven; no inference that the worker did/did not enter |
| Raw cancellation | Explicit string explanation | Typed cancellation while original exception/backtrace still propagate |
| Structured trace | started, cancelled, source admission, finished; every timestamp labelled admitted | Closed event type separates request start, worker entry, producer return/cancel, job cancel/release and UI source/terminal processing |
| UI source processing | A single outcome string | UI admission and source application are separate fields; refused source payload is not applied data |
| UI explanation | Reads a string error | Typed failure formatter preserves explanations; details remain out of trace JSON |

`followup_result` is shared by the projection, UI state and original scoped
terminal message. Classification uses constructors at the observed boundaries;
no reason substring/regex matching or sentinel messages. A missing Eio switch
proves no producer entry. Dispatch exceptions are failed observations with entry
unproven; pre-dispatch cancellation retains cancellation cause without pretending
that a physical worker ran. Original producer wire frames/HTTP decoder are
unchanged, and strict EOF validation can still refuse a nominal successful return.

A received source and terminal completion are separate observations. Cancellation,
failure or withdrawal keeps received facts and marks only pending peers unconfirmed.
No source observation/transport outcome establishes Task or Goal completion.
The first result remains after UI retirement, preserving a successful, failed,
cancelled or unstarted attempt's denominator. Beginning a new read creates a new
unfinished phase while retaining earlier source facts as earlier evidence.

## Trace and matched-comparison boundary

The trace carries original Keeper/Ask, source request number, submission start
clock and original question Turn_ref. Events are emitted at their own boundaries:

- `started`: UI requested the original read, not worker or HTTP entry.
- `worker_entered`: actual producer callback entered, not network/model/useful work.
- `producer_returned` / `cancelled`: producer result or raw cancellation; not proof
  of completed workspace-job registration cleanup or UI admission.
- `cancel_requested` / `registration_released`: existing original job events;
  registration release is not proof of domain work success.
- `source_processed`: original current message was processed; `source_applied`
  separately records whether that payload decoded/applied successfully.
- `finished`: existing owner/scope/ticket checks settled the original UI read.

`observed_ns` is the actual logging boundary clock. `admitted_ns` is present only
for UI processing. `completion.state` serializes the closed logical cause; no
error explanation, question/answer body or Task description is added to logs.
The former generic outcome field is removed rather than interpreted as a cause.
Producer cleanup logs capture their original request, never current replacement
source state. Existing job callbacks still own cancellation and unregistering.

A producer result and UI settlement are stages of one attempt, not two attempts.
Source request numbers/submission clocks are scoped to a TUI process/lifetime;
matched runs must retain run/workspace provenance rather than treating them as
globally unique. Missing producer/cleanup/UI endpoints remain unfinished at that
boundary. They cannot be dropped from the cohort or changed into a zero duration.
No matched run, renderer paint, actual input latency or timing comparison occurred.

Added costs include typed cause/terminal storage, not-started formatter closures,
new lifecycle log calls/clocks, immutable JSON serialization and existing source
snapshot logging. Normal retained operation/session APIs pass their existing
boundary mapper at both launch-error sites and retain their result/cancellation
semantics. The shared launcher change has costs even when the observation-specific
mapper is unused. No cap, retry, polling rule, permission, timeout or cache added.

## Updated actual protocol/resource cases (unexecuted)

Five existing private canonical Ask/answer, actual wake/Task and production
frame/strict-decoder scenarios now distinguish the new behavior:

1. Held actual source is unfinished; actual complete stream retains success even
   after retiring that reading. Shared queue, original facts/input/resources stay.
2. Actual partial stream disconnect remains failed after retirement. Active
   withdrawal gets its own typed outcome; old held envelopes cannot settle a new read.
3. Missing actual turn switch is not-started, with no invented source facts.
4. Actual exact-job cancellation with protected producer cleanup remains cancelled,
   retains original Task/input and cannot settle the replacement read.
5. Pre-dispatch switch cancellation still propagates and retains cancellation cause
   without claiming worker entry; fresh actual read succeeds with unchanged Task.

These scenarios were updated, not executed. Existing synthetic ownership cases
were adapted to the typed interface. No helper-count, wording/layout, snapshot
or PTY checks were added. Projection/retained-result/protocol interfaces were
edited before implementations. Direct protocol Dune dependency on the projection
is explicit under `implicit_transitive_deps false`.

Only parsing and source inspection apply. No typecheck/build/test, CI,
native/model/controller/audio/PTY run, install, restart, live writes,
self-approval or merge. Independent review and actual runtime proof remain open.
Previous 51 native-stack heads/bases and known ancestry gaps are preserved.
