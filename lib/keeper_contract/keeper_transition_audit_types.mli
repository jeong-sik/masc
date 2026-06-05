(** Structured transition audit record types and JSON serializers. *)

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

val event_type_of_event : Keeper_state_machine.event -> string

val operator_signal
  :  ?next_human_action:string
  -> signal_class:string
  -> severity:string
  -> requires_operator_decision:bool
  -> string
  -> operator_signal

val operator_signal_to_json : operator_signal -> Yojson.Safe.t
val operator_signal_of_transition : transition_record -> operator_signal
val to_json : transition_record -> Yojson.Safe.t

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

val completed_turn_outcome_to_json : completed_turn_outcome -> Yojson.Safe.t
val completed_turn_outcome_of_json : Yojson.Safe.t -> completed_turn_outcome option
val completed_turn_to_json : completed_turn_record -> Yojson.Safe.t
val turn_fsm_transition_to_json : turn_fsm_transition_record -> Yojson.Safe.t
val completed_turn_of_json : Yojson.Safe.t -> completed_turn_record option
