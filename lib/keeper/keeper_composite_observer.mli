(** Keeper Composite Lifecycle Observer — pure projection.

    Projects a [Keeper_registry.registry_entry] into a composite snapshot
    spanning Decision / Cascade / Memory / Compaction sub-FSMs as
    specified in RFC-0003 and
    [specs/keeper-state-machine/KeeperCompositeLifecycle.tla].

    Contract:
    - Pure read. No mutation, no I/O, no event emission.
    - Never calls [Keeper_state_machine.apply_event],
      [Keeper_cascade_routing.select_cascade], or any routine that would
      shift keeper lifecycle state.
    - Does not read provider names, token counts, or context bytes —
      those belong to OAS (see [feedback_masc-oas-layer-boundary]).

    Current scope: all projected sub-FSM live states are written directly
    into [Keeper_registry.registry_entry]. The observer no longer infers
    decision/cascade/compaction state from coarse parent conditions.

    @since RFC-0003 — Composite observer v0. *)

(** KSM projection mirrored from [PhaseSet] in
    [specs/keeper-state-machine/KeeperCompositeLifecycle.tla].

    This is intentionally not the full [Keeper_state_machine.phase] domain:
    the composite observer collapses turn-external phases into [Ksm_stable]
    so the state set stays aligned with the observer TLA+ model. *)
type ksm_phase =
  | Ksm_running
  | Ksm_failing
  | Ksm_overflowed
  | Ksm_compacting
  | Ksm_handing_off
  | Ksm_draining
  | Ksm_stable

val all_ksm_phases : ksm_phase list

type turn_phase = Keeper_registry.turn_phase =
  | Turn_idle
  | Turn_prompting
  | Turn_executing
  | Turn_compacting
  | Turn_finalizing

val all_turn_phases : turn_phase list

type decision_stage = Keeper_registry.decision_stage =
  | Decision_undecided
  | Decision_guard_ok
  | Decision_gate_rejected
  | Decision_tool_policy_selected

val all_decision_stages : decision_stage list

type cascade_state = Keeper_registry.cascade_state =
  | Cascade_idle
  | Cascade_selecting
  | Cascade_trying
  | Cascade_done
  | Cascade_exhausted

val all_cascade_states : cascade_state list

type compaction_stage = Keeper_registry.compaction_stage =
  | Compaction_accumulating
  | Compaction_compacting
  | Compaction_done

val all_compaction_stages : compaction_stage list

(** Named TLA actions mirrored as OCaml variants so the observer contract
    can stay 1:1 with [KeeperCompositeLifecycle.tla]. *)
type tla_action =
  | Action_start_turn
  | Action_measurement_broadcast
  | Action_decide_guard
  | Action_select_tool_policy
  | Action_start_cascade_selection
  | Action_select_cascade
  | Action_gate_rejected
  | Action_cascade_done
  | Action_cascade_exhausted
  | Action_finish_turn
  | Action_start_compaction
  | Action_finish_compaction
  | Action_enter_failing
  | Action_clear_failing
  | Action_enter_overflowed
  | Action_overflowed_auto_compact

val all_tla_actions : tla_action list

(** Named TLA invariants mirrored as OCaml variants. *)
type invariant_key =
  | Invariant_phase_turn_alignment
  | Invariant_no_cascade_before_measurement
  | Invariant_compaction_atomicity
  | Invariant_event_priority_monotone

val all_invariant_keys : invariant_key list

(** Safety invariants from KeeperCompositeLifecycle.tla.
    Each field is [true] when the invariant holds for the observed
    snapshot. A [false] value signals a composite-level safety violation
    that the dashboard should surface to the operator. *)
type invariants_check = {
  phase_turn_alignment : bool;
  no_cascade_before_measurement : bool;
  compaction_atomicity : bool;
  event_priority_monotone : bool;
}

(** Increment [masc_keeper_invariant_violations_total\{keeper, invariant\}]
    once per violated invariant. No-op when all invariants hold. Called
    automatically from [observe]; exposed so unit tests can assert the
    counter bump without going through the full snapshot pipeline. *)
val bump_invariant_violations :
  keeper_name:string -> invariants_check -> unit

(** Frozen outcome of the most recently completed turn (RFC-0003
    Phase 2). Surfaces terminal data ([Done]/[Guard_ok]/...) without
    polluting the live sub-FSM fields. [None] until the first turn
    has finished after registration. *)
type last_outcome = {
  turn_id : int;
  ended_at : float;
  decision_stage : decision_stage;
  cascade_state : cascade_state;
  selected_model : string option;
}

