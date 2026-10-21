# Original Ask follow-up structured observation transport

## As-Is / To-Be

| Boundary | Before this source change | After this source change |
|---|---|---|
| Event data | Full JSON inside the Info message; ring details null | `details.event = "tui_ask_followup"` and original payload in structured details |
| Disabled Info | Projection encoding, JSON construction and serialization before filtering | Same original clock captured; payload and message formatting only after module-level admission |
| Console | Entire encoded payload in message | Readable Ask/request/phase/source summary; authoritative details remain in ring and configured file sink |
| Consumer path | Ring/file/dashboard/TUI already support details | Production writer now uses that existing path, without a new sink or decoder |
| Original provenance | Private read capsule, worker/job/UI clocks and typed outcomes | Same original capsule and fields; added event discriminator and typed keeper/lifecycle metadata |

`Log.Make.emit_lazy` checks the existing module override/global threshold once.
A shared private write function serves eager and lazy emission; there is no
second filter after the builder and no copied console/ring/file backend. The
existing Routine policy and all existing eager APIs are preserved. No new
configuration, threshold, timer, gate, retry or endpoint is introduced.

`Masc_tui_ask_followup_observation` owns the closed original follow-up event type
and its structured emission. Main and the actual protocol/resource scenario use
this same production owner. It does not retain mutable UI state, allocate an
execution owner, authorize requests or change publication/settlement decisions.
Original admission/submission/receipt/observed/UI clocks and null unobserved
values are preserved. Completion carries only the typed cause; question/answer
bodies, error explanations and credentials are not added.

## Before/After and costs

This is source topology evidence. Disabled Info no longer performs projection
encoding, payload construction or message formatting. It still captures the
observation clock, creates/passes its closure and obtains original keeper
metadata. When enabled, structured data still undergoes sink redaction, UTF-8
sanitization and configured JSONL serialization/flush. Enabled sink I/O is
synchronous under the existing policy and can still delay the caller. The
console summary and structured event/category fields add their own work/bytes.

No measured milliseconds, percent speedup, Loading improvement, useful-work
rate or matched actual Before/After is claimed. Original failed, cancelled,
withdrawn, unstarted and unfinished attempts remain separate, as do producer
return, physical registration release and UI settlement. Cross-process monotonic
clocks require the original instance context; local numbers are not join keys
across processes. All six objective axes remain open.

## Actual protocol/resource case authored, unexecuted

One added case uses private real workspaces, canonical Ask/answer, real wake/Task
sources, the server frame producer, strict decoder, retained result publication,
production observation emitter, actual Log.Ring daily JSONL, the dashboard JSON
builder and TUI decoder. It keeps completed, actually disconnected and missing
switch/unstarted reads in the exported cohort. Original capsule provenance,
producer/release/UI boundaries and typed causes must survive; persisted and
exported structured data must agree and actual Task resources must be unchanged.
The existing actual cancellation and scope scenarios now also use the production
emitter. The log sink case runs last because the process owns its sink channel
until exit; it uses a private directory and leaves live runtime data untouched.

The scenario was not executed. No wording/layout/snapshot/PTY or helper-count
tests were added. Interfaces were changed first. Every direct consumer declares
its observation/logger library dependencies explicitly.

Only OCaml parsing and source/diff inspection are allowed and recorded for this
unit. No typecheck/build/test, CI dispatch/watch, native/model/controller/audio/
PTY run, install/restart, live write, self approval or merge. Lower canonical
native-stack heads/bases and existing ancestry/review issues remain separate.

## Remaining observation boundary

There is no machine reader that joins these original structured follow-up events
into matched actual Before/After cohorts. Such a reader must use the explicit
event discriminator and original instance/read identity, retain all terminal and
missing outcomes, and keep admission/worker/physical release/UI timing distinct.
It must not infer useful Task progress from read completion, frame counts or
reported build metadata. Runtime evidence requires a separately authorized run.
