# Keeper Autonomous, Proactive, Reactive Audit - 2026-07-05

## Verdict

MASC Keeper autonomy is real, not stubbed: the original live runtime probe had 14/14 keeper fibers healthy, explicit board mentions woke keepers, scheduled autonomous turns ran, busy connector messages went through a durable chat queue, HITL resolution wakes were wired, and Fusion completion was delivered back into the Keeper event layer.

At original live-audit time it was not yet production-correct under the requested bar. Current branch `codex/keeper-autonomy-audit-20260705` has source-level fixes for the audit blockers below; live deployment and a fresh `/health?full=1` probe are still required before calling the running system production-correct.

Original blockers and current source status:

- P1 board relevance keyword/stigmergy final authority: closed in this worktree.
- P1 board cursor advancement before admission/backpressure gates: closed in this worktree by pre-collection gating.
- P1 full health missing durable event queue backlog: closed in this worktree with durable queue counts, age, payload counts, snapshot discovery for durable-only keepers, read/parse errors, and stale policy.
- P2 chat lane hard-coded waiting cap: closed in this worktree by runtime policy plus per-Keeper queue/rejection health.
- P2 scheduler only waking indirectly through board-post side effects: closed in this worktree with typed `masc.keeper_wake` / `Schedule_due` stimuli.

## Current Worktree Progress

Implemented on branch `codex/keeper-autonomy-audit-20260705` after the audit:

- Board non-explicit wake no longer uses keyword/stigmergy score as final authority. Explicit mentions and thread replies remain deterministic; goal-token overlap no longer wakes.
- Cursor-scanned board collection is gated before cursor advancement when the Keeper is cold, paused, blocked on HITL approval, under runtime backpressure, or blocked by provider cooldown.
- `/health?full=1` includes durable Keeper event-queue pending/inflight counts, payload-kind counts, immediate count, oldest/newest age data, durable-only keeper snapshot discovery, and durable snapshot read/parse errors.
- Durable event-queue backlog degradation is now an explicit health policy:
  `MASC_KEEPER_DURABLE_QUEUE_STALE_SEC` / runtime.toml `[health].durable_queue_stale_sec`.
  Default `0.0` preserves existing operator-visible behavior, while larger values keep fresh handoff backlog visible without marking full health degraded.
- `/health?full=1` top-level `operator_action_reasons` now preserves component-level
  `status_reasons`, so reaction-ledger causes such as pending stimuli or stale durable event queues do not collapse into a generic `keeper_reaction_ledger:degraded`.
- Board-event collection failures now surface as `keeper_board_event_collection` health with per-Keeper failure details, runtime-resolution visibility, and top-level `keeper_board_event_collection:board_event_collection_failure` operator reason; the next successful collection clears the failure.
- The arbitrary chat waiter cap was removed. `keeper_turn_admission` keeps one
  serial lane per Keeper, queues chat work without a policy rejection, and
  exposes only the per-Keeper in-flight lane and raw waiting count.
- Scheduler can dispatch typed `masc.keeper_wake` payloads into a Keeper's event queue as `Schedule_due`, independent of board-post side effects.
- Scheduled autonomous no-op backoff and idle decay caps are named runtime policy:
  `MASC_KEEPER_PROACTIVE_NOOP_BACKOFF_MAX_SHIFT`,
  `MASC_KEEPER_PROACTIVE_IDLE_DECAY_MAX_PERIODS`, with runtime.toml mappings under `[proactive]`.
- Removed the dead `Keeper_relevance_check` keyword coverage module and its dedicated test so it cannot be accidentally wired in as a production relevance authority.

Remaining follow-up:

- Re-run the live `/health?full=1` and durable queue probe after deployment, because the original live-runtime evidence predates these source changes.
- Let CI own the full Dune build; local validation here stayed focused on the touched admission/health/scheduler/event-queue paths.

## Scope

- Repo: `/Users/dancer/me/workspace/yousleepwhen/masc`
- Source revision: `cc9011d287 feat(dashboard): show declared runtime spec in model editor (#23270)`
- Live runtime root: `/Users/dancer/me/.masc`
- Runtime probe: `curl -fsS 'http://127.0.0.1:8935/health?full=1'`
- Checked at: `2026-07-05T05:00:35+0900 KST`
- Validation mode: source-level audit plus live runtime/log/queue inspection. No full local `dune build` was run because CI is the build authority for this work; focused touched-path tests were run via `scripts/dune-local.sh exec`.

