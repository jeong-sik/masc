(** Keeper_registry_types — pure type definitions extracted from
    Keeper_registry (3041 LoC godfile).

    See keeper_registry_types.mli for rationale and contract. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
module StringMap = Set_util.StringMap

(* Failure reason types and kill-class re-exports extracted to
   [Keeper_registry_types_failure] (godfile decomp). *)
include Keeper_registry_types_failure

exception Operator_interrupt

(* Turn_phase FSM types, witnesses, transitions, and resolver extracted to
   [Keeper_registry_types_turn_phase] (500-line decomp). *)
include Keeper_registry_types_turn_phase
(* Decision_stage FSM types, witnesses, and transitions extracted to
   [Keeper_registry_types_decision] (500-line decomp). *)
include Keeper_registry_types_decision

(* Compaction-stage (KMC) FSM types, witnesses, transitions, and spec
   violations re-homed to [Keeper_registry_types_compaction] (RFC-0206). The
   runtime selection FSM that shared the deleted [Keeper_registry_types_runtime]
   module is removed — single-binding Runtime has no Selecting/Trying loop; turn
   lifecycle is the surviving [turn_phase] FSM. *)
include Keeper_registry_types_compaction

(* The root interface still exposes the ppx_tla helpers generated for the
   re-exported [compaction_stage] type. Keep those aliases explicit so the
   keeper aggregate remains compatible while the implementation delegates the
   FSM body to [Keeper_registry_types_compaction]. *)
let to_tla_symbol (stage : compaction_stage) =
  match stage with
  | Compaction_accumulating -> "compaction_accumulating"
  | Compaction_compacting -> "compaction_compacting"
  | Compaction_done -> "compaction_done"
;;

let all_states : compaction_stage list =
  [ Compaction_accumulating; Compaction_compacting; Compaction_done ]
;;

let all_symbols = List.map to_tla_symbol all_states
let terminal_symbols = [ to_tla_symbol Compaction_done ]
let active_symbols = [ to_tla_symbol Compaction_compacting ]
let idle_symbols = [ to_tla_symbol Compaction_accumulating ]

let is_terminal (stage : compaction_stage) =
  match stage with
  | Compaction_done -> true
  | Compaction_accumulating | Compaction_compacting -> false
;;

let is_active (stage : compaction_stage) =
  match stage with
  | Compaction_compacting -> true
  | Compaction_accumulating | Compaction_done -> false
;;

let is_idle (stage : compaction_stage) =
  match stage with
  | Compaction_accumulating -> true
  | Compaction_compacting | Compaction_done -> false
;;

type livelock_attempt_state =
  { turn_id : int
  ; attempts : int
  ; first_started_at : float
  }

type turn_measurement =
  { tm_captured_at : float
  ; tm_auto_rules : Keeper_state_machine.auto_rule_summary
  }

type done_resolution = [ `Stopped | `Crashed of string ]

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
  ; done_p : done_resolution Eio.Promise.t
  ; done_r : done_resolution Eio.Promise.u
  ; restart_count : int
  ; last_restart_ts : float
  ; dead_since_ts : float option
  ; crash_log : (float * string) list
  ; last_error : string option
  ; last_failure_reason : failure_reason option
  ; turn_consecutive_failures : int
  ; livelock_state : livelock_attempt_state option Atomic.t
  ; current_turn_switch : Eio.Switch.t option Atomic.t
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
  ; last_progress_at : float
  ; last_progress_kind : string option
  ; active_tool_count : int
  ; turn_phase : packed_turn_phase
  ; decision_stage : packed_decision_stage
  ; measurement : turn_measurement option
  ; measurement_bind_count : int
  ; selected_model : string option
  }

and completed_turn_observation =
  { ct_turn_id : int
  ; ct_started_at : float
  ; ct_ended_at : float
  ; ct_decision_stage : packed_decision_stage
  ; ct_selected_model : string option
  }

type done_resolve_result =
  | Done_resolved of { source : string }
  | Done_already_resolved of
      { source : string
      ; previous : done_resolution
      }

type registry_entry_health =
  | Healthy
  | Meta_validation_failed of { reason : string }
  | Required_field_missing of { field : string }
  | Base_path_mismatch of { expected : string; actual : string }
  | Name_mismatch of { expected : string; actual : string }

type registry_entry_validation_error = registry_entry_health

