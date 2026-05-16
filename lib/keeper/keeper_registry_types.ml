(** Keeper_registry_types — pure type definitions extracted from
    Keeper_registry (3041 LoC godfile).

    See keeper_registry_types.mli for rationale and contract. *)

open Keeper_types
module StringMap = Map.Make (String)

(** Structured failure reason for cohort detection in self-preservation.
    ADT matching replaces string prefix matching for crash_msg grouping. *)
type ambiguous_partial_commit_kind =
  | Post_commit_timeout
  | Post_commit_failure

type ambiguous_partial_commit =
  { kind : ambiguous_partial_commit_kind
  ; detail : string
  }

(** Phase B PR-6 (2026-04-28): typed sub-class of stale-watchdog kills.
    See keeper_registry.mli for rationale. *)
type stale_kill_class =
  | Idle_turn of { stall_seconds : float }
  | In_turn_hung of
      { active_seconds : float
      ; timeout_threshold : float
      }
  | Noop_failure_loop of { noop_count : int }

let stale_kill_class_to_string = function
  | Idle_turn { stall_seconds } -> Printf.sprintf "idle_turn(%.0fs)" stall_seconds
  | In_turn_hung { active_seconds; timeout_threshold } ->
    Printf.sprintf
      "in_turn_hung(active=%.0fs threshold=%.0fs)"
      active_seconds
      timeout_threshold
  | Noop_failure_loop { noop_count } ->
    Printf.sprintf "noop_failure_loop(noop=%d)" noop_count
;;