## External Baseline

[근거] OCaml 5.4 official docs, checked `2026-07-05 KST`, confidence High:

- OCaml 5.4.0 release page: https://ocaml.org/releases/5.4.0
- `Mutex` lock/protect semantics: https://ocaml.org/manual/5.4/api/Mutex.html
- `Lazy` concurrency warning: https://ocaml.org/manual/5.4/api/Lazy.html
- `Domain` module and multicore API status: https://ocaml.org/manual/5.4/api/Domain.html

The audited Keeper code generally uses `Eio.Mutex` for fiber-yielding turn critical sections and `Stdlib.Mutex` for short non-yielding state/table sections, which is consistent with the concurrency shape expected here.

## Live Runtime Evidence

`/health?full=1` reported:

- `status = ok`
- `version = 0.19.55`
- `effective_base_path = /Users/dancer/me`
- `effective_masc_root = /Users/dancer/me/.masc`
- `running_keeper_fiber_count = 14`
- `healthy_running_keeper_fiber_count = 14`
- `failing_keeper_fiber_count = 0`
- `paused_keeper_count = 0`
- `blocked_keeper_count = 0`
- `effective_reaction_capacity_count = 14`

Recent logs show real activity:

- Explicit board wake: `board signal wakeup: keeper=sangsu reason=explicit_mention`
- Queued board stimulus consumed: `turn entry: consumed stimulus ... class=board_signal`
- Reactive turn scheduled: `keepalive turn scheduled ... reasons=board_event_pending`
- Scheduled autonomous turn: `keepalive turn scheduled for analyst: channel=scheduled_autonomous`
- HITL blocks are visible: `keeper:rondo blocked on 1 pending HITL approval(s)`

But disk queues show backlog despite the full-health reaction ledger reporting `pending_stimulus_count = 0`:

| Keeper | Pending event queue items | Main classes |
| --- | ---: | --- |
| `taskmaster` | 349 | 348 `board_signal`, 1 `bootstrap` |
| `albini` | 51 | 49 `board_signal`, 1 `bootstrap`, plus live drift during probe |
| `sangsu` | 19-20 | `board_signal` |
| `executor` | 16 | 14 `board_signal`, 2 `hitl_resolved` |
| `idealist` | 9 | `board_signal` |
| `mad-improver` | 7 | 6 `board_signal`, 1 `hitl_resolved` |

This means fleet liveness is currently good, but health does not fully represent durable stimulus backlog.

## Area Assessment

### 1. Lane Per Keeper

Status: mostly correct.

Evidence:

- `lib/keeper/keeper_turn_admission.ml:47-61` keys admission slots by `base_path` and `keeper_name`, so one Keeper does not globally block another.
- `lib/keeper/keeper_turn_admission.ml:87-99` lets autonomous turns run only if the per-Keeper slot is free and no chat waiter is parked.
- `lib/keeper/keeper_turn_admission.ml:101-125` serializes chat turns through the same per-Keeper slot.
- `lib/keeper/keeper_turn_admission.ml:27-38` uses `Eio.Mutex` for the whole admitted turn and `Stdlib.Mutex` for short state updates.
- Tests prove per-Keeper isolation and chat-yield behavior in `test/test_keeper_turn_admission.ml`.

Current worktree update:

- `Keeper_turn_admission` records the per-Keeper waiting count and in-flight
  lane without inventing a capacity threshold.
- `/health?full=1` exposes the same raw admission state; waiting work is not
  converted into a rejection, fleet degradation, or operator requirement.

### 2. Autonomous And Proactive Scheduling

Status: real and mostly justified.

Evidence:

- `lib/keeper/keeper_world_observation.ml:1102-1105` blocks turns when paused or pending HITL approval exists.
- `lib/keeper/keeper_world_observation.ml:1167-1174` bootstraps a never-started Keeper.
- `lib/keeper/keeper_world_observation.ml:1175-1186` avoids blind no-signal housekeeping turns.
- `lib/keeper/keeper_world_observation.ml:1205-1219` prevents a reactive wake from becoming a global task-backlog herd.
- `lib/keeper/keeper_world_observation.ml:1237-1243` requires bootstrap, due schedule, or real work signal for scheduled autonomous turns.
- `lib/keeper/keeper_heartbeat_loop.ml:212-249` runs event intake, observes world, then decides scheduling.

Current worktree update:

