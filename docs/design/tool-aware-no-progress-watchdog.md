# Tool-aware no-progress watchdog (P1-4a)

Status: Implemented (this PR; tests cover the consumer gate and the FSM count, the drain→callback glue is integration-covered — see §7)
Governing RFC: RFC-0197 (runtime-attempt watchdog, per-candidate wrap) — Replacement Direction points 2–4
Extends: RFC-0012 (Mid-Turn Progress Probe) — the `Mid_turn_no_progress` producer wired in PR #21938 (`3449f60cd`)
Scope: MASC keeper no-progress watchdog only. OAS execution-idle tool-awareness is a separate slice (P1-4b, see §8).

## 1. Problem

PR #21938 gave the `Mid_turn_no_progress` kill-class its first producer:
`Keeper_supervisor.assess_in_turn_progress` (`lib/keeper/keeper_supervisor.ml:68`)
flags a `Running` keeper whose `current_turn_observation.last_progress_at`
(`lib/keeper/keeper_registry_types.ml:124`) is older than the configured window.

`last_progress_at` is stamped by `Keeper_registry.record_turn_progress` on many
events. Directly in `keeper_hooks_oas.ml` these include `sdk_before_turn`,
`sdk_after_turn`, and `tool_completed:<name>` (`:276`, `:283`, `:519`). Most SSE
events during model streaming also stamp progress via
`keeper_agent_run_turn_helpers.registry_progress_on_event` (`:108-109`), e.g.
`sse_message_start`, `sse_content_block_start`, `sse_tool_block_start`,
`sse_text_delta`, `sse_thinking_delta`, `sse_tool_arg_delta`, `sse_content_delta`,
`sse_content_block_stop`, and `sse_message_delta`; admission yield/resume
(`slot_yield`/`slot_resume` at `:288/296`) stamps it as well.

Because streaming tool-call generation stamps progress continuously, the real
unstamped gap is not the whole "tool-involved turn" but the single tool
execution window: after the SSE stream ends and the runtime actually executes
the tool, until `tool_completed:<name>` is recorded. A legitimate long-running
tool (a multi-minute build, a slow MCP call) can stay in this window longer than
the progress timeout.

If the operator enables the window (`MASC_KEEPER_MID_TURN_PROGRESS_TIMEOUT_SEC`),
`assess_in_turn_progress` classifies active tool execution as no-progress. This
is exactly what RFC-0197 forbids:

- Point 2: "MASC should observe `ToolCalled` / `ToolCompleted` and avoid
  classifying active tool work as provider idle."
- Point 3: "If a turn appears stuck while a tool is active, report it as active
  tool execution, not provider timeout."
- Point 4: "only introduce cancellation after the execution region is tool-aware
  and can prove no active tool call is in flight."

The producer is opt-in and default-off, so this is not a live defect. Making the
advisory `Mid_turn_no_progress` signal tool-aware is the precondition that makes
the P1-5 signal safe to enable.

This PR does not make cancellation safe per RFC-0197 point 4. The mirror is a
lagging copy (§5), so it can prove only that the count was zero at the last
drain, not at the exact instant a cancellation decision is made. A future
cancellation gate will need a stronger seam—either a synchronous authoritative
read of `pending_tool_count` or a "lag ≤ X + pre-cancel recheck" protocol.

## 2. What already exists (grounding)

- `pending_tool_count : int` is maintained in `keeper_unified_turn_event_bus`
  (`lib/keeper/keeper_unified_turn_event_bus.ml:13`). It is computed by
  `record_fsm_tool_transitions` (`:70`), an FSM over `ToolCalled`/`ToolCompleted`
  events that validates transitions and drops invalid ones (`:109`), updated
  under an `Atomic` CAS (`:160`). It is leak-safe: the count comes from a
  validated transition function, not a naive increment/decrement pair, so a
  dropped or out-of-order event cannot wedge the count. The same holds for tool
  errors: `ToolCompleted` carries `output = Error _` and the FSM transition
  decrements the count. The only remaining wedge is a hard crash that emits no
  terminal event at all; that is covered by sweep-based crash recovery
  (`assess_stale_run` → `Idle_turn`), since the per-turn `In_turn_hung` wall-clock
  backstop was retired (RFC-0125 P4 amendment, 2026-06-22).
- The registry's `update_entry_if_registered` (`keeper_registry_setup.ml:80-88`)
  uses an `Atomic.compare_and_set` retry loop, so concurrent
  `record_turn_progress` and `record_turn_tool_inflight` writes to the same
  `current_turn_observation` cannot lose updates.
