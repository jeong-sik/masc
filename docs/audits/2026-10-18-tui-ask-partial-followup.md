# Original-answer follow-up: partial TUI observations

## Source boundary

Baseline: `8179489c617b81c5d879919863a2b119814559c2`, the source-stream transport
layer in #43660. This layer connects its existing receiver to Questions state
and rendering. It changes source; no installed binary or painted frame was run.

## As-Is / To-Be

| Boundary | Baseline | This source |
| --- | --- | --- |
| Follow-up HTTP | Aggregate receiver waits for all three sources | One streaming request admits each validated source independently |
| Canonical Ask reads | One per request | One per request, unchanged |
| Pending peer | No partial view before aggregate delivery | Explicit pending state and absent observation; no fabricated unavailable/empty payload |
| Repeated read | Earlier complete observation | Earlier source facts retained, marked earlier evidence while that source is pending |
| Partial read then transport failure | Aggregate error makes every retained source stale | Received sources stay admitted; unfinished peers become unconfirmed |
| Answer/workspace withdrawal | Aggregate ticket rejects late completion | Worker receives cancellation, ticket rejects late events, old cleanup cannot retire a successor owner |
| Observation clocks | One aggregate admission | Request start, decoded-source receipt and state admission share a request number; cancellation/unfinished starts remain observable |

For a shared canonical read followed by source durations `T1`, `T2`, `T3`, the
baseline makes every source wait for `max(T1,T2,T3)` before delivery. This source
allows source `i` to be admitted after its own `Ti`, plus transport, decoding and
mailbox overhead. The first available source can therefore become useful without
waiting for a slower peer. This is a source-derived dependency change, not a
measured duration or percentage. Total work, model round trips, full-read latency
and full refresh duration are not claimed to improve.

## Identity, history and ownership

`Masc_tui_ask_projection` owns a pure per-read reducer and a separate optional
observation for reaction evidence, Tool results and the original linked Task.
A source has pending, received or unconfirmed read state. The shared decoder
still enforces start, one of each source, matching completion and unchanged
answer time/stimulus. Refreshes also bind the earlier answer identity and the
original linked Task id, including missing/unavailable/unlinked outcomes.

Positive clocks and exact physical Tool execution identity survive unavailable
reads or a regressed count. Missing Task lookup cannot erase an earlier status.
Those retained facts explicitly lack current confirmation. A fresh canonical Task
status may move to an earlier phase; no invented monotonic phase gate is added.
A stream completion proves a read, never answer consumption or Task/Goal success.

Questions launches the shared authenticated receiver in a workspace-owned Eio
observation job. New submission and read-authority withdrawal signal its owned
cancellation and invalidate its ticket. Each partial event checks the current
ticket, submission and workspace. Terminal completion alone retires the ticket;
partial delivery cannot open a duplicate poll. Old worker cleanup compares its
original ticket before removing cancellation ownership. Common HTTP/executor
cleanup remains responsible for actually ending the worker; signalling cancellation
is not proof of cleanup completion.

The existing frame loop processes these events without joining peer reads. The
renderer consumes each optional source independently, preserving earlier facts
beside pending state. No reconnect loop, extra per-source HTTP query, result
registry, timeout, numeric work cap or runtime configuration write is added. The
unused aggregate TUI HTTP wrapper is removed; the aggregate server contract and
its decoder remain available to existing callers and protocol scenarios.

## Observation and evidence limits

`tui_ask_followup` records request number, original Keeper/Ask and asking-turn
reference, source, decoded-source receipt and state-admission monotonic clocks,
canonical answer identity, source read state and execution facts. Question/answer
bodies, submitted free text, Task descriptions and error details are excluded.
A cancelled worker logs no later owner's projection. State admission is not paint,
key response, first wire byte, Tool execution or useful Task progress.

One existing state scenario is rewritten for the stream and one ownership scenario
is added. They cover early original Task admission with pending peers, no fabricated
empty evidence, partial transport failure, retained clocks/Tool counts/Task phase,
changed answer/Task refusal, original POST ownership, poll sharing, late-event and
cleanup rejection, and read-authority cancellation. Both scenarios are authored
and unexecuted. No UI wording, row-order, layout, snapshot or PTY test is added.

Parser-only checks and `git diff --check` do not establish typing, executable
protocol behavior, actual network cancellation, worker cleanup, runtime continuity,
painted UI or speed. No local Dune/test run, CI dispatch/watch, native/model run,
install/restart, independent approval or merge is included in this unit.

The broader goal remains open: first usable input, remaining synchronous form
reads, exact preparation reuse, Ask-to-original-work continuity, resource-owned
Composition and matched Before/After still require their own implementation and
evidence. Failed, interrupted, cancelled and unfinished samples must remain in
any later comparison cohort.
