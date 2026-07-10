(** Keeper_transition_audit_types — types and JSON serialization extracted
    from [Keeper_transition_audit] (605 LoC).
    Ring buffer, store, and recording operations remain in the parent.
    @since Keeper 500-line decomposition *)

(* tla-lint: file-scope: structured audit trail types for FSM transitions. *)

type transition_record =
  { snapshot : Keeper_measurement.measurement_snapshot option
  ; events_fired : Keeper_state_machine.event list
  ; selected_event : Keeper_state_machine.event
  ; prev_phase : Keeper_state_machine.phase
  ; new_phase : Keeper_state_machine.phase
  ; transition_outcome : string
  ; wall_clock_at_decision : float
  }

type operator_signal =
  { signal_class : string
  ; severity : string
  ; requires_operator_decision : bool
  ; next_human_action : string option
  ; summary : string
  }

let event_type_of_event event =
  match Keeper_state_machine_json.event_to_json event with
  | `Assoc fields ->
    (match List.assoc_opt "type" fields with
     | Some (`String value) -> value
     | _ -> Keeper_state_machine.event_to_string event)
  | _ -> Keeper_state_machine.event_to_string event
;;

let operator_signal
      ?next_human_action
      ~signal_class
      ~severity
      ~requires_operator_decision
      summary
  =
  { signal_class; severity; requires_operator_decision; next_human_action; summary }
;;

