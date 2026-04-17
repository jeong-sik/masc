(** Keeper State Machine — Deterministic Core (RFC-0002).

    This module defines the 12-state keeper lifecycle as a pure state machine.
    All functions are deterministic: no I/O, no clock reads, no mutable state.

    Architecture:
    - Layer 3 (NonDet Shell): measurements captured via [Keeper_measurement]
    - Layer 2 (Det Core): THIS MODULE — events x conditions -> phase transitions
    - Layer 1 (Storage): [Keeper_registry] applies transitions atomically

    Key invariant: given the same [conditions] and [event], [apply_event]
    always produces the same [transition_result]. *)

(** {1 Phase (12-State Enum)} *)

(** Fine-grained keeper lifecycle phase.
    Buffer states ([Failing], [Overflowed], [Compacting], [HandingOff],
    [Draining], [Restarting]) are observable intermediaries between
    stable states. *)
type phase =
  | Offline       (** Registered but no heartbeat fiber started *)
  | Running       (** Healthy heartbeat loop executing *)
  | Failing       (** Consecutive failures detected, probing recovery *)
  | Overflowed    (** Prompt exceeded provider max context; auto-compact
                      pending. Transient: [entry_actions_for] emits
                      [Start_compaction] so the next event-loop iteration
                      derives [Compacting]. Distinguishes "context overflow"
                      from generic [Failing] for operator observability. *)
  | Compacting    (** Context compaction in progress *)
  | HandingOff    (** Generation rollover in progress *)
  | Draining      (** Graceful shutdown: completing current turn *)
  | Paused        (** Operator-paused or auto-compact-retry-exhausted,
                      fiber sleeping *)
  | Stopped       (** Clean exit, terminal *)
  | Crashed       (** Unrecoverable error, restart candidate *)
  | Restarting    (** Supervisor backoff wait before re-launch *)
  | Dead          (** Restart budget exhausted, tombstone, terminal *)

val phase_to_string : phase -> string
val phase_of_string : string -> phase option
val all_phases : phase list

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
  (** [consecutive_failures < max_hb_failures] *)
  turn_healthy : bool;
  (** [turn_consecutive_failures < max_turn_failures] *)
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
  restart_budget_remaining : bool;
  (** [restart_count < max_restarts] *)
  backoff_elapsed : bool;
  (** [now - last_restart_ts >= backoff_delay(restart_count)] *)
  guardrail_triggered : bool;
  (** [auto_rules.guardrail_stop = true] *)
  drain_complete : bool;
  (** Current turn finished, no pending work *)
  context_overflow : bool;
  (** Provider rejected the most recent prompt for exceeding its max
      context window. Distinct from [context_within_budget] (soft,
      ratio-based warning): [context_overflow] is a hard failure reported
      by the provider. Cleared by a successful [Compaction_completed] or
      by an operator clear action. *)
  compact_retry_exhausted : bool;
  (** Consecutive auto-compact attempts failed to resolve the overflow.
      While set, the next [Context_overflow_detected] derives [Paused]
      instead of [Overflowed] so operator intervention is required.
      Reset by [Compaction_completed] or [Fiber_started]. *)
}

val default_conditions : conditions
(** All false — the "zero state" for initialization. *)

(** {1 Events (Det/NonDet Boundary Output)} *)

(** Auto-rule evaluation summary, captured at the boundary. *)
type auto_rule_summary = {
  reflect : bool;
  plan : bool;
  compact : bool;
  handoff : bool;
  guardrail_stop : bool;
  guardrail_reason : string option;
  goal_drift : float;
}

(** Typed events that trigger condition re-evaluation.
    These are the ONLY inputs to the deterministic state machine.
    Non-deterministic measurements become typed events at the boundary.

    {2 Post-turn lifecycle contract (implicit invariant)}

    [Compaction_started] / [Handoff_started] / their matching
    [_completed] / [_failed] events MUST be dispatched only from
    {!Keeper_post_turn.apply_post_turn_lifecycle}, which runs
    synchronously at the tail of a keeper turn (inside
    [Keeper_unified_turn.run_unified_turn] or the legacy
    [Keeper_turn] path).

    The keepalive loop ({!Keeper_keepalive.run_heartbeat_loop}) does
    NOT explicitly gate dispatch on [phase]. It relies on the
    structural property that [Compaction_started] and [Handoff_started]
    are always paired with their [_completed] / [_failed] counterparts
    inside a single [run_unified_turn] call, so the next keepalive
    iteration can never observe the keeper in [Compacting] or
    [HandingOff] phase at its dispatch decision point.

    Violating this rule — for example, by emitting [Compaction_started]
    from a separate async monitor fiber while a turn is still in flight
    — reopens the {b KeepalivePhaseConsistency} safety bug formalized in
    [specs/bug-models/KeepalivePhaseConsistency.tla]. That spec's
    [NoDrainTransition] / [GhostDispatch] actions are the exact
    counterexamples TLC will find.

    If a future change needs to emit these events from outside
    [apply_post_turn_lifecycle], add an explicit phase gate to the
    keepalive dispatch site (roughly: [phase_allows_dispatch] reading
    [Keeper_registry.get] before [run_unified_turn]) and re-verify
    the TLA+ spec against the new code path. *)
