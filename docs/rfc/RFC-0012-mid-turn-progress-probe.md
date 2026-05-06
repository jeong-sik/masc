# RFC 0012 — Mid-Turn Progress Probe

- Status: Draft
- Author: Vincent (vincent.dev@kidsnote.com)
- Date: 2026-04-29
- Related memory:
  `feedback_oas_execution_uncancellable_mid_turn`,
  `feedback_provider_cli_rollout_thread_not_found`,
  `feedback_proactive_turn_contract_violation_dominant`
- Related code:
  `lib/keeper/keeper_stale_watchdog.ml`,
  `lib/keeper/keeper_registry.ml`,
  `lib/keeper/keeper_hooks_oas.ml`

## Problem

The keeper stale-watchdog has three stale-detection paths
(`keeper_stale_watchdog.ml:212-232`):

1. `idle_stale` — `now - last_turn_ts > stale_threshold_sec`
   when no turn is running (`current_turn_observation = None`).
2. `in_turn_stale` — `now - obs.started_at > active_turn_timeout_sec`
   when a turn is running.
3. `failure_loop` — `consecutive_noop_count >= noop_threshold`.

`active_turn_timeout_sec` is `max(turn_timeout_sec, threshold)`.
Historically, this RFC assumed the design default was
`Keeper_runtime_resolved.turn_timeout_sec () = 3600 s`; the current
runtime default is 600 s because `keeper_runtime_resolved.ml:73-79`
clamps the env-driven value to `[60, 600]`.
`consecutive_noop_count` is updated only at turn end.

Consequence: a turn that hangs in the middle — for example, an
OAS HTTP single-bulk-read on a slow local LLM that never yields
intermediate progress — is invisible to the watchdog for up to one
hour. The Apr 23 shutdown log confirms this is not theoretical:

```
[Keeper] keeper_llm_bridge: OAS execution cancelled after 91.5s
[Keeper] keeper_llm_bridge: OAS execution cancelled after 496.8s
[Keeper] keeper_llm_bridge: OAS execution cancelled after 504.3s
```

These were 14 fibers all stuck mid-turn, only released by SIGTERM.
None were cancelled by the watchdog.

The user-visible symptom is that the operator log fills with
`watchdog tick noop=1 ... stale=false` heartbeats every 30 s, while
the actual `turn completed` event arrives once per ~30 min. Without
mid-turn signal, an operator cannot distinguish "slow turn making
progress" from "hung turn that will never complete".

## Out of scope

- Flat global lowering of `turn_timeout_sec` to a single value
  below the per-cascade design floor. Note the historical drift:
  this RFC was authored assuming `turn_timeout_sec () = 3600 s`,
  but `keeper_runtime_resolved.ml:73-79` currently clamps the
  env-driven value to `[60, 600]`. The desync is a code regression
  resolved separately by per-cascade override (Step 2 of goal
  `oas-bridge-stabilization`). What remains rejected is **flat
  global reduction** that ignores the legitimate 27 B `900 s+`
  floor (`lib/keeper/keeper_stale_watchdog.ml:405-418`).
- **Permitted (per-cascade override, added 2026-05-06)**: a cascade
  profile in `config/cascade.toml` may declare its own
  `turn_timeout_sec`. Checked-in remote/CLI profiles (`big_three`,
  `keeper_diverse`, `tier_fast`, `tier_medium`) run at 600 s.
  Operator-populated local-model profiles run at 900 s when they
  declare local providers (for example, `tier_small` with its Ollama
  entries enabled). `keeper_diverse` remains a single checked-in
  profile, not a family of implicit local variants. The 1 800 s tier
  is gated behind a follow-up RFC after one week of Prometheus data
  demonstrates a 900 s ceiling hit. Implementation: see
  `feature/cascade-tiered-turn-timeout`.
- Changing OAS execution to use chunked reads. That is an OAS-level
  change; the user explicitly noted in
  `feedback_oas_execution_uncancellable_mid_turn` that
  "masc-mcp 단독 fix 영역 zero".