let operator_signal_to_json signal =
  `Assoc
    [ "class", `String signal.signal_class
    ; "severity", `String signal.severity
    ; "requires_operator_decision", `Bool signal.requires_operator_decision
    ; "next_human_action", Json_util.string_opt_to_json signal.next_human_action
    ; "summary", `String signal.summary
    ]
;;

let operator_signal_of_transition (r : transition_record) =
  let open Keeper_state_machine in
  let phase_name = Keeper_state_machine.phase_to_string in
  match r.selected_event with
  | Operator_pause ->
    operator_signal
      ~signal_class:"operator_gate"
      ~severity:"warn"
      ~requires_operator_decision:true
      ~next_human_action:"resume_or_update_policy"
      "keeper paused; operator decision is required"
  | Operator_resume ->
    operator_signal
      ~signal_class:"operator_gate"
      ~severity:"ok"
      ~requires_operator_decision:false
      "keeper resumed by operator"
  | Operator_stop _ | Stop_requested ->
    operator_signal
      ~signal_class:"operator_stop"
      ~severity:"warn"
      ~requires_operator_decision:false
      "keeper stop requested"
  | Restart_budget_exhausted ->
    operator_signal
      ~signal_class:"runtime_alert"
      ~severity:"bad"
      ~requires_operator_decision:true
      ~next_human_action:"inspect_or_restart_keeper"
      "restart budget exhausted; operator must choose recovery"
  | Compact_retry_exhausted ->
    operator_signal
      ~signal_class:"context_management"
      ~severity:"bad"
      ~requires_operator_decision:true
      ~next_human_action:"approve_handoff_or_reduce_context"
      "auto-compact retry budget exhausted"
  | Compaction_failed { reason } ->
    operator_signal
      ~signal_class:"context_management"
      ~severity:"bad"
      ~requires_operator_decision:true
      ~next_human_action:"retry_compaction_or_handoff"
      (Printf.sprintf "compaction failed: %s" reason)
  | Handoff_failed { reason } ->
    operator_signal
      ~signal_class:"handoff"
      ~severity:"bad"
      ~requires_operator_decision:true
      ~next_human_action:"retry_handoff_or_resume"
      (Printf.sprintf "handoff failed: %s" reason)
  | Context_overflow_detected _ ->
    operator_signal
      ~signal_class:"context_management"
      ~severity:"warn"
      ~requires_operator_decision:false
      "context overflow detected; recovery path should continue"
  | _ ->
    (match r.new_phase with
     | Paused ->
       operator_signal
         ~signal_class:"operator_gate"
         ~severity:"warn"
         ~requires_operator_decision:true
         ~next_human_action:"resume_or_update_policy"
         (Printf.sprintf
            "%s -> paused; operator decision is required"
            (phase_name r.prev_phase))
     | Crashed ->
       operator_signal
         ~signal_class:"runtime_alert"
         ~severity:"bad"
         ~requires_operator_decision:true
         ~next_human_action:"inspect_or_restart_keeper"
         "keeper crashed; operator must inspect recovery"
     | Dead ->
       operator_signal
         ~signal_class:"runtime_alert"
         ~severity:"bad"
         ~requires_operator_decision:true
         ~next_human_action:"inspect_or_recreate_keeper"
         "keeper reached dead phase"
     | Zombie ->
       operator_signal
         ~signal_class:"runtime_alert"
         ~severity:"bad"
         ~requires_operator_decision:true
         ~next_human_action:"inspect_or_recreate_keeper"
         "keeper reached zombie phase (terminal structural failure)"
     | Failing ->
       operator_signal
         ~signal_class:"runtime_recovery"
         ~severity:"warn"
         ~requires_operator_decision:false
         "keeper entered failing recovery lane"
     | Overflowed ->
       operator_signal
         ~signal_class:"context_management"
         ~severity:"warn"
         ~requires_operator_decision:false
         "keeper overflowed context and should compact or hand off"
     | Compacting ->
       operator_signal
         ~signal_class:"context_management"
         ~severity:"warn"
         ~requires_operator_decision:false
         "keeper is compacting context"
     | HandingOff ->
       operator_signal
         ~signal_class:"handoff"
         ~severity:"warn"
         ~requires_operator_decision:false
         "keeper handoff is in progress"
     | Draining ->
       operator_signal
         ~signal_class:"operator_stop"
         ~severity:"warn"
         ~requires_operator_decision:false
         "keeper is draining toward stop"
     | Restarting ->
       operator_signal
         ~signal_class:"runtime_recovery"
         ~severity:"warn"
         ~requires_operator_decision:false
         "keeper restart is scheduled"
     | Running when r.prev_phase <> Running ->
       operator_signal
         ~signal_class:"healthy"
         ~severity:"ok"
         ~requires_operator_decision:false
         "keeper recovered to running"
     | Offline | Running | Stopped ->
       operator_signal
         ~signal_class:"healthy"
         ~severity:"ok"
         ~requires_operator_decision:false
         "phase transition observed")
;;

let to_json (r : transition_record) : Yojson.Safe.t =
  let event_type = event_type_of_event r.selected_event in
  let operator_signal = operator_signal_of_transition r in
  `Assoc
    [ ( "snapshot"
      , match r.snapshot with
        | Some s -> Keeper_measurement.measurement_snapshot_to_json s
        | None -> `Null )
    ; "events_fired", `List (List.map Keeper_state_machine_json.event_to_json r.events_fired)
    ; "selected_event", Keeper_state_machine_json.event_to_json r.selected_event
    ; "event_type", `String event_type
    ; "prev_phase", Keeper_state_machine_json.phase_to_json r.prev_phase
    ; "new_phase", Keeper_state_machine_json.phase_to_json r.new_phase
    ; "transition_outcome", `String r.transition_outcome
    ; "operator_signal", operator_signal_to_json operator_signal
    ; "wall_clock_at_decision", `Float r.wall_clock_at_decision
    ]
;;

type completed_turn_outcome =
  | Turn_substantive
  | Turn_failed
  | Turn_gate_rejected

type completed_turn_record =
  { turn_id : int
  ; started_at : float
  ; ended_at : float
  ; outcome : completed_turn_outcome
  }

type turn_fsm_transition_record =
  { turn_fsm_turn_id : int
  ; turn_fsm_prev_state : string
  ; turn_fsm_new_state : string
  ; turn_fsm_action : string
  ; turn_fsm_stop_signaled_before : bool option
  ; turn_fsm_stop_signaled_after : bool option
  ; turn_fsm_wall_clock_at : float
  }

let completed_turn_outcome_to_json = function
  | Turn_substantive -> `String "substantive"
  | Turn_failed -> `String "failed"
  | Turn_gate_rejected -> `String "gate_rejected"
;;

let completed_turn_outcome_of_json = function
  | `String "substantive" -> Some Turn_substantive
  | `String "failed" -> Some Turn_failed
  | `String "gate_rejected" -> Some Turn_gate_rejected
  | _ -> None
;;

let completed_turn_to_json (r : completed_turn_record) : Yojson.Safe.t =
  `Assoc
    [ "turn_id", `Int r.turn_id
    ; "started_at", `Float r.started_at
    ; "ended_at", `Float r.ended_at
    ; "outcome", completed_turn_outcome_to_json r.outcome
    ]
;;

let turn_fsm_transition_to_json (r : turn_fsm_transition_record) : Yojson.Safe.t =
  `Assoc
    [ "turn_id", `Int r.turn_fsm_turn_id
    ; "prev_state", `String r.turn_fsm_prev_state
    ; "new_state", `String r.turn_fsm_new_state
    ; "action", `String r.turn_fsm_action
    ; ( "stop_signaled_before"
      , Json_util.bool_opt_to_json r.turn_fsm_stop_signaled_before )
    ; "stop_signaled_after", Json_util.bool_opt_to_json r.turn_fsm_stop_signaled_after
    ; "wall_clock_at", `Float r.turn_fsm_wall_clock_at
    ]
;;

let completed_turn_of_json = function
  | `Assoc fields ->
    (match
       ( List.assoc_opt "turn_id" fields
       , List.assoc_opt "started_at" fields
       , List.assoc_opt "ended_at" fields
       , List.assoc_opt "outcome" fields )
     with
     | ( Some (`Int turn_id)
       , Some (`Float started_at)
       , Some (`Float ended_at)
       , Some outcome_json ) ->
       (match completed_turn_outcome_of_json outcome_json with
        | Some outcome -> Some { turn_id; started_at; ended_at; outcome }
        | None -> None)
     | ( Some (`Int turn_id)
       , Some (`Int started_at)
       , Some (`Int ended_at)
       , Some outcome_json ) ->
       (match completed_turn_outcome_of_json outcome_json with
        | Some outcome ->
          Some
            { turn_id
            ; started_at = float_of_int started_at
            ; ended_at = float_of_int ended_at
            ; outcome
            }
        | None -> None)
     | _ -> None)
  | _ -> None
;;

(* ================================================================ *)
(* In-memory ring buffer for recent transitions                     *)
