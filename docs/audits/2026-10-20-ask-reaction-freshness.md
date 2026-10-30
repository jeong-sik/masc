# Original Ask follow-up: retained clocks are not freshly confirmed

Comparison base: `dda18672a7bc434635db9b27ec7b96a03e28deb4`.
This finding is from source inspection. No installed TUI or live incident was
reproduced, and no latency or useful-work result is claimed.

Related PR: [#44243](https://github.com/jeong-sik/masc/pull/44243).

## As-Is / To-Be

The Questions follow-up already streams wake/turn, physical Tool results and the
original linked Task independently. Beginning a new read marks previous evidence
as earlier observations. Its reaction reducer keeps earlier positive clocks when
a new reaction source omits them. However, that merge inherited the newly
received source's `ar_evidence_current=true`, even when its displayed turn/wake
facts came from an earlier read. The existing renderer and observation JSON
could therefore classify retained facts as currently confirmed. A complete empty
history had the same problem; transport completion did not establish the missing
positive evidence.

The merged reaction observation is now current only if the new source is current
and no clock had to be borrowed from the prior observation. This applies to the
existing turn entry, turn boundary, queue settlement and queue cancellation
fields. The original positive clocks remain visible. Newly supplied clocks also
remain in the merged observation. When the source contains every positive clock
that would otherwise need retention, it can be current again. There is no sticky
failure gate, guessed chronological threshold or requirement that all four
different events must have happened.

| Observation boundary | Before | After |
| --- | --- | --- |
| New source omits an earlier turn entry | Old entry retained but source could be current | Old entry retained; merged observation includes earlier evidence |
| New complete history is empty | Earlier positive clocks could be recertified | Empty read cannot confirm retained positives |
| New cancellation beside missing old turn entry | Both clocks shown as current | Both clocks retained; aggregate explicitly includes earlier evidence |
| Later source confirms all retained positive fields | Current | Current again |
| Fresh Tool result or original Task beside stale wake facts | Independent source state | Same independent source state |
| Complete stream or partial disconnect | Controls read settlement | Same read settlement; never recertifies prior clocks |

The UI's existing stale-observation branch now explains that the observation
includes earlier evidence and the latest read did not confirm all of it. The
existing `followup_to_json` projection carries the corrected boolean to existing
request/source observations. No new log record, wire field, read, HTTP request,
worker, cache, timer or write is introduced. The extra field-presence checks and
longer wrapped explanation add work; no frame, allocation or speed improvement
is inferred from this correctness fix.

## Ownership and authored scenario

Original canonical answer identity, exact linked Task identity, current
workspace/read ticket, source-order validation, cancellation ownership and
late-event rejection retain their existing checks. The change affects
observation classification, not enqueue/admission or execution authority.
Task phase remains its own observation and is not proof that this answer caused
useful work or completed the overall Goal.

The existing request/workspace-owned follow-up state scenario is extended,
without adding a new helper/count/wording/layout/snapshot/PTY test. After a real
state read retains old evidence, it receives a complete empty reaction source
beside current original Task/Tool observations. A subsequent partial read then
receives a new cancellation but omits the retained original turn entry and loses
transport before Tool arrival. The received reaction source stays received, its
merged facts remain unconfirmed, the Task stays independently current, and the
unfinished Tool source remains unconfirmed. A later complete source can confirm
all the retained clocks again. Existing changed-answer/Task refusal and
Task-phase reversal cases continue afterward.

This is authored, unexecuted state/protocol-consumer coverage with supplied
typed observations. It does not exercise real HTTP/SSE, server ledger mutation,
worker cleanup, input response, a painted TUI or actual Task effects. No new
assertion tests the renderer's wording or layout.

## Evidence limits and original goal

Changed OCaml files receive parsing-only checks and source/whitespace inspection.
No build/typecheck/test execution, CI dispatch/watch/poll, native/model/PTY/
controller/report run, install/restart/live write, independent approval or merge
is part of this unit. Actual Before/After must preserve the same original
Ask/answer/Task and dataset, including unavailable, cancelled, interrupted and
unfinished reads. A source-level classification fix is not a measured reduction
in Loading time.

All six axes remain open: original Ask/Task/useful work; exact preparation and
frozen discovery; ordinary/nested/dynamic/effectful Composition; held reactivation
and shared backends; cold input/TUI readability/visibility/observation; and
matched actual cohorts. This patch makes retained progress evidence more honest;
it does not establish the full objective complete.
