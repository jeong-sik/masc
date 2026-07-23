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

let event_type_of_event event =
  match Keeper_state_machine_json.event_to_json event with
  | `Assoc fields ->
    (match List.assoc_opt "type" fields with
     | Some (`String value) -> value
     | _ -> Keeper_state_machine.event_to_string event)
  | _ -> Keeper_state_machine.event_to_string event
;;

let to_json (r : transition_record) : Yojson.Safe.t =
  let event_type = event_type_of_event r.selected_event in
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
    ; "wall_clock_at_decision", `Float r.wall_clock_at_decision
    ]
;;

type completed_turn_outcome =
  | Turn_substantive
  | Turn_failed

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
;;

let completed_turn_outcome_of_json = function
  | `String "substantive" -> Some Turn_substantive
  | `String "failed" -> Some Turn_failed
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
