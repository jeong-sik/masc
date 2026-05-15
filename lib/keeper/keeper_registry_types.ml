(** Keeper_registry_types — pure type definitions extracted from
    Keeper_registry (3041 LoC godfile).

    See keeper_registry_types.mli for rationale and contract. *)

open Keeper_types

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