type failure_reason =
  | Heartbeat_consecutive_failures of int
  | Turn_consecutive_failures of int
  | Stale_turn_timeout of stale_kill_class
  | Stale_termination_storm of { count : int }
  (** #10765 Phase 2: latched when [record_stale_termination] returns a
          window count >= [escalation_threshold]. The supervisor's
          [`Crashed] branch checks this variant and skips [to_restart],
          persisting [meta.paused = true] instead so an operator must
          investigate the underlying cascade/provider/fd issue before
          resuming the keeper. *)
  | Stale_fleet_batch of { distinct_count : int }
  (** Latched when the stale watchdog observes several distinct keepers
          terminating inside the fleet batch window. This is a systemic
          cascade/provider/runtime signal, so the supervisor pauses affected
          keepers with auto-resume backoff instead of restarting each keeper
          independently into the same failure mode. *)
  | Oas_timeout_budget_loop of { count : int }
  (** Latched when the same keeper exhausts the OAS turn budget on
          consecutive cycles. This is a provider/cascade/runtime throughput
          failure, so the supervisor pauses instead of restarting into the
          same slow model and burning another multi-minute budget. *)
  | Provider_runtime_error of
      { code : string
      ; detail : string
      }
  | Tool_required_unsatisfied of
      { code : string
      ; detail : string
      }
  | Ambiguous_partial_commit of ambiguous_partial_commit
  | Fiber_unresolved
  | Exception of string

let ambiguous_partial_commit_kind_to_string = function
  | Post_commit_timeout -> "post_commit_timeout"
  | Post_commit_failure -> "post_commit_failure"
;;

let failure_reason_to_string = function
  | Heartbeat_consecutive_failures n ->
    Printf.sprintf "heartbeat_consecutive_failures(%d)" n
  | Turn_consecutive_failures n -> Printf.sprintf "turn_consecutive_failures(%d)" n
  | Stale_turn_timeout cls ->
    Printf.sprintf "stale_turn_timeout(%s)" (stale_kill_class_to_string cls)
  | Stale_termination_storm { count } ->
    Printf.sprintf "stale_termination_storm(count=%d)" count
  | Stale_fleet_batch { distinct_count } ->
    Printf.sprintf "stale_fleet_batch(distinct_count=%d)" distinct_count
  | Oas_timeout_budget_loop { count } ->
    Printf.sprintf "oas_timeout_budget_loop(count=%d)" count
  | Provider_runtime_error { code; detail } ->
    Printf.sprintf "provider_runtime_error(%s:%s)" code detail
  | Tool_required_unsatisfied { code; detail } ->
    Printf.sprintf "tool_required_unsatisfied(%s:%s)" code detail
  | Ambiguous_partial_commit { kind; detail } ->
    Printf.sprintf
      "ambiguous_partial_commit(%s:%s)"
      (ambiguous_partial_commit_kind_to_string kind)
      detail
  | Fiber_unresolved -> "fiber_unresolved"
  | Exception s -> Printf.sprintf "exception(%s)" s
;;

(** #10584: cohort key for grouping failures by variant, ignoring
    parameters (e.g. failure count, timeout seconds).  Lives next to
    [failure_reason_to_string] in the source-of-truth module so any
    new variant added to [failure_reason] forces a same-PR update of
    BOTH conversion arms — the consumer in keeper_supervisor (and
    any other dashboard / metrics call site) just delegates here.
    This is Option B from #10584: avoid the recurring-P0 pattern
    where consumer-side exhaustive matches catch up to upstream
    variant additions only after the warn-error build trip. *)
let failure_reason_cohort_key = function
  | Some (Heartbeat_consecutive_failures _) -> "heartbeat_failures"
  | Some (Turn_consecutive_failures _) -> "turn_failures"
  | Some (Stale_turn_timeout _) -> "stale_turn_timeout"
  | Some (Stale_termination_storm _) -> "stale_termination_storm"
  | Some (Stale_fleet_batch _) -> "stale_fleet_batch"
  | Some (Oas_timeout_budget_loop _) -> "oas_timeout_budget_loop"
  | Some (Provider_runtime_error _) -> "provider_runtime_error"
  | Some (Tool_required_unsatisfied _) -> "tool_required_unsatisfied"
  | Some (Ambiguous_partial_commit _) -> "ambiguous_partial_commit"
  | Some Fiber_unresolved -> "fiber_unresolved"
  | Some (Exception _) -> "exception"
  | None -> "unknown"
;;

let stale_watchdog_failure_reason ~prior ~kill_class =
  match prior with
  | Some
      ( Oas_timeout_budget_loop _
      | Provider_runtime_error _
      | Tool_required_unsatisfied _
      | Ambiguous_partial_commit _
      | Turn_consecutive_failures _
      | Heartbeat_consecutive_failures _
      | Exception _ ) -> prior
  | Some
      ( Stale_termination_storm _
      | Stale_fleet_batch _
      | Stale_turn_timeout _
      | Fiber_unresolved )
  | None -> Some (Stale_turn_timeout kill_class)
;;

(** Pure control-flow signal for immediate fiber termination (RFC-0002).
    Carries no state — failure reason must be pre-stored via
    [set_failure_reason] before raising. *)
exception Keeper_fiber_crash
type turn_phase =
  | Turn_idle [@tla.idle]
  | Turn_prompting [@tla.active]
  | Turn_routing [@tla.active]
  | Turn_executing [@tla.active]
  | Turn_compacting [@tla.active]
  | Turn_finalizing [@tla.active]
  | Turn_exhausted [@tla.terminal]
[@@deriving tla]

(* Phantom witness types for turn_phase GADT (Tier B5 pattern).
   Covers all 7 phases of [turn_phase]. Turn_routing and Turn_exhausted
   were added to the normal variant on main while this PR was in flight;
   the GADT tracks them too so the transition matrix below stays
   compile-time exhaustive. *)
type turn_idle = |
type turn_prompting = |
type turn_routing = |
type turn_executing = |
type turn_compacting = |
type turn_finalizing = |
type turn_exhausted = |

type 'a turn_phase_witness =
  | Turn_idle : turn_idle turn_phase_witness
  | Turn_prompting : turn_prompting turn_phase_witness
  | Turn_routing : turn_routing turn_phase_witness
  | Turn_executing : turn_executing turn_phase_witness
  | Turn_compacting : turn_compacting turn_phase_witness
  | Turn_finalizing : turn_finalizing turn_phase_witness
  | Turn_exhausted : turn_exhausted turn_phase_witness

type packed_turn_phase = Packed : 'a turn_phase_witness -> packed_turn_phase

let turn_phase_to_witness : turn_phase -> packed_turn_phase = function
  | Turn_idle -> Packed Turn_idle
  | Turn_prompting -> Packed Turn_prompting
  | Turn_routing -> Packed Turn_routing
  | Turn_executing -> Packed Turn_executing
  | Turn_compacting -> Packed Turn_compacting
  | Turn_finalizing -> Packed Turn_finalizing
  | Turn_exhausted -> Packed Turn_exhausted
;;

let witness_to_turn_phase : packed_turn_phase -> turn_phase = function
  | Packed Turn_idle -> Turn_idle
  | Packed Turn_prompting -> Turn_prompting
  | Packed Turn_routing -> Turn_routing
  | Packed Turn_executing -> Turn_executing
  | Packed Turn_compacting -> Turn_compacting
  | Packed Turn_finalizing -> Turn_finalizing
  | Packed Turn_exhausted -> Turn_exhausted
;;

(* Diagnostic label for invalid-transition error messages.  Must stay in
   sync with the [turn_phase] variant — adding a constructor will fail
   compilation here, which forces the operator to extend
   [validate_turn_phase_transition] at the same time. *)
let packed_turn_phase_label : packed_turn_phase -> string = function
  | Packed Turn_idle -> "Turn_idle"
  | Packed Turn_prompting -> "Turn_prompting"
  | Packed Turn_routing -> "Turn_routing"
  | Packed Turn_executing -> "Turn_executing"
  | Packed Turn_compacting -> "Turn_compacting"
  | Packed Turn_finalizing -> "Turn_finalizing"
  | Packed Turn_exhausted -> "Turn_exhausted"
;;

(* RFC-0072 Phase 4: GADT-encoded turn_phase transitions, aligned with
   [Cascade_transition] shape — idempotent self-loops are NOT represented
   (they are mutator-boundary no-ops; the resolver returns
   [Resolved_idempotent] for them).  This module enumerates the 23 valid
   cross-state transitions of the 7-variant [turn_phase] FSM.  The 19
   forbidden pairs have no constructor and are therefore
   type-unrepresentable.  Adding a new [turn_phase] variant will trigger
   Warning 8 in [to_tag] and in [resolve_turn_phase_transition]. *)
module Turn_phase_transition = struct
  type ('from, 'to_) t =
    (* Boot dispatch. *)
    | Idle_to_prompting : (turn_idle, turn_prompting) t
    (* From Prompting (4): routing / executing / finalizing / exhausted. *)
    | Prompting_to_routing : (turn_prompting, turn_routing) t
    | Prompting_to_executing : (turn_prompting, turn_executing) t
    | Prompting_to_finalizing : (turn_prompting, turn_finalizing) t
    | Prompting_to_exhausted : (turn_prompting, turn_exhausted) t
    (* From Routing (3): retry-back / dispatch / exhausted. *)
    | Routing_to_prompting : (turn_routing, turn_prompting) t
    | Routing_to_executing : (turn_routing, turn_executing) t
    | Routing_to_exhausted : (turn_routing, turn_exhausted) t
    (* From Executing (5): retry-back / re-entry / compacting / completion. *)
    | Executing_to_prompting : (turn_executing, turn_prompting) t
    | Executing_to_routing : (turn_executing, turn_routing) t
    | Executing_to_compacting : (turn_executing, turn_compacting) t
    | Executing_to_finalizing : (turn_executing, turn_finalizing) t
    | Executing_to_exhausted : (turn_executing, turn_exhausted) t
    (* From Compacting (3): retry / completion / exhausted. *)
    | Compacting_to_prompting : (turn_compacting, turn_prompting) t
    | Compacting_to_finalizing : (turn_compacting, turn_finalizing) t
    | Compacting_to_exhausted : (turn_compacting, turn_exhausted) t
    (* From Finalizing (4): degraded retry across phases. *)
    | Finalizing_to_prompting : (turn_finalizing, turn_prompting) t
    | Finalizing_to_routing : (turn_finalizing, turn_routing) t
    | Finalizing_to_executing : (turn_finalizing, turn_executing) t
    | Finalizing_to_exhausted : (turn_finalizing, turn_exhausted) t
    (* From Exhausted (3): retry after compaction. *)
    | Exhausted_to_prompting : (turn_exhausted, turn_prompting) t
    | Exhausted_to_routing : (turn_exhausted, turn_routing) t
    | Exhausted_to_executing : (turn_exhausted, turn_executing) t

  type packed = Packed_transition : ('a, 'b) t -> packed

  let to_tag : type a b. (a, b) t -> string = function
    | Idle_to_prompting -> "idle->prompting"
    | Prompting_to_routing -> "prompting->routing"
    | Prompting_to_executing -> "prompting->executing"
    | Prompting_to_finalizing -> "prompting->finalizing"
    | Prompting_to_exhausted -> "prompting->exhausted"
    | Routing_to_prompting -> "routing->prompting"
    | Routing_to_executing -> "routing->executing"
    | Routing_to_exhausted -> "routing->exhausted"
    | Executing_to_prompting -> "executing->prompting"
    | Executing_to_routing -> "executing->routing"
    | Executing_to_compacting -> "executing->compacting"
    | Executing_to_finalizing -> "executing->finalizing"
    | Executing_to_exhausted -> "executing->exhausted"
    | Compacting_to_prompting -> "compacting->prompting"
    | Compacting_to_finalizing -> "compacting->finalizing"
    | Compacting_to_exhausted -> "compacting->exhausted"
    | Finalizing_to_prompting -> "finalizing->prompting"
    | Finalizing_to_routing -> "finalizing->routing"
    | Finalizing_to_executing -> "finalizing->executing"
    | Finalizing_to_exhausted -> "finalizing->exhausted"
    | Exhausted_to_prompting -> "exhausted->prompting"
    | Exhausted_to_routing -> "exhausted->routing"
    | Exhausted_to_executing -> "exhausted->executing"
  ;;
end

(* RFC-0072 Phase 4: typed error for turn_phase transition spec violations.
   Each of the 19 forbidden pairs has its own constructor; mirrors the
   cascade-side [cascade_transition_spec_violation] (PR #14903). *)
type turn_phase_transition_spec_violation =
  | Idle_to_routing
  | Idle_to_executing
  | Idle_to_compacting
  | Idle_to_finalizing
  | Idle_to_exhausted
  | Prompting_to_idle
  | Prompting_to_compacting
  | Routing_to_idle
  | Routing_to_compacting
  | Routing_to_finalizing
  | Executing_to_idle
  | Compacting_to_idle
  | Compacting_to_routing
  | Compacting_to_executing
  | Finalizing_to_idle
  | Finalizing_to_compacting
  | Exhausted_to_idle
  | Exhausted_to_compacting
  | Exhausted_to_finalizing

let turn_phase_transition_spec_violation_to_tag = function
  | Idle_to_routing -> "idle->routing"
  | Idle_to_executing -> "idle->executing"
  | Idle_to_compacting -> "idle->compacting"
  | Idle_to_finalizing -> "idle->finalizing"
  | Idle_to_exhausted -> "idle->exhausted"
  | Prompting_to_idle -> "prompting->idle"
  | Prompting_to_compacting -> "prompting->compacting"
  | Routing_to_idle -> "routing->idle"
  | Routing_to_compacting -> "routing->compacting"
  | Routing_to_finalizing -> "routing->finalizing"
  | Executing_to_idle -> "executing->idle"
  | Compacting_to_idle -> "compacting->idle"
  | Compacting_to_routing -> "compacting->routing"
  | Compacting_to_executing -> "compacting->executing"
  | Finalizing_to_idle -> "finalizing->idle"
  | Finalizing_to_compacting -> "finalizing->compacting"
  | Exhausted_to_idle -> "exhausted->idle"
  | Exhausted_to_compacting -> "exhausted->compacting"
  | Exhausted_to_finalizing -> "exhausted->finalizing"
;;

(* RFC-0072 Phase 5: typed exception for forbidden turn_phase transitions.
   Mirrors [Cascade_transition_violation] — the typed
   [turn_phase_transition_spec_violation] payload travels on the exception
   instead of through a string message. Raised by
   [validate_turn_phase_transition] / [set_turn_phase]. The registered
   [Printexc] printer reproduces the original message for generic catchers
   and log output. *)
exception
  Turn_phase_transition_violation of
    { where : string
    ; from : packed_turn_phase
    ; to_ : packed_turn_phase
    ; violation : turn_phase_transition_spec_violation
    }

let turn_phase_transition_violation_message ~where ~from ~to_ ~violation =
  Printf.sprintf
    "%s: invalid turn_phase transition %s -> %s (spec_violation=%s)"
    where
    (packed_turn_phase_label from)
    (packed_turn_phase_label to_)
    (turn_phase_transition_spec_violation_to_tag violation)
;;

let raise_turn_phase_transition_violation ~where ~from ~to_ ~violation =
  raise (Turn_phase_transition_violation { where; from; to_; violation })
;;

let () =
  Printexc.register_printer (function
    | Turn_phase_transition_violation { where; from; to_; violation } ->
      Some (turn_phase_transition_violation_message ~where ~from ~to_ ~violation)
    | _ -> None)
;;

(* RFC-0072 Phase 4: resolver mirroring [resolve_cascade_transition]. *)
type turn_phase_resolve_outcome =
  | Resolved_turn_transition of Turn_phase_transition.packed
  | Resolved_turn_idempotent
  | Resolved_turn_violation of turn_phase_transition_spec_violation

let resolve_turn_phase_transition
      ~(from : packed_turn_phase)
      ~(target : packed_turn_phase)
  : turn_phase_resolve_outcome
  =
  match from, target with
  (* Idempotent self-loops (7). *)
  | Packed Turn_idle, Packed Turn_idle
  | Packed Turn_prompting, Packed Turn_prompting
  | Packed Turn_routing, Packed Turn_routing
  | Packed Turn_executing, Packed Turn_executing
  | Packed Turn_compacting, Packed Turn_compacting
  | Packed Turn_finalizing, Packed Turn_finalizing
  | Packed Turn_exhausted, Packed Turn_exhausted -> Resolved_turn_idempotent
  (* Valid cross-state transitions (23). *)
  | Packed Turn_idle, Packed Turn_prompting ->
    Resolved_turn_transition (Turn_phase_transition.Packed_transition Idle_to_prompting)
  | Packed Turn_prompting, Packed Turn_routing ->
    Resolved_turn_transition
      (Turn_phase_transition.Packed_transition Prompting_to_routing)
  | Packed Turn_prompting, Packed Turn_executing ->
    Resolved_turn_transition
      (Turn_phase_transition.Packed_transition Prompting_to_executing)
  | Packed Turn_prompting, Packed Turn_finalizing ->
    Resolved_turn_transition
      (Turn_phase_transition.Packed_transition Prompting_to_finalizing)
  | Packed Turn_prompting, Packed Turn_exhausted ->
    Resolved_turn_transition
      (Turn_phase_transition.Packed_transition Prompting_to_exhausted)
  | Packed Turn_routing, Packed Turn_prompting ->
    Resolved_turn_transition
      (Turn_phase_transition.Packed_transition Routing_to_prompting)
  | Packed Turn_routing, Packed Turn_executing ->
    Resolved_turn_transition
      (Turn_phase_transition.Packed_transition Routing_to_executing)
  | Packed Turn_routing, Packed Turn_exhausted ->
    Resolved_turn_transition
      (Turn_phase_transition.Packed_transition Routing_to_exhausted)
  | Packed Turn_executing, Packed Turn_prompting ->
    Resolved_turn_transition
      (Turn_phase_transition.Packed_transition Executing_to_prompting)
  | Packed Turn_executing, Packed Turn_routing ->
    Resolved_turn_transition
      (Turn_phase_transition.Packed_transition Executing_to_routing)
  | Packed Turn_executing, Packed Turn_compacting ->
    Resolved_turn_transition
      (Turn_phase_transition.Packed_transition Executing_to_compacting)
  | Packed Turn_executing, Packed Turn_finalizing ->
    Resolved_turn_transition
      (Turn_phase_transition.Packed_transition Executing_to_finalizing)
  | Packed Turn_executing, Packed Turn_exhausted ->
    Resolved_turn_transition
      (Turn_phase_transition.Packed_transition Executing_to_exhausted)
  | Packed Turn_compacting, Packed Turn_prompting ->
    Resolved_turn_transition
      (Turn_phase_transition.Packed_transition Compacting_to_prompting)
  | Packed Turn_compacting, Packed Turn_finalizing ->
    Resolved_turn_transition
      (Turn_phase_transition.Packed_transition Compacting_to_finalizing)
  | Packed Turn_compacting, Packed Turn_exhausted ->
    Resolved_turn_transition
      (Turn_phase_transition.Packed_transition Compacting_to_exhausted)
  | Packed Turn_finalizing, Packed Turn_prompting ->
    Resolved_turn_transition
      (Turn_phase_transition.Packed_transition Finalizing_to_prompting)
  | Packed Turn_finalizing, Packed Turn_routing ->
    Resolved_turn_transition
      (Turn_phase_transition.Packed_transition Finalizing_to_routing)
  | Packed Turn_finalizing, Packed Turn_executing ->
    Resolved_turn_transition
      (Turn_phase_transition.Packed_transition Finalizing_to_executing)
  | Packed Turn_finalizing, Packed Turn_exhausted ->
    Resolved_turn_transition
      (Turn_phase_transition.Packed_transition Finalizing_to_exhausted)
  | Packed Turn_exhausted, Packed Turn_prompting ->
    Resolved_turn_transition
      (Turn_phase_transition.Packed_transition Exhausted_to_prompting)
  | Packed Turn_exhausted, Packed Turn_routing ->
    Resolved_turn_transition
      (Turn_phase_transition.Packed_transition Exhausted_to_routing)
  | Packed Turn_exhausted, Packed Turn_executing ->
    Resolved_turn_transition
      (Turn_phase_transition.Packed_transition Exhausted_to_executing)
  (* Spec violations (19). *)
  | Packed Turn_idle, Packed Turn_routing -> Resolved_turn_violation Idle_to_routing
  | Packed Turn_idle, Packed Turn_executing -> Resolved_turn_violation Idle_to_executing
  | Packed Turn_idle, Packed Turn_compacting -> Resolved_turn_violation Idle_to_compacting
  | Packed Turn_idle, Packed Turn_finalizing -> Resolved_turn_violation Idle_to_finalizing
  | Packed Turn_idle, Packed Turn_exhausted -> Resolved_turn_violation Idle_to_exhausted
  | Packed Turn_prompting, Packed Turn_idle -> Resolved_turn_violation Prompting_to_idle
  | Packed Turn_prompting, Packed Turn_compacting ->
    Resolved_turn_violation Prompting_to_compacting
  | Packed Turn_routing, Packed Turn_idle -> Resolved_turn_violation Routing_to_idle
  | Packed Turn_routing, Packed Turn_compacting ->
    Resolved_turn_violation Routing_to_compacting
  | Packed Turn_routing, Packed Turn_finalizing ->
    Resolved_turn_violation Routing_to_finalizing
  | Packed Turn_executing, Packed Turn_idle -> Resolved_turn_violation Executing_to_idle
  | Packed Turn_compacting, Packed Turn_idle -> Resolved_turn_violation Compacting_to_idle
  | Packed Turn_compacting, Packed Turn_routing ->
    Resolved_turn_violation Compacting_to_routing
  | Packed Turn_compacting, Packed Turn_executing ->
    Resolved_turn_violation Compacting_to_executing
  | Packed Turn_finalizing, Packed Turn_idle -> Resolved_turn_violation Finalizing_to_idle
  | Packed Turn_finalizing, Packed Turn_compacting ->
    Resolved_turn_violation Finalizing_to_compacting
  | Packed Turn_exhausted, Packed Turn_idle -> Resolved_turn_violation Exhausted_to_idle
  | Packed Turn_exhausted, Packed Turn_compacting ->
    Resolved_turn_violation Exhausted_to_compacting
  | Packed Turn_exhausted, Packed Turn_finalizing ->
    Resolved_turn_violation Exhausted_to_finalizing
;;
type decision_stage =
  | Decision_undecided [@tla.idle]
  | Decision_guard_ok [@tla.active]
  | Decision_gate_rejected [@tla.terminal]
  | Decision_tool_policy_selected [@tla.active]
[@@deriving tla]

type decision_undecided = |
type decision_guard_ok = |
type decision_gate_rejected = |
type decision_tool_policy_selected = |

type 'a decision_stage_witness =
  | Decision_undecided : decision_undecided decision_stage_witness
  | Decision_guard_ok : decision_guard_ok decision_stage_witness
  | Decision_gate_rejected : decision_gate_rejected decision_stage_witness
  | Decision_tool_policy_selected : decision_tool_policy_selected decision_stage_witness

type packed_decision_stage = Packed : 'a decision_stage_witness -> packed_decision_stage

let witness_to_stage : type a. a decision_stage_witness -> decision_stage = function
  | Decision_undecided -> Decision_undecided
  | Decision_guard_ok -> Decision_guard_ok
  | Decision_gate_rejected -> Decision_gate_rejected
  | Decision_tool_policy_selected -> Decision_tool_policy_selected
;;

let stage_to_witness : decision_stage -> packed_decision_stage = function
  | Decision_undecided -> Packed Decision_undecided
  | Decision_guard_ok -> Packed Decision_guard_ok
  | Decision_gate_rejected -> Packed Decision_gate_rejected
  | Decision_tool_policy_selected -> Packed Decision_tool_policy_selected
;;

(* Decision stages valid as ADVANCE targets within a turn.
   Excludes [Decision_undecided] (the initial state, set only by
   [mark_turn_started] / [mark_sdk_turn_started]).  The 3 spec-forbidden
   [<active>_to_undecided] transitions are unrepresentable through this
   type, replacing the prior runtime [invalid_arg] inside
   [set_turn_decision_stage]. *)
type decision_stage_active =
  | Decision_active_guard_ok
  | Decision_active_gate_rejected
  | Decision_active_tool_policy_selected

let decision_stage_active_to_packed : decision_stage_active -> packed_decision_stage =
  function
  | Decision_active_guard_ok -> Packed Decision_guard_ok
  | Decision_active_gate_rejected -> Packed Decision_gate_rejected
  | Decision_active_tool_policy_selected -> Packed Decision_tool_policy_selected
;;

(* Diagnostic label for invalid-transition error messages.  Mirrors
   [decision_stage]; constructor changes will fail compilation here. *)
let packed_decision_stage_label : packed_decision_stage -> string = function
  | Packed Decision_undecided -> "Decision_undecided"
  | Packed Decision_guard_ok -> "Decision_guard_ok"
  | Packed Decision_gate_rejected -> "Decision_gate_rejected"
  | Packed Decision_tool_policy_selected -> "Decision_tool_policy_selected"
;;

module Decision_transition = struct
  type ('from, 'to_) t =
    | Undecided_to_guard_ok : (decision_undecided, decision_guard_ok) t
    | Undecided_to_gate_rejected : (decision_undecided, decision_gate_rejected) t
    | Undecided_to_tool_policy_selected :
        (decision_undecided, decision_tool_policy_selected) t
    | Guard_ok_to_gate_rejected : (decision_guard_ok, decision_gate_rejected) t
    | Guard_ok_to_tool_policy_selected :
        (decision_guard_ok, decision_tool_policy_selected) t
    | Gate_rejected_to_guard_ok : (decision_gate_rejected, decision_guard_ok) t
    | Gate_rejected_to_tool_policy_selected :
        (decision_gate_rejected, decision_tool_policy_selected) t
    | Tool_policy_selected_to_guard_ok :
        (decision_tool_policy_selected, decision_guard_ok) t
    | Tool_policy_selected_to_gate_rejected :
        (decision_tool_policy_selected, decision_gate_rejected) t

  let to_tag : type a b. (a, b) t -> string = function
    | Undecided_to_guard_ok -> "undecided->guard_ok"
    | Undecided_to_gate_rejected -> "undecided->gate_rejected"
    | Undecided_to_tool_policy_selected -> "undecided->tool_policy_selected"
    | Guard_ok_to_gate_rejected -> "guard_ok->gate_rejected"
    | Guard_ok_to_tool_policy_selected -> "guard_ok->tool_policy_selected"
    | Gate_rejected_to_guard_ok -> "gate_rejected->guard_ok"
    | Gate_rejected_to_tool_policy_selected -> "gate_rejected->tool_policy_selected"
    | Tool_policy_selected_to_guard_ok -> "tool_policy_selected->guard_ok"
    | Tool_policy_selected_to_gate_rejected -> "tool_policy_selected->gate_rejected"
  ;;
end

(* Living-matrix documentation of the decision-stage transition relation.
   Forbidden [<active>_to_undecided] pairs are unrepresentable through
   the [decision_stage_active] target type (PR #14887 made
   [set_turn_decision_stage] reject them at compile time; this
   validator mirrors that invariant at the test surface).

   We pattern-match on the raw [decision_stage] / [decision_stage_active]
   variants — *not* on the packed GADT witnesses returned by
   [stage_to_witness] / [decision_stage_active_to_packed].  The packed
   wrappers existentially quantify away the witness phantom, after
   which the compiler can no longer see that [decision_stage_active]
   has no [Decision_active_undecided] constructor; Warning 8 then
   spuriously demands the unreachable [(Packed Decision_undecided,
   Packed Decision_undecided)] case (regression introduced by #14893).

   By matching directly on the source variants the exhaustiveness
   check ranges over the *actual* input domain: 4 [decision_stage]
   sources × 3 [decision_stage_active] targets = 12 admitted pairs,
   no false-positive cases.  Adding a new [decision_stage] or
   [decision_stage_active] constructor still fails Warning 8 here,
   preserving the original tripwire intent. *)
let validate_decision_transition ~(from : decision_stage) ~(to_ : decision_stage_active) =
  match from, to_ with
  | Decision_undecided, Decision_active_guard_ok -> ()
  | Decision_undecided, Decision_active_gate_rejected -> ()
  | Decision_undecided, Decision_active_tool_policy_selected -> ()
  | Decision_guard_ok, Decision_active_guard_ok -> ()
  | Decision_guard_ok, Decision_active_gate_rejected -> ()
  | Decision_guard_ok, Decision_active_tool_policy_selected -> ()
  | Decision_gate_rejected, Decision_active_guard_ok -> ()
  | Decision_gate_rejected, Decision_active_gate_rejected -> ()
  | Decision_gate_rejected, Decision_active_tool_policy_selected -> ()
  | Decision_tool_policy_selected, Decision_active_guard_ok -> ()
  | Decision_tool_policy_selected, Decision_active_gate_rejected -> ()
  | Decision_tool_policy_selected, Decision_active_tool_policy_selected -> ()
;;

type cascade_state =
  | Cascade_idle [@tla.idle]
  | Cascade_selecting [@tla.active]
  | Cascade_trying [@tla.active]
  | Cascade_done [@tla.terminal]
  | Cascade_exhausted [@tla.terminal]
[@@deriving tla]

(* Phantom witness types for cascade_state GADT (Tier B5 pattern). *)
type cascade_idle = |
type cascade_selecting = |
type cascade_trying = |
type cascade_done = |
type cascade_exhausted = |

type 'a cascade_state_witness =
  | Cascade_idle : cascade_idle cascade_state_witness
  | Cascade_selecting : cascade_selecting cascade_state_witness
  | Cascade_trying : cascade_trying cascade_state_witness
  | Cascade_done : cascade_done cascade_state_witness
  | Cascade_exhausted : cascade_exhausted cascade_state_witness

type packed_cascade_state = Packed : 'a cascade_state_witness -> packed_cascade_state

let cascade_state_to_witness : cascade_state -> packed_cascade_state = function
  | Cascade_idle -> Packed Cascade_idle
  | Cascade_selecting -> Packed Cascade_selecting
  | Cascade_trying -> Packed Cascade_trying
  | Cascade_done -> Packed Cascade_done
  | Cascade_exhausted -> Packed Cascade_exhausted
;;

let witness_to_cascade_state : packed_cascade_state -> cascade_state = function
  | Packed Cascade_idle -> Cascade_idle
  | Packed Cascade_selecting -> Cascade_selecting
  | Packed Cascade_trying -> Cascade_trying
  | Packed Cascade_done -> Cascade_done
  | Packed Cascade_exhausted -> Cascade_exhausted
;;

(* Diagnostic label for invalid-transition error messages.  Mirrors
   [cascade_state]; constructor changes will fail compilation here. *)
let packed_cascade_state_label : packed_cascade_state -> string = function
  | Packed Cascade_idle -> "Cascade_idle"
  | Packed Cascade_selecting -> "Cascade_selecting"
  | Packed Cascade_trying -> "Cascade_trying"
  | Packed Cascade_done -> "Cascade_done"
  | Packed Cascade_exhausted -> "Cascade_exhausted"
;;

(* RFC-0072 Phase 1: GADT-encoded cascade transitions.

   Enumerates the 13 valid cross-state transitions of the 5-variant
   [cascade_state] FSM.  Idempotent (self-loop) transitions are
   intentionally not represented — mirrors [Decision_transition] —
   because they correspond to no-op writes at the mutator boundary.

   The 7 forbidden pairs ([Idle -> Trying/Done/Exhausted],
   [Selecting -> Done/Exhausted], [Done <-> Exhausted]) have no
   constructor and are therefore type-unrepresentable.  Adding a new
   [cascade_state] variant will trigger Warning 8 in [to_tag] and in
   any future per-transition dispatcher.

   Phase 1 (this PR) introduces the module additively — no caller is
   wired yet.  Phase 2 routes [set_turn_cascade_state] through
   [resolve_cascade_transition] for internal dispatch.  Phase 3
   converts [validate_cascade_transition] into a compile-time
   fixture (mirroring PR #14893 for decision). *)
module Cascade_transition = struct
  type ('from, 'to_) t =
    (* Boot dispatch (Idle -> Selecting). *)
    | Idle_to_selecting : (cascade_idle, cascade_selecting) t
    (* Selecting -> {Idle, Trying} (retry-back or forward dispatch). *)
    | Selecting_to_idle : (cascade_selecting, cascade_idle) t
    | Selecting_to_trying : (cascade_selecting, cascade_trying) t
    (* Trying -> {Idle, Selecting, Done, Exhausted}: retry-back,
       re-entry, completion, exhaustion. *)
    | Trying_to_idle : (cascade_trying, cascade_idle) t
    | Trying_to_selecting : (cascade_trying, cascade_selecting) t
    | Trying_to_done : (cascade_trying, cascade_done) t
    | Trying_to_exhausted : (cascade_trying, cascade_exhausted) t
    (* Compaction-driven retry from terminal states.
       prepare_turn_retry_after_compaction lifts Done/Exhausted back
       into Idle/Selecting/Trying. *)
    | Done_to_idle : (cascade_done, cascade_idle) t
    | Done_to_selecting : (cascade_done, cascade_selecting) t
    | Done_to_trying : (cascade_done, cascade_trying) t
    | Exhausted_to_idle : (cascade_exhausted, cascade_idle) t
    | Exhausted_to_selecting : (cascade_exhausted, cascade_selecting) t
    | Exhausted_to_trying : (cascade_exhausted, cascade_trying) t

  type packed = Packed_transition : ('a, 'b) t -> packed

  let to_tag : type a b. (a, b) t -> string = function
    | Idle_to_selecting -> "idle->selecting"
    | Selecting_to_idle -> "selecting->idle"
    | Selecting_to_trying -> "selecting->trying"
    | Trying_to_idle -> "trying->idle"
    | Trying_to_selecting -> "trying->selecting"
    | Trying_to_done -> "trying->done"
    | Trying_to_exhausted -> "trying->exhausted"
    | Done_to_idle -> "done->idle"
    | Done_to_selecting -> "done->selecting"
    | Done_to_trying -> "done->trying"
    | Exhausted_to_idle -> "exhausted->idle"
    | Exhausted_to_selecting -> "exhausted->selecting"
    | Exhausted_to_trying -> "exhausted->trying"
  ;;
end

(* RFC-0072 Phase 1: typed error for cascade transition spec violations.

   Replaces the prior string-formatted [Invalid_argument] message at
   [validate_cascade_transition].  Each forbidden pair has its own
   constructor — adding a future forbidden pair (or downgrading an
   admitted pair to forbidden) is a deliberate type-level commit, not
   a substring of an error message.  Idempotent self-loops are
   classified [Idempotent_no_op] (admitted by the mutator boundary
   but not a Cascade_transition.t value). *)
type cascade_transition_spec_violation =
  | Idle_to_trying
  | Idle_to_done
  | Idle_to_exhausted
  | Selecting_to_done
  | Selecting_to_exhausted
  | Done_to_exhausted
  | Exhausted_to_done

let cascade_transition_spec_violation_to_tag = function
  | Idle_to_trying -> "idle->trying"
  | Idle_to_done -> "idle->done"
  | Idle_to_exhausted -> "idle->exhausted"
  | Selecting_to_done -> "selecting->done"
  | Selecting_to_exhausted -> "selecting->exhausted"
  | Done_to_exhausted -> "done->exhausted"
  | Exhausted_to_done -> "exhausted->done"
;;

(* RFC-0072 Phase 5: typed exception for forbidden cascade transitions.
   Replaces the prior [invalid_arg (Printf.sprintf ...)] at
   [validate_cascade_transition] / [set_turn_cascade_state] — the typed
   [cascade_transition_spec_violation] payload now travels on the exception
   instead of being projected through a string, so callers (and the test
   surface) can pattern-match on the violation directly. The [where] field
   is a diagnostic-only label naming the raising function for parity with
   the prior message. A [Printexc] printer is registered below so logging
   that catches a generic [exn] still produces the original message text. *)
exception
  Cascade_transition_violation of
    { where : string
    ; from : packed_cascade_state
    ; to_ : packed_cascade_state
    ; violation : cascade_transition_spec_violation
    }

let cascade_transition_violation_message ~where ~from ~to_ ~violation =
  Printf.sprintf
    "%s: invalid cascade transition %s -> %s (spec_violation=%s)"
    where
    (packed_cascade_state_label from)
    (packed_cascade_state_label to_)
    (cascade_transition_spec_violation_to_tag violation)
;;

let raise_cascade_transition_violation ~where ~from ~to_ ~violation =
  raise (Cascade_transition_violation { where; from; to_; violation })
;;

let () =
  Printexc.register_printer (function
    | Cascade_transition_violation { where; from; to_; violation } ->
      Some (cascade_transition_violation_message ~where ~from ~to_ ~violation)
    | _ -> None)
;;

(* RFC-0072 Phase 1: resolve a (from, target) packed pair to a typed
   transition value.

   - [Ok (Packed_transition t)] when the pair matches a Cascade_transition.t
     constructor (13 valid cross-state pairs).
   - [Ok Packed_transition Idle_to_selecting] etc do NOT cover idempotent
     self-loops — those return [Error] with no spec violation (they are a
     mutator-boundary concern, not a transition).  Callers that need
     idempotent handling should check [from = target] before calling.
   - [Error spec_violation] for the 7 forbidden cross-state pairs.

   Self-loops are deliberately not in the GADT.  This function distinguishes
   them via a separate [`Idempotent] return tag below to keep Result.t
   semantically clean (Ok = transition value exists, Error = spec violation).

   Phase 2 will use this to replace the [validate_cascade_transition] call
   inside [set_turn_cascade_state]. *)
