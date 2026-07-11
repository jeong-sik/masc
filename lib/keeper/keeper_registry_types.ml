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
exception Shutdown_interrupt

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

(* #16 (38-bug campaign PR-5): see .mli for rationale. *)
type wake_reason =
  | Proactive_tick
  | Woken of Keeper_event_queue.stimulus_payload list

let wake_reason_label = function
  | Proactive_tick -> "proactive_tick"
  | Woken _ -> "woken"
;;

type turn_measurement =
  { tm_captured_at : float
  ; tm_context_actions : Keeper_state_machine.context_actions
  }

type done_resolution = [ `Stopped | `Crashed of string ]

type fiber_lifecycle_state =
  | Fiber_not_started
  | Fiber_running
  | Fiber_exited

type fiber_launch_claim_result =
  | Fiber_launch_claimed
  | Fiber_launch_already_running
  | Fiber_launch_already_exited

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
  ; fiber_exited_p : unit Eio.Promise.t
  ; fiber_exited_r : unit Eio.Promise.u
  ; fiber_lifecycle_state : fiber_lifecycle_state Atomic.t
  ; restart_count : int
  ; last_restart_ts : float
  ; dead_since_ts : float option
  ; crash_log : (float * string) list
  ; last_error : string option
  ; last_failure_reason : failure_reason option
  ; turn_consecutive_failures : int
  ; livelock_state : livelock_attempt_state option Atomic.t
  ; current_turn_switch : Eio.Switch.t option Atomic.t
  ; shutdown_state : Keeper_shutdown_types.state Atomic.t
  ; shutdown_transaction_claimed : bool Atomic.t
  ; board_wakeups : float StringMap.t
  ; board_cursor_ts : float
  ; board_cursor_post_id : string option
  ; tool_usage : tool_call_entry StringMap.t
  ; transition_seq : int
  ; waiting_for_inference : bool Atomic.t
    (** Ephemeral flag: true when keeper is blocked in admission queue.
          Set/cleared around [Admission_queue.with_permit].
          Does not affect state machine phase derivation. *)
  ; last_context_actions : (float * Keeper_state_machine.context_actions) option
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
  ; wake : wake_reason
  }

and completed_turn_observation =
  { ct_turn_id : int
  ; ct_started_at : float
  ; ct_ended_at : float
  ; ct_decision_stage : packed_decision_stage
  ; ct_selected_model : string option
  ; ct_wake : wake_reason
  }

type shutdown_begin_result =
  | Shutdown_started
  | Shutdown_already_started of Keeper_shutdown_types.turn_settlement

type shutdown_state_error =
  | Shutdown_not_requested
  | Shutdown_turn_mismatch of
      { expected_turn_id : int
      ; actual_turn_id : int
      }
  | Shutdown_turn_already_settled of { turn_id : int }

type shutdown_interrupt_result =
  | Shutdown_no_turn_in_flight
  | Shutdown_turn_interrupted of { turn_id : int }
  | Shutdown_turn_interrupt_pending of { turn_id : int }
  | Shutdown_turn_state_error of shutdown_state_error

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

let resolve_fiber_exited entry =
  Atomic.set entry.fiber_lifecycle_state Fiber_exited;
  match Eio.Promise.peek entry.fiber_exited_p with
  | Some () -> false
  | None ->
    (try
       Eio.Promise.resolve entry.fiber_exited_r ();
       true
     with
     | Invalid_argument _ -> false)
;;

let await_fiber_exit entry = Eio.Promise.await entry.fiber_exited_p

let rec claim_fiber_launch entry =
  let current = Atomic.get entry.fiber_lifecycle_state in
  match current with
  | Fiber_not_started ->
    if Atomic.compare_and_set entry.fiber_lifecycle_state current Fiber_running
    then Fiber_launch_claimed
    else claim_fiber_launch entry
  | Fiber_running -> Fiber_launch_already_running
  | Fiber_exited -> Fiber_launch_already_exited
;;

let rec settle_unlaunched_fiber_exit entry =
  let current = Atomic.get entry.fiber_lifecycle_state in
  match current with
  | Fiber_not_started ->
    if Atomic.compare_and_set entry.fiber_lifecycle_state current Fiber_exited
    then (
      let (_was_first_resolver : bool) = resolve_fiber_exited entry in
      true)
    else settle_unlaunched_fiber_exit entry
  | Fiber_running | Fiber_exited -> false
;;

let try_claim_shutdown_transaction entry =
  Atomic.compare_and_set entry.shutdown_transaction_claimed false true
;;

let release_shutdown_transaction entry =
  Atomic.set entry.shutdown_transaction_claimed false
;;

let rec begin_shutdown entry =
  let current = Atomic.get entry.shutdown_state in
  match current with
  | Keeper_shutdown_types.Not_requested ->
    let requested =
      Keeper_shutdown_types.Requested Keeper_shutdown_types.No_interrupted_turn
    in
    if Atomic.compare_and_set entry.shutdown_state current requested
    then Shutdown_started
    else begin_shutdown entry
  | Keeper_shutdown_types.Requested settlement ->
    Shutdown_already_started settlement
;;

let shutdown_requested entry =
  match Atomic.get entry.shutdown_state with
  | Keeper_shutdown_types.Not_requested -> false
  | Keeper_shutdown_types.Requested _ -> true
;;