- The event bus already observes `ToolCalled` (`lib/keeper/keeper_event_bridge.ml:79`,
  `:236`), so RFC-0197 point 2's "observe" half is shipped.
- RFC-0197 point 4 is already honored at the OAS-idle boundary:
  `MASC_KEEPER_EXECUTION_IDLE_TIMEOUT_SEC` is parsed but deliberately NOT
  forwarded to OAS "until OAS proves active tool execution is excluded from idle
  accounting" (`lib/config/env_config_keeper.ml:419-420`).
- A turn that never terminates is caught by the no-turn / no-progress sweeps
  (`assess_stale_run` → `Idle_turn`, `assess_in_turn_progress` →
  `Mid_turn_no_progress`); the former per-turn `In_turn_hung` wall-clock watchdog
  was retired (RFC-0125 P4 amendment, 2026-06-22).

## 3. Constraint that picks the seam

The event-bus instance is created per-turn inside the turn-execution call stack
(`lib/keeper/keeper_unified_turn.ml:357`) and `unsubscribe`d at turn end (`:383`).
It is not registered in any global table keyed by keeper. The supervisor sweep
is a separate periodic loop that iterates registry entries and only sees
`entry.current_turn_observation` (`lib/keeper/keeper_supervisor.ml:369`).

Therefore the sweep cannot reach `pending_tool_count` by querying the event bus
(`get_state : t -> event_bus_state`, `keeper_unified_turn_event_bus.mli:51`).
The in-flight signal must be made visible through the one structure the sweep
already reads: `turn_observation`.

## 4. Design

Add an `active_tool_count : int` field to `turn_observation`, maintained as a
**write-through mirror** of the authoritative `pending_tool_count`, and have
`assess_in_turn_progress` treat a positive count as active tool execution.

### 4.1 Mirror via injected callback (no reverse dependency)

The event bus must not depend on `Keeper_registry` (that would reverse the
dependency direction; `keeper_unified_turn` and `keeper_hooks_oas` already depend
on the registry, not the other way around). Inject a callback instead:

```
(* keeper_unified_turn_event_bus *)
val create :
  keeper_name:string -> turn_id:int ->
  ?on_pending_count_change:(int -> unit) -> unit -> t
```

`drain` invokes `on_pending_count_change new_pending_tool_count` in the
CAS-success branch (`:160`), next to the existing `emit_fsm_transition`, only
when the count actually changes. Both the foreground drain
(`keeper_unified_turn.ml:368`) and the `start_background_drain` fiber (`:378`)
run through `drain`, so the mirror stays current without a separate poll.

The turn flow supplies the callback when it creates the bus:

```
(* keeper_unified_turn.ml, at create site :357 *)
~on_pending_count_change:(fun count ->
   Keeper_registry.record_turn_tool_inflight ~base_path name ~count)
```

### 4.2 Registry mirror write

```
(* keeper_registry_setup.ml, alongside record_turn_progress *)
let record_turn_tool_inflight ~base_path name ~count =
  update_entry_if_registered ~base_path name (fun e ->
    update_current_turn e (fun obs -> { obs with active_tool_count = count }))
```

This writes only the mirror field; it does not touch `last_progress_at` or any
turn-scoped data. When the turn ends, `mark_turn_finished` clears
`current_turn_observation`, so the mirror cannot leak across turns.

### 4.3 Assessment

```
(* keeper_supervisor.ml assess_in_turn_progress *)
| Some obs
  when phase = Keeper_state_machine.Running
       && obs.active_tool_count = 0          (* NEW: exclude active tool work *)
       && now -. obs.last_progress_at > progress_timeout -> Some (... Mid_turn_no_progress ...)
| Some _ | None -> None
```

A turn with a tool in flight is reported as active tool execution (no producer
emission), matching RFC-0197 point 3. A turn with no tool in flight and a stale
`last_progress_at` still produces `Mid_turn_no_progress` (P1-5 behavior preserved).

## 5. Why this seam (tradeoffs)

- **Write-through mirror of `pending_tool_count`** (chosen): the count stays a
  single authoritative value (the FSM); the registry field is a derived copy
  with no independent lifecycle, so it cannot leak. Cost: the event bus gains
  one optional callback parameter, and the mirror lags the true count by at most
  one drain interval. That lag is negligible against a ≥300 s no-progress window
  (the background drain keeps it fresh), but it is why this mirror is only an
  advisory signal, not a point-in-time proof for RFC-0197 point 4 cancellation.