type cascade_resolve_outcome =
  | Resolved_transition of Cascade_transition.packed
  | Resolved_idempotent
  | Resolved_violation of cascade_transition_spec_violation

let resolve_cascade_transition
      ~(from : packed_cascade_state)
      ~(target : packed_cascade_state)
  : cascade_resolve_outcome
  =
  match from, target with
  (* Idempotent self-loops (5). *)
  | Packed Cascade_idle, Packed Cascade_idle
  | Packed Cascade_selecting, Packed Cascade_selecting
  | Packed Cascade_trying, Packed Cascade_trying
  | Packed Cascade_done, Packed Cascade_done
  | Packed Cascade_exhausted, Packed Cascade_exhausted -> Resolved_idempotent
  (* Valid cross-state transitions (13). *)
  | Packed Cascade_idle, Packed Cascade_selecting ->
    Resolved_transition (Cascade_transition.Packed_transition Idle_to_selecting)
  | Packed Cascade_selecting, Packed Cascade_idle ->
    Resolved_transition (Cascade_transition.Packed_transition Selecting_to_idle)
  | Packed Cascade_selecting, Packed Cascade_trying ->
    Resolved_transition (Cascade_transition.Packed_transition Selecting_to_trying)
  | Packed Cascade_trying, Packed Cascade_idle ->
    Resolved_transition (Cascade_transition.Packed_transition Trying_to_idle)
  | Packed Cascade_trying, Packed Cascade_selecting ->
    Resolved_transition (Cascade_transition.Packed_transition Trying_to_selecting)
  | Packed Cascade_trying, Packed Cascade_done ->
    Resolved_transition (Cascade_transition.Packed_transition Trying_to_done)
  | Packed Cascade_trying, Packed Cascade_exhausted ->
    Resolved_transition (Cascade_transition.Packed_transition Trying_to_exhausted)
  | Packed Cascade_done, Packed Cascade_idle ->
    Resolved_transition (Cascade_transition.Packed_transition Done_to_idle)
  | Packed Cascade_done, Packed Cascade_selecting ->
    Resolved_transition (Cascade_transition.Packed_transition Done_to_selecting)
  | Packed Cascade_done, Packed Cascade_trying ->
    Resolved_transition (Cascade_transition.Packed_transition Done_to_trying)
  | Packed Cascade_exhausted, Packed Cascade_idle ->
    Resolved_transition (Cascade_transition.Packed_transition Exhausted_to_idle)
  | Packed Cascade_exhausted, Packed Cascade_selecting ->
    Resolved_transition (Cascade_transition.Packed_transition Exhausted_to_selecting)
  | Packed Cascade_exhausted, Packed Cascade_trying ->
    Resolved_transition (Cascade_transition.Packed_transition Exhausted_to_trying)
  (* Spec violations (7). *)
  | Packed Cascade_idle, Packed Cascade_trying -> Resolved_violation Idle_to_trying
  | Packed Cascade_idle, Packed Cascade_done -> Resolved_violation Idle_to_done
  | Packed Cascade_idle, Packed Cascade_exhausted -> Resolved_violation Idle_to_exhausted
  | Packed Cascade_selecting, Packed Cascade_done -> Resolved_violation Selecting_to_done
  | Packed Cascade_selecting, Packed Cascade_exhausted ->
    Resolved_violation Selecting_to_exhausted
  | Packed Cascade_done, Packed Cascade_exhausted -> Resolved_violation Done_to_exhausted
  | Packed Cascade_exhausted, Packed Cascade_done -> Resolved_violation Exhausted_to_done
