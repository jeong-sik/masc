type transition_error =
  | Invalid_phase_transition of {
      from_phase : Engine_types.phase;
      to_phase : Engine_types.phase;
    }
  | Not_in_round_phase of Engine_types.phase
  | Empty_turn_order

val can_transition :
  from_phase:Engine_types.phase ->
  to_phase:Engine_types.phase ->
  bool

val transition_phase :
  Engine_types.room_state ->
  Engine_types.phase ->
  (Engine_types.room_state, transition_error) result

val current_turn_actor : Engine_types.room_state -> string option

val next_turn :
  Engine_types.room_state ->
  (Engine_types.room_state, transition_error) result

val string_of_transition_error : transition_error -> string
