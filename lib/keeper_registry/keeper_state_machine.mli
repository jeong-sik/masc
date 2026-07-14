(** Keeper State Machine — Deterministic Core (RFC-0002).

    This module defines the keeper lifecycle as a pure state machine.
    All functions are deterministic: no I/O, no clock reads, no mutable state.

    Phase count history:
      - 11 phases at RFC-0002 Phase 1 introduction (#5229, 2026-04-05)
      - +1 → 12 when [Overflowed] was added (MASC-1, 2026-04)
    Single Source of Truth (SSOT) is the [type phase] declaration below;
    spec doc counts are
    cross-checked by [scripts/audit-tla-phase-count.sh] (R-H-1.c #14874).

    Architecture:
    - Layer 3 (NonDet Shell): measurements captured via [Keeper_measurement]
    - Layer 2 (Det Core): THIS MODULE — events x conditions -> phase transitions
    - Layer 1 (Storage): [Keeper_registry] applies transitions atomically

    Key invariant: given the same [conditions] and [event], [apply_event]
    always produces the same [transition_result]. *)

(** {1 Phase (13-State Enum)} *)

(** Fine-grained keeper lifecycle phase.
    Buffer states ([Failing], [Overflowed], [Compacting], [HandingOff],
    [Draining], [Restarting]) are observable intermediaries between
    stable states. *)
type phase =
  | Offline       (** Registered but no heartbeat fiber started *)
  | Running       (** Healthy heartbeat loop executing *)
  | Failing       (** Consecutive failures detected, probing recovery *)
  | Overflowed    (** Prompt exceeded provider max context; durable lane
                      compaction is pending. *)
  | Compacting    (** Context compaction in progress *)
  | HandingOff    (** Generation rollover in progress *)
  | Draining      (** Graceful shutdown: completing current turn *)
  | Paused        (** Explicitly operator-paused; fiber sleeping *)
  | Stopped       (** Clean exit, terminal *)
  | Crashed       (** Unrecoverable error, restart candidate *)
  | Restarting    (** Supervisor backoff wait before re-launch *)
  | Dead          (** Explicit durable tombstone, terminal *)

val phase_to_string : phase -> string
val phase_of_string : string -> phase option
val all_phases : phase list

(** [is_terminal phase] is true for Stopped/Dead — phases with no
    outgoing transition (see {!can_transition}). Shared by health surfaces
    and the mermaid renderer so the terminal triple is defined once in the
    FSM instead of re-matched at each consumer. *)
val is_terminal : phase -> bool

(** {1 Observable Conditions (Kubernetes Pattern)} *)

(** Observable boolean conditions computed from keeper state.
    Phase is DERIVED from conditions via [derive_phase].
    Conditions are the primitive; phase is the projection. *)
type conditions = {
  launch_pending : bool;
  (** Fresh registration exists, but the keepalive fiber has not started yet. *)
  fiber_alive : bool;
  (** [done_p] unresolved AND [fiber_stop] not set *)
  heartbeat_healthy : bool;
  (** Result of the latest heartbeat observation. *)
  turn_healthy : bool;
  (** Result of the latest completed turn observation. *)
  context_within_budget : bool;
  (** [context_ratio < compaction.ratio_gate] *)
  context_handoff_needed : bool;
  (** [auto_handoff AND context_ratio >= handoff_threshold] *)
  compaction_active : bool;
  (** Set true on compaction entry, false on exit *)
  handoff_active : bool;
  (** Set true on handoff entry, false on exit *)
  operator_paused : bool;
  (** [meta.paused = true] *)
  stop_requested : bool;
  (** [Atomic.get fiber_stop = true] *)
  dead_tombstone_latched : bool;
  (** Explicit durable Dead tombstone observed by lifecycle admission. *)
  restart_requested : bool;
  (** Supervisor has requested immediate restart of a stopped fiber. *)
  drain_complete : bool;
  (** Current turn finished, no pending work *)
  context_overflow : bool;
  (** Provider rejected the most recent prompt for exceeding its max
      context window. Distinct from [context_within_budget] (soft,
      ratio-based warning): [context_overflow] is a hard failure reported
      by the provider. Cleared by completed compaction or operator clear;
      token counts remain observations, not lifecycle gates. *)
  credential_archived : bool;
}

val default_conditions : conditions
(** All false — the "zero state" for initialization. *)

(** {1 Events (Det/NonDet Boundary Output)} *)

(** Auto-rule evaluation summary, captured at the boundary. *)
type context_actions = {
  compact : bool;
  handoff : bool;
}

(** Typed events that trigger condition re-evaluation.
    These are the ONLY inputs to the deterministic state machine.
    Non-deterministic measurements become typed events at the boundary.

    {2 Paired lifecycle event contract}

    [Compaction_started] / [Handoff_started] / their matching
    [_completed] / [_failed] events MUST be dispatched with an explicit
    lifecycle origin through {!Keeper_registry}. Normal turn-owned events
    use [Post_turn_lifecycle], which runs synchronously at the tail of a
    keeper turn (inside [Keeper_unified_turn.run_keeper_cycle] or the
    legacy [Keeper_turn] path). Manual compaction uses the narrower
    [Operator_compact] origin for compaction events only.

    The keepalive loop ({!Keeper_keepalive.run_heartbeat_loop}) does
    NOT explicitly gate dispatch on [phase]. It relies on the
    structural property that [Compaction_started] and [Handoff_started]
    are always paired with their [_completed] / [_failed] counterparts
    inside a single [run_keeper_cycle] call, so the next keepalive
    iteration can never observe the keeper in [Compacting] or
    [HandingOff] phase at its dispatch decision point.

    Violating this rule — for example, by emitting [Compaction_started]
    from a separate async monitor fiber while a turn is still in flight
    — reopens the {b KeepalivePhaseConsistency} safety bug formalized in
    [specs/bug-models/KeepalivePhaseConsistency.tla]. That spec's
    [NoDrainTransition] / [GhostDispatch] actions are the exact
    counterexamples TLC will find.

    If a future change needs another origin for these events, add it to
    the registry origin guard and re-verify the TLA+ spec against the new
    code path. *)
type event =
  | Heartbeat_ok
  | Heartbeat_failed of { consecutive : int }
  | Turn_succeeded
  | Turn_failed of { consecutive : int }
  | Context_measured of {
      context_ratio : float;
      message_count : int;
      token_count : int;
      context_actions : context_actions;
    }
  | Compaction_started
    (** Emit only through the registry lifecycle origin guard. See the
        paired lifecycle contract above. *)
  | Compaction_completed
    (** Must fire after the matching [Compaction_started] and durable save. *)
  | Compaction_failed of { reason : string }
    (** Must fire in the same turn as the matching [Compaction_started]. *)
  | Handoff_started
    (** Emit only through the registry lifecycle origin guard. See the
        paired lifecycle contract above. *)
  | Handoff_completed of { new_trace_id : string; generation : int }
    (** Must fire in the same turn as the matching [Handoff_started]. *)
  | Handoff_failed of { reason : string }
    (** Must fire in the same turn as the matching [Handoff_started]. *)
  | Operator_pause
  | Operator_resume
  | Operator_stop of { remove_meta : bool }
  | Stop_requested
  | Drain_complete
  | Fiber_started
  | Fiber_terminated of
      { outcome : string
      ; provider_id : string option
      ; http_status : int option
      }
  | Supervisor_restart_attempt of { attempt : int }
  | Credential_archived
  | Context_overflow_detected of {
      source : [`Prompt_rejected | `Oas_signal];
      token_count : int;
      limit_tokens : int option;
    }
    (** Provider rejected prompt for exceeding max context.
        [`Prompt_rejected] is sourced from a failed unified turn
        (see [Keeper_error_classify.is_context_overflow]);
        [`Oas_signal] is sourced either from structured OAS overflow
        diagnostics or from the drained OAS [Event_bus]
        [ContextOverflowImminent] signal for the same turn. *)
  | Auto_compact_triggered
    (** Legacy explicit input; no entry action produces this event. *)
  | Operator_compact_requested
    (** Operator invoked [masc_keeper_compact] MCP tool. *)
  | Operator_clear_requested of { preserve_system : bool; reason : string }
    (** Operator invoked [masc_keeper_clear]. Last-resort: drops
        conversation context entirely. Bypasses [Compacting] buffer
        state — conditions reset in-place. [reason] is required for
        audit trail. *)

val event_to_string : event -> string

(** {1 Transition} *)

(** Entry actions — side-effect descriptors emitted on state entry.
    Runtime contract:
    - [Publish_lifecycle] is executed by the registry integration as an
      observability-only SSE/log side effect.
    - The remaining variants remain descriptive placeholders for
      supervisor-owned work and are intentionally ignored by the registry. *)
type entry_action =
  | Start_compaction
  | Start_handoff
  | Start_drain
  | Schedule_restart of { delay_sec : float }
  | Publish_lifecycle of { event_name : string; detail : string }
  | Mark_dead_tombstone
  | Cleanup_and_unregister
  | Trigger_immediate_cleanup
  | Cancel_pending_oas

(** Result of applying an event. *)
type transition_result = {
  prev_phase : phase;
  new_phase : phase;
  updated_conditions : conditions;
  entry_actions : entry_action list;
  event_applied : event;
  timestamp : float;
}

(** Transition errors. *)
type transition_error =
  | Terminal_state of { current : phase; attempted_event : string }
  | Invalid_transition of { from_phase : phase; to_phase : phase; reason : string }
  | Precondition_violation of { event : string; reason : string }
        (** Event was dispatched at a phase/conditions state that the TLA+
            spec's corresponding action would not enable.  Used to surface
            silent state-machine corruption caused by mis-ordered callers.
            See [docs/tla-audit/ksm-precondition-enforcement-gap-2026-05-12.md]
            (iter 9 #14730) for the systematic gap analysis and R-A-9. *)

val transition_error_to_string : transition_error -> string

(** {1 Core Functions} *)

(** Derive phase from conditions. Pure, priority-ordered.
    This is the SOLE function that determines keeper phase.

    Priority (first match wins) — mirrors the [DerivePhase] action in
    [specs/keeper-state-machine/KeeperStateMachine.tla]:
    1.  Dead (explicit durable [dead_tombstone_latched])
    2.  Stopped (stop_requested + drain_complete + ~compaction_active +
                 ~handoff_active)
        -- Checked first because a clean drain wins even if the fiber
        subsequently exits.  Buffer-state guards prevent a TLC deadlock
        where Stopped is entered while compaction/handoff is still in
        flight (see comment on [keeper_state_machine.ml:derive_phase]).
    3.  Offline (launch_pending + ~fiber_alive) -- pre-start registration
    4.  Restarting (~fiber_alive + restart_requested)
    5.  Crashed (~fiber_alive)
    6.  Draining (stop_requested) -- in-progress stop
    7.  Paused (operator_paused)
    8.  HandingOff (handoff_active)
    9.  Compacting (compaction_active)
    10. Overflowed (context_overflow) -- durable compaction pending
    11. Failing (latest health failure or structural failure observation)
    12. Running (fiber_alive)
    13. Offline (default fallback for inconsistent zero-state)

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

(** Check if a direct transition from one phase to another is valid. *)
val can_transition : from_phase:phase -> to_phase:phase -> bool

(** [true] when a keeper phase is allowed to execute a unified turn.
    Runtime contract:
    - [Running] and [Failing] may execute turns.
    - All other phases must skip OAS turn execution until the keeper
      re-enters an executable phase. *)
val can_execute_turn : phase -> bool

(* JSON encoders moved to [Keeper_state_machine_json] (godfile decomp,
   no reverse alias due to wrapped-library cycle).  Use:
     Keeper_state_machine_json.{phase_to_json,
                                conditions_to_json,
                                event_to_json,
                                transition_result_to_json} *)

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