let shutdown_turn_settlement entry =
  match Atomic.get entry.shutdown_state with
  | Keeper_shutdown_types.Not_requested -> None
  | Keeper_shutdown_types.Requested settlement -> Some settlement
;;

let settlement_turn_id = function
  | Keeper_shutdown_types.No_interrupted_turn -> None
  | Keeper_shutdown_types.Awaiting_interrupted_turn { turn_id } -> Some turn_id
  | Keeper_shutdown_types.Interrupted_turn_persisted { record; _ }
  | Keeper_shutdown_types.Interrupted_turn_persist_failed { record; _ } ->
    Some record.turn_id
;;

let rec mark_shutdown_turn_pending entry ~turn_id =
  let current = Atomic.get entry.shutdown_state in
  match current with
  | Keeper_shutdown_types.Not_requested -> Error Shutdown_not_requested
  | Keeper_shutdown_types.Requested Keeper_shutdown_types.No_interrupted_turn ->
    let next =
      Keeper_shutdown_types.Requested
        (Keeper_shutdown_types.Awaiting_interrupted_turn { turn_id })
    in
    if Atomic.compare_and_set entry.shutdown_state current next
    then Ok ()
    else mark_shutdown_turn_pending entry ~turn_id
  | Keeper_shutdown_types.Requested settlement ->
    (match settlement_turn_id settlement with
     | Some expected_turn_id when expected_turn_id = turn_id -> Ok ()
     | Some expected_turn_id ->
       Error (Shutdown_turn_mismatch { expected_turn_id; actual_turn_id = turn_id })
     | None -> Error Shutdown_not_requested)
;;

let rec record_shutdown_turn_persisted entry
      (persisted : Keeper_shutdown_types.persisted_interrupted_turn)
  =
  let turn_id = persisted.record.turn_id in
  let current = Atomic.get entry.shutdown_state in
  match current with
  | Keeper_shutdown_types.Not_requested -> Error Shutdown_not_requested
  | Keeper_shutdown_types.Requested
      (Keeper_shutdown_types.Awaiting_interrupted_turn { turn_id = expected_turn_id })
  | Keeper_shutdown_types.Requested
      (Keeper_shutdown_types.Interrupted_turn_persist_failed
         { record = { turn_id = expected_turn_id; _ }; _ }) ->
    if expected_turn_id <> turn_id
    then Error (Shutdown_turn_mismatch { expected_turn_id; actual_turn_id = turn_id })
    else
      let next =
        Keeper_shutdown_types.Requested
          (Keeper_shutdown_types.Interrupted_turn_persisted persisted)
      in
      if Atomic.compare_and_set entry.shutdown_state current next
      then Ok ()
      else record_shutdown_turn_persisted entry persisted
  | Keeper_shutdown_types.Requested
      (Keeper_shutdown_types.Interrupted_turn_persisted { record; _ }) ->
    if record.turn_id = turn_id
    then Ok ()
    else
      Error
        (Shutdown_turn_mismatch
           { expected_turn_id = record.turn_id; actual_turn_id = turn_id })
  | Keeper_shutdown_types.Requested Keeper_shutdown_types.No_interrupted_turn ->
    Error Shutdown_not_requested
;;

let rec record_shutdown_turn_persist_failed entry
      (record : Keeper_shutdown_types.interrupted_turn)
      ~error
  =
  let turn_id = record.turn_id in
  let current = Atomic.get entry.shutdown_state in
  match current with
  | Keeper_shutdown_types.Not_requested -> Error Shutdown_not_requested
  | Keeper_shutdown_types.Requested
      (Keeper_shutdown_types.Awaiting_interrupted_turn { turn_id = expected_turn_id }) ->
    if expected_turn_id <> turn_id
    then Error (Shutdown_turn_mismatch { expected_turn_id; actual_turn_id = turn_id })
    else
      let next =
        Keeper_shutdown_types.Requested
          (Keeper_shutdown_types.Interrupted_turn_persist_failed { record; error })
      in
      if Atomic.compare_and_set entry.shutdown_state current next
      then Ok ()
      else record_shutdown_turn_persist_failed entry record ~error
  | Keeper_shutdown_types.Requested
      (Keeper_shutdown_types.Interrupted_turn_persisted { record = prior; _ })
  | Keeper_shutdown_types.Requested
      (Keeper_shutdown_types.Interrupted_turn_persist_failed
         { record = prior; _ }) ->
    if prior.turn_id = turn_id
    then Error (Shutdown_turn_already_settled { turn_id })
    else
      Error
        (Shutdown_turn_mismatch
           { expected_turn_id = prior.turn_id; actual_turn_id = turn_id })
  | Keeper_shutdown_types.Requested Keeper_shutdown_types.No_interrupted_turn ->
    Error Shutdown_not_requested
;;

let shutdown_state_error_to_string = function
  | Shutdown_not_requested -> "shutdown was not requested"
  | Shutdown_turn_mismatch { expected_turn_id; actual_turn_id } ->
    Printf.sprintf
      "shutdown turn mismatch: expected=%d actual=%d"
      expected_turn_id
      actual_turn_id
  | Shutdown_turn_already_settled { turn_id } ->
    Printf.sprintf "shutdown turn %d is already settled" turn_id
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
  | Keeper_state_machine.Context_measured { context_actions; _ } ->
    Some { tm_captured_at = now; tm_context_actions = context_actions }
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
