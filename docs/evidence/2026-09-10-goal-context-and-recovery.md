# Goal context and live recovery observation

Source base: e361d0f1c00a611c2c01f7aada77dd7e836dcb65.

`active_goal_summaries_for_task` previously read linked stored goals but
projected only ID, title and phase into the model-facing turn context.
This change carries the existing typed `Goal_store.criterion` (revision,
title, metric, target value) and latest review note through that same read.
Missing metric/target values remain null. Task linkage and progressable-phase
filtering are unchanged; no additional model calls or runtime gates are added.

The feature scenario in `test_keeper_goal_phase_projection.ml` stores a linked
audio-essay goal, assembles the actual turn prompt, and checks that metric,
review and criterion revision arrive. A subsequent store update checks that
unspecified criteria and revised review text replace the earlier values.
The existing unreadable-store scenario continues to test independent work.
These OCaml scenarios require CI execution; they were not run locally.

## Live observation (independent of this un-deployed change)

Earlier `masc_keeper_status(analyst, fast=true)` reported failing/offline
while its live fiber and newer successful tool calls belonged to turn 2852.
A follow-up status read returned:

```json
{
  "runtime": {
    "paused": false,
    "keepalive_running": true,
    "phase": "running",
    "fiber_health": "alive",
    "runtime_blocker_state": "clear"
  },
  "latest_receipt": {
    "turn_count": 2852,
    "outcome": "receipt_done",
    "ended_at": "2026-09-09T16:10:21Z"
  },
  "latest_causal_event": {
    "ts": "2026-09-09T16:10:33Z",
    "kind": "transition",
    "summary": "failing -> running via turn_succeeded; outcome=applied"
  }
}
```

This is a selected-field transcription of the tool response. No restart or
Keeper message was issued in this investigation. It proves one recovery
completed; it does not prove fleet health, accurate in-progress presentation,
goal focus, or long-duration continuity. Browser screenshots and deployed
model-request evidence remain outstanding for the full product acceptance.
