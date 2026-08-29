(** Keeper State Machine — Deterministic Core (RFC-0002).

    This module defines the keeper lifecycle as a pure state machine.
    All functions are deterministic: no I/O, no clock reads, no mutable state.

    Single Source of Truth (SSOT) is the [type phase] declaration below;
    spec doc counts are
    cross-checked by [scripts/audit-tla-phase-count.sh] (R-H-1.c #14874).

    Architecture:
    - Layer 3 (NonDet Shell): the caller supplies wall-clock and event inputs
    - Layer 2 (Det Core): THIS MODULE — events x conditions -> phase transitions
    - Layer 1 (Storage): [Keeper_registry] applies transitions atomically

    Key invariant: given the same [conditions] and [event], [apply_event]
    always produces the same [transition_result]. *)

(** {1 Phase} *)

(** Fine-grained keeper lifecycle phase.
    Buffer states ([Failing], [Draining], [Restarting])
    are observable intermediaries between
    stable states. *)
type phase =
  | Offline       (** Registered but no heartbeat fiber started *)
  | Running       (** Healthy heartbeat loop executing *)
  | Failing       (** Consecutive failures detected, probing recovery *)
  | Draining      (** Graceful shutdown: completing current turn *)
  | Paused        (** Explicitly operator-paused; fiber sleeping *)
  | Stopped       (** Clean exit, terminal *)
  | Crashed       (** Unrecoverable error, restart candidate *)
  | Restarting    (** Supervisor backoff wait before re-launch *)

val phase_to_string : phase -> string
val phase_of_string : string -> phase option
val all_phases : phase list

(** [is_terminal phase] is true for Stopped — a phase with no
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
  context_handoff_needed : bool;
  operator_paused : bool;
  (** [meta.paused = true] *)
  stop_requested : bool;
  (** [Atomic.get fiber_stop = true] *)
  restart_requested : bool;
  (** Supervisor has requested immediate restart of a stopped fiber. *)
  drain_complete : bool;
  (** Current turn finished, no pending work *)
  credential_archived : bool;
}

val default_conditions : conditions
(** All false — the "zero state" for initialization. *)

(** {1 Events (Det/NonDet Boundary Output)} *)

(** Auto-rule evaluation summary, captured at the boundary. *)
type context_actions = { handoff : bool }

(** Typed events that trigger condition re-evaluation.
    These are the ONLY inputs to the deterministic state machine.
    Non-deterministic measurements become typed events at the boundary. *)

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
  | Operator_clear_requested of { preserve_system : bool; reason : string }
    (** Operator invoked [masc_keeper_clear]. Last-resort: drops
        conversation context entirely; conditions reset in-place.
        [reason] is required for audit trail. *)

val event_to_string : event -> string

(** {1 Transition} *)

(** Entry actions — side-effect descriptors emitted on state entry.
    Runtime contract:
    - [Publish_lifecycle] is executed by the registry integration as an
      observability-only SSE/log side effect.
    - The remaining variants remain descriptive placeholders for
      supervisor-owned work and are intentionally ignored by the registry. *)
type entry_action =
  | Start_drain
  | Schedule_restart of { delay_sec : float }
  | Publish_lifecycle of { event_name : string; detail : string }
  | Cleanup_and_unregister
  | Trigger_immediate_cleanup
  | Cancel_pending_agent_core

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
    2.  Stopped (stop_requested + drain_complete)
        -- Checked first because a clean drain wins even if the fiber
        subsequently exits.
    3.  Offline (launch_pending + ~fiber_alive) -- pre-start registration
    4.  Restarting (~fiber_alive + restart_requested)
    5.  Crashed (~fiber_alive)
    6.  Draining (stop_requested) -- in-progress stop
    7.  Paused (operator_paused)
    9.  Failing (latest health failure or structural failure observation)
    10. Running (fiber_alive)
    11. Offline (default fallback for inconsistent zero-state)

    The order above is the ground truth enforced by
    [keeper_state_machine.ml] and TLC. *)
val derive_phase : conditions -> phase

(** Pure condition updater: given current conditions and an event,
    return the new conditions. No phase derivation or transition checks.
    Exposed for structural testing (set/clear coverage). *)
val update_conditions : conditions -> event -> conditions

(** Apply an event to the current state: update conditions, derive new phase.
    Returns [Error] for events on the terminal state (Stopped).
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
    - All other phases must skip AGENT_CORE turn execution until the keeper
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
