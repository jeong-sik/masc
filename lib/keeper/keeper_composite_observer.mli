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

type turn_phase = Keeper_registry.turn_phase =
  | Turn_idle
  | Turn_prompting
  | Turn_routing
  | Turn_executing
  | Turn_compacting
  | Turn_finalizing
  | Turn_exhausted

val all_turn_phases : Keeper_registry.packed_turn_phase list

type decision_stage = Keeper_registry.decision_stage =
  | Decision_undecided
  | Decision_guard_ok
  | Decision_gate_rejected
  | Decision_tool_policy_selected

val all_decision_stages : Keeper_registry.packed_decision_stage list

type cascade_state = Keeper_registry.cascade_state =
  | Cascade_idle
  | Cascade_selecting
  | Cascade_trying
  | Cascade_done
  | Cascade_exhausted

val all_cascade_states : Keeper_registry.packed_cascade_state list

type compaction_stage = Keeper_registry.compaction_stage =
  | Compaction_accumulating
  | Compaction_compacting
  | Compaction_done

val all_compaction_stages : Keeper_registry.packed_compaction_stage list

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
  | Invariant_phase_derivation_agreement

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
  phase_derivation_agreement : bool;
}

(** Increment [masc_keeper_invariant_violations_total\{keeper, invariant\}]
    once per violated invariant. No-op when all invariants hold. Called
    automatically from [observe]; exposed so unit tests can assert the
    counter bump without going through the full snapshot pipeline. *)
val bump_invariant_violations :
  keeper_name:string -> invariants_check -> unit

(** {2 Pure invariant predicates}

    The [check_*] functions below mirror the composite TLA+
    [SafetyInvariant] conjuncts and the runtime phase-derivation
    agreement check. They are exposed so cross-FSM joint tests
    ([test/test_keeper_fsm_joints.ml]) can drive realistic state
    combinations through the same predicates that production
    [compute_invariants] uses, without having to construct a full
    {!Keeper_registry.registry_entry} value.

    Pure: no side effects, no clock, no I/O. *)

(** Mirror of TLA+ I1 [PhaseTurnAlignment] (KeeperCompositeLifecycle.tla:354):
    when KSM is in [Compacting], the turn phase must also be
    [Turn_compacting]; conversely no other KSM phase may carry a live
    [Turn_compacting]. *)
val check_phase_turn_alignment : Keeper_state_machine.phase -> Keeper_registry.packed_turn_phase -> bool

(** Mirror of TLA+ I3 [CompactionAtomicity] (KeeperCompositeLifecycle.tla:368):
    [(kmc_compaction = compacting) <=> (phase = Compacting)]. *)
val check_compaction_atomicity : Keeper_state_machine.phase -> Keeper_registry.packed_compaction_stage -> bool

(** Mirror of TLA+ I2 [NoCascadeBeforeMeasurement]
    (KeeperCompositeLifecycle.tla:361): cascade selection past [idle]
    requires a captured measurement. *)
val check_no_cascade_before_measurement :
  cascade_state:Keeper_registry.packed_cascade_state -> measurement_captured:bool -> bool

val check_phase_derivation_agreement :
  Keeper_registry.registry_entry -> bool
(** Runtime-visible mirror of
    [Keeper_invariant_check.DerivePhaseAgreement]: the recorded registry
    phase must equal [Keeper_state_machine.derive_phase conditions]. *)

(** Minimal state extracted from {!Keeper_registry.registry_entry} for
    the [EventPriorityMonotone] invariant. Separating this type allows
    QCheck property tests to exercise the predicate without constructing
    a full registry entry (~20 fields). *)
type event_priority_state = {
  ep_measurement_bind_count : int;
  ep_has_measurement : bool;
  ep_has_pending_measurement : bool;
}

(** Pure predicate for TLA+ I4 [EventPriorityMonotone]
    (KeeperCompositeLifecycle.tla:374): at most one measurement binding
    per turn, and a live measurement excludes a pending one. *)
val check_event_priority_monotone_pure : event_priority_state -> bool

(** Frozen outcome of the most recently completed turn (RFC-0003
    Phase 2). Surfaces terminal data ([Done]/[Guard_ok]/...) without
    polluting the live sub-FSM fields. [None] until the first turn
    has finished after registration. *)
type last_outcome = {
  turn_id : int;
  ended_at : float;
  decision_stage : Keeper_registry.packed_decision_stage;
  cascade_state : Keeper_registry.packed_cascade_state;
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
  phase : Keeper_state_machine.phase;
      (** Full 13-state keeper phase (RFC-0002, post-Zombie #14707). Previously
          collapsed to a 7-state projection for dashboard brevity; now exposed
          raw so the fleet matrix renders every state with its own chip colour.
          The 13-state alphabet matches
          [specs/keeper-state-machine/KeeperStateMachine.tla] exactly. *)
  ktc_turn_phase : Keeper_registry.packed_turn_phase;
  kdp_decision : Keeper_registry.packed_decision_stage;
  kcl_cascade_state : Keeper_registry.packed_cascade_state;
  kmc_compaction : Keeper_registry.packed_compaction_stage;
  kcb_state : Keeper_failure_circuit_breaker.display_state;
      (** 6th axis (LT-16-KCB). Observable circuit-breaker state —
          never [Tripped] because the mutator resets [consecutive_count]
          before snapshots can see it. See
          {!Keeper_failure_circuit_breaker.display_state}. *)
  shared_measurement : Keeper_state_machine.auto_rule_summary option;
  invariants : invariants_check;
  conditions : Keeper_state_machine.conditions;
      (** Raw observable conditions that derive [raw_phase]. Exposed for
          dashboard diagnostics; callers should not infer composite state from
          this when the dedicated axes above are present. *)
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
  fsm_guard_violations : int;
      (** Runtime [@@fsm_guard] assertion violations observed for this
          keeper since process start. Bumped by
          [Keeper_fsm_guard_runtime.wrap_unit] on every invariant breach.
          Exposed in the dashboard FSM matrix top strip so operators can
          spot spec-drift without reading logs. *)
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

val turn_phase_to_string : Keeper_registry.packed_turn_phase -> string
val turn_phase_of_string : string -> turn_phase option

(** Stringify [decision_stage]. Mirrors KeeperDecisionPipeline.tla. *)
val decision_stage_to_string : Keeper_registry.packed_decision_stage -> string
val decision_stage_of_string : string -> decision_stage option

(** Stringify [cascade_state]. Mirrors KeeperCascadeLifecycle.tla. *)
val cascade_state_to_string : Keeper_registry.packed_cascade_state -> string
val cascade_state_of_string : string -> cascade_state option

(** Stringify [compaction_stage]. Mirrors KeeperCompactionLifecycle.tla. *)
val compaction_stage_to_string : Keeper_registry.packed_compaction_stage -> string
val compaction_stage_of_string : string -> compaction_stage option

val tla_action_to_string : tla_action -> string
val tla_action_of_string : string -> tla_action option

val invariant_key_to_string : invariant_key -> string
val invariant_key_of_string : string -> invariant_key option

(** Serialise a snapshot as the [/api/keepers/:name/composite] payload
    documented in RFC-0003 §7. *)
val snapshot_to_json : snapshot -> Yojson.Safe.t