- Scheduled autonomous no-op backoff and idle decay caps are now named runtime policy under `MASC_KEEPER_PROACTIVE_NOOP_BACKOFF_MAX_SHIFT`, `MASC_KEEPER_PROACTIVE_IDLE_DECAY_MAX_PERIODS`, and runtime.toml `[proactive]`.

### 3. Board Reactive Path

Status: explicit mentions and thread replies work. The original non-explicit relevance path was not compliant; the current worktree removes keyword/stigmergy score as final wake authority.

Evidence of working path:

- `lib/server/server_bootstrap_loops.ml:496-499` wires `Board_dispatch` to `Keeper_keepalive.wakeup_relevant_keeper_for_board_signal`.
- Live logs show `board signal wakeup`, `consumed stimulus`, and `board_event_pending` turn scheduling.
- `lib/keeper/keeper_heartbeat_stimulus_intake.ml:233-276` drains board event stimuli, coalesces a board batch, and promotes them into pending board observations.

Original blocking issue:

- `lib/keeper/keeper_world_observation_board_signal.ml:150-172` implements `stigmergy_match` by splitting the Keeper goal on spaces, filtering tokens longer than 3 chars, substring-matching the board text, adding 5 points per match, and capping at 50.
- `lib/keeper/keeper_world_observation_board_signal.ml:196-216` wakes on `Stigmergy` whenever that score is greater than zero.

Explicit `@keeper` mention and "new external reply after self-comment" are structural and defensible. The stigmergy path is a heuristic classifier in the core reactive wake path. It should be replaced with a typed LLM judgment boundary or downgraded to a candidate signal that a Keeper/Judge must explicitly accept.

Current worktree update:

- Non-explicit keyword/stigmergy overlap no longer wakes Keepers as final authority.
- The dead `Keeper_relevance_check` keyword coverage module was removed so it cannot be reintroduced as an accidental production relevance gate.

### 4. Board Cursor And Drop Risk

Status: original unsafe edge closed at source level; live re-probe still pending.

Evidence:

- `lib/keeper/keeper_heartbeat_loop_board_events.ml:11-22` documents that collecting board events advances the per-Keeper cursor as a side effect and admits that runtime-backpressure and approval-pending gates are decided later.
- `lib/keeper/keeper_heartbeat_loop_board_events.ml:28-35` only gates collection on proactive warmup and paused state.
- `lib/keeper/keeper_world_observation.ml:747-763` records cursor ack and writes the new board cursor.
- `lib/keeper/keeper_world_observation.ml:1102-1105` can later skip the turn due to `Approval_pending`.
- `lib/keeper/keeper_heartbeat_loop.ml:228-249` performs event intake/observation before scheduling.

Why this matters:

If board events are collected by cursor scan, the cursor can advance before the later scheduling verdict blocks the turn. Event-queue stimuli are requeued on skip or crash (`lib/keeper/keeper_heartbeat_loop.ml:423-459`), but cursor-scanned board observations do not get an equivalent lease/requeue path. This violates the no-silent-drop expectation for reactive work.

Current worktree update:

- Cursor-scanned collection now pre-gates before cursor advancement when the Keeper is cold, paused, blocked on HITL approval, under runtime backpressure, or blocked by provider cooldown.
- This preserves the simpler cursor model without adding a lease subsystem in the same change.

### 5. Event Queue Persistence

Status: good durability model; health/backlog observability is improved in the current worktree.

Evidence:

- `lib/keeper_runtime/keeper_event_queue_persistence.ml:1-9` persists pending and inflight event queues to disk.
- `lib/keeper_runtime/keeper_event_queue_persistence.ml:14-23` avoids poisoning the global Eio write mutex on non-cancellation exceptions.
- `lib/keeper_runtime/keeper_event_queue_persistence.ml:164-172` reloads pending plus inflight stimuli.
- `lib/keeper/keeper_registry_event_queue.ml:39-73` persists a stimulus even if the Keeper is not registered yet.
- `lib/keeper/keeper_registry_event_queue.ml:154-190` records inflight stimuli before dequeue/drain.
- `lib/keeper_runtime/keeper_event_queue_persistence.ml:284-302` consumes ack from both pending and inflight snapshots as one synchronized transition.
- `lib/keeper/keeper_heartbeat_loop.ml:423-459` acks only after a completed turn and requeues on skip or exception.

Original risk:

