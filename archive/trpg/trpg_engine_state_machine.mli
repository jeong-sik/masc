type transition_error =
  | Invalid_phase_transition of {
      from_phase : Trpg_engine_types.phase;
      to_phase : Trpg_engine_types.phase;
    }
  | Not_in_round_phase of Trpg_engine_types.phase
  | Empty_turn_order

val can_transition :
  from_phase:Trpg_engine_types.phase ->
  to_phase:Trpg_engine_types.phase ->
  bool

val transition_phase :
  Trpg_engine_types.room_state ->
  Trpg_engine_types.phase ->
  (Trpg_engine_types.room_state, transition_error) result

val current_turn_actor : Trpg_engine_types.room_state -> string option

val next_turn :
  Trpg_engine_types.room_state ->
  (Trpg_engine_types.room_state, transition_error) result

val string_of_transition_error : transition_error -> string
