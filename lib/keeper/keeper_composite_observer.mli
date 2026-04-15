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

    Initial scope: derives [ksm_phase] and [kmc_compaction] directly from
    the registry entry. [kdp_decision] / [kcl_cascade_state] remain
    [`Undecided`] / [`Idle`] until follow-up PRs wire the
    [Context_measured] / cascade-runtime observation points.

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

type turn_phase =
  | Turn_idle
  | Turn_prompting
  | Turn_executing
  | Turn_compacting
  | Turn_finalizing

val all_turn_phases : turn_phase list

type decision_stage =
  | Decision_undecided
  | Decision_guard_ok
  | Decision_gate_rejected
  | Decision_tool_policy_selected

val all_decision_stages : decision_stage list

type cascade_state =
  | Cascade_idle
  | Cascade_selecting
  | Cascade_trying
  | Cascade_done
  | Cascade_exhausted

val all_cascade_states : cascade_state list

type compaction_stage =
  | Compaction_accumulating
  | Compaction_compacting
  | Compaction_done

val all_compaction_stages : compaction_stage list

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

(** Frozen outcome of the most recently completed turn (RFC-0003
    Phase 2). Surfaces terminal data ([Done]/[Guard_ok]/...) without
    polluting the live sub-FSM fields. [None] until the first turn
    has finished after registration. *)
type last_outcome = {
  turn_id : int;
  ended_at : float;
}

type snapshot = {
  correlation_id : string;
  run_id : string;
  ts : float;
  ksm_phase : ksm_phase;
  ktc_turn_phase : turn_phase;
  kdp_decision : decision_stage;
  kcl_cascade_state : cascade_state;
  kmc_compaction : compaction_stage;
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

(** Stringify [turn_phase] for JSON serialisation. Mirrors the lowercase
    edge labels used in KeeperTurnCycle.tla. *)
val ksm_phase_to_string : ksm_phase -> string
val ksm_phase_of_string : string -> ksm_phase option

val turn_phase_to_string : turn_phase -> string
val turn_phase_of_string : string -> turn_phase option

(** Stringify [decision_stage]. Mirrors KeeperDecisionPipeline.tla. *)
val decision_stage_to_string : decision_stage -> string
val decision_stage_of_string : string -> decision_stage option

(** Stringify [cascade_state]. Mirrors CascadeLiveness.tla action labels. *)
val cascade_state_to_string : cascade_state -> string
val cascade_state_of_string : string -> cascade_state option

(** Stringify [compaction_stage]. Mirrors MemoryCompaction.tla. *)
val compaction_stage_to_string : compaction_stage -> string
val compaction_stage_of_string : string -> compaction_stage option

(** Serialise a snapshot as the [/api/keepers/:name/composite] payload
    documented in RFC-0003 §7. *)
val snapshot_to_json : snapshot -> Yojson.Safe.t