Live disk state shows durable queue backlog while `/health?full=1` reaction-ledger summary shows `pending_stimulus_count = 0`. Even if the backlog is being drained, full health should surface queue length, age, class, and oldest item per Keeper. Otherwise operators see a false green.

Current worktree update:

- `/health?full=1` now includes durable event queue pending/inflight totals, per-Keeper queue rows, payload-kind counts, immediate count, oldest/newest age, durable-only keeper snapshot discovery, and read/parse errors.
- Durable queue health has explicit stale policy via `MASC_KEEPER_DURABLE_QUEUE_STALE_SEC` / runtime.toml `[health].durable_queue_stale_sec`.
- Durable queue snapshot read/parse errors now set `durable_event_queue_read_error`, make the fleet status `unknown`, and require operator action instead of silently reporting an empty backlog.
- Durable queue snapshot discovery now unions registry/meta-store keeper names with keeper directories that have `event-queue.json` or `event-queue-inflight.json`, so an unregistered keeper with queued work is still operator-visible.
- Durable queue snapshot discovery failures, including invalid snapshot-bearing keeper directories, now set `durable_event_queue_discovery_error`, make the fleet status `unknown`, and require operator action.

### 6. Connector Reactive Path

Status: typed connector leaves and generic HTTP Gate have separate explicit paths.

Evidence:

- `Gate_keeper_backend.accept_connector` consumes a leaf-built immutable delivery projection and durably queues it without identifying a product.
- `Gate_keeper_backend.dispatch` is the generic HTTP Gate path and uses async poll when the Keeper lane is busy.
- `lib/keeper/keeper_chat_queue.ml:1-10` documents durable queue replay.
- `lib/keeper/keeper_chat_queue.ml:275-341` persists enqueue/dequeue and coalesces same-source queued messages.
- `lib/keeper/keeper_chat_consumer.ml:62-126` drains queued messages only when the Keeper is no longer in flight.
- `test/test_keeper_busy_connector_deferred.ml` pins durable Discord and Slack queue behavior through the projection boundary.

Risk:

Slack is intentionally absent until an in-process Slack inbound gateway exists. That is fine because it is explicit, but the product feature list should not claim Slack/Discord parity until the Slack path has the same queue/outbound proof.

### 7. HITL

Status: correct design direction.

Evidence:

- `lib/keeper/keeper_approval_queue.ml:804-819` explains why resolution must wake the Keeper instead of assuming a blocked fiber resumes.
- `lib/keeper/keeper_approval_queue.ml:831-839` surfaces wake-hook failure with a warning.
- `lib/keeper/keeper_approval_queue.ml:1440-1485` expiry also wakes the Keeper with a rejected HITL resolution.
- `lib/server/server_bootstrap_loops.ml:500-521` installs the real wake hook and emits a typed `Hitl_resolved` immediate stimulus.

This matches the spec: HITL does not have to block the Keeper forever; resolution becomes async stimulus.

### 8. Fusion

Status: correct design direction.

Evidence:

- `lib/fusion/fusion_sink.ml:433-455` explicitly avoids silent chat append failure.
- `lib/fusion/fusion_sink.ml:468-487` marks the Fusion run completed, broadcasts status, and wakes the Keeper on completion.
- `lib/keeper/keeper_heartbeat_stimulus_intake.ml:111-122` converts `Fusion_completed` into a pending board-style event so returning `[]` cannot silently drop the result.

This matches the spec: Fusion can complete asynchronously and wake the Keeper without blocking the main turn.

### 9. Scheduler

Status: production substrate exists; typed Keeper wake semantics are now present in the current worktree.

Evidence:

- `lib/server/server_bootstrap_maintenance.ml:184-226` runs the schedule runner every 15 seconds and catches per-tick failures.
- `lib/schedule/schedule_runner.ml:315-332` refreshes due schedules, emits wake signals, and dispatches via the configured consumer.
- `lib/server/server_schedule_consumers.ml:72-89` accepts only `masc.board_post` payloads with side-effecting risk.
- `lib/server/server_schedule_consumers.ml:109-148` dispatches a schedule by creating a board post.

Original gap:

The scheduler could indirectly wake Keepers through board-post side effects and observation of due scheduled automation. It was not yet a general typed Keeper wake/job mechanism.

Current worktree update:

- Scheduler payload kind `masc.keeper_wake` now dispatches typed Keeper wake stimuli.
- Keeper event queue payload `Schedule_due` carries scheduled wake context without depending on board relevance.