- Changing cascade routing. Tracked separately in the
  `diag/27b-fallback-trace` worktree.

## Proposal

Add a `last_progress_at : float` field to `turn_observation` in
`keeper_registry.ml`. Update it from every `oas:event` that proves
forward motion (tool call started, tool call completed, agent text
delta, substrate event). Use it as a third
in-turn-stale criterion in `keeper_stale_watchdog.ml`:

```ocaml
let in_turn_stale =
  let elapsed_total = now -. obs.started_at in
  let elapsed_since_progress = now -. obs.last_progress_at in
  fiber_age >= grace_period_sec ()
  && (elapsed_total > active_turn_timeout_sec
      || elapsed_since_progress > progress_timeout_sec ())
```

Default `progress_timeout_sec` = 300 s (5 min).

Rationale:
- A healthy local-LLM turn emits at least one tool-call event or
  text delta within 5 minutes, even at 1 tok/s.
- A hung HTTP read emits zero events. After 5 min of zero progress
  the watchdog acts, regardless of `active_turn_timeout_sec`.
- `fiber_age >= grace_period_sec ()` is preserved so server restart
  does not produce false positives.

## Files affected

| File | Change |
|---|---|
| `lib/keeper/keeper_registry.ml` | Add `last_progress_at : float` to `turn_observation`; initialise in `start_turn`; expose `record_progress` |
| `lib/keeper/keeper_registry.mli` | Surface `record_progress` |
| `lib/keeper/keeper_hooks_oas.ml` | Call `Keeper_registry.record_progress` from each OAS event hook (`turn_ready`, `tool_started`, `tool_completed`, `agent_message_delta`) |
| `lib/keeper/keeper_stale_watchdog.ml` | Use `last_progress_at` in `in_turn_stale` |
| `lib/config/env_config_keeper.ml` | Add `progress_timeout_sec` (default 300, range \[60, 3600\]) |
| `test/test_keeper_stale_watchdog.ml` (new or extended) | Cover three cases: progressing slow turn (no kill), hung mid-turn (kill after 300 s), legitimately long single-shot turn that never emits events (kill — desired behaviour) |

LOC estimate: 80–150 net additions.

## Migration & rollout

- Default-on. The new path only triggers after `progress_timeout_sec`
  of zero events, which is strictly stricter than the existing
  1-hour `active_turn_timeout_sec`. Existing healthy turns continue
  to pass.
- Add a structured `keeper_stale_watchdog_progress_kill` log event
  with `cascade_name`, `model`, `last_event_kind`,
  `seconds_since_last_progress`, so the new kill class is
  attributable.
- Mark the kill class in
  `Keeper_registry.stale_kill_class` as a new variant
  `Mid_turn_no_progress { since_progress_sec : float }`.

## Acceptance criteria

1. Stale watchdog terminates a fiber whose turn has been in
   progress for ≥ `progress_timeout_sec` with zero recorded events,
   even when total turn elapsed < `active_turn_timeout_sec`.
2. A turn emitting at least one OAS event every 4 minutes is
   never killed by the new path, regardless of total duration.
3. Test fixture verifies both, including the boundary at exactly
   `progress_timeout_sec`.
4. Prometheus counter
   `masc_keeper_stale_termination_by_class_total{class="mid_turn_no_progress"}`
   is non-zero in synthetic reproducer.

## Open questions

- Should `progress_timeout_sec` differ per cascade? A cloud-only
  cascade can reasonably have a 60 s threshold; a local-LLM cascade
  needs 300 s+. Probably yes, exposed via cascade-level
  `progress_timeout_sec_override`.
- Substrate events that are not progress (heartbeats, surface
  re-emissions) must be filtered out. The list of "real progress"
  events is enumerable but needs review against `oas:event` taxonomy.
- Should the watchdog distinguish "no event yet" (turn just
  started) from "no event for 5 min" (hang)? Yes — initialise
  `last_progress_at = obs.started_at`, then progress timeout has
  the same semantics from turn start.