let resolve_done entry ~source (value : done_resolution) =
  match Eio.Promise.peek entry.done_p with
  | Some previous -> Done_already_resolved { source; previous }
  | None ->
    (try
       Eio.Promise.resolve entry.done_r value;
       Done_resolved { source }
     with
     | Invalid_argument _ ->
       let previous =
         match Eio.Promise.peek entry.done_p with
         | Some previous -> previous
         | None -> value
       in
       Done_already_resolved { source; previous })
;;

let registry_key ~base_path name =
  if String.contains name '\x1f'
  then invalid_arg (Printf.sprintf "keeper name contains unit separator: %s" name);
  base_path ^ "\x1f" ^ name
;;

let registry_key_parts key =
  match String.rindex_opt key '\x1f' with
  | None -> Error (Printf.sprintf "malformed registry key: %S" key)
  | Some idx ->
    let key_len = String.length key in
    let base_path = String.sub key 0 idx in
    let name = String.sub key (idx + 1) (key_len - idx - 1) in
    Ok (base_path, name)
;;

let completed_turn_outcome_of_observation (obs : turn_observation)
  : Keeper_transition_audit.completed_turn_outcome
  =
  (* RFC-0206: the runtime selection FSM was removed; turn substantiveness is
     now read off the surviving [turn_phase] projection. Terminal
     [Turn_finalizing] (the phase the deleted [turn_phase_of_runtime_state]
     mapped [Runtime_done] onto) = substantive; every other phase = failed.
     Exhaustive match (no wildcard) so a new turn_phase or decision_stage
     variant fails the build rather than silently degrading to Turn_failed. *)
  match obs.decision_stage with
  | Packed Decision_gate_rejected -> Keeper_transition_audit.Turn_gate_rejected
  | Packed (Decision_undecided | Decision_guard_ok | Decision_tool_policy_selected) ->
    (match obs.turn_phase with
     | Packed Turn_finalizing -> Keeper_transition_audit.Turn_substantive
     | Packed Turn_idle
     | Packed Turn_prompting
     | Packed Turn_routing
     | Packed Turn_executing
     | Packed Turn_compacting
     | Packed Turn_exhausted -> Keeper_transition_audit.Turn_failed)
;;

(* RFC-0002 Event Dispatch — lifecycle_event_origin type + pure helpers. *)
type lifecycle_event_origin =
  | Generic_dispatch
  | Post_turn_lifecycle
  | Operator_compact

let lifecycle_event_origin_to_string = function
  | Generic_dispatch -> "generic_dispatch"
  | Post_turn_lifecycle -> "post_turn_lifecycle"
  | Operator_compact -> "operator_compact"
;;

let is_paired_lifecycle_event = function
  | Keeper_state_machine.Compaction_started
  | Keeper_state_machine.Compaction_completed _
  | Keeper_state_machine.Compaction_failed _
  | Keeper_state_machine.Handoff_started
  | Keeper_state_machine.Handoff_completed _
  | Keeper_state_machine.Handoff_failed _ -> true
  | _ -> false
;;

let origin_allows_paired_lifecycle_event origin event =
  (* This guard only constrains paired lifecycle events (compaction +
     handoff half-events). For any other event the gate is outside its
     domain and returns true unconditionally — the caller's question
     does not apply. *)
  if not (is_paired_lifecycle_event event) then true
  else
    (* Outer match is exhaustive on [lifecycle_event_origin] so adding a
       new origin variant forces an explicit arm here instead of silently
       inheriting the previous [_, _ -> true] default-allow catch-all,
       which was the FSM-sparse-match anti-pattern called out in
       instructions/software-development.md §4. *)
    match origin with
    | Post_turn_lifecycle -> true
    | Generic_dispatch -> false
    | Operator_compact ->
      (* Operator_compact authorizes only compaction half-events;
         handoff half-events flow through other origins. *)
      (match event with
       | Keeper_state_machine.Compaction_started
       | Keeper_state_machine.Compaction_completed _
       | Keeper_state_machine.Compaction_failed _ -> true
       | _ -> false)
;;

let pending_measurement_after_event now entry event =
  match event with
  | Keeper_state_machine.Context_measured { auto_rules; _ } ->
    Some { tm_captured_at = now; tm_auto_rules = auto_rules }
  | _ -> entry.pending_turn_measurement
;;

let compaction_stage_of_event entry event =
  match event with
  | Keeper_state_machine.Compaction_started
  | Keeper_state_machine.Auto_compact_triggered
  | Keeper_state_machine.Operator_compact_requested -> Packed Compaction_compacting
  | Keeper_state_machine.Compaction_completed _ -> Packed Compaction_done
  | Keeper_state_machine.Compaction_failed _ -> Packed Compaction_accumulating
  | _ -> entry.compaction_stage
;;