### 10. MASC/OAS Boundary

Status: source scan did not find production OAS depending on MASC.

Evidence:

- `rg` over `/Users/dancer/me/workspace/yousleepwhen/oas/lib` for `MASC`, `Masc`, `masc`, `keeper`, `Keeper` returned no production hits.
- Test files in OAS contain MASC/keeper regression context comments and fixtures, which is acceptable as cross-repo regression evidence if it stays out of public runtime API.

MASC uses OAS/runtime concepts from its side. I did not find evidence that OAS production code imports MASC.

## Findings

### P1 - Board relevance used production heuristic for non-explicit wakes

Original finding: the `stigmergy_match` path was keyword scoring, not LLM judgment. It could false-wake and false-miss, especially for Korean text, punctuation, aliases, and multi-context Keeper identity.

Current source status: closed in this worktree.

- Explicit mention and thread reply remain deterministic structural signals.
- Non-explicit keyword/stigmergy score no longer wakes as final authority.
- The dead keyword relevance module was removed.

### P1 - Cursor-scanned board events could be acked before later scheduling gates

Original finding: cursor advancement happened before later approval/backpressure scheduling gates, creating a possible no-requeue drop path for cursor-scanned board events.

Current source status: closed in this worktree.

- Board cursor collection now pre-gates on cold Keeper state, pause, pending HITL approval, runtime backpressure, and provider cooldown before cursor advancement.
- Board-event collection failures are no longer only log/metric signals; they now degrade `keeper_board_event_collection` health and propagate to top-level operator action reasons until a successful collection clears the failure.

### P1 - Full health missed durable event-queue backlog

Original finding: live state had non-empty durable event queues, including `taskmaster` with 349 pending items, while full health said reaction-ledger pending count was zero.

Current source status: closed in this worktree.

- `/health?full=1` now includes durable queue pending/inflight counts, payload class counts, immediate counts, queue age, durable-only keeper snapshot discovery, and durable snapshot read/parse errors.
- Degradation uses explicit stale policy `MASC_KEEPER_DURABLE_QUEUE_STALE_SEC` / `[health].durable_queue_stale_sec`.
- Component `status_reasons` now propagate into top-level `operator_action_reasons`.

### P2 - Chat waiter cap was hard-coded

Original finding: `max_waiting_chat_requests = 8` was typed and observable, but arbitrary.

Current source status: removed in this worktree.

- There is no chat waiting cap or capacity-derived rejection.
- `keeper_turn_admission` health exposes the in-flight lane and raw waiting
  count per Keeper without escalating it into fleet or operator state.

### P2 - Scheduler was not yet a general Keeper wake mechanism

Original finding: the schedule consumer created board posts, making "Scheduler wakes Keeper" depend on board relevance side effects.

Current source status: closed in this worktree.

- `masc.keeper_wake` schedule payloads now dispatch typed `Schedule_due` Keeper event-queue stimuli.
- Board-post schedule remains a consumer, not the only wake semantics.

### P3 - Dead keyword relevance module should not become production path

Resolved in this worktree by removing `Keeper_relevance_check` and its dedicated test. Any future relevance authority should be introduced through an explicit LLM-boundary contract instead of reviving keyword coverage logic.

## Pass Criteria For Next Round

- Source-level pass: board non-explicit wake no longer uses substring/keyword score as final authority.
- Source-level pass: board cursor collection pre-gates pending HITL and backpressure states before cursor advancement.
- Source-level pass: board-event collection exceptions are visible in full health and runtime resolution, not only logs/metrics.
- Source-level pass: `/health?full=1` reports durable event queue backlog, age, payload classes, durable-only keeper snapshot discovery, and snapshot read/parse errors.
- Source-level pass: scheduler can emit a typed Keeper stimulus independent of board-post side effects.
- Source-level pass: chat admission cap and proactive backoff/idle-decay caps are named policy, config-backed, and observable.
- Remaining live pass: deploy this branch, let CI run full Dune build, and re-run `/health?full=1` plus durable queue probes against `/Users/dancer/me/.masc`.

## Summary

The Keeper system is already alive and materially autonomous/reactive. The current worktree closes the original source-level gaps in non-explicit attention, cursor/drop safety, board collection failure visibility, durable queue health, chat admission policy, and typed scheduler wake. The remaining production gate is live verification after CI/deployment, because the live-runtime evidence in this report predates these changes.