type snapshot = {
  keeper_name : string;
      (** Canonical keeper identity from the registry entry. This is separate
          from [correlation_id], which may come from an external event envelope
          and is not a stable row key for fleet dashboards. *)
  correlation_id : string;
  run_id : string;
  ts : float;
  ksm_phase : ksm_phase;
  collapsed_from : Keeper_state_machine.phase option;
      (** Raw keeper phase collapsed into [Ksm_stable], when applicable.
          [None] for active composite phases or older payload readers.
          Lets operator surfaces distinguish "quiet" from terminal or
          operator-paused raw phases without widening the composite enum. *)
  ktc_turn_phase : turn_phase;
  kdp_decision : decision_stage;
  kcl_cascade_state : cascade_state;
  kmc_compaction : compaction_stage;
  kcb_state : Keeper_failure_circuit_breaker.display_state;
      (** 6th axis (LT-16-KCB). Observable circuit-breaker state —
          never [Tripped] because the mutator resets [consecutive_count]
          before snapshots can see it. See
          {!Keeper_failure_circuit_breaker.display_state}. *)
  shared_measurement : Keeper_state_machine.auto_rule_summary option;
  invariants : invariants_check;
  is_live : bool;
      (** [true] when [current_turn_observation] is [Some] — a turn is
          actively executing and the live sub-FSM fields reflect its
          state. [false] indicates an idle keeper; sub-FSM fields
          revert to [Idle]/[Undecided]. *)
  last_outcome : last_outcome option;
      (** Most recent completed turn, surfaced separately from live
          state so operators can see "what just finished" without
          confusing it with "what's running now". *)
  fiber_stop_flag : bool;
      (** Snapshot of [registry_entry.fiber_stop] at observation time.
          When [true] without a corresponding stopped/dead phase, the
          keepalive loop will exit on its next iteration — used to
          discriminate fiber-supervisor wedge from cycle-gate wedge in
          fleet silence diagnoses. *)
  fiber_wakeup_flag : bool;
      (** Snapshot of [registry_entry.fiber_wakeup]. [true] means a
          wake signal is queued; the next [interruptible_sleep] chunk
          will return early. Stale [true] points at a wake source
          that was set but never consumed. *)
  consecutive_noop_count : int;
      (** Lifetime [consecutive_noop_count] from the proactive runtime.
          Increments per cycle that produced no text and only used
          observation-only tools; resets on substantive output. Reaching
          ≥3 caps the noop backoff multiplier at 8x. *)
  idle_seconds : int;
      (** Wall-clock seconds since the keeper last did something the
          metrics layer treated as substantive. Compared against
          [proactive.idle_sec] to gate scheduled-autonomous turns. *)
  last_turn_ts : float;
      (** Raw [runtime.usage.last_turn_ts] from the registry entry.
          Exposed for watchdog staleness diagnosis — the stale watchdog
          in [Keeper_supervisor] reads this exact field. A value of [0.0]
          means the registry never recorded a completed turn. *)
}

(** Derive a composite snapshot from a live registry entry.

    [correlation_id] and [run_id] may be supplied by the caller when the
    observer is driven from a known event envelope (OAS event_bus
    envelope, PR OAS#845). When absent, the snapshot uses
    [keeper:<name>:<transition_seq>] as a stable identifier so repeated
    reads within the same keeper transition return the same id. *)

val observe :
  ?correlation_id:string ->
  ?run_id:string ->
  ?now:float ->
  Keeper_registry.registry_entry ->
  snapshot

(** Observe every registered keeper under [base_path] once. Used by
    [GET /api/v1/keepers/composite] to render fleet-level matrices
    (LT-16a). Preserves registry iteration order. *)
val all_snapshots : base_path:string -> unit -> snapshot list

(** Stringify [turn_phase] for JSON serialisation. Mirrors the lowercase
    edge labels used in KeeperTurnCycle.tla. *)
val ksm_phase_to_string : ksm_phase -> string
val ksm_phase_of_string : string -> ksm_phase option

val turn_phase_to_string : turn_phase -> string
val turn_phase_of_string : string -> turn_phase option

(** Stringify [decision_stage]. Mirrors KeeperDecisionPipeline.tla. *)
val decision_stage_to_string : decision_stage -> string
val decision_stage_of_string : string -> decision_stage option

(** Stringify [cascade_state]. Mirrors KeeperCascadeLifecycle.tla. *)
val cascade_state_to_string : cascade_state -> string
val cascade_state_of_string : string -> cascade_state option

(** Stringify [compaction_stage]. Mirrors KeeperCompactionLifecycle.tla. *)
val compaction_stage_to_string : compaction_stage -> string
val compaction_stage_of_string : string -> compaction_stage option

val tla_action_to_string : tla_action -> string
val tla_action_of_string : string -> tla_action option

val invariant_key_to_string : invariant_key -> string
val invariant_key_of_string : string -> invariant_key option

(** Serialise a snapshot as the [/api/keepers/:name/composite] payload
    documented in RFC-0003 §7. *)
val snapshot_to_json : snapshot -> Yojson.Safe.t