;;

type compaction_stage =
  | Compaction_accumulating [@tla.idle]
  | Compaction_compacting [@tla.active]
  | Compaction_done [@tla.terminal]
[@@deriving tla]

(* Phantom witness types for compaction_stage GADT (Tier B5 pattern). *)
type compaction_accumulating = |
type compaction_compacting = |
type compaction_done = |

type 'a compaction_stage_witness =
  | Compaction_accumulating : compaction_accumulating compaction_stage_witness
  | Compaction_compacting : compaction_compacting compaction_stage_witness
  | Compaction_done : compaction_done compaction_stage_witness

type packed_compaction_stage =
  | Packed : 'a compaction_stage_witness -> packed_compaction_stage

let compaction_stage_to_witness : compaction_stage -> packed_compaction_stage = function
  | Compaction_accumulating -> Packed Compaction_accumulating
  | Compaction_compacting -> Packed Compaction_compacting
  | Compaction_done -> Packed Compaction_done
;;

let witness_to_compaction_stage : packed_compaction_stage -> compaction_stage = function
  | Packed Compaction_accumulating -> Compaction_accumulating
  | Packed Compaction_compacting -> Compaction_compacting
  | Packed Compaction_done -> Compaction_done
;;

(* Diagnostic label using the constructor name (e.g. ["Compaction_done"]).
   Used by the [Compaction_transition_violation] [Printexc] printer.
   Distinct from [Keeper_composite_observer.compaction_stage_to_string]
   which emits a snake_case form for dashboards. *)
