(** Structured transition audit record types and JSON serializers. *)

type transition_record =
  { events_fired : Keeper_state_machine.event list
  ; selected_event : Keeper_state_machine.event
  ; prev_phase : Keeper_state_machine.phase
  ; new_phase : Keeper_state_machine.phase
  ; transition_outcome : string
  ; wall_clock_at_decision : float
  }

val to_json : transition_record -> Yojson.Safe.t

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

val completed_turn_to_json : completed_turn_record -> Yojson.Safe.t
val turn_fsm_transition_to_json : turn_fsm_transition_record -> Yojson.Safe.t
val turn_fsm_transition_of_json :
  Yojson.Safe.t -> (turn_fsm_transition_record, string) result
(** Strict inverse of {!turn_fsm_transition_to_json}. All current fields are
    required; duplicate, unknown, missing, or ill-typed fields fail closed. *)

val completed_turn_of_json : Yojson.Safe.t -> completed_turn_record option
