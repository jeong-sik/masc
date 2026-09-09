# Live Keeper non-code memory guide scenario

The operator asked analyst for a Korean guide distinguishing corroboration from
verification, covering conflicting observations, later corrections and unreadable
sources. Deliverables are a readable PDF and a diagram, linked to work and review
records. The request leaves tool choice, collaboration and important decisions
to the Keeper; it does not prescribe Fusion or dictate a sequence of tool calls.
It permits internal MASC communication, not external Slack/email publication.

`operation.json` is the independently read exact operation record from the running
server after message submission. It records Running, not just queue acceptance.
Operation: `kmsg-33f4c994e9afd0fe78c40c8dcbce1be2`.

Acceptance still requires retrieving the actual files, opening/rendering them,
checking the requested cases and attribution, and joining any delegation,
decisions or actionable operator requests to their results. A response claiming
completion will not close this scenario on its own. This operator-seeded task is
not evidence of unprompted initiative or a 10-turn/24-hour continuity run.

No output artifact or successful collaboration is claimed by this initial capture.

## Terminal observation

The same operation later entered `Failed` with `failure_kind: Turn_exception`
and `turn_failed: Rate limited: Rate limit reached for requests`.
`failed-operation.json` records this terminal state. No response artifact or
completion is claimed. The Keeper status subsequently reported its fiber alive
with no queued/running chat operation. Its turn-2872 receipt says
`api_error_rate_limited`, one attempt, `fallback_applied: false` and
`degraded_retry_applied: false`, despite an operator disposition of
`fail_open_next_runtime`. Source tracing is needed to determine whether the
failed direct request is retained for subsequent work; no restart or duplicate
request has been issued merely because this one failed.

## Source diagnosis

At inspected source `47796f6884251e792294f368314ec8746ef12f2d`, the direct
`Keeper_agent_run.run_turn` call in `lib/keeper/keeper_turn.ml` does not supply
`on_runtime_retry_deferred`. `keeper_turn_driver.ml` defaults the callback to
a no-op, although the checkpoint-deferral branch emits the remaining runtime
candidates through it. The direct error branch restarts keepalive and returns
a failed result. `lib/keeper_chat_operations/keeper_chat_operation_reducer.ml`
clears the queued input on `Fail_running` and provides no Failed-to-Queued
transition. Transcript retention therefore does not establish pending-request
replay. Same-turn fallback remains possible when admitted by the driver; this
finding concerns the deferred branch.

An independent reviewer traced these paths. Direct comparison against the
observed deployed commit `3dd470d9f9bd9e818ecfe7387aba334604872ca4` found no
difference in those three source files. This binds the source diagnosis to the
reported binary source identity but does not identify every internal event of
this failed operation. The measured receipt remains the evidence that only one
attempt ran and no fallback was applied. A separate repair is in progress.