let packed_compaction_stage_label : packed_compaction_stage -> string = function
  | Packed Compaction_accumulating -> "Compaction_accumulating"
  | Packed Compaction_compacting -> "Compaction_compacting"
  | Packed Compaction_done -> "Compaction_done"
;;

(* RFC-0072 Phase 6: typed error for forbidden compaction-stage transitions.
   One constructor per of the 3 forbidden pairs in the compaction matrix
   (3 idempotent + 3 valid cross-state + 3 forbidden = 9 = 3×3).  Mirrors
   [cascade_transition_spec_violation] / [turn_phase_transition_spec_violation];
   smaller because the compaction axis has only 3 states. *)
type compaction_transition_spec_violation =
  | Accumulating_to_done
  | Done_to_accumulating
  | Done_to_compacting

let compaction_transition_spec_violation_to_tag = function
  | Accumulating_to_done -> "accumulating->done"
  | Done_to_accumulating -> "done->accumulating"
  | Done_to_compacting -> "done->compacting"
;;

(* RFC-0072 Phase 6: typed exception for forbidden compaction transitions.
   Replaces the prior bare [assert (match ... -> bool)] inside
   [validate_compaction_transition], whose [Assert_failure] carried only a
   file/line — not the rejected (from, to) pair.  Mirrors
   [Cascade_transition_violation] / [Turn_phase_transition_violation]:
   the typed [compaction_transition_spec_violation] payload travels on the
   exception, and a [Printexc] printer renders the labelled message. *)