- **Query the event bus from the sweep** (rejected): the bus is not globally
  registered (§3). Making it queryable would require a keeper-keyed table with
  its own create/unsubscribe lifecycle and cross-fiber synchronization — more
  surface and more failure modes than a mirror field.
- **Independent hook counter in `keeper_hooks_oas`** (rejected): incrementing on
  `pre_tool_use` and decrementing on `post_tool_use` duplicates `pending_tool_count`
  and re-derives the lifecycle by hand. A missed decrement on a tool-error path
  wedges the count above zero and silently disables the watchdog. Duplicated
  mutable state that can drift is the anti-pattern this design avoids.
- **Stamp `last_progress_at` on tool start** (rejected as insufficient): it only
  shifts the window to the tool's start; a tool that runs longer than the window
  still false-fires. RFC-0197 point 2 requires excluding active tool work
  entirely, which needs an in-flight signal, not a timestamp.

## 6. Layering (where each concern lives)

- Per-tool runaway (a hung subprocess/MCP call): owned by the tool substrate's
  own budget (RFC-0197 point 2), not this watchdog.
- A turn that never terminates regardless of tool state: `In_turn_hung`
  wall-clock backstop. Excluding active tool from no-progress does not weaken
  this — a genuinely hung turn still hits the absolute bound.
- Model stall with no tool and no output: this watchdog (`Mid_turn_no_progress`),
  now gated on `active_tool_count = 0`.

## 7. Changes and acceptance

Files (≤5, additive):

1. `lib/keeper/keeper_registry_types.ml` / `.mli` — add `active_tool_count : int`
   to `turn_observation`; default `0` at turn start.
2. `lib/keeper/keeper_registry_setup.ml` — `record_turn_tool_inflight`.
3. `lib/keeper/keeper_unified_turn_event_bus.ml` / `.mli` — `?on_pending_count_change`
   on `create`, invoked in `drain` on count change.
4. `lib/keeper/keeper_unified_turn.ml` — pass the mirror callback at the create site.
5. `lib/keeper/keeper_supervisor.ml` — gate `assess_in_turn_progress` on
   `active_tool_count = 0`.

Tests:

- `assess_in_turn_progress` (added, `test_keeper_supervisor.ml`): tool in flight
  (`active_tool_count = 1`) + stale `last_progress_at` → `None`; in flight far past
  the threshold (`= 3`, 9000 s stale) → `None` (count-gated, not timing); count
  back to `0` + stale → `Some Mid_turn_no_progress` (P1-5 behavior preserved).
- FSM count (existing, `test_keeper_unified_turn_event_bus.ml`):
  `record_fsm_tool_transitions` already covers `ToolCalled`/`ToolCompleted`
  balance, pending residue, and the no-prior-`ToolCalled` drop path that keeps
  the count from going below `0`.
- The `drain` → `on_pending_count_change` glue and the `record_turn_tool_inflight`
  registry write are integration-covered: both ends (FSM count, consumer gate)
  are unit-tested, and the glue is a single `old <> new` conditional plus a
  write-through. Driving `drain` in isolation needs a live `Keeper_event_bus`
  subscription, which has no unit harness here; this is recorded rather than
  fabricated.

Acceptance: with the producer enabled, a turn executing one long tool emits no
`Mid_turn_no_progress`; a turn stalled with no tool in flight still emits it
after the window.

## 8. Out of scope

- **P1-4b (OAS execution-idle tool-awareness)**: making the OAS execution-idle
  watchdog exclude active tool execution so MASC can forward
  `MASC_KEEPER_EXECUTION_IDLE_TIMEOUT_SEC` (`env_config_keeper.ml:419-420`). That
  change lives in the OAS repo at the turn-lifecycle boundary and ships
  separately.
- Turning the producer on by default. This design makes the signal tool-aware;
  the default-off posture is unchanged. Enabling is an operator decision once
  tool-awareness has fleet evidence.

## 9. RFC disposition

This implements RFC-0197 Replacement Direction points 2–3 for the MASC
no-progress watchdog and extends the RFC-0012 producer. It does not implement
point 4 (cancellation safety); that remains future work and will require a
stronger, point-in-time seam than the lagging mirror used here. It introduces
one contract change (`turn_observation.active_tool_count`). Recommendation: land
under RFC-0197 as its named implementation (cite RFC-0197 + RFC-0012 in the PR);
a new RFC is not warranted because no new lifecycle contract is created — the
field mirrors an existing authoritative value. `lib/keeper/keeper_supervisor.ml`
and the touched modules are outside the mandatory-RFC subsystem list, so the
hard gate does not fire; the PR body cites RFC-0197 explicitly.
