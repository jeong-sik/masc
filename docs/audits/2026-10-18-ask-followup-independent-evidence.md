# Independent answer follow-up evidence

Source baseline: `5139594d7731968a99fac62541b16759d167bd3e`.
Scope: exact canonical Ask follow-up reads, wire decoding, retained observations
and operator display. Answer writing, delivery and execution authority are separate.

| Boundary | Before | After |
| --- | --- | --- |
| Reaction storage unavailable | Whole follow-up fails before Tool/Task reads | Reaction branch unavailable; Tool results and original Task still read |
| Source read dependency | Reaction read precedes parallel Tool/Task pair | Three independent reads join after their own outcomes |
| Blocking reaction/Tool storage work | Caller executes the source read | Common I/O executor policy, with existing inline cases |
| Reaction not read vs observed empty/quarantined | Whole-read error or flat optional clocks | Typed unavailable/observed branch with explicit completeness |
| Same-answer source failure | Last facts retained inconsistently | Retain only same-source observations with explicit stale flags |
| Whole refresh failure | Task marked stale; Tool and reaction facts lack matching freshness | All retained branches marked as earlier observations |
| Fresh original Task while wake history fails | Hidden by the failed aggregate read | Fresh Task shown independently of stale/unavailable wake evidence |
| Delivery/turn/Tool result/Task phase | Different facts | Still different facts; no answer causation or whole-work completion claim |

For the reaction-read failure path, Tool and Task read attempts change from zero
to two independent source attempts. This is a source-path count, not a measured
I/O count or speedup. With cooperative executor availability, the preparation
dependency changes from reaction then Tool/Task to three joined independent
reads. Pool queueing, actual concurrency and rendered timing remain unmeasured.
All branches still join before the HTTP response; this change does not stream
early branch results or establish first-result paint.

The canonical answer's Keeper, question, answer time and original stimulus are
validated before any source read. That shared identity remains mandatory.
Expected or unexpected per-source read failures remain unavailable outcomes;
Eio cancellation propagates. The reads enqueue no wake, write no answer, choose
no current Task and advance no execution. Source diagnostic logs carry question
identity and source kind without human answer content.

The endpoint now puts reaction clocks/completeness under `reaction_evidence`,
whose state is `observed` or `unavailable`, alongside `tool_actions` and
`linked_task`. The OCaml wire decoder and TUI state/rendering/logging change
together. Missing/duplicate/unknown reaction states or malformed observed clocks
remain protocol errors. No compatibility decoder for the removed flat reaction
fields is retained. No Dashboard consumer of this opt-in projection was found.

Four existing feature/protocol scenarios are strengthened and unexecuted:
real reaction-store failure with a committed physical Tool result and canonical
original Task; partial wire evidence with positive Tool/Task observations;
workspace/request-owned refresh retaining stale branches while a fresh original
Task advances; and HTTP follow-up decoding against the new source shape.
Existing source identity, quarantine, queue-only, failed-Tool-result and physical
recheck cases remain. No wording, layout, row-order or PTY tests are added.

Parser/source checks do not establish typing or behavior. No executable
scenario, CI, installation, restart, model/native run, real TUI frame, paint or
latency measurement was performed. Match original Ask/answer/Task identities
and datasets in Before/After observations, and retain failed, cancelled,
interrupted and unfinished samples. A current Task phase, including Done, does
not establish that this answer caused it or that the overall Goal is complete.

Remaining original scope includes Ask-to-original-Task useful execution,
preparation/request/model attribution, demonstrated repeated discovery work,
complete Composition/held-job scenarios, synchronous TUI editor operations and
matched runtime/visible-UI evidence.