exception
  Compaction_transition_violation of
    { where : string
    ; from : packed_compaction_stage
    ; to_ : packed_compaction_stage
    ; violation : compaction_transition_spec_violation
    }

let compaction_transition_violation_message ~where ~from ~to_ ~violation =
  Printf.sprintf
    "%s: invalid compaction transition %s -> %s (spec_violation=%s)"
    where
    (packed_compaction_stage_label from)
    (packed_compaction_stage_label to_)
    (compaction_transition_spec_violation_to_tag violation)
;;

let raise_compaction_transition_violation ~where ~from ~to_ ~violation =
  raise (Compaction_transition_violation { where; from; to_; violation })
;;

let () =
  Printexc.register_printer (function
    | Compaction_transition_violation { where; from; to_; violation } ->
      Some (compaction_transition_violation_message ~where ~from ~to_ ~violation)
    | _ -> None)
;;

type turn_measurement =
  { tm_captured_at : float
  ; tm_auto_rules : Keeper_state_machine.auto_rule_summary
  }

type registry_entry =
  { base_path : string
  ; name : string
  ; meta : keeper_meta
  ; phase : Keeper_state_machine.phase
    (** Keeper lifecycle phase (RFC-0002 13-state machine; 11 at #5229 → 12 Overflowed (MASC-1) → 13 Zombie #14707). *)
  ; conditions : Keeper_state_machine.conditions
    (** Observable conditions that derive [phase]. *)
  ; fiber_stop : bool Atomic.t
  ; fiber_wakeup : bool Atomic.t
  ; event_queue : Keeper_event_queue.t Atomic.t
  ; started_at : float
  ; grpc_close : (unit -> unit) option Atomic.t
  ; done_p : [ `Stopped | `Crashed of string ] Eio.Promise.t
  ; done_r : [ `Stopped | `Crashed of string ] Eio.Promise.u
  ; restart_count : int
  ; last_restart_ts : float
  ; dead_since_ts : float option
  ; crash_log : (float * string) list
  ; last_error : string option
  ; last_failure_reason : failure_reason option
  ; turn_consecutive_failures : int
  ; last_agent_count : int
  ; board_wakeups : float StringMap.t
  ; board_cursor_ts : float
  ; board_cursor_post_id : string option
  ; tool_usage : tool_call_entry StringMap.t
  ; transition_seq : int
  ; waiting_for_inference : bool Atomic.t
    (** Ephemeral flag: true when keeper is blocked in admission queue.
          Set/cleared around [Admission_queue.with_permit].
          Does not affect state machine phase derivation. *)
  ; last_auto_rules : (float * Keeper_state_machine.auto_rule_summary) option
  ; last_event_bus_correlation : string option
  ; pending_turn_measurement : turn_measurement option
  ; current_turn_observation : turn_observation option
  ; last_completed_turn : completed_turn_observation option
  ; last_skip_observation : (float * string list) option
  ; compaction_stage : packed_compaction_stage
  }

and turn_observation =
  { turn_id : int
  ; started_at : float
  ; turn_phase : packed_turn_phase
  ; decision_stage : packed_decision_stage
  ; cascade_state : packed_cascade_state
  ; measurement : turn_measurement option
  ; measurement_bind_count : int
  ; selected_model : string option
  }

and completed_turn_observation =
  { ct_turn_id : int
  ; ct_started_at : float
  ; ct_ended_at : float
  ; ct_decision_stage : packed_decision_stage
  ; ct_cascade_state : packed_cascade_state
  ; ct_selected_model : string option
  }

