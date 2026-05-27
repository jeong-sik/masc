(** Keeper State Machine — Deterministic Core (RFC-0002).

    This module defines the 13-state keeper lifecycle as a pure state machine.
    All functions are deterministic: no I/O, no clock reads, no mutable state.

    Phase count history:
      - 11 phases at RFC-0002 Phase 1 introduction (#5229, 2026-04-05)
      - +1 → 12 when [Overflowed] was added (MASC-1, 2026-04)
      - +1 → 13 when [Zombie] was added (#14707, /loop iter 4)
    Single Source of Truth (SSOT) is the [type phase] declaration below;
    spec doc counts are
    cross-checked by [scripts/audit-tla-phase-count.sh] (R-H-1.c #14874).

    Architecture:
    - Layer 3 (NonDet Shell): measurements captured via [Keeper_measurement]
    - Layer 2 (Det Core): THIS MODULE — events x conditions -> phase transitions
    - Layer 1 (Storage): [Keeper_registry] applies transitions atomically

    Key invariant: given the same [conditions] and [event], [apply_event]
    always produces the same [transition_result]. *)

(** {1 SSOT Types}

    All type definitions ([phase], [conditions], [event], etc.) and their
    associated pure converters live in {!Keeper_state_machine_types}.
    Re-exported here so callers can write [Keeper_state_machine.phase]
    without reaching into the types submodule. *)
include module type of struct
  include Keeper_state_machine_types
end

(** {1 Core Functions} *)

(** Derive phase from conditions. Pure, priority-ordered.
    This is the SOLE function that determines keeper phase.

    Priority (first match wins) — mirrors the [DerivePhase] action in
    [specs/keeper-state-machine/KeeperStateMachine.tla]:
    1.  Stopped (stop_requested + drain_complete + ~compaction_active +
                 ~handoff_active)
        -- Checked first because a clean drain wins even if the fiber
        subsequently exits.  Buffer-state guards prevent a TLC deadlock
        where Stopped is entered while compaction/handoff is still in
        flight (see comment on [keeper_state_machine.ml:derive_phase]).
    2.  Offline (launch_pending + ~fiber_alive) -- pre-start registration
    3.  Dead (~fiber_alive + ~restart_budget_remaining) -- terminal
    4.  Restarting (~fiber_alive + budget + backoff_elapsed)
    5.  Crashed (~fiber_alive + budget remaining)
    6.  Draining (stop_requested) -- in-progress stop
    7.  Failing (guardrail_triggered)
    8.  Paused (operator_paused OR context_overflow + compact_retry_exhausted)
    9.  HandingOff (handoff_active)
    10. Compacting (compaction_active)
    11. Overflowed (context_overflow) -- transient, auto-compact pending
    12. Failing (~heartbeat_healthy OR ~turn_healthy)
    13. Running (fiber_alive)
    14. Offline (default fallback for inconsistent zero-state)

    Drift note: prior to this revision the docstring listed Dead as
    priority 1; the actual implementation has always checked Stopped
    first (the TLA+ spec agrees).  The order above is the ground truth
    enforced by [keeper_state_machine.ml] and TLC. *)
val derive_phase : conditions -> phase

(** Pure condition updater: given current conditions and an event,
    return the new conditions. No phase derivation or transition checks.
    Exposed for structural testing (set/clear coverage). *)
val update_conditions : conditions -> event -> conditions

(** Apply an event to the current state: update conditions, derive new phase.
    Returns [Error] for events on terminal states (Stopped, Dead).
    Pure function — no I/O, no clock. [now] is passed as argument. *)
val apply_event :
  current_phase:phase ->
  conditions:conditions ->
  event:event ->
  now:float ->
  (transition_result, transition_error) result

(** {1 Mermaid Visualization} *)

(* Mermaid rendering moved to [Keeper_state_machine_mermaid] (godfile
   decomp). Use that module directly:
     Keeper_state_machine_mermaid.phase_to_mermaid_id : phase -> string
     Keeper_state_machine_mermaid.phase_to_mermaid : current:phase -> string
   No reverse alias here: wrapped-library cycle blocked the alias. *)

(** {1 Attribution envelope (Layer 1)}

    Convert a transition attempt (event + current state) into the typed
    attribution envelope used by SSE emitters.

    All keeper FSM transitions are [Det]: the comment above the [event]
    type declares the invariant that non-deterministic measurements must
    be translated into typed events at the boundary before reaching the
    state machine. *)

val attribution_of_transition :
  event:event ->
  (transition_result, transition_error) result ->
  Attribution.t
(** Mapping:
    - [Ok result]                       → [Attribution.Passed]
                                          evidence: [{event, from_phase,
                                          to_phase, timestamp}]
    - [Error (Invalid_transition ..)]   → [Attribution.Transition_blocked]
                                          carrying [from_state], [to_state],
                                          [reason] directly. Evidence adds
                                          [event].
    - [Error (Terminal_state ..)]       → [Attribution.Policy_failed]
                                          reason is formatted from the
                                          [current] phase and attempted
                                          event. Evidence adds the phase. *)