type event =
  | Heartbeat_ok
  | Heartbeat_failed of { consecutive : int; max_allowed : int }
  | Turn_succeeded
  | Turn_failed of { consecutive : int; max_allowed : int }
  | Context_measured of {
      context_ratio : float;
      message_count : int;
      token_count : int;
      auto_rules : auto_rule_summary;
    }
  | Compaction_started
    (** Emit ONLY from {!Keeper_post_turn.apply_post_turn_lifecycle}.
        See the post-turn lifecycle contract above. *)
  | Compaction_completed of { before_tokens : int; after_tokens : int }
    (** Must fire in the same turn as the matching [Compaction_started]. *)
  | Compaction_failed of { reason : string }
    (** Must fire in the same turn as the matching [Compaction_started]. *)
  | Handoff_started
    (** Emit ONLY from {!Keeper_post_turn.apply_post_turn_lifecycle}.
        See the post-turn lifecycle contract above. *)
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
  | Fiber_terminated of { outcome : string }
  | Supervisor_restart_attempt of { attempt : int }
  | Restart_budget_exhausted
  | Guardrail_stop of { reason : string }
  | Context_overflow_detected of {
      source : [`Prompt_rejected | `Oas_signal];
      token_count : int;
      limit_tokens : int option;
    }
    (** Provider rejected prompt for exceeding max context.
        [`Prompt_rejected] is sourced from a failed unified turn
        (see [Keeper_unified_turn.is_context_overflow]);
        [`Oas_signal] is reserved for the future OAS event_bus
        subscription feature (masc.overflow.source=event_bus). *)
  | Auto_compact_triggered
    (** Emitted as part of [Overflowed] entry actions to mark the
        start of auto-recovery. Sets [compaction_active] so the next
        [derive_phase] returns [Compacting]. *)
  | Operator_compact_requested
    (** Operator invoked [masc_keeper_compact] MCP tool. Behaves like
        [Auto_compact_triggered] but also clears [compact_retry_exhausted]
        so a subsequent compaction failure restarts the retry counter. *)
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
    - All other variants remain descriptive placeholders for
      supervisor-owned work and are intentionally ignored by the registry. *)
type entry_action =
  | Start_compaction
  | Start_handoff
  | Start_drain
  | Schedule_restart of { delay_sec : float }
  | Publish_lifecycle of { event_name : string; detail : string }
  | Mark_dead_tombstone
  | Cleanup_and_unregister

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

val transition_error_to_string : transition_error -> string

(** {1 Core Functions} *)

(** Derive phase from conditions. Pure, priority-ordered.
    This is the SOLE function that determines keeper phase.

    Priority (first match wins):
    1.  Dead (terminal)
    2.  Stopped (stop_requested + drain_complete)
    3.  Offline (launch_pending before first fiber start)
    4.  Restarting (fiber dead + budget + backoff elapsed)
    5.  Crashed (fiber dead + budget remaining)
    6.  Draining (stop_requested)
    7.  Guardrail -> Failing
    8.  Paused (operator_paused OR context_overflow + compact_retry_exhausted)
    9.  HandingOff (handoff_active)
    10. Compacting (compaction_active)
    11. Overflowed (context_overflow AND NOT compaction_active)
    12. Failing (heartbeat degraded, turn degraded, or manual reconcile required)
    13. Running (fiber_alive) *)
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

(** {1 JSON Serialization} *)

val phase_to_json : phase -> Yojson.Safe.t
val conditions_to_json : conditions -> Yojson.Safe.t
val event_to_json : event -> Yojson.Safe.t
val transition_result_to_json : transition_result -> Yojson.Safe.t

(** {1 Mermaid Visualization} *)

(** Maps a phase to its Mermaid diagram state identifier (capitalized).
    Use this to reference states in generated Mermaid `class` directives. *)
val phase_to_mermaid_id : phase -> string

(** Generate a Mermaid stateDiagram-v2 string with the given phase
    highlighted. The diagram visualizes the keeper phases and
    distinguishes the current phase visually (green for active,
    amber for buffer, gray for terminal). *)
val phase_to_mermaid : current:phase -> string

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
